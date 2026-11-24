// ==============================================================================
// FILE: hdl/mr4/lib/mr4_tile.dart
// Hierarchical Reusable ASIC Compute Tile (`mr4_tile`, Track D.4) and
// Flat-Frequency Multi-Tile ASIC Cluster (`Mr4AsicCluster` / `mr4_quad_top`).
//
// Architectural Properties:
//   - ONE identical hardened `mr4_tile` macro is instantiated N times (4, 8, ...).
//   - Tile identity comes purely from top-level static `tile_id` strap pins
//     (zero per-core RTL divergence -> 1x harden, Nx stamp-out).
//   - Every inter-tile Lean Ring wire is strictly registered at the tile output
//     boundary (`RegisteredNocHop` FF Q -> wire -> next tile D input), with
//     purely registered backpressure (`~skidValidQ` / `~rxFull` / `~mboxValidQ`)
//     -> ZERO combinational loops and FLAT Fmax independent of core count!
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'asic_top.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'memory_factory.dart';
import 'noc_cache_wrapper.dart';
import 'noc_router.dart';
import 'uart.dart';

/// Reusable self-contained MicroRISC4 ASIC Compute Tile (`mr4_tile`).
///
/// Bundles:
///   - 4-stage pipelined `CpuCore` (1-cycle ASIC SRAM/Flop + `AsicBootRom`,
///     Hardware `EPC`/`ERET`, Async Trap 14, dynamic `core_id_in` strap)
///   - `NocRouterNi` (`0x0020`–`0x002A` Lean Ring NI, pure ASIC flop RX FIFO)
///   - `RegisteredNocHop` perimeter ring stage (transit-priority, zero loops)
///   - `Uart` (used by Tile 0; workers tie `uart_rxd = 1`)
class Mr4Tile extends Module {
  late final CpuCore cpu;
  final int numCores;
  final int coreIdWidth;
  final int nocFifoDepth;
  final int uartDivisor;

  Mr4Tile({
    required Logic clk,
    required Logic rstN,
    required Logic tileId,
    required Logic uartRxd,
    required Logic ringInValid,
    required Logic ringInType,
    required Logic ringInSrc,
    required Logic ringInDst,
    required Logic ringInPayload,
    required Logic ringOutReady,
    this.numCores = 4,
    this.nocFifoDepth = 16,
    CpuConfig? config,
    int? uartDivisor,
    super.name = 'mr4_tile',
  })  : coreIdWidth = NocRouterNi.idWidthForCores(numCores),
        uartDivisor = uartDivisor ??
            AsicTop.defaultUartDivisor((config ?? const CpuConfig(clkFreqMhz: 100)).clkFreqMhz) {
    final baseCfg = config ??
        const CpuConfig(
          coreId: 0,
          enableCpuid: true,
          enableUart: true,
          enableCrossTraps: true,
          enableEpc: true,
          enableMathAccel: false,
          enableSpi: false,
          enableNoc: true,
          enableSdramCache: false,
          isPipelined: true,
          memReadLatency: 1,
          memoryTarget: MemoryTarget.asicFlop,
          clkFreqMhz: 100,
          trapTableBase: 0x0100,
          memWords: 1024,
        );

    assert(baseCfg.memoryTarget != MemoryTarget.fpgaEcp5,
        'Mr4Tile requires MemoryTarget.asicSram or MemoryTarget.asicFlop');
    assert(numCores >= 2, 'Mr4Tile cluster requires numCores >= 2');

    // External hardened macro pins
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    tileId = addInput('tile_id', tileId, width: coreIdWidth);
    uartRxd = addInput('uart_rxd', uartRxd);

    ringInValid = addInput('ring_in_valid', ringInValid);
    ringInType = addInput('ring_in_type', ringInType);
    ringInSrc = addInput('ring_in_src', ringInSrc, width: coreIdWidth);
    ringInDst = addInput('ring_in_dst', ringInDst, width: coreIdWidth);
    ringInPayload = addInput('ring_in_payload', ringInPayload,
        width: MicroRISC4Constants.dataWidth);
    ringOutReady = addInput('ring_out_ready', ringOutReady);

    final uartTxdOut = addOutput('uart_txd');
    final debugPcOut = addOutput('debug_pc', width: 16);
    final ringInReadyOut = addOutput('ring_in_ready');
    final ringOutValidOut = addOutput('ring_out_valid');
    final ringOutTypeOut = addOutput('ring_out_type');
    final ringOutSrcOut = addOutput('ring_out_src', width: coreIdWidth);
    final ringOutDstOut = addOutput('ring_out_dst', width: coreIdWidth);
    final ringOutPayloadOut =
        addOutput('ring_out_payload', width: MicroRISC4Constants.dataWidth);

    final sysReset = ~rstN;

    // UART RX/TX MMIO latches
    final uartRxdLatch = Logic(name: 'uart_rxd_latch', width: 8);
    final uartRxValid = Logic(name: 'uart_rx_valid');
    final txBusyLatch = Logic(name: 'tx_busy_latch');

    final cpuRxData = [uartRxValid, Const(0, width: 7), uartRxdLatch].swizzle();
    final cpuTxStatus =
        mux(txBusyLatch, Const(1, width: 16), Const(0, width: 16));

    // Late-bound NoC feedback wires into CpuCore
    final nocRdataBus = Logic(name: 'noc_rdata_bus', width: 16);
    final nocTrapReq = Logic(name: 'noc_trap_req');

    final effectiveConfig = CpuConfig(
      coreId: 0, // Runtime identity supplied by strapped `tile_id` input port!
      enableCpuid: true,
      enableCpuInfo: baseCfg.enableCpuInfo,
      enableUart: true,
      enableCrossTraps: true,
      enableEpc: true,
      enableShadowRegs: baseCfg.enableShadowRegs,
      enableMathAccel: baseCfg.enableMathAccel,
      enableFpu: false,
      enableSpi: false,
      enableNoc: true,
      enableSdramCache: false,
      isPipelined: true,
      memReadLatency: baseCfg.memReadLatency,
      memoryTarget: baseCfg.memoryTarget,
      bootRomBase: baseCfg.bootRomBase,
      bootRomWords: baseCfg.bootRomWords,
      sramMacroName: baseCfg.sramMacroName,
      clkFreqMhz: baseCfg.clkFreqMhz,
      cpuVersionMajor: baseCfg.cpuVersionMajor,
      cpuVersionMinor: baseCfg.cpuVersionMinor,
      cpuCaps2: baseCfg.cpuCaps2,
      nocChannels: 1,
      nocFifoDepth: nocFifoDepth,
      trapTableBase: baseCfg.trapTableBase,
      memWords: baseCfg.memWords,
    );

    cpu = CpuCore(
      clk: clk,
      rstN: rstN,
      mmioRxData: cpuRxData,
      mmioTxStatus: cpuTxStatus,
      extTrapReq: nocTrapReq,
      extTrapNum: Const(14, width: 4),
      nocRdata: nocRdataBus,
      coreIdIn: tileId,
      config: effectiveConfig,
      name: 'cpu_core',
    );

    // Fast MMIO range decode for Lean Ring NI (0x0020..0x002A)
    final busAddr = cpu.portBAddr;
    final busWdata = cpu.portBWdata;
    final busWe = cpu.portBWe;
    final busEn = cpu.portBEn;
    final inNocRange = busAddr.slice(15, 4).eq(Const(0x002, width: 12)) &
        busAddr.slice(3, 0).lte(Const(0xA, width: 4));

    // Incoming ring flit local-vs-transit classification
    final inIsLocal = ringInDst.eq(tileId);
    final ejectValid = ringInValid & inIsLocal;
    final transitValid = ringInValid & (~inIsLocal);

    final niOutReady = Logic(name: 'ni_out_ready');
    final ni = NocRouterNi(
      clk: clk,
      reset: sysReset,
      mmioAddr: busAddr,
      mmioWdata: busWdata,
      mmioWe: busEn & busWe & inNocRange,
      mmioRe: busEn & (~busWe) & inNocRange,
      netInValid: ejectValid,
      netInType: ringInType,
      netInSrcCore: ringInSrc,
      netInPayload: ringInPayload,
      netOutReady: niOutReady,
      coreId: 0,
      numCores: numCores,
      fifoDepth: nocFifoDepth,
      memoryTarget: baseCfg.memoryTarget,
      name: 'noc_ni',
    );

    nocRdataBus <= ni.output('mmioRdata');

    // One-shot-per-doorbell MBOX cross-trap gate (matches Ulx3sTop):
    // holds ext_trap_req high until CpuCore acknowledges via extTrapAck, then
    // masks re-entry until software drains NOC_MBOX_DATA (mboxReq -> 0).
    final mboxReq = ni.output('mboxTrapReq');
    final mboxTrapInFlightQ = Logic(name: 'mbox_trap_inflight_q');
    nocTrapReq <= mboxReq & (~mboxTrapInFlightQ);
    Sequential(clk, reset: sysReset, resetValues: {
      mboxTrapInFlightQ: 0,
    }, [
      If(~mboxReq, then: [
        mboxTrapInFlightQ < 0,
      ], orElse: [
        If(cpu.extTrapAck, then: [
          mboxTrapInFlightQ < 1,
        ]),
      ]),
    ]);

    final niOutValid = ni.output('netOutValid');
    final niOutType = ni.output('netOutType');
    final niOutDst = ni.output('netOutDstCore');
    final niOutPayload = ni.output('netOutPayload');
    final niInReady = ni.output('netInReady');

    // Transit-priority mux into tile's registered perimeter ring hop
    final hopInValid = transitValid | niOutValid;
    final hopInType = mux(transitValid, ringInType, niOutType);
    final hopInSrc = mux(transitValid, ringInSrc, tileId);
    final hopInDst = mux(transitValid, ringInDst, niOutDst);
    final hopInPayload = mux(transitValid, ringInPayload, niOutPayload);

    final txHop = RegisteredNocHop(
      clk: clk,
      reset: sysReset,
      inValid: hopInValid,
      inType: hopInType,
      inSrcCore: hopInSrc,
      inDstCore: hopInDst,
      inPayload: hopInPayload,
      coreIdWidth: coreIdWidth,
      outReady: ringOutReady,
      name: 'ring_hop',
    );

    final hopInReady = txHop.output('inReady');
    // Local NI can inject whenever the output hop has room AND no transit flit is active
    niOutReady <= hopInReady & (~transitValid);
    // Registered backpressure back to upstream neighbor (zero combinational loop)
    ringInReadyOut <= mux(inIsLocal, niInReady, hopInReady);

    // Strictly registered perimeter ring outputs (straight from RegisteredNocHop FFs)
    ringOutValidOut <= txHop.output('outValid');
    ringOutTypeOut <= txHop.output('outType');
    ringOutSrcOut <= txHop.output('outSrcCore');
    ringOutDstOut <= txHop.output('outDstCore');
    ringOutPayloadOut <= txHop.output('outPayload');

    // Tile UART (active on Tile 0; workers tie uart_rxd = 1)
    final uart = Uart(
      clk: clk,
      reset: sysReset,
      serialRxd: uartRxd,
      txd: cpu.txData,
      txdStrobe: cpu.txStrobe,
      divisor: this.uartDivisor,
    );
    uartTxdOut <= uart.serialTxd;
    debugPcOut <= cpu.debugPc;

    Sequential(clk, reset: sysReset, resetValues: {
      uartRxValid: 0,
      uartRxdLatch: 0,
    }, [
      If(uart.rxdStrobe, then: [
        uartRxdLatch < uart.rxd,
        uartRxValid < 1,
      ], orElse: [
        If(cpu.rxPop, then: [
          uartRxValid < 0,
        ]),
      ]),
    ]);

    Sequential(clk, reset: sysReset, resetValues: {
      txBusyLatch: 0,
    }, [
      If(cpu.txStrobe, then: [
        txBusyLatch < 1,
      ], orElse: [
        If(uart.txdReady, then: [
          txBusyLatch < 0,
        ]),
      ]),
    ]);
  }

  @override
  String get definitionName => 'mr4_tile';

  Logic get uartTxd => output('uart_txd');
  Logic get debugPc => output('debug_pc');
  Logic get ringInReady => output('ring_in_ready');
  Logic get ringOutValid => output('ring_out_valid');
  Logic get ringOutType => output('ring_out_type');
  Logic get ringOutSrc => output('ring_out_src');
  Logic get ringOutDst => output('ring_out_dst');
  Logic get ringOutPayload => output('ring_out_payload');
}

/// Port-exact `(* blackbox *)` SystemVerilog stub for hardened `mr4_tile` macros.
/// Used by hierarchical top-level synthesis (`mr4_quad_top`) when linking against
/// ORFS-generated `mr4_tile.lef`, `mr4_tile.lib`, and `6_final.gds`.
class Mr4TileBlackbox extends Module with SystemVerilog {
  final int coreIdWidth;

  Mr4TileBlackbox({
    required Logic clk,
    required Logic rstN,
    required Logic tileId,
    required Logic uartRxd,
    required Logic ringInValid,
    required Logic ringInType,
    required Logic ringInSrc,
    required Logic ringInDst,
    required Logic ringInPayload,
    required Logic ringOutReady,
    required this.coreIdWidth,
    super.name = 'mr4_tile_inst',
  }) : super(definitionName: 'mr4_tile') {
    addInput('clk', clk);
    addInput('rst_n', rstN);
    addInput('tile_id', tileId, width: coreIdWidth);
    addInput('uart_rxd', uartRxd);
    addInput('ring_in_valid', ringInValid);
    addInput('ring_in_type', ringInType);
    addInput('ring_in_src', ringInSrc, width: coreIdWidth);
    addInput('ring_in_dst', ringInDst, width: coreIdWidth);
    addInput('ring_in_payload', ringInPayload,
        width: MicroRISC4Constants.dataWidth);
    addInput('ring_out_ready', ringOutReady);

    addOutput('uart_txd');
    addOutput('debug_pc', width: 16);
    addOutput('ring_in_ready');
    addOutput('ring_out_valid');
    addOutput('ring_out_type');
    addOutput('ring_out_src', width: coreIdWidth);
    addOutput('ring_out_dst', width: coreIdWidth);
    addOutput('ring_out_payload', width: MicroRISC4Constants.dataWidth);
  }

  @override
  String get definitionName => 'mr4_tile';

  Logic get uartTxd => output('uart_txd');
  Logic get debugPc => output('debug_pc');
  Logic get ringInReady => output('ring_in_ready');
  Logic get ringOutValid => output('ring_out_valid');
  Logic get ringOutType => output('ring_out_type');
  Logic get ringOutSrc => output('ring_out_src');
  Logic get ringOutDst => output('ring_out_dst');
  Logic get ringOutPayload => output('ring_out_payload');

  @override
  String definitionVerilog(String definitionType) {
    final idRange = coreIdWidth > 1 ? '[${coreIdWidth - 1}:0] ' : '';
    return '''
(* blackbox *)
module mr4_tile (
  input  logic clk,
  input  logic rst_n,
  input  logic ${idRange}tile_id,
  input  logic uart_rxd,
  input  logic ring_in_valid,
  input  logic ring_in_type,
  input  logic ${idRange}ring_in_src,
  input  logic ${idRange}ring_in_dst,
  input  logic [15:0] ring_in_payload,
  input  logic ring_out_ready,
  output logic uart_txd,
  output logic [15:0] debug_pc,
  output logic ring_in_ready,
  output logic ring_out_valid,
  output logic ring_out_type,
  output logic ${idRange}ring_out_src,
  output logic ${idRange}ring_out_dst,
  output logic [15:0] ring_out_payload
);
endmodule
''';
  }
}

/// Hierarchical Multi-Core Tiled ASIC Top (`mr4_quad_top` by default for 4 tiles).
///
/// Instantiates `numTiles` identical `mr4_tile` blocks connected purely by
/// registered point-to-point neighbor ring links (`Tile[i] -> Tile[(i+1)%N]`)
/// with a shared 2-FF chip-level reset synchronizer and static `tile_id` straps.
///
/// Set [useTileBlackbox] to `true` when generating hierarchical ORFS top-level
/// SystemVerilog that links against a pre-hardened `mr4_tile` macro (`LEF/LIB/GDS`),
/// or `false` for full flat RTL simulation in ROHD/Verilator.
class Mr4AsicCluster extends Module {
  final int numTiles;
  final int coreIdWidth;
  final bool useTileBlackbox;
  final List<Mr4Tile> tiles = [];

  Mr4AsicCluster({
    required Logic clk,
    required Logic rstN,
    required Logic uartRxd,
    this.numTiles = 4,
    int nocFifoDepth = 16,
    CpuConfig? tileConfig,
    int? uartDivisor,
    this.useTileBlackbox = false,
    super.name = 'mr4_quad_top',
  }) : coreIdWidth = NocRouterNi.idWidthForCores(numTiles) {
    assert(numTiles >= 2, 'Mr4AsicCluster requires numTiles >= 2');

    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    uartRxd = addInput('uart_rxd', uartRxd);

    final uartTxdOut = addOutput('uart_txd');
    final debugPcOut = addOutput('debug_pc', width: 16);

    // Chip-level 2-FF reset synchronizer so all tiles release reset simultaneously
    final rstSync0 = Logic(name: 'rst_sync_0');
    final rstSync1 = Logic(name: 'rst_sync_1');
    Sequential(clk, [
      rstSync0 < rstN,
      rstSync1 < rstSync0,
    ]);
    final sysRstN = rstSync1;

    // Inter-tile registered neighbor ring wires (Tile[i] -> Tile[(i+1)%N])
    final linkValid =
        List.generate(numTiles, (i) => Logic(name: 'ring_${i}_valid'));
    final linkType =
        List.generate(numTiles, (i) => Logic(name: 'ring_${i}_type'));
    final linkSrc = List.generate(
        numTiles, (i) => Logic(name: 'ring_${i}_src', width: coreIdWidth));
    final linkDst = List.generate(
        numTiles, (i) => Logic(name: 'ring_${i}_dst', width: coreIdWidth));
    final linkPayload = List.generate(
        numTiles,
        (i) => Logic(
            name: 'ring_${i}_payload', width: MicroRISC4Constants.dataWidth));
    final linkReady =
        List.generate(numTiles, (i) => Logic(name: 'ring_${i}_ready'));

    for (var i = 0; i < numTiles; i++) {
      final prev = (i + numTiles - 1) % numTiles;
      final tileIdStrap = Const(i, width: coreIdWidth);
      final tileRxd = (i == 0) ? uartRxd : Const(1);

      if (useTileBlackbox) {
        final bb = Mr4TileBlackbox(
          clk: clk,
          rstN: sysRstN,
          tileId: tileIdStrap,
          uartRxd: tileRxd,
          ringInValid: linkValid[prev],
          ringInType: linkType[prev],
          ringInSrc: linkSrc[prev],
          ringInDst: linkDst[prev],
          ringInPayload: linkPayload[prev],
          ringOutReady: linkReady[i],
          coreIdWidth: coreIdWidth,
          name: 'u_tile_$i',
        );
        linkReady[prev] <= bb.ringInReady;
        linkValid[i] <= bb.ringOutValid;
        linkType[i] <= bb.ringOutType;
        linkSrc[i] <= bb.ringOutSrc;
        linkDst[i] <= bb.ringOutDst;
        linkPayload[i] <= bb.ringOutPayload;
        if (i == 0) {
          uartTxdOut <= bb.uartTxd;
          debugPcOut <= bb.debugPc;
        }
      } else {
        final tile = Mr4Tile(
          clk: clk,
          rstN: sysRstN,
          tileId: tileIdStrap,
          uartRxd: tileRxd,
          ringInValid: linkValid[prev],
          ringInType: linkType[prev],
          ringInSrc: linkSrc[prev],
          ringInDst: linkDst[prev],
          ringInPayload: linkPayload[prev],
          ringOutReady: linkReady[i],
          numCores: numCoresForTile(numTiles),
          nocFifoDepth: nocFifoDepth,
          config: tileConfig,
          uartDivisor: uartDivisor,
          name: 'u_tile_$i',
        );
        tiles.add(tile);
        linkReady[prev] <= tile.ringInReady;
        linkValid[i] <= tile.ringOutValid;
        linkType[i] <= tile.ringOutType;
        linkSrc[i] <= tile.ringOutSrc;
        linkDst[i] <= tile.ringOutDst;
        linkPayload[i] <= tile.ringOutPayload;
        if (i == 0) {
          uartTxdOut <= tile.uartTxd;
          debugPcOut <= tile.debugPc;
        }
      }
    }
  }

  @override
  String get definitionName => name;

  static int numCoresForTile(int numTiles) => numTiles;
}

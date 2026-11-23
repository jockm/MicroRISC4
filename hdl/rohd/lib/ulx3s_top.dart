// ==============================================================================
// FILE: hdl/rohd/lib/ulx3s_top.dart
// ULX3S-85F Board Top-Level Module Wrapper (Intel ROHD)
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'ecp5_pll.dart';
import 'noc_cache_wrapper.dart';
import 'uart.dart';

class Ulx3sTop extends Module {
  late final CpuCore cpu;
  late final List<CpuCore> cores;

  Ulx3sTop({
    required Logic clk25mhz,
    required Logic btnPwrN,
    required Logic ftdiTxd,
    CpuConfig config = const CpuConfig(
      coreId: 0,
      enableCpuid: false,
      enableUart: true,
      enableCrossTraps: false,
      enableMathAccel: false,
      trapTableBase: 0x0100,
      memWords: 65536,
    ),
    int nocCores = 0,
    int workerMemWords = 2048,
    int mboxTrapVec = 0x0E,
    int resetHoldBits = 2,
    String? initHexFile = 'system_image.hex',
    String? workerInitHexFile,
    Map<int, int>? initialMemory,
    List<Map<int, int>?>? workerInitialMemories,
    super.name = 'ulx3s_top',
  }) {
    clk25mhz = addInput('clk_25mhz', clk25mhz);
    btnPwrN = addInput('btn_pwr_n', btnPwrN);
    ftdiTxd = addInput('ftdi_txd', ftdiTxd);

    final ftdiRxd = addOutput('ftdi_rxd');
    final wifiGpio0 = addOutput('wifi_gpio0');
    final led = addOutput('led', width: 8);

    // Keep onboard ESP32 out of bootloader/reset interference
    wifiGpio0 <= Const(1);

    // 25 MHz -> 48 MHz PLL for exact 3 Mbaud UART (divisor = 16)
    final pll = Ecp5Pll25To24(clkIn: clk25mhz);
    final clk48mhz = pll.clkOut;

    // 2-FF synchronizer + power-on / button-debounce reset hold counter.
    // Raw async input (btnPwrN & pll.locked) only feeds rstSync0 so the
    // CPU/UART/NoC domain receives a clean synchronous single-register reset.
    final rawRstN = btnPwrN & pll.locked;
    final rstSync0 = Logic(name: 'rst_sync_0');
    final rstSync1 = Logic(name: 'rst_sync_1');
    final rstHoldCnt = Logic(name: 'rst_hold_cnt', width: resetHoldBits);
    final sysRstN = Logic(name: 'sys_rst_n');
    final rstHoldMax = Const((1 << resetHoldBits) - 1, width: resetHoldBits);

    Sequential(clk48mhz, [
      rstSync0 < rawRstN,
      rstSync1 < rstSync0,
      If(~rstSync1, then: [
        rstHoldCnt < 0,
        sysRstN < 0,
      ], orElse: [
        If(rstHoldCnt.eq(rstHoldMax), then: [
          sysRstN < 1,
        ], orElse: [
          rstHoldCnt < rstHoldCnt + 1,
          sysRstN < 0,
        ]),
      ]),
    ]);
    final uartReset = ~sysRstN;

    // UART MMIO Registers
    final uartRxdLatch = Logic(name: 'uart_rxd_latch', width: 8);
    final uartRxValid = Logic(name: 'uart_rx_valid');
    final txBusyLatch = Logic(name: 'tx_busy_latch');

    final useNoc = nocCores >= 2;
    final coreCount = useNoc ? nocCores : 1;
    final effectiveConfig = useNoc
        ? CpuConfig(
            coreId: config.coreId,
            enableCpuid: true,
            enableUart: config.enableUart,
            enableCrossTraps: config.enableCrossTraps,
            enableShadowRegs: config.enableShadowRegs,
            enableMathAccel: config.enableMathAccel,
            enableSpi: config.enableSpi,
            enableNoc: true,
            nocChannels: config.nocChannels,
            nocFifoDepth: config.nocFifoDepth,
            trapTableBase: config.trapTableBase,
            memWords: config.memWords,
          )
        : config;

    final cpuRxData = Logic(name: 'cpu_rx_data', width: 16);
    final cpuTxStatus = Logic(name: 'cpu_tx_status', width: 16);
    final nocRdataPerCore = List.generate(
      coreCount,
      (i) => Logic(name: 'noc_rdata_core$i', width: 16),
    );
    final coreExtTrapReq = List.generate(
      coreCount,
      (i) => Logic(name: 'core_ext_trap_req_$i'),
    );
    final mboxTrapVecConst = Const(mboxTrapVec & 0x0F, width: 4);

    cpuRxData <= [uartRxValid, Const(0, width: 7), uartRxdLatch].swizzle();
    cpuTxStatus <= mux(txBusyLatch, Const(1, width: 16), Const(0, width: 16));

    // Core 0: Primary OS / UART / Monitor core
    cpu = CpuCore(
      clk: clk48mhz,
      rstN: sysRstN,
      mmioRxData: cpuRxData,
      mmioTxStatus: cpuTxStatus,
      extTrapReq: (useNoc && effectiveConfig.enableCrossTraps)
          ? coreExtTrapReq[0]
          : null,
      extTrapNum: (useNoc && effectiveConfig.enableCrossTraps)
          ? mboxTrapVecConst
          : null,
      nocRdata: useNoc ? nocRdataPerCore[0] : null,
      config: effectiveConfig,
      initHexFile: initHexFile,
      initialMemory: initialMemory,
      name: 'cpu_core',
    );

    final instantiatedCores = <CpuCore>[cpu];

    // Worker Cores 1..N-1 (instantiated whenever nocCores >= 2)
    if (useNoc) {
      for (var c = 1; c < nocCores; c++) {
        final workerCfg = CpuConfig(
          coreId: c,
          enableCpuid: true,
          enableUart: false,
          enableCrossTraps: effectiveConfig.enableCrossTraps,
          enableShadowRegs: effectiveConfig.enableShadowRegs,
          enableMathAccel: effectiveConfig.enableMathAccel,
          enableSpi: false,
          enableNoc: true,
          nocChannels: effectiveConfig.nocChannels,
          nocFifoDepth: effectiveConfig.nocFifoDepth,
          trapTableBase: effectiveConfig.trapTableBase,
          memWords: workerMemWords,
        );
        final workerMem =
            (workerInitialMemories != null && (c - 1) < workerInitialMemories.length)
                ? workerInitialMemories[c - 1]
                : null;
        instantiatedCores.add(
          CpuCore(
            clk: clk48mhz,
            rstN: sysRstN,
            extTrapReq: effectiveConfig.enableCrossTraps
                ? coreExtTrapReq[c]
                : null,
            extTrapNum: effectiveConfig.enableCrossTraps
                ? mboxTrapVecConst
                : null,
            nocRdata: nocRdataPerCore[c],
            config: workerCfg,
            initHexFile: workerMem != null ? null : workerInitHexFile,
            initialMemory: workerMem,
            name: 'cpu_worker_$c',
          ),
        );
      }
    }
    cores = List.unmodifiable(instantiatedCores);

    final uart = Uart(
      clk: clk48mhz,
      reset: uartReset,
      serialRxd: ftdiTxd,
      txd: cpu.txData,
      txdStrobe: cpu.txStrobe,
      divisor: 16,
    );

    ftdiRxd <= uart.serialTxd;

    if (useNoc) {
      final mmioAddr = <Logic>[];
      final mmioWdata = <Logic>[];
      final mmioWe = <Logic>[];
      final mmioRe = <Logic>[];
      final netOutReady = List.generate(nocCores, (i) => Const(1));

      for (var c = 0; c < nocCores; c++) {
        final core = cores[c];
        final busEn = core.output('port_b_en_out');
        final busWe = core.output('port_b_we_out');
        final busAddr = core.output('port_b_addr_out');
        final busWdata = core.output('port_b_wdata_out');
        final inNocRange =
            busAddr.gte(Const(MiniRISC4Constants.addrNocTxData, width: 16)) &
                busAddr.lte(Const(MiniRISC4Constants.addrNocInfo, width: 16));
        mmioAddr.add(busAddr);
        mmioWdata.add(busWdata);
        mmioWe.add(busEn & busWe & inNocRange);
        mmioRe.add(busEn & (~busWe) & inNocRange);
      }

      final nocFabric = NocMultiCoreCacheWrapper(
        clk: clk48mhz,
        reset: uartReset,
        mmioAddr: mmioAddr,
        mmioWdata: mmioWdata,
        mmioWe: mmioWe,
        mmioRe: mmioRe,
        netOutReady: netOutReady,
        srvInjectValid: Const(0),
        srvInjectType: Const(0),
        srvInjectSrcCore: Const(0, width: 8),
        srvInjectSrcCh: Const(0, width: 8),
        srvInjectDstCore: Const(0, width: 8),
        srvInjectDstCh: Const(0, width: 8),
        srvInjectPayload: Const(0, width: MiniRISC4Constants.dataWidth),
        numCores: nocCores,
        serverCoreId: 0,
        numChannels: effectiveConfig.nocChannels,
        fifoDepth: effectiveConfig.nocFifoDepth,
        name: 'ulx3s_noc_fabric',
      );

      for (var c = 0; c < nocCores; c++) {
        nocRdataPerCore[c] <= nocFabric.output('mmioRdataReg_$c');
        if (effectiveConfig.enableCrossTraps) {
          // One-shot-per-burst MBOX cross-trap gate: holds ext_trap_req high
          // until CpuCore reaches ST_EXEC and acknowledges (ext_trap_ack),
          // then masks re-entry until software drains the MBOX FIFO.
          final mboxReq = nocFabric.output('mboxTrapReq_$c');
          final inFlightQ = Logic(name: 'mbox_trap_inflight_$c');
          coreExtTrapReq[c] <= mboxReq & (~inFlightQ);
          Sequential(clk48mhz, reset: uartReset, resetValues: {
            inFlightQ: 0,
          }, [
            If(~mboxReq, then: [
              inFlightQ < 0,
            ], orElse: [
              If(cores[c].extTrapAck, then: [
                inFlightQ < 1,
              ]),
            ]),
          ]);
        } else {
          coreExtTrapReq[c] <= Const(0);
        }
      }

      led <= [
        pll.locked,
        nocFabric.output('mboxTrapReq_0'),
        cpu.debugPc.slice(5, 0),
      ].swizzle();
    } else {
      nocRdataPerCore[0] <= Const(0, width: 16);
      coreExtTrapReq[0] <= Const(0);
      led <= [pll.locked, cpu.debugPc.slice(6, 0)].swizzle();
    }

    Sequential(clk48mhz, reset: uartReset, resetValues: {
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

    Sequential(clk48mhz, reset: uartReset, resetValues: {
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

  Logic get ftdiRxd => output('ftdi_rxd');
  Logic get wifiGpio0 => output('wifi_gpio0');
  Logic get led => output('led');
}

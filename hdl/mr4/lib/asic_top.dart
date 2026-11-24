// ==============================================================================
// FILE: hdl/mr4/lib/asic_top.dart
// Clean Chip-Level ASIC Top Module (`mr4_asic_top`, Track D.2)
//
// Zero FPGA/ECP5 primitives (no EHXPLLL, ODDRX1F, syn_useioff, ram_style,
// $readmemh, LEDs, buttons, or board-specific wiring). Shares CpuCore and Uart
// directly with the ULX3S FPGA flow while selecting ASIC SRAM/Flop + Boot ROM
// via MemoryFactory.
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'memory_factory.dart';
import 'uart.dart';

class AsicTop extends Module {
  late final CpuCore cpu;
  final bool hasSpi;
  final int uartDivisor;

  AsicTop({
    required Logic clk,
    required Logic rstN,
    required Logic uartRxd,
    Logic? spiMiso,
    CpuConfig? config,
    int? uartDivisor,
    super.name = 'mr4_asic_top',
  })  : hasSpi = (config ?? const CpuConfig()).enableSpi,
        uartDivisor = uartDivisor ?? _defaultUartDivisor((config ?? const CpuConfig()).clkFreqMhz) {
    final baseCfg = config ??
        const CpuConfig(
          coreId: 0,
          enableCpuid: false,
          enableUart: true,
          enableCrossTraps: false,
          enableMathAccel: false,
          enableSpi: false,
          enableNoc: false,
          enableSdramCache: false,
          isPipelined: true,
          memReadLatency: 1,
          memoryTarget: MemoryTarget.asicSram,
          clkFreqMhz: 100,
          trapTableBase: 0x0100,
          memWords: 2048,
        );

    assert(baseCfg.memoryTarget != MemoryTarget.fpgaEcp5,
        'AsicTop requires MemoryTarget.asicSram or MemoryTarget.asicFlop');
    assert(this.uartDivisor >= 4 && (this.uartDivisor % 4) == 0,
        'uartDivisor must be >= 4 and a multiple of 4 for 4x UART RX oversampling');

    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    uartRxd = addInput('uart_rxd', uartRxd);
    final uartTxd = addOutput('uart_txd');
    final debugPcOut = addOutput('debug_pc', width: 16);

    final Logic? spiMisoIn =
        hasSpi ? addInput('spi_miso', spiMiso ?? Const(1)) : null;
    final Logic? spiSckOut = hasSpi ? addOutput('spi_sck') : null;
    final Logic? spiMosiOut = hasSpi ? addOutput('spi_mosi') : null;
    final Logic? spiCsNOut = hasSpi ? addOutput('spi_cs_n') : null;

    // 2-FF reset synchronizer: async/external rst_n -> glitch-free synchronous sysRstN
    final rstSync0 = Logic(name: 'rst_sync_0');
    final rstSync1 = Logic(name: 'rst_sync_1');
    Sequential(clk, [
      rstSync0 < rstN,
      rstSync1 < rstSync0,
    ]);
    final sysRstN = rstSync1;
    final sysReset = ~sysRstN;

    // UART RX/TX MMIO latches (same clean MMIO contract as Ulx3sTop)
    final uartRxdLatch = Logic(name: 'uart_rxd_latch', width: 8);
    final uartRxValid = Logic(name: 'uart_rx_valid');
    final txBusyLatch = Logic(name: 'tx_busy_latch');

    final cpuRxData = [uartRxValid, Const(0, width: 7), uartRxdLatch].swizzle();
    final cpuTxStatus = mux(txBusyLatch, Const(1, width: 16), Const(0, width: 16));

    // Explicitly tie off unused optional interfaces (no SDRAM/NoC on single-core AsicTop)
    final effectiveConfig = CpuConfig(
      coreId: baseCfg.coreId,
      enableCpuid: baseCfg.enableCpuid,
      enableCpuInfo: baseCfg.enableCpuInfo,
      enableUart: true,
      enableCrossTraps: false,
      enableEpc: baseCfg.enableEpc,
      enableShadowRegs: baseCfg.enableShadowRegs,
      enableMathAccel: baseCfg.enableMathAccel,
      enableFpu: baseCfg.enableFpu,
      enableSpi: baseCfg.enableSpi,
      enableNoc: false,
      enableSdramCache: false,
      isPipelined: baseCfg.isPipelined,
      memReadLatency: baseCfg.memReadLatency,
      memoryTarget: baseCfg.memoryTarget,
      bootRomBase: baseCfg.bootRomBase,
      bootRomWords: baseCfg.bootRomWords,
      sramMacroName: baseCfg.sramMacroName,
      clkFreqMhz: baseCfg.clkFreqMhz,
      cpuVersionMajor: baseCfg.cpuVersionMajor,
      cpuVersionMinor: baseCfg.cpuVersionMinor,
      cpuCaps2: baseCfg.cpuCaps2,
      trapTableBase: baseCfg.trapTableBase,
      memWords: baseCfg.memWords,
    );

    cpu = CpuCore(
      clk: clk,
      rstN: sysRstN,
      mmioRxData: cpuRxData,
      mmioTxStatus: cpuTxStatus,
      spiMiso: hasSpi ? spiMisoIn : null,
      config: effectiveConfig,
      name: 'cpu_core',
    );

    if (hasSpi) {
      spiSckOut! <= cpu.output('spi_sck');
      spiMosiOut! <= cpu.output('spi_mosi');
      spiCsNOut! <= cpu.output('spi_cs_n');
    }

    final uart = Uart(
      clk: clk,
      reset: sysReset,
      serialRxd: uartRxd,
      txd: cpu.txData,
      txdStrobe: cpu.txStrobe,
      divisor: this.uartDivisor,
    );
    uartTxd <= uart.serialTxd;
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

  static int _defaultUartDivisor(int clkFreqMhz) {
    // Default to ~115,200 baud rounded to nearest multiple of 4 (>= 4)
    final raw = (clkFreqMhz * 1000000) ~/ 115200;
    final aligned = ((raw + 2) ~/ 4) * 4;
    return aligned < 4 ? 4 : aligned;
  }

  @override
  String get definitionName => 'mr4_asic_top';

  Logic get uartTxd => output('uart_txd');
  Logic get debugPc => output('debug_pc');
  Logic get spiSck => output('spi_sck');
  Logic get spiMosi => output('spi_mosi');
  Logic get spiCsN => output('spi_cs_n');
}

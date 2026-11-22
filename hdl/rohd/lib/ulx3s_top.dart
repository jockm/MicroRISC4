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
    String? initHexFile = 'system_image.hex',
    Map<int, int>? initialMemory,
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

    // 25 MHz -> 24 MHz PLL for exact 3 Mbaud UART
    final pll = Ecp5Pll25To24(clkIn: clk25mhz);
    final clk24mhz = pll.clkOut;
    final sysRstN = btnPwrN & pll.locked;
    final uartReset = ~sysRstN;

    // UART MMIO Registers
    final uartRxdLatch = Logic(name: 'uart_rxd_latch', width: 8);
    final uartRxValid = Logic(name: 'uart_rx_valid');
    final txBusyLatch = Logic(name: 'tx_busy_latch');

    final useNoc = nocCores >= 2;
    final effectiveConfig = useNoc
        ? CpuConfig(
            coreId: config.coreId,
            enableCpuid: config.enableCpuid,
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
    final nocRdataCore0 = Logic(name: 'noc_rdata_core0', width: 16);

    cpuRxData <= [uartRxValid, Const(0, width: 7), uartRxdLatch].swizzle();
    cpuTxStatus <= mux(txBusyLatch, Const(1, width: 16), Const(0, width: 16));

    cpu = CpuCore(
      clk: clk24mhz,
      rstN: sysRstN,
      mmioRxData: cpuRxData,
      mmioTxStatus: cpuTxStatus,
      nocRdata: useNoc ? nocRdataCore0 : null,
      config: effectiveConfig,
      initHexFile: initHexFile,
      initialMemory: initialMemory,
    );

    final uart = Uart(
      clk: clk24mhz,
      reset: uartReset,
      serialRxd: ftdiTxd,
      txd: cpu.txData,
      txdStrobe: cpu.txStrobe,
      divisor: 16,
    );

    ftdiRxd <= uart.serialTxd;

    if (useNoc) {
      final busEn = cpu.output('port_b_en_out');
      final busWe = cpu.output('port_b_we_out');
      final busAddr = cpu.output('port_b_addr_out');
      final busWdata = cpu.output('port_b_wdata_out');
      final inNocRange =
          busAddr.gte(Const(MiniRISC4Constants.addrNocTxData, width: 16)) &
              busAddr.lte(Const(MiniRISC4Constants.addrNocChCfg1, width: 16));

      final mmioAddr = List.generate(
        nocCores,
        (i) => (i == 0)
            ? busAddr
            : Const(MiniRISC4Constants.addrNocRxStat,
                width: MiniRISC4Constants.addrWidth),
      );
      final mmioWdata = List.generate(
        nocCores,
        (i) => (i == 0)
            ? busWdata
            : Const(0, width: MiniRISC4Constants.dataWidth),
      );
      final mmioWe = List.generate(
        nocCores,
        (i) => (i == 0) ? (busEn & busWe & inNocRange) : Const(0),
      );
      final mmioRe = List.generate(
        nocCores,
        (i) => (i == 0) ? (busEn & (~busWe) & inNocRange) : Const(0),
      );
      final netOutReady = List.generate(nocCores, (i) => Const(1));

      final nocFabric = NocMultiCoreCacheWrapper(
        clk: clk24mhz,
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
        numChannels: config.nocChannels,
        fifoDepth: config.nocFifoDepth,
        name: 'ulx3s_noc_fabric',
      );
      nocRdataCore0 <= nocFabric.output('mmioRdata_0');
      led <= [
        pll.locked,
        nocFabric.output('mboxTrapReq_0'),
        cpu.debugPc.slice(5, 0),
      ].swizzle();
    } else {
      nocRdataCore0 <= Const(0, width: 16);
      led <= [pll.locked, cpu.debugPc.slice(6, 0)].swizzle();
    }

    Sequential(clk24mhz, reset: uartReset, resetValues: {
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

    Sequential(clk24mhz, reset: uartReset, resetValues: {
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

// ==============================================================================
// ULX3S Board Top-Level Module Wrapper
// Intel ROHD Implementation
// ==============================================================================
import 'package:rohd/rohd.dart';
import 'cpu_core.dart';
import 'uart.dart';

class Ulx3sTop extends Module {
  Ulx3sTop({
    required Logic clk24mhz,
    required Logic rstN,
    required Logic ftdiTxd,
    super.name = 'ulx3s_top',
  }) {
    clk24mhz = addInput('clk_24mhz', clk24mhz);
    rstN = addInput('rst_n', rstN);
    ftdiTxd = addInput('ftdi_txd', ftdiTxd);

    final ftdiRxd = addOutput('ftdi_rxd');

    final uartRxdLatch = Logic(name: 'uart_rxd_latch', width: 8);
    final uartRxValid = Logic(name: 'uart_rx_valid');
    final txBusyLatch = Logic(name: 'tx_busy_latch');

    final cpuRxData = Logic(name: 'cpu_rx_data', width: 16);
    final cpuTxStatus = Logic(name: 'cpu_tx_status', width: 16);

    cpuRxData <= [uartRxValid, Const(0, width: 7), uartRxdLatch].swizzle();
    cpuTxStatus <= mux(txBusyLatch, Const(1, width: 16), Const(0, width: 16));

    final cpu = CpuCore(
      clk: clk24mhz,
      rstN: rstN,
      mmioRxData: cpuRxData,
      mmioTxStatus: cpuTxStatus,
    );

    final uartReset = ~rstN;
    final uart = Uart(
      clk: clk24mhz,
      reset: uartReset,
      serialRxd: ftdiTxd,
      txd: cpu.txData,
      txdStrobe: cpu.txStrobe,
      divisor: 8,
    );

    ftdiRxd <= uart.serialTxd;

    Sequential(clk24mhz, reset: uartReset, resetValues: {uartRxValid: 0, uartRxdLatch: 0}, [
      If(uart.rxdStrobe, then: [
        uartRxdLatch < uart.rxd,
        uartRxValid < 1,
      ], orElse: [
        If(cpu.rxPop, then: [
          uartRxValid < 0,
        ]),
      ]),
    ]);

    Sequential(clk24mhz, reset: uartReset, resetValues: {txBusyLatch: 0}, [
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
}

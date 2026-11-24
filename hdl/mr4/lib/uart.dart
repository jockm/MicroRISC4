// ==============================================================================
// 3 Mbps High-Speed UART Core (RX / TX / Top)
// Intel ROHD Implementation
//
// Based on the 3 Mbaud design by Trammell Hudson & Micah Dowty.
// Designed for 24 MHz master system clock (DIVISOR = 24 / 3 = 8).
// ==============================================================================
import 'package:rohd/rohd.dart';
import 'util.dart';

/// UART Transmitter module.
class UartTx extends Module {
  final int divisor;

  UartTx({
    required Logic clk,
    required Logic reset,
    required Logic dataStrobe,
    required Logic data,
    this.divisor = 8,
    super.name = 'uart_tx',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final dataIn = addInput('data', data, width: 8);
    final strobe = addInput('data_strobe', dataStrobe);

    final serial = addOutput('serial');
    final ready = addOutput('ready');

    final baudDiv = DivideByN(clk: clk, reset: reset, n: divisor);
    final baudX1 = baudDiv.out;

    final shiftreg = Logic(name: 'shiftreg', width: 10);
    final serialR = Logic(name: 'serial_r', width: 1);

    serial <= ~serialR;

    Sequential(clk, reset: reset, resetValues: {shiftreg: 0, serialR: 0}, [
      If(strobe, then: [
        shiftreg < [Const(1, width: 1), dataIn, Const(0, width: 1)].swizzle(),
        ready < 0,
      ], orElse: [
        If(baudX1, then: [
          If(shiftreg.eq(0), then: [
            serialR < 0,
            ready < 1,
          ], orElse: [
            serialR < ~shiftreg[0],
            shiftreg < [Const(0, width: 1), shiftreg.slice(9, 1)].swizzle(),
          ]),
        ], orElse: [
          ready < shiftreg.eq(0),
        ]),
      ]),
    ]);
  }

  Logic get serial => output('serial');
  Logic get ready => output('ready');
}

/// UART Receiver module with 4x oversampling.
class UartRx extends Module {
  final int divisor;

  UartRx({
    required Logic clk,
    required Logic reset,
    required Logic serial,
    this.divisor = 2,
    super.name = 'uart_rx',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final serIn = addInput('serial', serial);

    final dataOut = addOutput('data', width: 8);
    final dataStrobe = addOutput('data_strobe');

    final baudDiv = DivideByN(clk: clk, reset: reset, n: divisor);
    final baudX4 = baudDiv.out;

    final serialBuf = Logic(name: 'serial_buf', width: 2);
    Sequential(clk, [
      serialBuf < [serialBuf[0], serIn].swizzle(),
    ]);
    final serialSync = serialBuf[1];

    final shiftreg = Logic(name: 'shiftreg', width: 9);
    final state = Logic(name: 'state', width: 6);
    final bitCount = state.slice(5, 2);
    final bitPhase = state.slice(1, 0);

    final samplingPhase = bitPhase.eq(1);
    final startBit = bitCount.eq(0) & samplingPhase;
    final stopBit = bitCount.eq(9) & samplingPhase;

    final waitingForStart = state.eq(0) & serialSync.eq(1);
    final error = (startBit & serialSync.eq(1)) | (stopBit & serialSync.eq(0));

    dataOut <= shiftreg.slice(7, 0);

    Sequential(clk, reset: reset, resetValues: {state: 0, dataStrobe: 0}, [
      If(baudX4, then: [
        If(waitingForStart | error | stopBit, then: [
          state < 0,
        ], orElse: [
          state < state + 1,
        ]),
        If(bitPhase.eq(1), then: [
          shiftreg < [serialSync, shiftreg.slice(8, 1)].swizzle(),
        ]),
        dataStrobe < (stopBit & ~error),
      ], orElse: [
        dataStrobe < 0,
      ]),
    ]);
  }

  Logic get data => output('data');
  Logic get dataStrobe => output('data_strobe');
}

/// Unified UART transceiver module.
class Uart extends Module {
  final int divisor;

  Uart({
    required Logic clk,
    required Logic reset,
    required Logic serialRxd,
    required Logic txd,
    required Logic txdStrobe,
    this.divisor = 8,
    super.name = 'uart',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    serialRxd = addInput('serial_rxd', serialRxd);
    txd = addInput('txd', txd, width: 8);
    txdStrobe = addInput('txd_strobe', txdStrobe);

    final serialTxd = addOutput('serial_txd');
    final rxd = addOutput('rxd', width: 8);
    final rxdStrobe = addOutput('rxd_strobe');
    final txdReady = addOutput('txd_ready');

    final rx = UartRx(
      clk: clk,
      reset: reset,
      serial: serialRxd,
      divisor: divisor ~/ 4,
    );
    rxd <= rx.data;
    rxdStrobe <= rx.dataStrobe;

    final tx = UartTx(
      clk: clk,
      reset: reset,
      data: txd,
      dataStrobe: txdStrobe,
      divisor: divisor,
    );
    serialTxd <= tx.serial;
    txdReady <= tx.ready;
  }

  Logic get serialTxd => output('serial_txd');
  Logic get rxd => output('rxd');
  Logic get rxdStrobe => output('rxd_strobe');
  Logic get txdReady => output('txd_ready');
}

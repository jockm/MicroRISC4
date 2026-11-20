// ==============================================================================
// FILE: hdl/rohd/lib/spi_master.dart
// Architecture: MiniRISC4 SPI Mode 0 Master (SD Card MMIO 0x0018 - 0x001A)
// Framework: Intel ROHD (Dart)
// ==============================================================================

import 'package:rohd/rohd.dart';

class SpiMaster extends Module {
  static const int addrCtrl = 0x0018;
  static const int addrStat = 0x0019;
  static const int addrData = 0x001A;

  /// Half-period divider for slow clock (24 MHz / (2 * (29 + 1)) = 400 kHz).
  final int slowHalfDiv;

  /// Half-period divider for fast clock (24 MHz / (2 * (0 + 1)) = 12 MHz).
  final int fastHalfDiv;

  SpiMaster({
    required Logic clk,
    required Logic rstN,
    required Logic portBAddr,
    required Logic portBWdata,
    required Logic portBWe,
    required Logic portBEn,
    required Logic spiMiso,
    this.slowHalfDiv = 29,
    this.fastHalfDiv = 0,
    super.name = 'spi_master',
  }) {
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    portBAddr = addInput('port_b_addr', portBAddr, width: 16);
    portBWdata = addInput('port_b_wdata', portBWdata, width: 16);
    portBWe = addInput('port_b_we', portBWe);
    portBEn = addInput('port_b_en', portBEn);
    spiMiso = addInput('spi_miso', spiMiso);

    // MMIO Bus Outputs (matching MathAccelerator pattern)
    final rdata = addOutput('rdata', width: 16);
    final match = addOutput('match');

    // Physical SPI Pins (Mode 0: CPOL=0, CPHA=0)
    final spiSck = addOutput('spi_sck');
    final spiMosi = addOutput('spi_mosi');
    final spiCsN = addOutput('spi_cs_n');

    final reset = ~rstN;

    // Address decode
    final isCtrl = portBAddr.eq(Const(addrCtrl, width: 16));
    final isStat = portBAddr.eq(Const(addrStat, width: 16));
    final isData = portBAddr.eq(Const(addrData, width: 16));
    match <= isCtrl | isStat | isData;

    final wrCtrl = portBEn & portBWe & isCtrl;
    final wrData = portBEn & portBWe & isData;

    // Internal Registers
    final regCsN = Logic(name: 'reg_cs_n');
    final regFastClk = Logic(name: 'reg_fast_clk');
    final busy = Logic(name: 'busy');
    final sck = Logic(name: 'sck');
    final bitCnt = Logic(name: 'bit_cnt', width: 3);
    final divCnt = Logic(name: 'div_cnt', width: 8);
    final txShift = Logic(name: 'tx_shift', width: 8);
    final rxShift = Logic(name: 'rx_shift', width: 8);

    final halfDiv = mux(
      regFastClk,
      Const(fastHalfDiv, width: 8),
      Const(slowHalfDiv, width: 8),
    );

    // Physical pin assignments
    spiSck <= sck;
    spiMosi <= txShift[7];
    spiCsN <= regCsN;

    // MMIO Read MUX
    rdata <= mux(
      isCtrl,
      [Const(0, width: 14), regFastClk, regCsN].swizzle(),
      mux(
        isStat,
        [Const(0, width: 15), busy].swizzle(),
        [Const(0, width: 8), rxShift].swizzle(),
      ),
    );

    // SPI Mode 0 Shift Engine
    Sequential(clk, reset: reset, resetValues: {
      regCsN: Const(1),       // Deselected on reset
      regFastClk: Const(0),   // Slow init clock on reset
      busy: Const(0),
      sck: Const(0),
      bitCnt: Const(0, width: 3),
      divCnt: Const(0, width: 8),
      txShift: Const(0xFF, width: 8),
      rxShift: Const(0xFF, width: 8),
    }, [
      // Control register writes (0x0018)
      If(wrCtrl, then: [
        regCsN < portBWdata[0],
        regFastClk < portBWdata[1],
      ]),

      // Full-duplex 8-bit transfer FSM
      If(~busy, then: [
        sck < 0,
        If(wrData, then: [
          txShift < portBWdata.slice(7, 0),
          bitCnt < Const(7, width: 3),
          divCnt < halfDiv,
          busy < 1,
        ]),
      ], orElse: [
        If(divCnt.gt(0), then: [
          divCnt < divCnt - 1,
        ], orElse: [
          divCnt < halfDiv,
          If(~sck, then: [
            // Rising edge: sample MISO
            sck < 1,
            rxShift < [rxShift.slice(6, 0), spiMiso].swizzle(),
          ], orElse: [
            // Falling edge: advance MOSI or finish byte
            sck < 0,
            If(bitCnt.eq(0), then: [
              busy < 0,
            ], orElse: [
              bitCnt < bitCnt - 1,
              txShift < [txShift.slice(6, 0), Const(1, width: 1)].swizzle(),
            ]),
          ]),
        ]),
      ]),
    ]);
  }

  Logic get rdata => output('rdata');
  Logic get match => output('match');
  Logic get spiSck => output('spi_sck');
  Logic get spiMosi => output('spi_mosi');
  Logic get spiCsN => output('spi_cs_n');
}

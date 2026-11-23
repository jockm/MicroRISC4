// ==============================================================================
// FILE: hdl/rohd/lib/ecp5_pll.dart
// Lattice ECP5 EHXPLLL Wrapper (25 MHz -> 48 MHz via 480 MHz VCO / CLKOS)
// ==============================================================================

import 'package:rohd/rohd.dart';

class Ecp5Pll25To24 extends Module with SystemVerilog {
  Ecp5Pll25To24({
    required Logic clkIn,
    super.name = 'ecp5_pll_25_to_24',
  }) {
    clkIn = addInput('clk_in', clkIn);
    final clkOut = addOutput('clk_out');
    final locked = addOutput('locked');

    // Behavioral model for ROHD Dart simulation
    locked.put(1);
    clkOut.put(0);
    clkIn.changed.listen((_) {
      clkOut.put(clkIn.value);
    });
  }

  Logic get clkOut => output('clk_out');
  Logic get locked => output('locked');

  @override
  String definitionVerilog(String definitionType) => '''
module $definitionType (
  input  logic clk_in,
  output logic clk_out,
  output logic locked
);
  logic clkop_fb;

  (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
  EHXPLLL #(
    .PLLRST_ENA("DISABLED"),
    .INTFB_WAKE("DISABLED"),
    .STDBY_ENABLE("DISABLED"),
    .DPHASE_SOURCE("DISABLED"),
    .OUTDIVIDER_MUXA("DIVA"),
    .OUTDIVIDER_MUXB("DIVB"),
    .OUTDIVIDER_MUXC("DIVC"),
    .OUTDIVIDER_MUXD("DIVD"),
    .CLKI_DIV(5),
    .CLKFB_DIV(2),
    .CLKOP_ENABLE("ENABLED"),
    .CLKOP_DIV(48),
    .CLKOP_CPHASE(24),
    .CLKOP_FPHASE(0),
    .CLKOS_ENABLE("ENABLED"),
    .CLKOS_DIV(10),
    .CLKOS_CPHASE(5),
    .CLKOS_FPHASE(0),
    .FEEDBK_PATH("CLKOP")
  ) pll_inst (
    .CLKI(clk_in),
    .CLKFB(clkop_fb),
    .CLKINTFB(),
    .CLKOP(clkop_fb),
    .CLKOS(clk_out),
    .CLKOS2(),
    .CLKOS3(),
    .LOCK(locked),
    .INTLOCK(),
    .RST(1'b0),
    .STDBY(1'b0),
    .PHASESEL0(1'b0),
    .PHASESEL1(1'b0),
    .PHASEDIR(1'b0),
    .PHASESTEP(1'b0),
    .PHASELOADREG(1'b0),
    .ENCLKOP(1'b0),
    .ENCLKOS(1'b0),
    .ENCLKOS2(1'b0),
    .ENCLKOS3(1'b0)
  );
endmodule
''';
}

/// Hardware ECP5 DDR clock forwarding primitive (`ODDRX1F`) that drives an
/// external clock pin (`sdram_clk`) at 180° phase shift (`~clk_in`) directly
/// from the dedicated IOLOGIC block — zero fabric LUT4, zero routing skew.
class Ecp5OddrClkInv extends Module with SystemVerilog {
  Ecp5OddrClkInv({
    required Logic clkIn,
    super.name = 'ecp5_oddr_clk_inv',
  }) {
    clkIn = addInput('clk_in', clkIn);
    final clkOut = addOutput('clk_out');
    clkOut <= ~clkIn;
  }

  Logic get clkOut => output('clk_out');

  @override
  String definitionVerilog(String definitionType) => '''
module $definitionType (
  input  logic clk_in,
  output logic clk_out
);
  ODDRX1F oddr_inst (
    .D0(1'b0),
    .D1(1'b1),
    .SCLK(clk_in),
    .RST(1'b0),
    .Q(clk_out)
  );
endmodule
''';
}

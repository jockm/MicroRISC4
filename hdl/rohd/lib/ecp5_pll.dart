// ==============================================================================
// FILE: hdl/rohd/lib/ecp5_pll.dart
// Lattice ECP5 EHXPLLL Wrapper (25 MHz -> 24 MHz)
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
  (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
  EHXPLLL #(
    .PLLRST_ENA("DISABLED"),
    .INTFB_WAKE("DISABLED"),
    .STDBY_ENABLE("DISABLED"),
    .DPHASE_SOURCE("DISABLED"),
    .CLKOP_FPHASE(0),
    .CLKOP_CPHASE(24),
    .OUTDIVIDER_MUXA("DIVA"),
    .CLKOP_ENABLE("ENABLED"),
    .CLKOP_DIV(25),
    .CLKFB_DIV(24),
    .CLKI_DIV(25),
    .FEEDBK_PATH("INT_OP")
  ) pll_inst (
    .CLKI(clk_in),
    .CLKFB(clk_out),
    .CLKINTFB(),
    .CLKOP(clk_out),
    .CLKOS(),
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

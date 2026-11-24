// ==============================================================================
// FILE: hdl/rohd/lib/ecp5_pll.dart
// Lattice ECP5 EHXPLLL Wrapper (25 MHz -> 48 / 60 / 72 / 84 / 96 MHz)
// + ODDRX1F SDRAM Clock Forwarders
// ==============================================================================

import 'package:rohd/rohd.dart';

/// Validated Lattice ECP5 EHXPLLL timing parameters for exact 3 Mbaud-compatible
/// system clocks derived from the ULX3S 25 MHz crystal oscillator.
class _Ecp5PllConfig {
  final int clkFreqMhz;
  final int clkiDiv;
  final int clkfbDiv;
  final int clkopDiv;
  final int clkopCphase;
  final int clkosDiv;
  final int clkosCphase;
  final int clkos2Div;
  final int clkos2Cphase;
  final int clkos2Fphase;
  final int sdramPhaseDeg;

  const _Ecp5PllConfig({
    required this.clkFreqMhz,
    required this.clkiDiv,
    required this.clkfbDiv,
    required this.clkopDiv,
    required this.clkopCphase,
    required this.clkosDiv,
    required this.clkosCphase,
    required this.clkos2Div,
    required this.clkos2Cphase,
    required this.clkos2Fphase,
    required this.sdramPhaseDeg,
  });

  static const Map<int, _Ecp5PllConfig> presets = {
    // 48 MHz: PFD=5 MHz, VCO=480 MHz, CLKOS=48.000 MHz (0°), CLKOS2=180°
    48: _Ecp5PllConfig(
      clkFreqMhz: 48,
      clkiDiv: 5,
      clkfbDiv: 2,
      clkopDiv: 48,
      clkopCphase: 24,
      clkosDiv: 10,
      clkosCphase: 5,
      clkos2Div: 10,
      clkos2Cphase: 10,
      clkos2Fphase: 0,
      sdramPhaseDeg: 180,
    ),
    // 60 MHz: PFD=25 MHz, VCO=600 MHz, CLKOS=60.000 MHz (0°), CLKOS2=306° (+14.17 ns)
    60: _Ecp5PllConfig(
      clkFreqMhz: 60,
      clkiDiv: 1,
      clkfbDiv: 1,
      clkopDiv: 24,
      clkopCphase: 12,
      clkosDiv: 10,
      clkosCphase: 4,
      clkos2Div: 10,
      clkos2Cphase: 12,
      clkos2Fphase: 4,
      sdramPhaseDeg: 306,
    ),
    // 72 MHz: PFD=5 MHz, VCO=720 MHz, CLKOS=72.000 MHz (0°), CLKOS2=297° (+11.46 ns)
    72: _Ecp5PllConfig(
      clkFreqMhz: 72,
      clkiDiv: 5,
      clkfbDiv: 2,
      clkopDiv: 72,
      clkopCphase: 36,
      clkosDiv: 10,
      clkosCphase: 4,
      clkos2Div: 10,
      clkos2Cphase: 12,
      clkos2Fphase: 2,
      sdramPhaseDeg: 297,
    ),
    // 84 MHz: PFD=5 MHz, VCO=420 MHz, CLKOS=84.000 MHz (0°), CLKOS2=279° (+9.23 ns)
    84: _Ecp5PllConfig(
      clkFreqMhz: 84,
      clkiDiv: 5,
      clkfbDiv: 2,
      clkopDiv: 42,
      clkopCphase: 21,
      clkosDiv: 5,
      clkosCphase: 2,
      clkos2Div: 5,
      clkos2Cphase: 5,
      clkos2Fphase: 7,
      sdramPhaseDeg: 279,
    ),
    // 96 MHz: PFD=5 MHz, VCO=480 MHz, CLKOS=96.000 MHz (0°), CLKOS2=270° (+7.81 ns)
    96: _Ecp5PllConfig(
      clkFreqMhz: 96,
      clkiDiv: 5,
      clkfbDiv: 2,
      clkopDiv: 48,
      clkopCphase: 24,
      clkosDiv: 5,
      clkosCphase: 2,
      clkos2Div: 5,
      clkos2Cphase: 5,
      clkos2Fphase: 6,
      sdramPhaseDeg: 270,
    ),
  };
}

/// Parameterized Lattice ECP5 `EHXPLLL` generating exact 3 Mbaud-compatible
/// system clocks (`48`, `60`, `72`, `84`, or `96 MHz`) from the ULX3S 25 MHz
/// oscillator, plus a phase-shifted `clk_sdram` (`CLKOS2`) output tuned for
/// `IS42S16160G-7TL` setup/hold closure across all supported frequencies.
class Ecp5Pll extends Module with SystemVerilog {
  final int clkFreqMhz;
  final _Ecp5PllConfig _cfg;

  static List<int> get supportedFrequenciesMhz =>
      _Ecp5PllConfig.presets.keys.toList(growable: false);

  Ecp5Pll({
    required Logic clkIn,
    this.clkFreqMhz = 48,
    String? name,
  })  : _cfg = _Ecp5PllConfig.presets[clkFreqMhz] ??
            (throw ArgumentError(
              'Unsupported ULX3S clkFreqMhz=$clkFreqMhz. '
              'Supported exact-3Mbaud frequencies: ${_Ecp5PllConfig.presets.keys.join(", ")} MHz.',
            )),
        super(name: name ?? 'ecp5_pll_25_to_${clkFreqMhz}mhz') {
    clkIn = addInput('clk_in', clkIn);
    final clkOut = addOutput('clk_out');
    final clkSdram = addOutput('clk_sdram');
    final locked = addOutput('locked');

    // Behavioral model for ROHD Dart simulation
    locked.put(1);
    clkOut.put(0);
    clkSdram.put(1);
    clkIn.changed.listen((_) {
      clkOut.put(clkIn.value);
      clkSdram.put(~clkIn.value);
    });
  }

  Logic get clkOut => output('clk_out');
  Logic get clkSdram => output('clk_sdram');
  Logic get locked => output('locked');
  int get sdramPhaseDeg => _cfg.sdramPhaseDeg;

  @override
  String definitionVerilog(String definitionType) {
    final useClkos2 = clkFreqMhz > 48;
    return '''
module $definitionType (
  input  logic clk_in,
  output logic clk_out,
  output logic clk_sdram,
  output logic locked
);
  logic clkop_fb;

  (* FREQUENCY_PIN_CLKI="25" *)
  (* FREQUENCY_PIN_CLKOS="$clkFreqMhz" *)
  ${useClkos2 ? '(* FREQUENCY_PIN_CLKOS2="$clkFreqMhz" *)' : ''}
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
    .CLKI_DIV(${_cfg.clkiDiv}),
    .CLKFB_DIV(${_cfg.clkfbDiv}),
    .CLKOP_ENABLE("ENABLED"),
    .CLKOP_DIV(${_cfg.clkopDiv}),
    .CLKOP_CPHASE(${_cfg.clkopCphase}),
    .CLKOP_FPHASE(0),
    .CLKOS_ENABLE("ENABLED"),
    .CLKOS_DIV(${_cfg.clkosDiv}),
    .CLKOS_CPHASE(${_cfg.clkosCphase}),
    .CLKOS_FPHASE(0),
    .CLKOS2_ENABLE("${useClkos2 ? 'ENABLED' : 'DISABLED'}"),
    .CLKOS2_DIV(${_cfg.clkos2Div}),
    .CLKOS2_CPHASE(${_cfg.clkos2Cphase}),
    .CLKOS2_FPHASE(${_cfg.clkos2Fphase}),
    .FEEDBK_PATH("CLKOP")
  ) pll_inst (
    .CLKI(clk_in),
    .CLKFB(clkop_fb),
    .CLKINTFB(),
    .CLKOP(clkop_fb),
    .CLKOS(clk_out),
    .CLKOS2(${useClkos2 ? 'clk_sdram' : ''}),
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
  ${useClkos2 ? '' : 'assign clk_sdram = clk_out;'}
endmodule
''';
  }
}

/// Backwards-compatible alias for the legacy 48 MHz PLL wrapper.
class Ecp5Pll25To24 extends Ecp5Pll {
  Ecp5Pll25To24({
    required super.clkIn,
    super.name = 'ecp5_pll_25_to_24',
  }) : super(clkFreqMhz: 48);
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

/// Hardware ECP5 DDR clock forwarding primitive (`ODDRX1F`) that forwards a
/// PLL phase-shifted clock (`CLKOS2`) directly to the `sdram_clk` output pad
/// at 0° inversion (`D0=1, D1=0`) with zero fabric LUT4 skew.
class Ecp5OddrClkFwd extends Module with SystemVerilog {
  Ecp5OddrClkFwd({
    required Logic clkIn,
    super.name = 'ecp5_oddr_clk_fwd',
  }) {
    clkIn = addInput('clk_in', clkIn);
    final clkOut = addOutput('clk_out');
    clkOut <= clkIn;
  }

  Logic get clkOut => output('clk_out');

  @override
  String definitionVerilog(String definitionType) => '''
module $definitionType (
  input  logic clk_in,
  output logic clk_out
);
  ODDRX1F oddr_inst (
    .D0(1'b1),
    .D1(1'b0),
    .SCLK(clk_in),
    .RST(1'b0),
    .Q(clk_out)
  );
endmodule
''';
}

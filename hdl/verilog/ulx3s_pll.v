`timescale 1ns / 1ps
// =============================================================================
// Lattice ECP5 PLL Module (25 MHz -> 24 MHz)
// =============================================================================

module ulx3s_pll (
    input  wire clk_in,    // 25 MHz from ULX3S oscillator
    output wire clk_out,   // 24 MHz output for CPU & 3 Mbps UART
    output wire locked
);

    EHXPLLL #(
        .PLLRST_ENA("DISABLED"),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .CLKOP_FPHASE(0),
        .CLKOP_CPHASE(19),
        .OUTDIVIDER_MUXA("DIVA"),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_DIV(25),         // 24 MHz output
        .CLKFB_DIV(24),
        .CLKI_DIV(25),
        .FEEDBK_PATH("INT_OP")
    ) pll_inst (
        .CLKI(clk_in),
        .CLKFB(clk_out),
        .CLKOP(clk_out),
        .LOCK(locked),
        .RST(1'b0),
        .STDBY(1'b0),
        .PHASESEL0(1'b0),
        .PHASESEL1(1'b0),
        .PHASEDIR(1'b0),
        .PHASESTEP(1'b0),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0)
    );

endmodule

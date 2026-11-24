# ==============================================================================
# FILE: asic/mr4/constraint.sdc
# Full Timing Constraints for MiniRISC4 (`mr4_asic_top`) — Zero Unconstrained Paths
#
# Automatically adapts time & capacitance units for ORFS public PDKs:
#   - asap7      : time in ps, cap in fF  (default 2000 ps = 500 MHz)
#   - nangate45  : time in ns, cap in fF  (default 10.0 ns = 100 MHz)
#   - sky130hd   : time in ns, cap in pF  (default 20.0 ns = 50 MHz)
#   - ihp-sg13g2 : time in ns, cap in pF  (default 20.0 ns = 50 MHz)
# ==============================================================================

set current_platform "nangate45"
if {[info exists ::env(PLATFORM)]} {
    set current_platform $::env(PLATFORM)
}

if {$current_platform eq "asap7"} {
    set clk_period            [expr {[info exists ::env(CLOCK_PERIOD)] ? $::env(CLOCK_PERIOD) : 2000.0}]
    set clk_uncertainty_setup 50.0
    set clk_uncertainty_hold  15.0
    set clk_slew              50.0
    set io_slew               50.0
    set out_load              10.0
} elseif {$current_platform eq "sky130hd" || $current_platform eq "ihp-sg13g2"} {
    set clk_period            [expr {[info exists ::env(CLOCK_PERIOD)] ? $::env(CLOCK_PERIOD) : 20.0}]
    set clk_uncertainty_setup 0.25
    set clk_uncertainty_hold  0.05
    set clk_slew              0.20
    set io_slew               0.25
    set out_load              0.05
} else {
    set clk_period            [expr {[info exists ::env(CLOCK_PERIOD)] ? $::env(CLOCK_PERIOD) : 10.0}]
    set clk_uncertainty_setup 0.25
    set clk_uncertainty_hold  0.05
    set clk_slew              0.10
    set io_slew               0.15
    set out_load              10.0
}

set clk_port_name "clk"
set clk_port [get_ports $clk_port_name]

create_clock -name core_clk -period $clk_period $clk_port
# Separate setup vs. hold uncertainty: hold checks are same-edge (skew only, no
# cycle-to-cycle PLL jitter), whereas setup includes jitter + skew margin.
set_clock_uncertainty -setup $clk_uncertainty_setup [get_clocks core_clk]
set_clock_uncertainty -hold  $clk_uncertainty_hold  [get_clocks core_clk]
set_clock_transition         $clk_slew              [get_clocks core_clk]

# Constrain EVERY non-clock input port (rst_n, uart_rxd, optional spi_miso)
set non_clk_inputs [lsearch -inline -all -not -exact [all_inputs] $clk_port]
set in_delay_max   [expr {$clk_period * 0.25}]
set in_delay_min   [expr {$clk_period * 0.05}]

if {[llength $non_clk_inputs] > 0} {
    set_input_delay  -clock core_clk -max $in_delay_max $non_clk_inputs
    set_input_delay  -clock core_clk -min $in_delay_min $non_clk_inputs
    set_input_transition $io_slew $non_clk_inputs
}

# Constrain EVERY output port (uart_txd, debug_pc[*], optional spi_sck/mosi/cs_n)
set all_outs      [all_outputs]
set out_delay_max [expr {$clk_period * 0.25}]
set out_delay_min [expr {$clk_period * 0.05}]

if {[llength $all_outs] > 0} {
    set_output_delay -clock core_clk -max $out_delay_max $all_outs
    set_output_delay -clock core_clk -min $out_delay_min $all_outs
    set_load $out_load $all_outs
}

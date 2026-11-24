# ==============================================================================
# FILE: asic/mr4_quad/constraint.sdc
# Full Chip-Level Timing Constraints for Hierarchical 4-Tile `mr4_quad_top`
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

set clk_port [get_ports clk]

create_clock -name core_clk -period $clk_period $clk_port
set_clock_uncertainty -setup $clk_uncertainty_setup [get_clocks core_clk]
set_clock_uncertainty -hold  $clk_uncertainty_hold  [get_clocks core_clk]
set_clock_transition         $clk_slew              [get_clocks core_clk]

set non_clk_inputs [lsearch -inline -all -not -exact [all_inputs] $clk_port]
set in_delay_max   [expr {$clk_period * 0.25}]
set in_delay_min   [expr {$clk_period * 0.05}]

if {[llength $non_clk_inputs] > 0} {
    set_input_delay  -clock core_clk -max $in_delay_max $non_clk_inputs
    set_input_delay  -clock core_clk -min $in_delay_min $non_clk_inputs
    set_input_transition $io_slew $non_clk_inputs
}

set all_outs      [all_outputs]
set out_delay_max [expr {$clk_period * 0.25}]
set out_delay_min [expr {$clk_period * 0.05}]

if {[llength $all_outs] > 0} {
    set_output_delay -clock core_clk -max $out_delay_max $all_outs
    set_output_delay -clock core_clk -min $out_delay_min $all_outs
    set_load $out_load $all_outs
}

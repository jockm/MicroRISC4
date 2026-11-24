# ==============================================================================
# FILE: asic/mr4_tile/fastroute_nangate45.tcl
# Custom FastRoute layer ceiling for hardened child macro `mr4_tile` (Nangate45)
#
# Caps BOTH signal and clock routing at metal6 so metal8-metal10 remain 100%
# obstruction-free above mr4_tile's exposed metal7 VDD/VSS power pins for
# hierarchical top-level PDN (M8/M9) and over-macro routing in `mr4_quad_top`.
# ==============================================================================

set_global_routing_layer_adjustment metal2-metal6 0.5
set_routing_layers -signal metal2-metal6 -clock metal3-metal6

# ==============================================================================
# FILE: asic/mr4_quad/pdn_nangate45.tcl
# Hierarchical Top-Level PDN for `mr4_quad_top` on Nangate45
#
# Child `mr4_tile` macros route signals on metal1-metal6 and expose VDD/VSS
# power pins on metal7 (with metal8-metal10 obstruction-free). This top-level
# PDN adds chip-level metal8 (V) and metal9 (H) power meshes and drops vias
# cleanly onto every tile macro's metal7 power straps.
# ==============================================================================

set_voltage_domain -name {CORE} -power {VDD} -ground {VSS}

# Top-level standard-cell grid (M1 -> M4 -> M7 -> M8 -> M9)
define_pdn_grid -name {grid} -voltage_domains {CORE} -pins {metal9}
add_pdn_stripe -grid {grid} -layer {metal1} -width {0.17} -pitch {2.4}  -offset {0} -followpins
add_pdn_stripe -grid {grid} -layer {metal4} -width {0.48} -pitch {56.0} -offset {2}
add_pdn_stripe -grid {grid} -layer {metal7} -width {1.40} -pitch {30.0} -offset {2}
add_pdn_stripe -grid {grid} -layer {metal8} -width {1.60} -pitch {40.0} -offset {4}
add_pdn_stripe -grid {grid} -layer {metal9} -width {1.60} -pitch {40.0} -offset {4}
add_pdn_connect -grid {grid} -layers {metal1 metal4}
add_pdn_connect -grid {grid} -layers {metal4 metal7}
add_pdn_connect -grid {grid} -layers {metal7 metal8}
add_pdn_connect -grid {grid} -layers {metal8 metal9}

# Hierarchical mr4_tile macro connections (exposed tile metal7 -> top metal8 -> metal9)
define_pdn_grid -name {CORE_macro_grid_1} -voltage_domains {CORE} -macro \
  -orient {R0 R180 MX MY} -halo {2.0 2.0 2.0 2.0} -default
add_pdn_connect -grid {CORE_macro_grid_1} -layers {metal7 metal8}
add_pdn_connect -grid {CORE_macro_grid_1} -layers {metal8 metal9}

define_pdn_grid -name {CORE_macro_grid_2} -voltage_domains {CORE} -macro \
  -orient {R90 R270 MXR90 MYR90} -halo {2.0 2.0 2.0 2.0} -default
add_pdn_connect -grid {CORE_macro_grid_2} -layers {metal7 metal8}
add_pdn_connect -grid {CORE_macro_grid_2} -layers {metal8 metal9}

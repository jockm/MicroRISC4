# ==============================================================================
# FILE: asic/mr4_tiny/config.mk
# OpenROAD-flow-scripts (ORFS) Design Configuration for Tiny Tapeout MicroRISC4
# (`tt_um_mr4`, Track E.1.2 / E.1.3)
#
# Targets exact site-grid-aligned 2x2 Tiny Tapeout tile footprints with ZERO
# mocked memories:
#   - sky130hd   : 331.66 x 225.76 um (0.0749 mm^2, exact TT 2x2 Sky130 tile;
#                  site grid 0.46 x 2.72 um -> 721 x 83 sites)
#   - ihp-sg13g2 : 415.68 x 313.74 um (0.1304 mm^2, exact TT 2x2 IHP SG13G2 tile;
#                  site grid 0.48 x 3.78 um -> 866 x 83 sites, 20+ um PDN margin)
#
# Usage:
#   make tiny-flow TINY_PLATFORM=sky130hd
#   make tiny-flow TINY_PLATFORM=ihp-sg13g2
# ==============================================================================

MR4_TINY_DIR  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
MR4_REPO_ROOT := $(abspath $(MR4_TINY_DIR)/../..)

export DESIGN_NICKNAME = tt_um_mr4
export DESIGN_NAME     = tt_um_mr4
export PLATFORM       ?= sky130hd

export VERILOG_FILES   = $(MR4_REPO_ROOT)/build/asic_tiny/tt_um_mr4.sv
export SDC_FILE        = $(MR4_TINY_DIR)/constraint.sdc

# ZERO mocked memories: tt_um_mr4 only has 16x16 (256b) local scratchpad +
# 8x16 (128b) iqRam + 256x16 synthesizable Boot ROM — all synthesized as real
# standard cells!
export SYNTH_MEMORY_MAX_BITS ?= 4096

export PLACE_DENSITY_LB_ADDON ?= 0.10

ifeq ($(PLATFORM),sky130hd)
  # 50 MHz Tiny Tapeout board clock (20.0 ns; tighten to 10.0 ns / 100 MHz as desired)
  export CLOCK_PERIOD ?= 20.0
  # Exact 2x2 Tiny Tapeout Sky130 tile footprint (331.66 x 225.76 um = 0.0749 mm^2)
  export DIE_AREA  ?= 0 0 331.66 225.76
  export CORE_AREA ?= 3.68 5.44 327.98 220.32
else ifeq ($(PLATFORM),ihp-sg13g2)
  export CLOCK_PERIOD ?= 20.0
  # Exact 2x2 Tiny Tapeout IHP SG13G2 tile footprint (415.68 x 313.74 um = 0.1304 mm^2)
  # with 20.16 / 22.68 um margins for ORFS's SG13G2 TopMetal1/2 PDN ring
  export DIE_AREA  ?= 0 0 415.68 313.74
  export CORE_AREA ?= 20.16 22.68 395.52 291.06
else ifeq ($(PLATFORM),asap7)
  export CLOCK_PERIOD ?= 2000
  export CORE_UTILIZATION ?= 45
  export CORE_ASPECT_RATIO ?= 1
  export CORE_MARGIN ?= 2
else
  # Nangate45 quick dry-run
  export CLOCK_PERIOD ?= 10.0
  export CORE_UTILIZATION ?= 45
  export CORE_ASPECT_RATIO ?= 1
  export CORE_MARGIN ?= 2
endif

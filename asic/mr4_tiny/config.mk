# ==============================================================================
# FILE: asic/mr4_tiny/config.mk
# OpenROAD-flow-scripts (ORFS) Design Configuration for Tiny Tapeout MicroRISC4
# (`tt_um_mr4`, Track E.1.2 / E.1.3)
#
# Targets a 2x2 Tiny Tapeout tile footprint with ZERO mocked memories:
#   - sky130hd   : 330 x 220 um (0.0726 mm^2, 2x2 TT Sky130 tile budget)
#   - ihp-sg13g2 : 400 x 300 um (0.1200 mm^2, 2x2 TT IHP SG13G2 tile budget
#                  accounting for larger SG13G2 stdcell pitch + PDN ring margin)
#
# Usage:
#   make tiny-flow ASIC_PLATFORM=sky130hd
#   make tiny-flow ASIC_PLATFORM=ihp-sg13g2
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
  # Exact 2x2 Tiny Tapeout Sky130 tile footprint (~330 x 220 um = 0.0726 mm^2)
  export DIE_AREA  ?= 0 0 330 220
  export CORE_AREA ?= 10 10 320 210
else ifeq ($(PLATFORM),ihp-sg13g2)
  export CLOCK_PERIOD ?= 20.0
  # IHP SG13G2 2x2 tile footprint (larger stdcell height + 20 um PDN ring margin)
  export DIE_AREA  ?= 0 0 420 340
  export CORE_AREA ?= 22 22 398 318
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

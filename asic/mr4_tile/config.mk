# ==============================================================================
# FILE: asic/mr4_tile/config.mk
# OpenROAD-flow-scripts (ORFS) Macro Hardening Config for `mr4_tile` (Track D.4)
#
# Hardens ONE reusable MicroRISC4 compute tile (`CpuCore` + RAM/BootROM +
# `NocRouterNi` + registered `RegisteredNocHop` perimeter + `Uart`) and exports
# its abstract views (`mr4_tile.lef`, `mr4_tile.lib`, `6_final.gds`) via
# `make asic-tile-flow` (`ORFS_TARGET=generate_abstract`).
# ==============================================================================

MR4_TILE_DIR  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
MR4_REPO_ROOT := $(abspath $(MR4_TILE_DIR)/../..)

export DESIGN_NICKNAME = mr4_tile
export DESIGN_NAME     = mr4_tile
export PLATFORM       ?= nangate45

export VERILOG_FILES   = $(MR4_REPO_ROOT)/build/asic_tile/mr4_tile.sv
export SDC_FILE        = $(MR4_TILE_DIR)/constraint.sdc

# Allow the standalone 1024x16 (16,384-bit) flop-RAM dry run to synthesize into
# real standard-cell flip-flops (switch to ASIC_MEM_TARGET=sram for foundry macros).
export SYNTH_MEMORY_MAX_BITS ?= 16384

# Export abstract views from 5_route (post-routing + stdcell fill, BEFORE 6_1_fill
# dummy metal fill) so upper layers metal8-metal10 stay obstruction-free above the
# macro's metal7 power pins for top-level hierarchical PDN connections.
export ABSTRACT_SOURCE ?= 5_route

# Conservative utilization for clean macro routing and pin access
export CORE_UTILIZATION       ?= 40
export CORE_ASPECT_RATIO      ?= 1
export CORE_MARGIN            ?= 2
export PLACE_DENSITY_LB_ADDON ?= 0.15

ifeq ($(PLATFORM),asap7)
  export CLOCK_PERIOD      ?= 2000
  export CORE_UTILIZATION   = 35
  # Keep upper metals clear above macro power pins for parent-chip PDN vias
  export MAX_ROUTING_LAYER ?= M6
else ifeq ($(PLATFORM),sky130hd)
  export CLOCK_PERIOD      ?= 20.0
  export CORE_UTILIZATION   = 35
  export MAX_ROUTING_LAYER ?= met4
else ifeq ($(PLATFORM),ihp-sg13g2)
  export CLOCK_PERIOD      ?= 20.0
  export CORE_UTILIZATION   = 35
  export CORE_MARGIN        = 20
  export MAX_ROUTING_LAYER ?= Metal4
else
  export CLOCK_PERIOD          ?= 10.0
  # Nangate45 macro PDN exposes VDD/VSS pins on metal7; cap BOTH signal and clock
  # routing at metal6 via FASTROUTE_TCL so metal8/metal9 have zero OBS polygons!
  export MAX_ROUTING_LAYER      = metal6
  export MAX_CLK_ROUTING_LAYER  = metal6
  export FASTROUTE_TCL          = $(MR4_TILE_DIR)/fastroute_nangate45.tcl
endif

# Optional foundry SRAM macro hooks when ASIC_MEM_TARGET=sram
ifdef MR4_SRAM_LEFS
  export ADDITIONAL_LEFS += $(MR4_SRAM_LEFS)
endif
ifdef MR4_SRAM_LIBS
  export ADDITIONAL_LIBS += $(MR4_SRAM_LIBS)
endif
ifdef MR4_SRAM_GDS
  export ADDITIONAL_GDS  += $(MR4_SRAM_GDS)
endif

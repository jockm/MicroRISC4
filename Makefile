# ==============================================================================
# Makefile - MiniRISC4 Master Build, Simulation & ULX3S-85F FPGA Automation
# ==============================================================================

SHELL          := /bin/bash
DART           ?= dart
PYTHON         ?= $(shell command -v python3 2>/dev/null || echo python)

ROHD_DIR       := hdl/rohd
BUILD_DIR      := build
LIB_DIR        := lib
TOOLS_DIR      := tools

MR4ASM         := $(PYTHON) $(TOOLS_DIR)/mr4asm.py
ACT4C          := $(PYTHON) $(TOOLS_DIR)/act4c.py
MR4SIM         := $(PYTHON) $(TOOLS_DIR)/mr4sim.py

# macOS writes ._ metadata files on non-Apple file systems (such as exFAT).
# Where dot_clean exists, targets run it once at the end.
DOT_CLEAN      := $(shell command -v dot_clean 2>/dev/null)
DOT_CLEAN_CMD   = $(if $(and $(DOT_CLEAN),$(filter $@,$(or $(MAKECMDGOALS),all))),$(DOT_CLEAN) "$(CURDIR)" > /dev/null 2>&1 || true,true)

# Source discovery (excluding macOS ._* metadata files)
ASM_SRCS       := $(filter-out mr4src/asm/._%,$(wildcard mr4src/asm/*.asm))
ASM_BINS       := $(patsubst mr4src/asm/%.asm,$(BUILD_DIR)/%.bin,$(ASM_SRCS))
ASM_HEXS       := $(patsubst mr4src/asm/%.asm,$(BUILD_DIR)/%.hex,$(ASM_SRCS))

ACT4_SRCS      := $(filter-out mr4src/act4/._%,$(wildcard mr4src/act4/*.a4))
ACT4_ASMS      := $(patsubst mr4src/act4/%.a4,$(BUILD_DIR)/act4/%.asm,$(ACT4_SRCS))
ACT4_BINS      := $(patsubst mr4src/act4/%.a4,$(BUILD_DIR)/act4_%.bin,$(ACT4_SRCS))

# ULX3S-85F FPGA build settings
ULX3S_BLD      := $(BUILD_DIR)/ulx3s
ULX3S_PROGRAM  ?= mr4src/asm/monitor.asm
ULX3S_DEVICE   ?= 85k
ULX3S_PACKAGE  ?= CABGA381
ULX3S_CLOCK_MHZ ?= 24
ULX3S_LPF      := $(ROHD_DIR)/boards/ulx3s/ulx3s_v20.lpf
ULX3S_TOP      := Ulx3sTop
ULX3S_SV       := ulx3s_top_rohd.sv
ULX3S_BIT      := $(ULX3S_BLD)/ulx3s_top_rohd.bit

YOSYS          ?= yosys
NEXTPNR_ECP5   ?= nextpnr-ecp5
ECPPACK        ?= ecppack
OPENFPGALOADER ?= openFPGALoader

# Serial terminal settings (3 Mbaud 8-N-1)
ULX3S_PORT     ?= $(firstword $(wildcard /dev/cu.usbserial-* /dev/ttyUSB*))
ULX3S_BAUD     ?= 3000000

# Simulator defaults
SIM_PROGRAM    ?= $(BUILD_DIR)/monitor.bin

.PHONY: all help setup analyze build apps \
        test test-rohd sim debug \
        generate generate-ulx3s ulx3s-bit ulx3s-timing ulx3s-prog ulx3s-flash ulx3s-term \
        dot-clean clean

# ------------------------------------------------------------------------------
# Top-Level Targets
# ------------------------------------------------------------------------------

all: build test
	@$(DOT_CLEAN_CMD)

help:
	@echo "MiniRISC4 Build, Test & ULX3S-85F Automation"
	@echo "============================================"
	@echo "  make setup            - Fetch Dart dependencies for $(ROHD_DIR)"
	@echo "  make analyze          - Run dart analyze on the ROHD HDL"
	@echo "  make build            - Build ASM & ACT4 apps and generate ULX3S SystemVerilog"
	@echo "  make apps             - Assemble mr4src/asm/*.asm and compile mr4src/act4/*.a4"
	@echo "  make test             - Run all ROHD unit and firmware boot tests"
	@echo "  make test-rohd        - Run ROHD Dart test suite (assembles monitor hex first)"
	@echo "  make sim              - Run a binary in mr4sim.py (SIM_PROGRAM=build/monitor.bin)"
	@echo "  make debug            - Run mr4sim.py in interactive m4db debugger mode"
	@echo "  make generate         - Alias for generate-ulx3s"
	@echo "  make generate-ulx3s   - Assemble ULX3S_PROGRAM and generate SV in $(ULX3S_BLD)"
	@echo "  make ulx3s-bit        - Synthesize, place & route, and pack $(ULX3S_BIT)"
	@echo "  make ulx3s-timing     - Show Fmax and critical path from $(ULX3S_BLD)/nextpnr.log"
	@echo "  make ulx3s-prog       - Load $(ULX3S_BIT) into ULX3S SRAM ($(OPENFPGALOADER))"
	@echo "  make ulx3s-flash      - Write $(ULX3S_BIT) to ULX3S SPI flash"
	@echo "  make ulx3s-term       - Open 3 Mbaud FTDI serial terminal (ULX3S_PORT=..., ULX3S_BAUD=3000000)"
	@echo "  make dot-clean        - Remove macOS ._ metadata files (where dot_clean exists)"
	@echo "  make clean            - Remove $(BUILD_DIR)/ and generated SV/bitstream artifacts"

setup:
	@echo "==> Fetching Dart dependencies for MiniRISC4 ROHD..."
	@cd $(ROHD_DIR) && $(DART) pub get

analyze: setup
	@echo "==> Analyzing MiniRISC4 ROHD..."
	@cd $(ROHD_DIR) && $(DART) analyze

# ------------------------------------------------------------------------------
# Software Build Targets (ASM & ACT4)
# ------------------------------------------------------------------------------

build: apps generate-ulx3s
	@$(DOT_CLEAN_CMD)

apps: $(ASM_BINS) $(ASM_HEXS) $(ACT4_BINS)
	@$(DOT_CLEAN_CMD)

$(BUILD_DIR)/%.bin: mr4src/asm/%.asm
	@mkdir -p $(BUILD_DIR)
	@echo "==> Assembling $< -> $@"
	@$(MR4ASM) -I $(LIB_DIR) "$<" -o "$@" -l "$(BUILD_DIR)/$*.lst"

$(BUILD_DIR)/%.hex: mr4src/asm/%.asm
	@mkdir -p $(BUILD_DIR)
	@echo "==> Assembling $< -> $@ (hex)"
	@$(MR4ASM) -I $(LIB_DIR) "$<" --hex -o "$@"

$(BUILD_DIR)/act4/%.asm: mr4src/act4/%.a4 | $(BUILD_DIR)/act4
	@echo "==> Compiling ACT4 $< -> $@"
	@$(ACT4C) -I $(LIB_DIR) "$<" -o "$@"

$(BUILD_DIR)/act4_%.bin: $(BUILD_DIR)/act4/%.asm
	@mkdir -p $(BUILD_DIR)
	@echo "==> Assembling $< -> $@"
	@$(MR4ASM) -I $(LIB_DIR) "$<" -o "$@" -l "$(BUILD_DIR)/act4_$*.lst"

$(BUILD_DIR)/act4 $(ULX3S_BLD):
	@mkdir -p $@

# ------------------------------------------------------------------------------
# Verification & Simulation Targets
# ------------------------------------------------------------------------------

test: test-rohd
	@$(DOT_CLEAN_CMD)

test-rohd: setup
	@echo "==> Assembling monitor.asm for ROHD boot test..."
	@$(MR4ASM) -I $(LIB_DIR) mr4src/asm/monitor.asm --hex -o $(ROHD_DIR)/system_image.hex
	@echo "==> Running MiniRISC4 ROHD test suite..."
	@cd $(ROHD_DIR) && $(DART) test
	@$(DOT_CLEAN_CMD)

sim: $(SIM_PROGRAM)
	@echo "==> Running $(SIM_PROGRAM) in mr4sim.py..."
	@$(MR4SIM) "$(SIM_PROGRAM)"

debug: $(SIM_PROGRAM)
	@echo "==> Debugging $(SIM_PROGRAM) in mr4sim.py (m4db)..."
	@$(MR4SIM) --debug --sym "$(SIM_PROGRAM:.bin=.lst)" "$(SIM_PROGRAM)"

# ------------------------------------------------------------------------------
# ULX3S-85F FPGA Synthesis, Timing, Programming & Serial Terminal
# ------------------------------------------------------------------------------

generate: generate-ulx3s

generate-ulx3s: setup | $(ULX3S_BLD)
	@echo "==> Building $(ULX3S_PROGRAM) for ULX3S-85F block RAM..."
	@case "$(ULX3S_PROGRAM)" in \
		*.a4) \
			$(ACT4C) -I $(LIB_DIR) "$(ULX3S_PROGRAM)" -o "$(ULX3S_BLD)/program.asm" && \
			$(MR4ASM) -I $(LIB_DIR) "$(ULX3S_BLD)/program.asm" --hex -o "$(ULX3S_BLD)/system_image.hex" -l "$(ULX3S_BLD)/program.lst" ;; \
		*) \
			$(MR4ASM) -I $(LIB_DIR) "$(ULX3S_PROGRAM)" --hex -o "$(ULX3S_BLD)/system_image.hex" -l "$(ULX3S_BLD)/program.lst" ;; \
	esac
	@echo "==> Generating SystemVerilog ($(ULX3S_BLD)/$(ULX3S_SV))..."
	@cd $(ROHD_DIR) && $(DART) run bin/generate.dart --hex system_image.hex --out ../../$(ULX3S_BLD)
	@$(DOT_CLEAN_CMD)

ulx3s-bit: generate-ulx3s
	@echo "==> Synthesizing with Yosys (log: $(ULX3S_BLD)/yosys.log)..."
	@cd $(ULX3S_BLD) && $(YOSYS) -q -l yosys.log \
		-p "read_verilog -sv $(ULX3S_SV); synth_ecp5 -top $(ULX3S_TOP) -json ulx3s_top_rohd.json"
	@grep -E "DP16KD|LUT4|TRELLIS_FF" $(ULX3S_BLD)/yosys.log | tail -5 || true
	@echo "==> Placing and routing for ECP5-$(ULX3S_DEVICE) (log: $(ULX3S_BLD)/nextpnr.log)..."
	@cd $(ULX3S_BLD) && $(NEXTPNR_ECP5) -q --$(ULX3S_DEVICE) --package $(ULX3S_PACKAGE) \
		--lpf ../../$(ULX3S_LPF) --json ulx3s_top_rohd.json \
		--textcfg ulx3s_top_rohd.config --freq $(ULX3S_CLOCK_MHZ) -l nextpnr.log
	@cd $(ULX3S_BLD) && $(ECPPACK) --compress ulx3s_top_rohd.config ulx3s_top_rohd.bit
	@grep "Max frequency for clock" $(ULX3S_BLD)/nextpnr.log | tail -1
	@echo "==> Bitstream ready: $(ULX3S_BIT)"
	@$(DOT_CLEAN_CMD)

ulx3s-timing:
	@if [ ! -f "$(ULX3S_BLD)/nextpnr.log" ]; then \
		echo "[FAIL] $(ULX3S_BLD)/nextpnr.log not found: run 'make ulx3s-bit' first."; exit 1; \
	fi
	@grep "Max frequency for clock" $(ULX3S_BLD)/nextpnr.log | tail -1
	@sed -n '/Critical path report for clock/,/^Info: *$$/p' $(ULX3S_BLD)/nextpnr.log | \
		awk '$$2=="clk-to-q" || $$2=="logic" || $$2=="routing" || $$2=="setup" { \
			n = $$6; if (length(n) > 90) n = substr(n, 1, 90) "..."; \
			printf "%-9s %6s %7s  %s\n", $$2, $$3, $$4, n }'

ulx3s-prog:
	@if [ ! -f "$(ULX3S_BIT)" ]; then \
		echo "[FAIL] $(ULX3S_BIT) not found: run 'make ulx3s-bit' first."; exit 1; \
	fi
	$(OPENFPGALOADER) -b ulx3s "$(ULX3S_BIT)"

ulx3s-flash:
	@if [ ! -f "$(ULX3S_BIT)" ]; then \
		echo "[FAIL] $(ULX3S_BIT) not found: run 'make ulx3s-bit' first."; exit 1; \
	fi
	$(OPENFPGALOADER) -b ulx3s -f "$(ULX3S_BIT)"

ulx3s-term:
	@if [ -z "$(ULX3S_PORT)" ]; then \
		echo "[FAIL] No USB serial port found: connect the ULX3S, or pass ULX3S_PORT=/dev/..."; exit 1; \
	fi
	@$(PYTHON) $(ROHD_DIR)/boards/ulx3s/ulx3s_term.py "$(ULX3S_PORT)" $(ULX3S_BAUD)

# ------------------------------------------------------------------------------
# Maintenance
# ------------------------------------------------------------------------------

dot-clean:
	@$(DOT_CLEAN_CMD)

clean:
	@echo "==> Cleaning build artifacts and generated SV files..."
	@rm -rf $(BUILD_DIR)
	@rm -f $(ROHD_DIR)/ulx3s_top_rohd.sv $(ROHD_DIR)/ulx3s_top_rohd.json \
	       $(ROHD_DIR)/ulx3s_top_rohd_out.config $(ROHD_DIR)/ulx3s_top_rohd.bit \
	       $(ROHD_DIR)/system_image.hex
	@$(DOT_CLEAN_CMD)

# ==============================================================================
# Makefile - MicroRISC4 Master Build, Simulation & ULX3S-85F FPGA Automation
# ==============================================================================

SHELL          := /bin/bash
DART           ?= dart
PYTHON         ?= $(shell command -v python3 2>/dev/null || echo python)

ROHD_DIR       := hdl/mr4
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

# ULX3S-85F FPGA, Multi-Core NoC & SDRAM Cache build settings
# Override any of these on the command line, e.g.:
#   make ulx3s-bit ULX3S_SDRAM_CACHE=1
#   make ulx3s-bit ULX3S_SDRAM_CACHE=1 ULX3S_NOC_CORES=4
#   make ulx3s-bit ULX3S_NOC_CORES=4 ULX3S_MEM_WORDS=2048 ULX3S_WORKER_MEM_WORDS=2048
ULX3S_BLD              := $(BUILD_DIR)/ulx3s
ULX3S_PROGRAM          ?= mr4src/asm/monitor.asm
ULX3S_WORKER_PROGRAM   ?=
ULX3S_NOC_CORES        ?= 0
ULX3S_SDRAM_CACHE      ?= 0
ULX3S_CACHE_LINES      ?= 64
ifeq ($(ULX3S_SDRAM_CACHE),1)
ULX3S_MEM_WORDS        ?= 2048
else
ULX3S_MEM_WORDS        ?= 65536
endif
ULX3S_WORKER_MEM_WORDS ?= 2048
ULX3S_NOC_CHANNELS     ?= 1
ULX3S_NOC_FIFO_DEPTH   ?= 16
ULX3S_DEVICE           ?= 85k
ULX3S_PACKAGE          ?= CABGA381
ULX3S_CLOCK_MHZ        ?= 48
ULX3S_ENABLE_SPI       ?= 0
ULX3S_ENABLE_MATH      ?= 0
ULX3S_LPF              := $(ROHD_DIR)/boards/ulx3s/ulx3s_v20.lpf
ULX3S_TOP              := Ulx3sTop
ULX3S_SV               := ulx3s_top_rohd.sv
ULX3S_BIT              := $(ULX3S_BLD)/ulx3s_top_rohd.bit

# ASIC RTL-to-GDS generation, preflight & ORFS Docker settings (separate from ULX3S FPGA)
ASIC_BLD               := $(BUILD_DIR)/asic
ASIC_TOP               := mr4_asic_top
ASIC_SV                := $(ASIC_BLD)/mr4_asic_top.sv
ASIC_BOOT_PROGRAM      ?= mr4src/asm/asic_boot.asm
ASIC_MEM_TARGET        ?= sram
ASIC_MEM_WORDS         ?= 2048
ASIC_MEM_LATENCY       ?= 1
ASIC_BOOT_ROM_BASE     ?= 256
ASIC_BOOT_ROM_WORDS    ?= 512
ASIC_CLOCK_MHZ         ?= 100
ASIC_UART_DIVISOR      ?= 868
ASIC_ENABLE_SPI        ?= 0
ASIC_ENABLE_MATH       ?= 0
ASIC_PLATFORM          ?= nangate45
ORFS_USE_DOCKER        ?= 1
ORFS_DOCKER_IMAGE      ?= openroad/orfs:latest
ORFS_ROOT              ?= $(HOME)/OpenROAD-flow-scripts
ORFS_TARGET            ?= finish
ORFS_EXTRA_ARGS         = $(if $(CLOCK_PERIOD),CLOCK_PERIOD="$(CLOCK_PERIOD)",) \
                          $(if $(CORE_UTILIZATION),CORE_UTILIZATION="$(CORE_UTILIZATION)",) \
                          $(if $(SYNTH_MOCK_LARGE_MEMORIES),SYNTH_MOCK_LARGE_MEMORIES="$(SYNTH_MOCK_LARGE_MEMORIES)",)

# Hierarchical Multi-Core ASIC Tile & Cluster settings (Track D.4)
ASIC_TILE_BLD          := $(BUILD_DIR)/asic_tile
ASIC_TILE_BOOT_PROGRAM ?= mr4src/asm/asic_tile_boot.asm
ASIC_TILE_CORES        ?= 4
ASIC_TILE_NOC_FIFO     ?= 16
ASIC_QUAD_TOP          ?= mr4_quad_top

# Tiny Tapeout MicroRISC4 (`tt_um_mr4`, Track E.1)
TINY_BLD               := $(BUILD_DIR)/asic_tiny
TINY_TOP               := tt_um_mr4
TINY_SV                := $(TINY_BLD)/tt_um_mr4.sv
TINY_BOOT_PROGRAM      ?= mr4src/asm/tiny_boot.asm
TINY_BOOT_ROM_BASE     ?= 256
TINY_BOOT_ROM_WORDS    ?= 256
TINY_LOCAL_RAM_WORDS   ?= 8
TINY_CLOCK_MHZ         ?= 50
TINY_UART_DIVISOR      ?= 432
TINY_PLATFORM          ?= $(if $(filter command line,$(origin ASIC_PLATFORM)),$(ASIC_PLATFORM),sky130hd)

YOSYS          ?= yosys
IVERILOG       ?= iverilog
VVP            ?= vvp
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
        generate generate-ulx3s ulx3s-bit ulx3s-mr4os ulx3s-timing ulx3s-prog ulx3s-flash ulx3s-term \
        generate-asic asic-check asic-flow \
        generate-asic-tile asic-tile-check asic-tile-flow asic-quad-flow \
        generate-tiny tiny-check tiny-sim tiny-flow tiny-gls asic-clean \
        dot-clean clean

# ------------------------------------------------------------------------------
# Top-Level Targets
# ------------------------------------------------------------------------------

all: build test
	@$(DOT_CLEAN_CMD)

help:
	@echo "MicroRISC4 Build, Test & ULX3S-85F Automation"
	@echo "============================================"
	@echo "  make setup            - Fetch Dart dependencies for $(ROHD_DIR)"
	@echo "  make analyze          - Run dart analyze on the ROHD HDL"
	@echo "  make build            - Build ASM & ACT4 apps and generate ULX3S SystemVerilog"
	@echo "  make apps             - Assemble mr4src/asm/*.asm and compile mr4src/act4/*.a4"
	@echo "  make test             - Run all ROHD unit and firmware boot tests"
	@echo "  make test-rohd        - Run ROHD Dart test suite (assembles monitor hex first)"
	@echo "  make os-test          - Run OS, compiler, FAT32, and multi-core regression tests (alias: test-os)"
	@echo "  make sim              - Run a binary in mr4sim.py (SIM_PROGRAM=build/monitor.bin)"
	@echo "  make debug            - Run mr4sim.py in interactive m4db debugger mode"
	@echo "  make generate         - Alias for generate-ulx3s"
	@echo "  make generate-ulx3s   - Assemble ULX3S_PROGRAM and generate SV in $(ULX3S_BLD)"
	@echo "                          Options: ULX3S_CLOCK_MHZ=48|60|72|84|96 ULX3S_SDRAM_CACHE=0|1"
	@echo "                                   ULX3S_CACHE_LINES=64 ULX3S_NOC_CORES=0|2|3|4..."
	@echo "                                   ULX3S_MEM_WORDS=65536|2048 ULX3S_WORKER_MEM_WORDS=2048"
	@echo "                                   ULX3S_WORKER_PROGRAM=... ULX3S_NOC_FIFO_DEPTH=16"
	@echo "  make ulx3s-bit        - Synthesize, place & route, and pack $(ULX3S_BIT)"
	@echo "  make ulx3s-mr4os      - Build live 4-core MR4OS + SDRAM + SPI + Math ULX3S bitstream"
	@echo "  make ulx3s-timing     - Show Fmax and critical path from $(ULX3S_BLD)/nextpnr.log"
	@echo "  make ulx3s-prog       - Load $(ULX3S_BIT) into ULX3S SRAM ($(OPENFPGALOADER))"
	@echo "  make ulx3s-flash      - Write $(ULX3S_BIT) to ULX3S SPI flash"
	@echo "  make ulx3s-term       - Open 3 Mbaud FTDI serial terminal (ULX3S_PORT=..., ULX3S_BAUD=3000000)"
	@echo "  make generate-asic    - Generate clean ASIC SystemVerilog ($(ASIC_SV))"
	@echo "  make asic-check       - Run Yosys structural preflight on $(ASIC_SV)"
	@echo "  make asic-flow        - Run OpenROAD-flow-scripts RTL-to-GDS via Docker (ASIC_PLATFORM=nangate45|asap7|sky130hd)"
	@echo "  make generate-asic-tile - Generate hardened mr4_tile.sv + hierarchical mr4_quad_top.sv (Track D.4)"
	@echo "  make asic-tile-check  - Run Yosys structural preflight on mr4_tile and hierarchical mr4_quad_top"
	@echo "  make asic-tile-flow   - Harden 1x mr4_tile macro & export LEF/LIB/GDS abstracts via ORFS Docker"
	@echo "  make asic-quad-flow   - Assemble 4-tile mr4_quad_top chip from hardened mr4_tile macro via ORFS Docker"
	@echo "  make generate-tiny    - Assemble tiny_boot.asm & generate Tiny Tapeout tt_um_mr4.sv (Track E.1)"
	@echo "  make tiny-check       - Run Yosys structural & synth preflight on build/asic_tiny/tt_um_mr4.sv"
	@echo "  make tiny-sim         - Run 4-state Icarus Verilog RTL sim of tt_um_mr4 + QSPI PSRAM + UART"
	@echo "  make tiny-flow        - Run ORFS RTL-to-GDS for 2x2 Tiny Tapeout tile (TINY_PLATFORM=sky130hd|ihp-sg13g2)"
	@echo "  make tiny-gls         - Run post-route Gate-Level Simulation (GLS) on routed 6_final.v netlist"
	@echo "  make asic-clean       - Clean cached ORFS outputs (ASIC_PLATFORM=nangate45|asap7|all, optional ASIC_DESIGN=...)"
	@echo "  make dot-clean        - Remove macOS ._ metadata files (where dot_clean exists)"
	@echo "  make clean            - Remove $(BUILD_DIR)/ and generated SV/bitstream artifacts"
	@echo "  make install-hooks    - Install the project's git hooks (tools/git-hooks) into this clone"

setup:
	@echo "==> Fetching Dart dependencies for MicroRISC4 ROHD..."
	@cd $(ROHD_DIR) && $(DART) pub get

analyze: setup
	@echo "==> Analyzing MicroRISC4 ROHD..."
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
	@echo "==> Running MicroRISC4 ROHD test suite..."
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
			$(ACT4C) -I "$(dir $(ULX3S_PROGRAM))" -I $(LIB_DIR) "$(ULX3S_PROGRAM)" -o "$(ULX3S_BLD)/program.asm" && \
			$(MR4ASM) -I $(LIB_DIR) "$(ULX3S_BLD)/program.asm" --hex -o "$(ULX3S_BLD)/system_image.hex" -l "$(ULX3S_BLD)/program.lst" ;; \
		*) \
			$(MR4ASM) -I $(LIB_DIR) "$(ULX3S_PROGRAM)" --hex -o "$(ULX3S_BLD)/system_image.hex" -l "$(ULX3S_BLD)/program.lst" ;; \
	esac
	@if [ -n "$(ULX3S_WORKER_PROGRAM)" ]; then \
		echo "==> Building worker $(ULX3S_WORKER_PROGRAM) for worker cores 1..N-1..."; \
		case "$(ULX3S_WORKER_PROGRAM)" in \
			*.a4) \
				$(ACT4C) -I "$(dir $(ULX3S_WORKER_PROGRAM))" -I $(LIB_DIR) "$(ULX3S_WORKER_PROGRAM)" -o "$(ULX3S_BLD)/worker.asm" && \
				$(MR4ASM) -I $(LIB_DIR) "$(ULX3S_BLD)/worker.asm" --hex -o "$(ULX3S_BLD)/worker_image.hex" -l "$(ULX3S_BLD)/worker.lst" ;; \
			*) \
				$(MR4ASM) -I $(LIB_DIR) "$(ULX3S_WORKER_PROGRAM)" --hex -o "$(ULX3S_BLD)/worker_image.hex" -l "$(ULX3S_BLD)/worker.lst" ;; \
		esac; \
	fi
	@echo "==> Generating SystemVerilog ($(ULX3S_BLD)/$(ULX3S_SV))..."
	@cd $(ROHD_DIR) && $(DART) run bin/generate.dart \
		--hex system_image.hex \
		--out "$(CURDIR)/$(ULX3S_BLD)" \
		--clk-mhz "$(ULX3S_CLOCK_MHZ)" \
		--mem-words "$(ULX3S_MEM_WORDS)" \
		--worker-mem-words "$(ULX3S_WORKER_MEM_WORDS)" \
		--noc-cores "$(ULX3S_NOC_CORES)" \
		--noc-channels "$(ULX3S_NOC_CHANNELS)" \
		--noc-fifo-depth "$(ULX3S_NOC_FIFO_DEPTH)" \
		$(if $(filter 1,$(ULX3S_SDRAM_CACHE)),--sdram-cache --cache-lines "$(ULX3S_CACHE_LINES)",) \
		$(if $(filter 1,$(ULX3S_ENABLE_SPI)),--enable-spi,) \
		$(if $(filter-out 0 none,$(ULX3S_ENABLE_MATH)),--enable-math "$(ULX3S_ENABLE_MATH)",) \
		$(if $(ULX3S_WORKER_PROGRAM),--worker-hex worker_image.hex,)
	@$(DOT_CLEAN_CMD)

ulx3s-bit: generate-ulx3s
	@echo "==> Synthesizing with Yosys (log: $(ULX3S_BLD)/yosys.log)..."
	@cd $(ULX3S_BLD) && $(YOSYS) -q -l yosys.log \
		-p "read_verilog -sv $(ULX3S_SV); synth_ecp5 -top $(ULX3S_TOP) -json ulx3s_top_rohd.json"
	@grep -E "DP16KD|LUT4|TRELLIS_FF" $(ULX3S_BLD)/yosys.log | tail -5 || true
	@echo "==> Placing and routing for ECP5-$(ULX3S_DEVICE) (log: $(ULX3S_BLD)/nextpnr.log)..."
	@cd $(ULX3S_BLD) && $(NEXTPNR_ECP5) -q --$(ULX3S_DEVICE) --package $(ULX3S_PACKAGE) \
		--lpf "$(CURDIR)/$(ULX3S_LPF)" --json ulx3s_top_rohd.json \
		--placer-heap-timingweight 25 --placer-heap-critexp 3 \
		--textcfg ulx3s_top_rohd.config --freq $(ULX3S_CLOCK_MHZ) -l nextpnr.log
	@cd $(ULX3S_BLD) && $(ECPPACK) --compress ulx3s_top_rohd.config ulx3s_top_rohd.bit
	@grep "Max frequency for clock" $(ULX3S_BLD)/nextpnr.log | tail -1
	@echo "==> Bitstream ready: $(ULX3S_BIT)"
	@$(DOT_CLEAN_CMD)

ulx3s-mr4os:
	@"$(MAKE)" ulx3s-bit \
		ULX3S_PROGRAM=mr4src/act4/os/os_main.a4 \
		ULX3S_WORKER_PROGRAM=mr4src/asm/worker_stub.asm \
		ULX3S_NOC_CORES=4 \
		ULX3S_SDRAM_CACHE=1 \
		ULX3S_ENABLE_SPI=1 \
		ULX3S_ENABLE_MATH=all \
		ULX3S_MEM_WORDS=65536 \
		ULX3S_WORKER_MEM_WORDS=2048 \
		ULX3S_CLOCK_MHZ=72

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
# ASIC RTL Generation & Structural Preflight (Road to OpenROAD, Track D.2)
# ------------------------------------------------------------------------------

$(ASIC_BLD):
	mkdir -p $(ASIC_BLD)

generate-asic: setup | $(ASIC_BLD)
	@echo "==> Assembling ASIC Boot ROM ($(ASIC_BOOT_PROGRAM)) -> $(ASIC_BLD)/boot_rom.hex..."
	@case "$(ASIC_BOOT_PROGRAM)" in \
		*.a4) \
			$(ACT4C) -I "$(dir $(ASIC_BOOT_PROGRAM))" -I $(LIB_DIR) "$(ASIC_BOOT_PROGRAM)" -o "$(ASIC_BLD)/boot_rom.asm" && \
			$(MR4ASM) -I $(LIB_DIR) "$(ASIC_BLD)/boot_rom.asm" --hex -o "$(ASIC_BLD)/boot_rom.hex" -l "$(ASIC_BLD)/boot_rom.lst" ;; \
		*) \
			$(MR4ASM) -I $(LIB_DIR) "$(ASIC_BOOT_PROGRAM)" --hex -o "$(ASIC_BLD)/boot_rom.hex" -l "$(ASIC_BLD)/boot_rom.lst" ;; \
	esac
	@echo "==> Generating ASIC SystemVerilog ($(ASIC_SV))..."
	@cd $(ROHD_DIR) && $(DART) run bin/generate_asic.dart \
		--boot-hex "$(CURDIR)/$(ASIC_BLD)/boot_rom.hex" \
		--boot-rom-base "$(ASIC_BOOT_ROM_BASE)" \
		--boot-rom-words "$(ASIC_BOOT_ROM_WORDS)" \
		--out "$(CURDIR)/$(ASIC_BLD)" \
		--mem-target "$(ASIC_MEM_TARGET)" \
		--mem-words "$(ASIC_MEM_WORDS)" \
		--mem-latency "$(ASIC_MEM_LATENCY)" \
		--clk-mhz "$(ASIC_CLOCK_MHZ)" \
		--uart-divisor "$(ASIC_UART_DIVISOR)" \
		$(if $(filter 1,$(ASIC_ENABLE_SPI)),--enable-spi,) \
		$(if $(filter 1,$(ASIC_ENABLE_MATH)),--enable-math,)
	@$(DOT_CLEAN_CMD)

asic-check: generate-asic
	@echo "==> Checking $(ASIC_SV) for forbidden FPGA/ECP5 primitives..."
	@if grep -n -E "EHXPLLL|ODDRX1F|ram_style|syn_useioff|\\\$$readmemh" "$(ASIC_SV)"; then \
		echo "[FAIL] Forbidden FPGA primitive or \$$readmemh found in $(ASIC_SV)!"; exit 1; \
	fi
	@echo "==> Running Yosys ASIC structural preflight (log: $(ASIC_BLD)/asic_check.log)..."
	@$(YOSYS) -l "$(ASIC_BLD)/asic_check.log" \
		-p "read_verilog -sv -DSYNTHESIS $(ASIC_SV); hierarchy -check -top $(ASIC_TOP); proc; opt; check -assert; stat" | tail -n 35
	@echo "==> [PASS] ASIC structural preflight clean: $(ASIC_SV)"
	@$(DOT_CLEAN_CMD)

# End-to-end OpenROAD-flow-scripts RTL-to-GDS flow.
# Defaults to standalone flop-RAM mode (1024w) when running public-PDK dry runs
# without foundry SRAM macros; override ASIC_MEM_TARGET=sram when supplying LEF/LIB.
asic-flow:
	@"$(MAKE)" generate-asic \
		ASIC_MEM_TARGET="$(if $(filter command line,$(origin ASIC_MEM_TARGET)),$(ASIC_MEM_TARGET),flop)" \
		ASIC_MEM_WORDS="$(if $(filter command line,$(origin ASIC_MEM_WORDS)),$(ASIC_MEM_WORDS),1024)"
	@mkdir -p "$(ASIC_BLD)/orfs"
	@if [ "$(ORFS_USE_DOCKER)" = "1" ]; then \
		command -v docker >/dev/null 2>&1 || { \
			echo "[FAIL] docker not found in PATH. See GettingStarted.md for Docker + ORFS setup."; exit 1; \
		}; \
		HOST_ROOT="$(CURDIR)"; \
		if command -v cygpath >/dev/null 2>&1; then \
			HOST_ROOT="$$(cygpath -w "$(CURDIR)")"; \
		fi; \
		DOCKER_USER_FLAG=""; \
		if [ "$$(uname -s)" = "Linux" ]; then \
			DOCKER_USER_FLAG="-u $$(id -u):$$(id -g)"; \
		fi; \
		echo "==> Running ORFS ($(ASIC_PLATFORM), target=$(ORFS_TARGET)) in Docker ($(ORFS_DOCKER_IMAGE))..."; \
		MSYS_NO_PATHCONV=1 docker run --rm $$DOCKER_USER_FLAG \
			-v "$$HOST_ROOT:/work/mr4" \
			"$(ORFS_DOCKER_IMAGE)" \
			bash -c 'cd /OpenROAD-flow-scripts && [ -f ./env.sh ] && source ./env.sh; exec make -C /OpenROAD-flow-scripts/flow DESIGN_CONFIG=/work/mr4/asic/mr4/config.mk WORK_HOME=/work/mr4/build/asic/orfs PLATFORM="$(ASIC_PLATFORM)" $(ORFS_EXTRA_ARGS) $(ORFS_TARGET)'; \
	else \
		if [ ! -f "$(ORFS_ROOT)/flow/Makefile" ]; then \
			echo "[FAIL] ORFS Makefile not found at $(ORFS_ROOT)/flow/Makefile (set ORFS_ROOT or ORFS_USE_DOCKER=1)."; exit 1; \
		fi; \
		echo "==> Running native ORFS ($(ASIC_PLATFORM), target=$(ORFS_TARGET)) from $(ORFS_ROOT)..."; \
		bash -c 'cd "$(ORFS_ROOT)" && [ -f ./env.sh ] && source ./env.sh; exec "$(MAKE)" -C "$(ORFS_ROOT)/flow" DESIGN_CONFIG="$(CURDIR)/asic/mr4/config.mk" WORK_HOME="$(CURDIR)/$(ASIC_BLD)/orfs" PLATFORM="$(ASIC_PLATFORM)" $(ORFS_EXTRA_ARGS) $(ORFS_TARGET)'; \
	fi
	@echo "==> ORFS outputs under: $(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/$(ASIC_TOP)/base/"
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Hierarchical Multi-Core ASIC Tile Macro & Cluster Flow (Track D.4)
# ------------------------------------------------------------------------------

$(ASIC_TILE_BLD):
	mkdir -p $(ASIC_TILE_BLD)

generate-asic-tile: setup | $(ASIC_TILE_BLD)
	@echo "==> Assembling unified Tile Boot ROM ($(ASIC_TILE_BOOT_PROGRAM)) -> $(ASIC_TILE_BLD)/tile_boot.hex..."
	@$(MR4ASM) -I $(LIB_DIR) "$(ASIC_TILE_BOOT_PROGRAM)" --hex -o "$(ASIC_TILE_BLD)/tile_boot.hex" -l "$(ASIC_TILE_BLD)/tile_boot.lst"
	@echo "==> Generating mr4_tile.sv, hierarchical $(ASIC_QUAD_TOP).sv, and $(ASIC_QUAD_TOP)_sim.sv..."
	@cd $(ROHD_DIR) && $(DART) run bin/generate_asic_tile.dart \
		--boot-hex "$(CURDIR)/$(ASIC_TILE_BLD)/tile_boot.hex" \
		--boot-rom-base "$(ASIC_BOOT_ROM_BASE)" \
		--boot-rom-words "$(ASIC_BOOT_ROM_WORDS)" \
		--out "$(CURDIR)/$(ASIC_TILE_BLD)" \
		--mem-target "$(if $(filter command line,$(origin ASIC_MEM_TARGET)),$(ASIC_MEM_TARGET),flop)" \
		--mem-words "$(if $(filter command line,$(origin ASIC_MEM_WORDS)),$(ASIC_MEM_WORDS),1024)" \
		--mem-latency "$(ASIC_MEM_LATENCY)" \
		--clk-mhz "$(ASIC_CLOCK_MHZ)" \
		--uart-divisor "$(ASIC_UART_DIVISOR)" \
		--num-tiles "$(ASIC_TILE_CORES)" \
		--noc-fifo-depth "$(ASIC_TILE_NOC_FIFO)" \
		--top-name "$(ASIC_QUAD_TOP)" \
		$(if $(filter 1,$(ASIC_ENABLE_MATH)),--enable-math,)
	@$(DOT_CLEAN_CMD)

asic-tile-check: generate-asic-tile
	@echo "==> Checking $(ASIC_TILE_BLD)/mr4_tile.sv and $(ASIC_TILE_BLD)/$(ASIC_QUAD_TOP).sv for forbidden FPGA primitives..."
	@if grep -n -E "EHXPLLL|ODDRX1F|ram_style|syn_useioff|\\\$$readmemh" "$(ASIC_TILE_BLD)/mr4_tile.sv" "$(ASIC_TILE_BLD)/$(ASIC_QUAD_TOP).sv"; then \
		echo "[FAIL] Forbidden FPGA primitive or \$$readmemh found in tile ASIC RTL!"; exit 1; \
	fi
	@echo "==> Running Yosys preflight on mr4_tile (log: $(ASIC_TILE_BLD)/tile_check.log)..."
	@$(YOSYS) -l "$(ASIC_TILE_BLD)/tile_check.log" \
		-p "read_verilog -sv -DSYNTHESIS $(ASIC_TILE_BLD)/mr4_tile.sv; hierarchy -check -top mr4_tile; proc; opt; check -assert; stat" | tail -n 25
	@echo "==> Running Yosys preflight on hierarchical $(ASIC_QUAD_TOP) (log: $(ASIC_TILE_BLD)/quad_check.log)..."
	@$(YOSYS) -l "$(ASIC_TILE_BLD)/quad_check.log" \
		-p "read_verilog -sv -DSYNTHESIS $(ASIC_TILE_BLD)/$(ASIC_QUAD_TOP).sv; hierarchy -check -top $(ASIC_QUAD_TOP); proc; opt; check -assert; stat" | tail -n 20
	@echo "==> [PASS] Hierarchical mr4_tile + $(ASIC_QUAD_TOP) ASIC structural preflight clean!"
	@$(DOT_CLEAN_CMD)

# Step 1 (Track D.4): Harden 1x reusable `mr4_tile` macro and export LEF/LIB/GDS abstracts.
asic-tile-flow:
	@"$(MAKE)" generate-asic-tile \
		ASIC_MEM_TARGET="$(if $(filter command line,$(origin ASIC_MEM_TARGET)),$(ASIC_MEM_TARGET),flop)" \
		ASIC_MEM_WORDS="$(if $(filter command line,$(origin ASIC_MEM_WORDS)),$(ASIC_MEM_WORDS),1024)"
	@mkdir -p "$(ASIC_BLD)/orfs"
	@if [ "$(ORFS_USE_DOCKER)" = "1" ]; then \
		command -v docker >/dev/null 2>&1 || { \
			echo "[FAIL] docker not found in PATH. See GettingStarted.md for Docker + ORFS setup."; exit 1; \
		}; \
		HOST_ROOT="$(CURDIR)"; \
		if command -v cygpath >/dev/null 2>&1; then \
			HOST_ROOT="$$(cygpath -w "$(CURDIR)")"; \
		fi; \
		DOCKER_USER_FLAG=""; \
		if [ "$$(uname -s)" = "Linux" ]; then \
			DOCKER_USER_FLAG="-u $$(id -u):$$(id -g)"; \
		fi; \
		echo "==> Hardening reusable mr4_tile macro ($(ASIC_PLATFORM)) in Docker ($(ORFS_DOCKER_IMAGE))..."; \
		MSYS_NO_PATHCONV=1 docker run --rm $$DOCKER_USER_FLAG \
			-v "$$HOST_ROOT:/work/mr4" \
			"$(ORFS_DOCKER_IMAGE)" \
			bash -c 'cd /OpenROAD-flow-scripts && [ -f ./env.sh ] && source ./env.sh; exec make -C /OpenROAD-flow-scripts/flow DESIGN_CONFIG=/work/mr4/asic/mr4_tile/config.mk WORK_HOME=/work/mr4/build/asic/orfs PLATFORM="$(ASIC_PLATFORM)" $(ORFS_EXTRA_ARGS) finish generate_abstract'; \
	else \
		bash -c 'cd "$(ORFS_ROOT)" && [ -f ./env.sh ] && source ./env.sh; exec "$(MAKE)" -C "$(ORFS_ROOT)/flow" DESIGN_CONFIG="$(CURDIR)/asic/mr4_tile/config.mk" WORK_HOME="$(CURDIR)/$(ASIC_BLD)/orfs" PLATFORM="$(ASIC_PLATFORM)" $(ORFS_EXTRA_ARGS) finish generate_abstract'; \
	fi
	@echo "==> Hardened mr4_tile abstracts ready under: $(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/mr4_tile/base/"
	@$(DOT_CLEAN_CMD)

# Step 2 (Track D.4): Assemble 4-tile hierarchical `mr4_quad_top` chip from hardened `mr4_tile` macro.
asic-quad-flow:
	@if [ ! -f "$(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/mr4_tile/base/mr4_tile.lef" ] || \
	    ( [ ! -f "$(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/mr4_tile/base/mr4_tile_typ.lib" ] && \
	      [ ! -f "$(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/mr4_tile/base/mr4_tile.lib" ] ); then \
		echo "[FAIL] Hardened mr4_tile abstracts not found for $(ASIC_PLATFORM). Run 'make asic-tile-flow ASIC_PLATFORM=$(ASIC_PLATFORM)' first."; exit 1; \
	fi
	@if [ ! -f "$(ASIC_TILE_BLD)/$(ASIC_QUAD_TOP).sv" ]; then \
		"$(MAKE)" generate-asic-tile; \
	fi
	@TILE_LEF="$(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/mr4_tile/base/mr4_tile.lef"; \
	QUAD_FP="$(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/$(ASIC_QUAD_TOP)/base/2_1_floorplan.odb"; \
	if [ -f "$$QUAD_FP" ] && [ "$$TILE_LEF" -nt "$$QUAD_FP" ]; then \
		echo "==> Hardened mr4_tile.lef is newer than $(ASIC_QUAD_TOP) floorplan; clearing stale $(ASIC_QUAD_TOP) stages..."; \
		rm -rf "$(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/$(ASIC_QUAD_TOP)" \
		       "$(ASIC_BLD)/orfs/objects/$(ASIC_PLATFORM)/$(ASIC_QUAD_TOP)"; \
	fi
	@if [ "$(ORFS_USE_DOCKER)" = "1" ]; then \
		command -v docker >/dev/null 2>&1 || { \
			echo "[FAIL] docker not found in PATH. See GettingStarted.md for Docker + ORFS setup."; exit 1; \
		}; \
		HOST_ROOT="$(CURDIR)"; \
		if command -v cygpath >/dev/null 2>&1; then \
			HOST_ROOT="$$(cygpath -w "$(CURDIR)")"; \
		fi; \
		DOCKER_USER_FLAG=""; \
		if [ "$$(uname -s)" = "Linux" ]; then \
			DOCKER_USER_FLAG="-u $$(id -u):$$(id -g)"; \
		fi; \
		echo "==> Assembling hierarchical 4-tile $(ASIC_QUAD_TOP) ($(ASIC_PLATFORM)) in Docker ($(ORFS_DOCKER_IMAGE))..."; \
		MSYS_NO_PATHCONV=1 docker run --rm $$DOCKER_USER_FLAG \
			-v "$$HOST_ROOT:/work/mr4" \
			"$(ORFS_DOCKER_IMAGE)" \
			bash -c 'cd /OpenROAD-flow-scripts && [ -f ./env.sh ] && source ./env.sh; exec make -C /OpenROAD-flow-scripts/flow DESIGN_CONFIG=/work/mr4/asic/mr4_quad/config.mk WORK_HOME=/work/mr4/build/asic/orfs PLATFORM="$(ASIC_PLATFORM)" $(ORFS_EXTRA_ARGS) $(ORFS_TARGET)'; \
	else \
		bash -c 'cd "$(ORFS_ROOT)" && [ -f ./env.sh ] && source ./env.sh; exec "$(MAKE)" -C "$(ORFS_ROOT)/flow" DESIGN_CONFIG="$(CURDIR)/asic/mr4_quad/config.mk" WORK_HOME="$(CURDIR)/$(ASIC_BLD)/orfs" PLATFORM="$(ASIC_PLATFORM)" $(ORFS_EXTRA_ARGS) $(ORFS_TARGET)'; \
	fi
	@echo "==> Hierarchical 4-tile $(ASIC_QUAD_TOP) GDSII ready under: $(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/$(ASIC_QUAD_TOP)/base/"
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Tiny Tapeout MicroRISC4 (`tt_um_mr4`, Track E.1)
# ------------------------------------------------------------------------------

$(TINY_BLD):
	mkdir -p $(TINY_BLD)

generate-tiny: setup | $(TINY_BLD)
	@echo "==> Assembling Tiny Tapeout Boot ROM ($(TINY_BOOT_PROGRAM)) -> $(TINY_BLD)/tiny_boot.hex..."
	@$(MR4ASM) -I $(LIB_DIR) "$(TINY_BOOT_PROGRAM)" --hex -o "$(TINY_BLD)/tiny_boot.hex" -l "$(TINY_BLD)/tiny_boot.lst"
	@echo "==> Generating Tiny Tapeout SystemVerilog ($(TINY_SV))..."
	@cd $(ROHD_DIR) && $(DART) run bin/generate_tiny.dart \
		--boot-hex "$(CURDIR)/$(TINY_BLD)/tiny_boot.hex" \
		--boot-rom-base "$(TINY_BOOT_ROM_BASE)" \
		--boot-rom-words "$(TINY_BOOT_ROM_WORDS)" \
		--local-ram-words "$(TINY_LOCAL_RAM_WORDS)" \
		--clk-mhz "$(TINY_CLOCK_MHZ)" \
		--uart-divisor "$(TINY_UART_DIVISOR)" \
		--out "$(CURDIR)/$(TINY_BLD)"
	@$(DOT_CLEAN_CMD)

tiny-check: generate-tiny
	@echo "==> Checking $(TINY_SV) for forbidden FPGA/ECP5 primitives..."
	@if grep -n -E "EHXPLLL|ODDRX1F|ram_style|syn_useioff|\\\$$readmemh" "$(TINY_SV)"; then \
		echo "[FAIL] Forbidden FPGA primitive or \$$readmemh found in $(TINY_SV)!"; exit 1; \
	fi
	@echo "==> Running Yosys Tiny Tapeout structural + synth preflight (log: $(TINY_BLD)/tiny_check.log)..."
	@$(YOSYS) -l "$(TINY_BLD)/tiny_check.log" \
		-p "read_verilog -sv -DSYNTHESIS $(TINY_SV); hierarchy -check -top $(TINY_TOP); proc; opt; check -assert; synth -top $(TINY_TOP); stat" | tail -n 35
	@echo "==> [PASS] Tiny Tapeout structural & synthesis preflight clean: $(TINY_SV)"
	@$(DOT_CLEAN_CMD)

tiny-flow: generate-tiny
	@mkdir -p "$(ASIC_BLD)/orfs"
	@if [ "$(ORFS_USE_DOCKER)" = "1" ]; then \
		command -v docker >/dev/null 2>&1 || { \
			echo "[FAIL] docker not found in PATH. See GettingStarted.md for Docker + ORFS setup."; exit 1; \
		}; \
		HOST_ROOT="$(CURDIR)"; \
		if command -v cygpath >/dev/null 2>&1; then \
			HOST_ROOT="$$(cygpath -w "$(CURDIR)")"; \
		fi; \
		DOCKER_USER_FLAG=""; \
		if [ "$$(uname -s)" = "Linux" ]; then \
			DOCKER_USER_FLAG="-u $$(id -u):$$(id -g)"; \
		fi; \
		echo "==> Running ORFS Tiny Tapeout flow ($(TINY_PLATFORM), target=$(ORFS_TARGET)) in Docker ($(ORFS_DOCKER_IMAGE))..."; \
		MSYS_NO_PATHCONV=1 docker run --rm $$DOCKER_USER_FLAG \
			-v "$$HOST_ROOT:/work/mr4" \
			"$(ORFS_DOCKER_IMAGE)" \
			bash -c 'cd /OpenROAD-flow-scripts && [ -f ./env.sh ] && source ./env.sh; exec make -C /OpenROAD-flow-scripts/flow DESIGN_CONFIG=/work/mr4/asic/mr4_tiny/config.mk WORK_HOME=/work/mr4/build/asic/orfs PLATFORM="$(TINY_PLATFORM)" $(ORFS_EXTRA_ARGS) $(ORFS_TARGET)'; \
	else \
		bash -c 'cd "$(ORFS_ROOT)" && [ -f ./env.sh ] && source ./env.sh; exec "$(MAKE)" -C "$(ORFS_ROOT)/flow" DESIGN_CONFIG="$(CURDIR)/asic/mr4_tiny/config.mk" WORK_HOME="$(CURDIR)/$(ASIC_BLD)/orfs" PLATFORM="$(TINY_PLATFORM)" $(ORFS_EXTRA_ARGS) $(ORFS_TARGET)'; \
	fi
	@echo "==> Tiny Tapeout $(TINY_TOP) GDSII ready under: $(ASIC_BLD)/orfs/results/$(TINY_PLATFORM)/$(TINY_TOP)/base/"
	@$(DOT_CLEAN_CMD)

# 4-state Icarus Verilog RTL simulation of tt_um_mr4 (cold boot, UART loader -> QSPI PSRAM -> execute)
tiny-sim: generate-tiny
	@echo "==> Assembling Tiny Tapeout test payload (asic/mr4_tiny/tiny_payload.asm)..."
	@$(MR4ASM) -I $(LIB_DIR) asic/mr4_tiny/tiny_payload.asm --hex -o "$(TINY_BLD)/tiny_payload.hex"
	@echo "==> Compiling 4-state RTL testbench with $(IVERILOG)..."
	@$(IVERILOG) -g2012 -DSYNTHESIS -Ptb_tt_um_mr4.UART_DIV=$(TINY_UART_DIVISOR) \
		-o "$(TINY_BLD)/tb_tt_um_mr4_rtl.vvp" \
		asic/mr4_tiny/tb_tt_um_mr4.sv "$(TINY_SV)"
	@echo "==> Running 4-state RTL simulation ($(VVP))..."
	@$(VVP) "$(TINY_BLD)/tb_tt_um_mr4_rtl.vvp" "+PAYLOAD_HEX=$(TINY_BLD)/tiny_payload.hex"
	@$(DOT_CLEAN_CMD)

# Post-Route Gate-Level Simulation (GLS) of routed ORFS 6_final.v netlist
# Usage:
#   make tiny-gls TINY_PLATFORM=sky130hd
#   make tiny-gls TINY_PLATFORM=ihp-sg13g2
# Automatically extracts official PDK .v models (e.g. sg13g2_stdcell.v) or generates
# exact 4-state Liberty behavioral cell models via tools/lib2vlog.py from ORFS Docker,
# then runs Icarus Verilog (`iverilog`/`vvp`) on the actual post-route `6_final.v`!
tiny-gls:
	@NETLIST="$(ASIC_BLD)/orfs/results/$(TINY_PLATFORM)/$(TINY_TOP)/base/6_final.v"; \
	if [ ! -f "$$NETLIST" ]; then \
		echo "[FAIL] Routed netlist not found: $$NETLIST. Run 'make tiny-flow TINY_PLATFORM=$(TINY_PLATFORM)' first."; exit 1; \
	fi
	@mkdir -p "$(TINY_BLD)"
	@$(MR4ASM) -I $(LIB_DIR) asic/mr4_tiny/tiny_payload.asm --hex -o "$(TINY_BLD)/tiny_payload.hex"
	@CELL_MODELS="$(GLS_STDCELL_V)"; \
	if [ -z "$$CELL_MODELS" ]; then \
		OUT_CELLS="$(TINY_BLD)/gls_$(TINY_PLATFORM)_cells.v"; \
		HOST_ROOT="$(CURDIR)"; \
		if command -v cygpath >/dev/null 2>&1; then HOST_ROOT="$$(cygpath -w "$(CURDIR)")"; fi; \
		echo "==> Preparing $(TINY_PLATFORM) standard-cell GLS models -> $$OUT_CELLS..."; \
		MSYS_NO_PATHCONV=1 docker run --rm -v "$$HOST_ROOT:/work/mr4" "$(ORFS_DOCKER_IMAGE)" \
			bash -c 'set -e; LIBS=$$(find /OpenROAD-flow-scripts/flow/platforms/$(TINY_PLATFORM)/lib -name "*.lib" | grep -E "stdcell.*typ|sc_hd.*tt|Nangate|asap7" | head -n 4); if [ -z "$$LIBS" ]; then LIBS=$$(find /OpenROAD-flow-scripts/flow/platforms/$(TINY_PLATFORM)/lib -name "*.lib"); fi; echo "Using Liberty: $$LIBS"; python3 /work/mr4/tools/lib2vlog.py --lib $$LIBS --netlist /work/mr4/build/asic/orfs/results/$(TINY_PLATFORM)/$(TINY_TOP)/base/6_final.v --out /work/mr4/build/asic_tiny/gls_$(TINY_PLATFORM)_cells.v'; \
		CELL_MODELS="$$OUT_CELLS"; \
	fi; \
	echo "==> Compiling post-route GLS netlist ($(TINY_PLATFORM)) with $(IVERILOG)..."; \
	$(IVERILOG) -g2012 -DFUNCTIONAL -DUNIT_DELAY=#0 -Ptb_tt_um_mr4.UART_DIV=$(TINY_UART_DIVISOR) \
		-o "$(TINY_BLD)/tb_tt_um_mr4_gls_$(TINY_PLATFORM).vvp" \
		asic/mr4_tiny/tb_tt_um_mr4.sv \
		"$(ASIC_BLD)/orfs/results/$(TINY_PLATFORM)/$(TINY_TOP)/base/6_final.v" \
		$$CELL_MODELS && \
	echo "==> Running post-route Gate-Level Simulation ($(VVP))..." && \
	$(VVP) "$(TINY_BLD)/tb_tt_um_mr4_gls_$(TINY_PLATFORM).vvp" "+PAYLOAD_HEX=$(TINY_BLD)/tiny_payload.hex"
	@$(DOT_CLEAN_CMD)

# Clean cached ORFS outputs so config.mk / PDN / routing-layer edits rebuild cleanly.
# Examples:
#   make asic-clean                                   # cleans nangate45 only
#   make asic-clean ASIC_DESIGN=mr4_tile              # cleans nangate45/mr4_tile only
#   make asic-clean ASIC_PLATFORM=asap7               # cleans asap7 only
#   make asic-clean ASIC_PLATFORM=all                 # cleans all ORFS platforms
asic-clean:
	@if [ "$(ASIC_PLATFORM)" = "all" ]; then \
		echo "==> Removing all cached ORFS outputs ($(ASIC_BLD)/orfs)..."; \
		rm -rf "$(ASIC_BLD)/orfs"; \
	elif [ -n "$(ASIC_DESIGN)" ]; then \
		echo "==> Removing cached ORFS outputs for $(ASIC_PLATFORM)/$(ASIC_DESIGN)..."; \
		rm -rf "$(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)/$(ASIC_DESIGN)" \
		       "$(ASIC_BLD)/orfs/objects/$(ASIC_PLATFORM)/$(ASIC_DESIGN)" \
		       "$(ASIC_BLD)/orfs/logs/$(ASIC_PLATFORM)/$(ASIC_DESIGN)" \
		       "$(ASIC_BLD)/orfs/reports/$(ASIC_PLATFORM)/$(ASIC_DESIGN)"; \
	else \
		echo "==> Removing cached ORFS outputs for platform $(ASIC_PLATFORM)..."; \
		rm -rf "$(ASIC_BLD)/orfs/results/$(ASIC_PLATFORM)" \
		       "$(ASIC_BLD)/orfs/objects/$(ASIC_PLATFORM)" \
		       "$(ASIC_BLD)/orfs/logs/$(ASIC_PLATFORM)" \
		       "$(ASIC_BLD)/orfs/reports/$(ASIC_PLATFORM)"; \
	fi
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Maintenance
# ------------------------------------------------------------------------------

dot-clean:
	@$(DOT_CLEAN_CMD)

# Installs the git hooks in tools/git-hooks into this clone's hooks
# directory. A different hook already there is kept as <name>.bak.
GIT_HOOKS_DIR := tools/git-hooks
GIT_HOOKS     := pre-commit

install-hooks:
	# Not a hook, but a handy alias
	@git config --global alias.ac '!f() { msg="$1"; shift; git add "$@" && git commit -m "$msg"; }; f'
	
	# Now a hook that does a dot_clean before commit.
	@git rev-parse --git-dir > /dev/null 2>&1 || { echo "[FAIL] Not inside a git repository."; exit 1; }
	@hooks="$$(git rev-parse --git-path hooks)"; mkdir -p "$$hooks"; \
	for h in $(GIT_HOOKS); do \
		src="$(GIT_HOOKS_DIR)/$$h"; dst="$$hooks/$$h"; \
		if [ -f "$$dst" ] && ! cmp -s "$$src" "$$dst"; then \
			cp "$$dst" "$$dst.bak" && echo "==> Kept the existing $$h hook as $$dst.bak"; \
		fi; \
		cp "$$src" "$$dst" && chmod +x "$$dst" && echo "==> Installed the $$h hook ($$dst)"; \
	done

clean:
	@echo "==> Cleaning build artifacts and generated SV files..."
	@rm -rf $(BUILD_DIR)
	@rm -f $(ROHD_DIR)/ulx3s_top_rohd.sv $(ROHD_DIR)/ulx3s_top_rohd.json \
	       $(ROHD_DIR)/ulx3s_top_rohd_out.config $(ROHD_DIR)/ulx3s_top_rohd.bit \
	       $(ROHD_DIR)/system_image.hex
	@$(DOT_CLEAN_CMD)

# --- OS & FAT32 SD Image Targets ---
COMPILE    ?= bin/compile
ASSEMBLE   ?= bin/assemble
MKSDIMG    ?= tools/mksdimage.py
SIM        ?= tools/mr4sim.py

OS_SRC_DIR ?= mr4src/act4
OS_BUILD   ?= build/os
SD_SRC_DIR ?= build/sd_root
SD_IMG     ?= /tmp/mr4_sd.img
SD_SIZE_MB ?= 16
SD_SPC     ?= 1

OS_MAIN_A4  := $(OS_SRC_DIR)/os/os_main.a4
OS_MAIN_ASM := $(OS_BUILD)/os_main.asm
OS_MAIN_BIN := $(OS_BUILD)/os_main.bin
OS_MAIN_LST := $(OS_BUILD)/os_main.lst

LS_A4       := $(OS_SRC_DIR)/apps/ls.a4
LS_ASM      := $(OS_BUILD)/ls.asm
LS_PRG      := $(OS_BUILD)/ls.prg
LS_LST      := $(OS_BUILD)/ls.lst

PS_A4       := $(OS_SRC_DIR)/apps/ps.a4
PS_ASM      := $(OS_BUILD)/ps.asm
PS_PRG      := $(OS_BUILD)/ps.prg
PS_LST      := $(OS_BUILD)/ps.lst

CAT_A4      := $(OS_SRC_DIR)/apps/cat.a4
CAT_ASM     := $(OS_BUILD)/cat.asm
CAT_PRG     := $(OS_BUILD)/cat.prg
CAT_LST     := $(OS_BUILD)/cat.lst

XI_A4      := $(OS_SRC_DIR)/apps/xi.a4
XI_ASM     := $(OS_BUILD)/xi.asm
XI_PRG     := $(OS_BUILD)/xi.prg
XI_LST     := $(OS_BUILD)/xi.lst

FIBERS_A4   := $(OS_SRC_DIR)/apps/fibers.a4
FIBERS_ASM  := $(OS_BUILD)/fibers.asm
FIBERS_PRG  := $(OS_BUILD)/fibers.prg
FIBERS_LST  := $(OS_BUILD)/fibers.lst

MUL_A4      := $(OS_SRC_DIR)/apps/mul.a4
MUL_ASM     := $(OS_BUILD)/mul.asm
MUL_PRG     := $(OS_BUILD)/mul.prg
MUL_LST     := $(OS_BUILD)/mul.lst

OS_APP_PRGS := $(LS_PRG) $(PS_PRG) $(CAT_PRG) $(XI_PRG) $(FIBERS_PRG) $(MUL_PRG)

.PHONY: os-build sd-img sim-os os-test test-os clean-os

$(OS_BUILD):
	mkdir -p $(OS_BUILD)

$(OS_MAIN_ASM): $(OS_MAIN_A4) $(wildcard $(OS_SRC_DIR)/os/*.a4) | $(OS_BUILD)
	$(COMPILE) $(OS_MAIN_A4) -o $(OS_MAIN_ASM) -I $(OS_SRC_DIR)/os -I lib

$(OS_MAIN_BIN) $(OS_MAIN_LST): $(OS_MAIN_ASM)
	$(MR4ASM) -I $(LIB_DIR) "$<" -o "$(OS_MAIN_BIN)" -l "$(OS_MAIN_LST)"

$(OS_BUILD)/%.asm: $(OS_SRC_DIR)/apps/%.a4 lib/sys.a4 lib/fiber.a4 lib/term.a4 | $(OS_BUILD)
	$(COMPILE) $< -o $@ -I $(OS_SRC_DIR)/os -I lib --org 0x0400 --nopreamble

$(OS_BUILD)/%.prg: $(OS_BUILD)/%.asm
	$(MR4ASM) -I $(LIB_DIR) --sparsebin "$<" -o "$@" -l "$(@:.prg=.lst)"

os-build: $(OS_MAIN_BIN) $(OS_APP_PRGS) $(BUILD_DIR)/worker_stub.bin

$(SD_SRC_DIR): $(OS_APP_PRGS)
	rm -rf $(SD_SRC_DIR)
	mkdir -p $(SD_SRC_DIR)/BIN $(SD_SRC_DIR)/WORK
	cp $(LS_PRG) $(SD_SRC_DIR)/BIN/LS.PRG
	cp $(PS_PRG) $(SD_SRC_DIR)/BIN/PS.PRG
	cp $(CAT_PRG) $(SD_SRC_DIR)/BIN/CAT.PRG
	cp $(XI_PRG) $(SD_SRC_DIR)/BIN/XI.PRG
	cp $(FIBERS_PRG) $(SD_SRC_DIR)/BIN/FIBERS.PRG
	cp $(MUL_PRG) $(SD_SRC_DIR)/BIN/MUL.PRG
	printf "Hello from MicroRISC4 FAT32 SD card!\n" > $(SD_SRC_DIR)/README.TXT

sd-img: $(SD_SRC_DIR)
	python3 $(MKSDIMG) $(SD_SRC_DIR) -o $(SD_IMG) --size-mb $(SD_SIZE_MB) --spc $(SD_SPC)

sim-os: os-build sd-img
	python3 $(SIM) $(OS_MAIN_BIN) --sym $(OS_MAIN_LST) --sd-image $(SD_IMG) --worker $(BUILD_DIR)/worker_stub.bin --workers 3 --startaddr 0x0100

os-test: test-os

test-os: os-build sd-img
	$(PYTHON) $(TOOLS_DIR)/test_os.py --sd-image $(SD_IMG)

clean-os:
	rm -rf $(OS_BUILD) $(SD_SRC_DIR)

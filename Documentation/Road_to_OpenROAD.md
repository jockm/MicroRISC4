# Road to OpenROAD: ASIC Support for the MiniRISC4 HDL

This document describes how to add an ASIC implementation flow for the MiniRISC4 soft CPU while preserving the existing ULX3S/ECP5 FPGA flow. It focuses on the hardware under `hdl/rohd/`; the existing `make ulx3s-bit` target produces an FPGA bitstream, not an ASIC layout.

## What the repository currently builds

The current hardware generator, [`hdl/rohd/bin/generate.dart`](../hdl/rohd/bin/generate.dart), constructs `Ulx3sTop`. The root `Makefile` target `generate-ulx3s` generates SystemVerilog, and `ulx3s-bit` runs Yosys `synth_ecp5`, nextpnr, and bitstream packing.

The reusable CPU is [`hdl/rohd/lib/cpu_core.dart`](../hdl/rohd/lib/cpu_core.dart). [`hdl/rohd/lib/ulx3s_top.dart`](../hdl/rohd/lib/ulx3s_top.dart) wraps it with board-specific clocking, pins, UART wiring, and optional SDRAM/cache and multi-core systems. The CPU's default local memory is 65,536 × 16 bits.

Memory and board dependencies that need deliberate ASIC treatment:

* [`hdl/rohd/lib/tdp_bram.dart`](../hdl/rohd/lib/tdp_bram.dart) emits a two-cycle memory with FPGA-oriented banking and `ram_style` attributes. It optionally emits `$readmemh` initialization. The memory has a read port A and a read/write port B; preserve its latency and read/write collision behavior when replacing it.
* [`hdl/rohd/lib/cache_controllers.dart`](../hdl/rohd/lib/cache_controllers.dart) describes `CacheDataBram` as an ASIC SRAM macro, but the current generated Verilog is an inferred array. It does not instantiate a foundry macro.
* [`hdl/rohd/lib/noc_router.dart`](../hdl/rohd/lib/noc_router.dart) also infers a small RAM array with an FPGA `distributed` attribute.
* [`hdl/rohd/lib/ecp5_pll.dart`](../hdl/rohd/lib/ecp5_pll.dart) emits an ECP5 `EHXPLLL` primitive. `Ulx3sTop` instantiates it and relies on its `locked` signal.
* The optional SDRAM/cache path uses [`hdl/rohd/lib/cache_subsystem_top.dart`](../hdl/rohd/lib/cache_subsystem_top.dart) and [`hdl/rohd/lib/sdram_controller.dart`](../hdl/rohd/lib/sdram_controller.dart). The ULX3S top connects the external SDRAM pins and a bidirectional data bus; the I/O buffering and ECP5-specific I/O attributes need target-specific handling.

## Target architecture: share the CPU, split the tops and memories

Keep the current FPGA path working and add a separate ASIC path:

```text
                  Shared CpuCore and reusable logic
                    /                         \
      Ulx3sTop + FPGA memory             AsicTop + ASIC memory
      existing ECP5 flow                 new ORFS flow
```

Do not repurpose `make ulx3s-bit` or overwrite its generated files. Use separate top modules, generators, build directories, and flow configurations. For the first ASIC version, start with one CPU, a defined memory/boot solution, and a simple debug interface such as UART. Add the NoC, SDRAM, caches, and worker cores after the single-core flow is working.

## Repository changes

### 1. Add an ASIC top

Create `hdl/rohd/lib/asic_top.dart`. It should instantiate `CpuCore` and define the actual chip interface, for example:

* A clock input and reset input.
* UART pins or another boot/debug interface.
* GPIO or external memory signals only if the product needs them.
* Explicit tie-offs for unused optional CPU interfaces.

Do not instantiate `Ecp5Pll25To24`. For an ASIC clock, either accept a clock at a package pin or instantiate a foundry-approved PLL macro and wrapper. Remove ULX3S-only connections such as LEDs, buttons, Wi-Fi GPIO, and board-level pin wiring. Keep the existing UART logic if useful, but select the ASIC clock and baud divisor intentionally.

The current `Ulx3sTop` reset logic depends on the ECP5 PLL lock signal and includes a reset-hold counter configured for the FPGA clock. The ASIC top should define reset behavior for its own clock source and system requirements.

### 2. Make the CPU memory implementation selectable

`CpuCore` currently constructs `TdpBram` internally. Add a way to select a memory implementation without changing the existing FPGA default. Options include passing a memory factory/module into `CpuCore` or adding a target-specific memory configuration that selects an implementation with the same interface.

Keep the FPGA implementation and its ECP5 banking intact. Add an ASIC memory wrapper that instantiates the chosen foundry SRAM macro(s). The wrapper must preserve:

* Port A read behavior and port B read/write behavior.
* The two-cycle read latency expected by the CPU.
* The existing write timing and read-during-write semantics.

The actual foundry macro may not have the CPU's required depth, width, or port combination. In that case, bank one or more macros and implement address selection while preserving the CPU-visible timing. The macro's Liberty/LEF views and simulation model must match the instance used by synthesis.

Also decide the implementation for `CacheDataBram` and `NocFifoRam`. They can use explicit SRAM wrappers or remain flop-based if their capacities are small enough. An FPGA `ram_style` hint alone does not provide an ASIC memory macro.

### 3. Define how the ASIC boots

An RTL `$readmemh` initializer is not a general mechanism for preloading an ASIC SRAM at power-up. Choose and implement one of these approaches:

* A foundry ROM or mask-ROM macro containing the boot image.
* An external boot device and a bootloader.
* Another initialization mechanism explicitly supported by the selected process and chip architecture.

Keep `$readmemh` for simulation and the FPGA build if desired, but do not treat it as the manufactured chip's memory contents. The design is not boot-complete until it can fetch its first instruction after power-up.

### 4. Keep SDRAM and NoC optional, with target-specific implementations

If the ASIC uses external SDRAM, retain the protocol/controller only after verifying its timing and implementing the physical interface with the foundry's I/O and pad cells. The `TriStateBuffer` and top-level bidirectional `sdram_d` connection in `Ulx3sTop` are not an ASIC pad ring. The `syn_useioff` attribute in `sdram_controller.dart` is FPGA-specific and should not be relied on for ASIC timing.

If the ASIC instead uses on-chip SRAM, provide a new memory path and do not instantiate the ULX3S SDRAM controller/cache top. The NoC logic can remain shared, but its FIFO memories need an explicit ASIC implementation or a deliberate flop-based area budget.

### 5. Add an ASIC generator and build targets

Keep `generate.dart` and the existing ULX3S generation path working. Add a separate generator for `AsicTop`, or add explicit target selection. Emit ASIC RTL to a separate directory such as:

```text
build/asic/mr4_asic_top.sv
```

Add separate root Makefile variables and targets, for example:

* `generate-asic`: generate ASIC SystemVerilog under `build/asic/`.
* `asic-check`: perform a structural RTL/Yosys check.
* `asic-flow`: invoke the ORFS flow with the ASIC design configuration.

Keep `generate-ulx3s`, `ulx3s-bit`, timing, programming, and flashing targets unchanged. Do not reuse ECP5 settings such as `ULX3S_TOP`, `ULX3S_PACKAGE`, `ULX3S_CLOCK_MHZ`, `synth_ecp5`, or nextpnr for ASIC.

### 6. Add ORFS design configuration and constraints

Add project files such as:

```text
asic/mr4/config.mk
asic/mr4/constraint.sdc
```

The ORFS configuration needs at least the top module name, platform name, RTL input, and SDC path. Conceptually:

```make
export DESIGN_NAME = mr4_asic_top
export PLATFORM = <configured_orfs_platform>
export VERILOG_FILES = <path-to-build/asic/mr4_asic_top.sv>
export SDC_FILE = <path-to-asic/mr4/constraint.sdc>
```

The SDC must define the actual clock period and timing at every external interface. Add input/output delays, loads, uncertainty, generated clocks, and timing exceptions as required by the design. Do not leave paths unconstrained and interpret a clean timing report as success.

For a configured ORFS installation, the invocation pattern is:

```sh
make --file="$ORFS_ROOT/flow/Makefile" \
  DESIGN_CONFIG="$PWD/asic/mr4/config.mk"
```

ORFS's [flow tutorial](https://openroad-flow-scripts.readthedocs.io/en/latest/tutorials/FlowTutorial.html) documents design configuration, constraints, and the RTL-to-GDS stages.

## End-to-end implementation steps

### Step 0: Obtain the actual 24 nm process kit

“24 nm” is not a generic OpenROAD setting. Obtain the exact foundry/process PDK or an authorized platform kit, plus permission to use it. Required inputs typically include:

* Standard-cell Liberty timing libraries and physical LEFs.
* Technology LEF, routing stack/layer information, and RC extraction data.
* SRAM/ROM macro Liberty and LEF views, plus simulation/black-box models.
* Tap, well-tie, filler, decap, tie, antenna, and other required cells.
* I/O and pad-cell libraries and the foundry's pad/ESD requirements.
* DRC/LVS decks, extraction/signoff rules, and tapeout instructions.

ORFS also needs platform-specific integration/configuration: library lists, routing and RC settings, power-grid setup, required cell hookups, and macro handling. Exact platform files and design choices cannot be finalized until the foundry kit and memory/IO choices are known. Keep licensed kit files outside the public source repository.

The OpenROAD [platform overview](https://openroad.readthedocs.io/en/latest/main/README.html) lists several public and proprietary platforms, but there is no generic 24 nm PDK to substitute for the target foundry's kit. A public platform can be used to learn the flow, not to claim 24 nm manufacturability.

### Step 1: Capture the FPGA baseline

Before changing shared logic, verify the existing target:

```sh
make test
make generate-ulx3s
make ulx3s-bit
```

Keep these passing as you add ASIC support.

### Step 2: Implement the ASIC top and memory path

Start with one core and the simplest complete system you can test. Define its clock/reset pins, UART or boot interface, local memory capacity, and boot method. Add the ASIC memory wrapper and preserve the `CpuCore` memory timing. Do not initially enable the external SDRAM cache or NoC unless they are essential to the first chip.

### Step 3: Generate and preflight the ASIC RTL

Add `make generate-asic`, then inspect the generated module hierarchy and ports. Add an RTL preflight that checks for missing modules and structural errors before running the physical flow. For example, with the appropriate macro black-box declarations included:

```sh
yosys -p 'read_verilog -sv build/asic/mr4_asic_top.sv; \
  hierarchy -check -top mr4_asic_top; \
  proc; opt; check; stat'
```

This checks RTL structure; ORFS performs the platform-specific synthesis and cell mapping. Review inferred memories and unresolved cells carefully—do not accept a large flop expansion where an SRAM macro was intended.

### Step 4: Run ORFS

ORFS uses Yosys for synthesis and OpenROAD for floorplanning, power-grid setup, placement, clock-tree synthesis, timing optimization, routing, and finishing. Use a consistent ORFS tool installation; its [README](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts) recommends Docker for a reproducible setup. On macOS, keep the current OSS CAD Suite for the FPGA flow and run ORFS separately rather than assuming the FPGA bundle contains the complete ASIC flow.

Review the synthesis, placement, clock-tree, routing, and finishing reports. Check at least:

* No unresolved or accidentally black-boxed logic.
* Memories mapped to the intended macros.
* Area and macro placement are plausible.
* No unconstrained timing paths.
* Setup and hold timing meet the required corners.
* Congestion, routing, and physical checks complete successfully.

### Step 5: Complete chip-level signoff

An ORFS result is not, by itself, foundry signoff. Complete the foundry-required pad/ESD and package integration, DFT/scan and manufacturing-test strategy, final DRC/LVS, timing/reliability checks, and tapeout submission.

## Useful references

* [OpenROAD documentation and supported-platform overview](https://openroad.readthedocs.io/en/latest/main/README.html)
* [OpenROAD-flow-scripts RTL-to-GDS tutorial](https://openroad-flow-scripts.readthedocs.io/en/latest/tutorials/FlowTutorial.html)
* [OpenROAD-flow-scripts repository and installation guidance](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts)

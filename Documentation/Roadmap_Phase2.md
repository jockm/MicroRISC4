# MiniRISC4 Phase 2 Roadmap: High-Frequency Scaling, Hardware OS Bring-Up, Compiler Efficiency & OpenROAD ASIC Flow

> **Status:** Active (supersedes Phase 1 [Roadmap.md](Roadmap.md), which is 100% complete and hardware-verified on ULX3S-85F — including a 4-minute, ~896 MB, 0-error 4-core SDRAM + Lean Ring NoC + Trap 14 soak test).
> **Related Documents:** [Roadmap.md](Roadmap.md) (Phase 1 Archive) · [RoadmapOS.md](RoadmapOS.md) (MR4OS) · [Road_to_OpenROAD.md](Road_to_OpenROAD.md) (ASIC Flow Guide)

---

## 1. Phase 1 Verified Baseline (Starting Point)

All Phase 2 changes must preserve or improve upon these hardware-verified ULX3S-85F (`nextpnr-ecp5`) baselines and keep `make apps`, `make test-rohd` (29/29), and `make os-test` green:

| Configuration | `LUT4` | `TRELLIS_FF` | `DPR16X4` | `DP16KD` | `IOLOGIC` | **`nextpnr` $F_{\max}$** |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **1-Core 65K BRAM (baseline)** | `1189` | `467` | `0` | `64` | `0` | **`107.25 MHz`** |
| **1-Core 2K BRAM + I/D Cache + SDRAM** | `2008` | `844` | `16` | `4` | `17` | **`108.83 MHz`** |
| **4-Core `4×2K` + Lean NoC (BRAM only)** | `4216` | `1712` | `16` | `8` | `0` | **`106.15 MHz`** |
| **8-Core `8×2K` + Lean NoC (BRAM only)** | `8381` | `3400` | `32` | `16` | `0` | **`102.06 MHz`** |
| **4-Core `4×2K` + Lean NoC + Shared SDRAM** | `8404` | `3232` | `80` | `16` | `17` | **`91.42 MHz`** |

---

## 2. Structural & Architectural Analysis: Where Real Gains Live

Before writing RTL or compiler code, Phase 2 targets the **four measured bottlenecks** limiting frequency scaling, real-world performance, binary footprint, and ASIC readiness:

### 2.1 Do We Benefit from More Pipeline Stages?
**Yes — specifically a clean 4-stage in-order pipeline (`IF → ID/RF → EX → WB`), NOT a deep 6–8 stage pipeline.**

* **What `CpuCore` does today:** `_stExec` performs register-file read (`r0..r3`), 16-bit carry-chain ALU/address math (`CCU2C`), branch evaluation, next-state FSM decode, and register writeback inside a single clock cycle (~`18–22` logic levels). Sequential execution runs 1 slot/cycle, but every load takes **4 cycles** (`_stExec → _stMemWait → _stMemWait2 → _stMemRd`) and every taken branch takes **3–4 cycles**.
* **Why 4 stages is the sweet spot:**
  1. **ASIC GHz scaling (`Road_to_OpenROAD.md`):** Splitting `ID/RF` from `EX (ALU + Branch)` and `WB (Forwarding + Regfile)` cuts per-stage logic depth to **~10–12 levels** — the difference between ~600–800 MHz and **>1.5–2.0 GHz** on an advanced node (e.g., 24 nm).
  2. **ECP5 FPGA $F_{\max}$ & IPC:** Pushes 1-core ECP5 $F_{\max}$ from `~108 MHz` toward **`130–150 MHz`** while overlapping Slot 0 memory/ALU latency with Slot 1 decode (~`1.3×–1.5×` IPC gain on load/store-heavy ACT4 code).
  3. **Why NOT deeper (6–8+ stages):** MiniRISC4's 4-register ISA branches every ~4–6 instructions; without a branch predictor, a deep pipeline's branch-flush penalty erases the clock-speed gain.
* **Bonus ISA/Hardware Trap Fix:** Phase 1 hardware testing exposed that asynchronous Trap 14 overwrites `R0` (the link register), forcing interruptible loops to avoid holding live values in `R0`. Adding a dedicated 16-bit hardware `EPC` register (or trap-link shadow slot) eliminates this software hazard permanently.

### 2.2 Why 4-Core SDRAM Dropped from `108.8 MHz` to `91.4 MHz` (and How to Flatten Scaling)
* `make ulx3s-timing` proved that **78% of the 4-core SDRAM critical path is routing (`8.58 ns` wires vs `1.84 ns` logic)**.
* While the Lean Ring NoC scales almost flat (`110.7 → 106.2 → 102.1 MHz` from 1 → 4 → 8 cores), `SdramBurstArbiter` is a **centralized combinational $2N:1$ star hub** pinned to the right-edge SDRAM I/O bank (`X126`), pulling all 4 cores and 8 caches into one congested corner.
* **Fix:** Insert **1-cycle registered slices** (or a binary tree of registered `2:1` arbiters) between each core's caches and `SdramController`. Because an SDRAM burst already takes ~14 cycles, 1 extra pipeline cycle costs negligible throughput while completely breaking global star timing paths and letting cores scale flatly to **4, 8, and 16+ cores** (and mapping cleanly to OpenROAD hierarchical tiles).

### 2.3 Why Binaries (`MUL.PRG`, `XI.PRG`) Grew to 85–120 KB
* `act4c.py` currently emits every zero-initialized global array as explicit `.word 0` entries in the binary (`MUL.PRG` = `120,442` bytes / `60,221` words / `236` FAT32 clusters).
* Separating uninitialized/zero globals into a trailing **`.bss` region** (trimmed from `.PRG` on disk, with a `bss_words` header field zeroed by a 5-instruction loop in `worker_stub.asm`) will shrink `MUL.PRG` and `XI.PRG` by **~4×–5×**, speed up SD loading dramatically, and restore `os_mul` to `make os-test` (`17/17 PASS`).

### 2.4 Bridging Hardware & MR4OS + OpenROAD ASIC Readiness
* **Real-hardware MR4OS:** `SpiMaster` (`0x0018`–`0x001A`) already exists in `hdl/rohd/lib/spi_master.dart`, and 4-core Lean Ring + SDRAM already works on ULX3S-85F. Unifying `os_proc.a4`/`worker_stub.asm` onto the hardware Lean Ring (`0x0020`–`0x002A`) and wiring the ULX3S microSD pins lets the full **4-core MR4OS + FAT32 shell boot live on the ULX3S-85F board**.
* **OpenROAD ASIC Flow:** Following [Road_to_OpenROAD.md](Road_to_OpenROAD.md), separating `AsicTop` + selectable `MemoryFactory` (`fpgaEcp5` vs `asicSram`) + mask-ROM/boot strategy + ORFS `config.mk`/`constraint.sdc` lets us run an end-to-end RTL-to-GDS dry run on a public PDK (e.g., ASAP7 / Sky130 / Nangate45) while keeping `make ulx3s-bit` 100% untouched.

---

## 3. Phased Execution Roadmap & Checklist

> **Discipline:** Every hardware checkmark item records verified `LUT4`, `TRELLIS_FF`, `DPR16X4`, `DP16KD`, `IOLOGIC`, and `nextpnr-ecp5` $F_{\max}$ (plus Icarus Verilog simulation) before moving on.

### Track A: Scalable Multi-Core Fabric & Higher ULX3S Clock
- [ ] **A.1 Pipelined / Registered SDRAM Arbiter (`cache_subsystem_top.dart`)**
  - Add registered command/write/read slices (or a registered binary tree of `2:1` burst arbiters) between per-core I/D caches and `SdramController` to break the centralized $2N:1$ star bottleneck.
  - Benchmark **1-core**, **4-core**, and **8-core** `ULX3S_SDRAM_CACHE=1` builds (target: **4-core SDRAM `>100 MHz`** and **8-core SDRAM `>95 MHz`** on ULX3S-85F) and verify in ROHD Dart + Icarus Verilog + ULX3S-85F hardware soak.
- [ ] **A.2 Higher ULX3S Operating Frequency (`48 MHz` → `72–96 MHz`)**
  - Parameterize `Ecp5Pll` + UART baud divisor (`ULX3S_CLOCK_MHZ=48|72|96`) and verify `SdramController` timing parameters (`tRCD`, `tRP`, `tRFC`, `tWR`, `CL=2`/`CL=3`, `tREFI`) at the higher frequency.
  - Hardware-verify the 4-core continuous soak test on ULX3S-85F at the higher clock with `0` errors.
- [ ] **A.3 ULX3S microSD SPI Wiring + Hardware Math Accelerator Bring-Up**
  - Wire `SpiMaster` (`0x0018`–`0x001A`) to the ULX3S-85F onboard microSD slot in `ulx3s_v20.lpf` and `ulx3s_top.dart` (`ULX3S_ENABLE_SPI=1`) and hardware-verify SDHC `CMD0`/`CMD8`/`CMD55`/`ACMD41`/`CMD17` sector read.
  - Enable & hardware-verify `MathAccelerator` (`0x0010`–`0x0016`, ECP5 `MULT18X18D` DSP slices) on ULX3S-85F (`ULX3S_ENABLE_MATH=1`).

### Track B: Compiler & MR4OS Binary Efficiency + Live Hardware OS
- [ ] **B.1 Compiler `.bss` Zero-Data Separation & Binary Trimming (`act4c.py` / `mr4asm.py`)**
  - Group zero-initialized static arrays/globals at the end of compiled binaries (`.bss` section), emit `bss_words` in the `.PRG` load header, and zero-fill `.bss` in `worker_stub.asm` (`_stub_zero_bss`) instead of streaming zeros from SD.
  - Verify `MUL.PRG` shrinks from ~`120 KB` to `<30 KB` and `XI.PRG` shrinks from ~`85 KB` to `<25 KB`; re-enable `os_mul` in `tools/test_os.py` so `make os-test` passes **17/17**.
- [ ] **B.2 Hardware Math Accelerator Codegen (`act4c.py`)**
  - Add `--hw-math` lowering in `act4c.py` for 16/32-bit multiply, divide, modulo, and variable shifts via `0x0010`–`0x0016`, verified in `mr4sim.py` and ROHD co-sim.
- [ ] **B.3 Unify MR4OS IPC onto Hardware Lean Ring (`0x0020`–`0x002A`) & Boot MR4OS on ULX3S-85F**
  - Port `os_proc.a4`, `worker_stub.asm`, and `mr4sim.py` onto the direct-addressed Lean Ring (`NOC_TX_DATA`/`NOC_DST_CORE`/`NOC_RX_DATA`/`NOC_STAT`/`NOC_MBOX_*` + Trap 14) so simulation and FPGA share 100% identical binaries.
  - Boot **4-core MR4OS + FAT32 microSD shell + `! ls` / `! cat` / `! mul`** live on your ULX3S-85F board!

### Track C: Core Microarchitecture — GHz-Ready 4-Stage Pipeline
- [ ] **C.1 CPI & Critical-Path Profiling Baseline**
  - Instrument `mr4sim.py` and `yosys`/`nextpnr` to capture dynamic instruction mix (ALU / Load / Store / Branch / Stack / Trap), CPI, and per-stage logic-level histograms on `monitor`, `stress`, `os_main`, and `mul`.
- [ ] **C.2 Trap-Safe Hardware Return Link (`EPC` / Non-Destructive Async Traps)**
  - Add a dedicated hardware `EPC` register (or dedicated trap-return instruction/MMIO) so asynchronous hardware Trap 14 never clobbers a live `R0` in user/kernel code.
- [ ] **C.3 4-Stage In-Order Pipelined `CpuCore` (`IF → ID/RF → EX → WB`)**
  - Refactor `CpuCore` into 4 balanced pipeline stages with `EX→EX` and `WB→EX` register forwarding, 1-cycle load-use hazard interlock, clean branch/trap flush, and configurable memory latency (`1`-cycle ASIC SRAM or `2`-cycle ECP5 BRAM).
  - Verify 100% ISA & lockstep equivalence (`make test-rohd`, `make os-test`, Icarus Verilog, and ULX3S-85F 4-core soak).
  - Target: **`>130 MHz` on ECP5-85F** (1-core & 4-core), **~1.3×–1.5× higher IPC**, and **`<=12` logic levels/stage** for GHz ASIC synthesis.

### Track D: Road to OpenROAD (ASIC RTL-to-GDS Flow)
*(Implements [Road_to_OpenROAD.md](Road_to_OpenROAD.md) without disturbing the ULX3S ECP5 flow.)*
- [ ] **D.1 Target-Selectable Memory Abstraction (`MemoryFactory`) & Boot ROM Strategy**
  - Decouple `CpuCore`, `ICache`/`DCache`, and `NocRouterNi` from FPGA-only `TdpBram`/`ram_style`/`$readmemh` via a clean memory factory (`fpgaEcp5` vs `asicSram` / `asicFlop`).
  - Implement a synthesizable mask-ROM or SPI-boot loader module for `0x0100` cold-start instruction fetch on manufactured silicon.
- [ ] **D.2 `AsicTop`, Generator & Structural Preflight (`make generate-asic`, `make asic-check`)**
  - Add `hdl/rohd/lib/asic_top.dart` (clean chip-level clock/reset/UART/optional-SPI ports; zero ECP5 primitives like `EHXPLLL`, `ODDRX1F`, `syn_useioff`, LEDs, or board pins).
  - Emit `build/asic/mr4_asic_top.sv` and add `make asic-check` (`yosys` `hierarchy -check`, `proc`, `opt`, `check`, `stat`) confirming zero unresolved cells or unintended SRAM flop-explosions.
- [ ] **D.3 ORFS Configuration, Full SDC Constraints & Public-PDK Dry Run**
  - Create `asic/mr4/config.mk` and complete `asic/mr4/constraint.sdc` (clock period, uncertainty, I/O delays, loads — zero unconstrained paths).
  - Run an end-to-end OpenROAD-flow-scripts RTL-to-GDS dry run on a public reference PDK (e.g., ASAP7 / Nangate45 / Sky130) for a single-core `mr4_asic_top` and record area, power, setup/hold slack, and maximum clock frequency.
- [ ] **D.4 Hierarchical Multi-Core Tile Macro (`Mr4Tile`) for Flat-Frequency ASIC Scaling**
  - Harden a single reusable `Mr4Tile` (`CpuCore` + SRAM + I/D Cache + `NocRouterNi`) and verify a 4-tile / 8-tile tiled chip floorplan in ORFS with flat $F_{\max}$ across core counts.

---

## 4. Recommended Execution Order

1. **Track B.1 (Compiler `.bss` Trimming)** — quick, high-value win (~5× smaller `.PRG` binaries, restores **17/17** `make os-test` immediately).
2. **Track A.1 (Pipelined SDRAM Arbiter)** — fixes the 4-core SDRAM `91.4 MHz` routing bottleneck so **4-core & 8-core SDRAM run >100 MHz** on ULX3S-85F.
3. **Track D.1–D.2 (`AsicTop` + `MemoryFactory` + `make asic-check`)** — establishes clean FPGA/ASIC separation early so all subsequent `CpuCore` pipeline work stays ASIC-clean from day one.
4. **Track C.1–C.3 (4-Stage GHz-Ready Pipeline + Trap-Safe `EPC`)** — unlocks both `>130 MHz` ECP5 + `>1.5 GHz` 24 nm ASIC potential and higher IPC.
5. **Track A.2–A.3 & B.3 (72–96 MHz ULX3S + microSD + Live 4-Core MR4OS on Hardware)** — crowns the FPGA platform by booting the full multitasking OS live on ULX3S-85F.
6. **Track D.3–D.4 (ORFS RTL-to-GDS Dry Run & Tiled Multi-Core Macro)** — validates physical ASIC closure and prepares for the target 24 nm foundry PDK.

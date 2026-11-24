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
- [x] **A.1 Pipelined / Registered SDRAM Arbiter (`cache_subsystem_top.dart` / `cache_controllers.dart`)**
  - Refactored `SdramBurstArbiter` into a 5-state fully-registered burst arbiter (`_stIdle → _stLatch → _stIssue → _stActive → _stDrain`) with 2-stage command grant (separating the round-robin encoder from the 24-bit address mux), per-write-client local `wdataCapQ` capture FFs + central 4-word `wbuf` skid ring (breaking `DP16KD.DO → N:1 mux`), per-core local `coreRdataQ`/`core*RvalidQ` read-return repeaters, 1-cycle registered `ic_inval_idx_q` invalidation, and pure-FF `_stSnoop` `tagRaddr` selection in `DCache`.
  - Verified **29/29 `make test-rohd` PASS** and **Icarus Verilog 4-core SDRAM stress PASS** (`64+` concurrent SDRAM/NoC/Trap 14 rounds, `1,269` refreshes, `0` errors), completely removing `SdramBurstArbiter` from the critical path across all core counts:
    - **1-Core SDRAM:** `2026 LUT4`, `986 TRELLIS_FF`, `16 DPR16X4`, `4 DP16KD`, `17 IOLOGIC` — **`105.39 MHz`** (`cpu_core` internal path)
    - **4-Core SDRAM:** `8590 LUT4`, `3484 TRELLIS_FF`, `80 DPR16X4`, `16 DP16KD`, `17 IOLOGIC` — **`102.52 MHz`** (**+11.10 MHz** vs `91.42 MHz` baseline; `cpu_worker_1` internal path)
    - **8-Core SDRAM:** `16664 LUT4`, `6680 TRELLIS_FF`, `160 DPR16X4`, `32 DP16KD`, `17 IOLOGIC` — **`88.46 MHz`** at relaxed `48 MHz` PLL constraint (0% arbiter nets on critical path; tightens under Track A.2 higher PLL constraint)
- [x] **A.2 Higher ULX3S Operating Frequency (`48 MHz` → `72–96 MHz`)**
  - Parameterized `Ecp5Pll` (`48 / 60 / 72 / 84 / 96 MHz` exact 3.000 Mbaud clocks via `EHXPLLL` `CLKOS` + phase-shifted `CLKOS2` `sdram_clk` at `270°–306°` via `Ecp5OddrClkFwd`), auto-scaled `Uart` divisor (`16/20/24/28/32`), `SdramController` timing (`tRCD`/`tRP`/`tRFC`/`tWR`/`tREFI`/`extraReadPipeCycles`), POR debounce, `--clk-mhz`, and `ULX3S_CLOCK_MHZ`.
  - Verified **30/30 `make test-rohd` PASS**, physically-timed Icarus Verilog 4-core stress **PASS** across `72`, `84`, and `96 MHz` (both slow `tODDR=2.6ns/tAC=5.4ns` and fast `tODDR=1.6ns/tAC=2.7ns` corners, `0` SDRAM/UART errors), and **ULX3S-85F hardware-verified at `96 MHz` (`0` errors)**:
    - **4-Core SDRAM @ `72 MHz`:** `8656 LUT4`, `3489 TRELLIS_FF`, `80 DPR16X4`, `16 DP16KD`, `17 IOLOGIC` — **`99.15 MHz`** (PASS)
    - **4-Core SDRAM @ `84 MHz`:** `8484 LUT4`, `3489 TRELLIS_FF`, `80 DPR16X4`, `16 DP16KD`, `17 IOLOGIC` — **`94.78 MHz`** (PASS)
    - **8-Core SDRAM @ `84 MHz`:** `16710 LUT4`, `6685 TRELLIS_FF`, `160 DPR16X4`, `32 DP16KD`, `17 IOLOGIC` — **`92.97 MHz`** (PASS)
    - **4-Core SDRAM @ `96 MHz`:** `8442 LUT4`, `3489 TRELLIS_FF`, `80 DPR16X4`, `16 DP16KD`, `17 IOLOGIC` — **`100.79 MHz`** (PASS, **ULX3S-85F hardware soak PASS @ `96 MHz`, `0` errors**)
- [x] **A.3 ULX3S microSD SPI Wiring + Lean 1-DSP Math Accelerator Bring-Up**
  - Wired `SpiMaster` (`0x0018`–`0x001A`) to the ULX3S-85F onboard microSD slot (`sd_clk`=`H2`, `sd_cmd`=`J1`, `sd_d0`=`J3`, `sd_d3`=`K2`) in `ulx3s_v20.lpf`, `ulx3s_top.dart`, `generate.dart`, and `Makefile` (`ULX3S_ENABLE_SPI=0|1`), with `clkFreqMhz`-auto-scaled dividers (`<= 400 kHz` slow init clock, `<= 12 MHz` fast transfer clock) and fast 2-LUT page address decode.
  - Refactored `MathAccelerator` (`0x0010`–`0x0016`) into an optional, per-core configurable (`ULX3S_ENABLE_MATH=0|core0|all`, default `0`) **registered 1-DSP (`SignedMul17x17` → `1 × MULT18X18D`) multi-cycle coprocessor** implementing all 11 32-bit opcodes (`MUL`/`MULH`/`MULHU`/`MULHSU` in 6 cycles, restoring `DIVU`/`REMU`/`DIV`/`REM` + div-by-zero flag in 34 cycles, `SLL`/`SRL`/`SRA` barrel shifts in 1 cycle) with fast 2-LUT `match` decode (fixed for 2-cycle `CpuCore` reads).
  - Created ULX3S bring-up firmware (`mr4src/asm/a3_hw_verify.asm`), verified **35/35 `make test-rohd` PASS** (all 11 Math opcodes + signed/div-by-zero edge cases + `Ulx3sTop` SPI loopback + `CPU_CAPS` `0x042D`), and **Icarus Verilog end-to-end `a3_hw_verify.asm` @ `96 MHz` PASS** (`MathAccelerator: PASS (12/12)`, `SDHC CMD0/CMD8/CMD55/ACMD41` @ `400 kHz` → `12 MHz` → `CMD17` Sector 0 MBR `SIG=0xAA55`):
    - **1-Core 4K BRAM + SPI + 1-DSP Math @ `96 MHz` (`a3_hw_verify.asm`):** `2471 LUT4`, `864 TRELLIS_FF`, **`1 MULT18X18D`**, `4 DPR16X4`, `4 DP16KD`, `0 IOLOGIC` — **`121.24 MHz`** (PASS at `96.01 MHz`)
    - **4-Core `4×2K` + Lean NoC + SDRAM + SPI + Core-0 Math @ `96 MHz`:** `10417 LUT4`, `4740 TRELLIS_FF`, **`1 MULT18X18D`**, `96 DPR16X4`, `16 DP16KD`, `17 IOLOGIC` — **`113.97 MHz`** (PASS at `96.01 MHz`, +18 MHz slack!)
    - **4-Core `4×2K` + Lean NoC + SDRAM + SPI + All-4-Cores Math @ `96 MHz`:** `13585 LUT4`, `5583 TRELLIS_FF`, **`4 MULT18X18D`**, `96 DPR16X4`, `16 DP16KD`, `17 IOLOGIC` — **`98.94 MHz`** (PASS at `96.01 MHz`)

### Track B: Compiler & MR4OS Binary Efficiency + Live Hardware OS
- [x] **B.1 Compiler `.bss` Zero-Data Separation & Binary Trimming (`act4c.py` / `mr4asm.py`)**
  - Added `.resw <N>` directive to `tools/mr4asm.py` (advancing addresses & listing `.bss` symbols without emitting zero words to disk) and reordered `tools/act4c.py` into `.text` (functions + `_act4_zero_bss` + `M4R_LIB.asm`) → `.data`/`.rodata` (non-zero globals + strings) → `.bss` (all zero globals, arrays, and function locals/params), zero-filled at `_main` entry with zero loader/protocol changes.
  - Verified massive shrinkage: **`MUL.PRG` `120,442 B → 29,878 B` (−75.2%, 4.0×)**, **`XI.PRG` `85,890 B → 19,050 B` (−77.8%, 4.5×)**, **`os_main.bin` `68,004 B → 64,716 B` (−4.8%)**, total SD app payload **`217.8 KB → 59.5 KB` (−72.7%)**; re-enabled `os_mul` and restored original `16M` `os_path_and_history` step budget — **17/17 `make os-test` PASS**.
- [x] **B.2 Hardware Math Accelerator Codegen (`act4c.py` + `mr4sim.py` + `CPU_CAPS` Startup Guard)**
  - Mirrored all 11 32-bit `MathAccelerator` opcodes (`0x0010`–`0x0016`) in `tools/mr4sim.py` behind `--enable-math` (default `False` so legacy `worker_stub.asm` scratchpad stays unaffected), setting `CAP_MATH_ACCEL` (`0x0008`, bit 3) in `CPU_CAPS` (`0x001C`).
  - Added `--hw-math` to `tools/act4c.py` lowering `*`, `/`, `%`, compound `*=`, `/=`, `%=`, `<<=`, `>>=`, non-power-of-two array index scaling (`elem_sz * idx`), variable shifts (`<<`, `>>`), and constant shifts `>= 4` onto register-direct `_ACT4_HW_*` helpers (`R1=A, R2=B -> R1`, zero `APUSH`/`APOP` stack overhead, 100% divide-by-zero & shift `>= 16` parity with `M4R_LIB.asm`), and fixed lexer precedence for `<<=`/`>>=` compound shifts.
  - Emits automatic `_act4_require_hw_math` startup capability guard at `_main` entry whenever `--hw-math` is enabled: if `CPU_CAPS.b3 == 0`, reports `ERR: CPU lacks HW Math Accelerator (CPU_CAPS.b3=0)` (via `sys_puts` + `SYS_EXIT(1)` for `--nopreamble` MR4OS worker apps, or direct UART when `CAP_UART` is set + `R1=1` clean halt for standalone binaries) without executing `_main`.
  - Verified **18/18 `make os-test` PASS** (including `hw_math_codegen`: **5.73× cycle speedup**, `232,898 → 40,662` cycles on math-heavy checksum loop, bit-exact `OK:175F`, plus standalone & MR4OS worker guard verification) and **36/36 `make test-rohd` PASS** (end-to-end `act4c.py --hw-math` → `mr4asm.py` → ROHD `CpuCore` 1-DSP `MathAccelerator` + `CPU_CAPS` guard RTL co-simulation).
- [x] **B.3 Unify MR4OS IPC onto Hardware Lean Ring (`0x0020`–`0x002A`) & Boot MR4OS on ULX3S-85F**
  - Ported `mr4src/act4/os/os_proc.a4`, `mr4src/act4/os/os_main.a4`, `mr4src/asm/worker_stub.asm` (also relocating stub scratchpad from `0x0010` to `0x03F0` so workers never collide with the Hardware Math Accelerator), `tools/act4c.py` (unbound Trap 14 → `ERET`), and `tools/mr4sim.py` (`LeanNocNI`/`LeanNocFabric` mirroring exact 16-word finite RX FIFO & 1-entry MBOX backpressure + Slot-0 Trap 14 boundary) onto the direct-addressed Hardware Lean Ring (`0x0020`–`0x002A`) with a deadlock-free MBOX-doorbell → `"GO"` (`0x474F`) grant protocol and Hardware Trap 14 remote KILL (`0xDEAD`) — 100% identical binaries in simulation and FPGA!
  - Added `make ulx3s-mr4os` target (`Makefile`) building the complete 4-core MR4OS ULX3S-85F system (`os_main.a4` in Core 0 64K BRAM + `worker_stub.asm` in Workers 1..3 2K BRAM + private SDRAM I/D caches + Lean Ring NoC + microSD SPI + 4× 1-DSP Math Accelerators @ `72 MHz`).
  - Verified **18/18 `make os-test` PASS**, **36/36 `make test-rohd` PASS**, and **Verilator end-to-end 4-core hardware RTL simulation (`ulx3s_top_rohd.sv` + FAT32 SDHC image + physically timed JEDEC SDRAM + 3 Mbaud UART) PASS** (`MiniRISC4 OS v0.1`, `FAT32 mounted OK`, live `! ls`, `! cat README.TXT`, `! ps` across Worker 1 SDRAM caches, `46` sectors read, `0` UART errors):
    - **4-Core MR4OS (`64K` Core 0 + `3×2K` Workers + SDRAM + Lean Ring + SPI + 4× 1-DSP Math @ `72 MHz`):** `14,617 LUT4` (`17%`), `5,318 TRELLIS_FF` (`6%`), **`4 MULT18X18D`** (`2%`), `82 DPR16X4`, `77 DP16KD` (`37%`), `17 IOLOGIC` (`7%`) — **`104.74 MHz`** (**PASS at `72.00 MHz`**, +32.7 MHz slack; bitstream `build/ulx3s/ulx3s_top_rohd.bit` ready for ULX3S-85F live bring-up!).

### Track C: Core Microarchitecture — GHz-Ready 4-Stage Pipeline
- [x] **C.1 CPI & Critical-Path Profiling Baseline**
  - Added zero-overhead-when-off `ExecutionProfiler` (`--profile`, `--max-steps`) to `tools/mr4sim.py` modeling exact current `CpuCore` FSM cycles, load-use hazard distance, and 4-stage pipeline projections (2-cycle BRAM & 1-cycle SRAM).
  - Profiled `monitor.bin` (`CPI 1.989 → 1.307/1.201`), `stress_hw_master/worker` (`CPI 1.853–2.125 → 1.369–1.399 / 1.195–1.237`), `os_main.bin` (`CPI 1.606–1.634 → 1.305–1.311 / 1.152–1.158`, `29–34%` `XCHG`), and `MUL.PRG` (`CPI 1.739 → 1.296 / 1.167`); identified `PUSH8` `_stFetchLatch` bubbles (`13–22%` of cycles) as the #1 software cycle sink alongside load stalls (`12–17%`) and branch flushes (`10–15%`).
  - Captured `yosys` generic 2-input gate depth (**`35` levels**: `dec_rl_q → regfile mux → 16-bit adder → port_b_addr`) and `nextpnr-ecp5` 96 MHz critical path (**`9.92 ns`**, `2.79 ns` logic / `9` LUT levels + `7.13 ns` routing: `dec_imm4_q → regL==0 → FSM CE`) in [Profiling_Baseline_C1.md](Profiling_Baseline_C1.md).
- [x] **C.2 Trap-Safe Hardware Return Link (`EPC` / Non-Destructive Async Traps)**
  - Added dedicated 16-bit hardware `EPC` register (`epc_q`, R/W MMIO at `0x001E`, enabled via `CpuConfig.hasEpc` whenever `enableCrossTraps` or `enableEpc` is set) and 1-byte `ERET` instruction (`0x0F`, pre-decoded into `dec_is_eret_q`, returning `PC ← EPC` while preserving all four `R0`–`R3` and `shadow_r[0..3]`).
  - Asynchronous hardware Trap 14 (`crossTrapTake`) now latches `epc_q` **without clobbering `R0`** (also simplifying `CpuCore` register-file writeback muxing), while synchronous `TRAP`/`LINK`/Trap 15 remain 100% backwards-compatible.
  - Added `ERET` mnemonic to `tools/mr4asm.py`, mirrored `EPC`/`ERET`/non-destructive Trap 14 in `tools/mr4sim.py`, updated all four hardware Trap 14 firmwares (`ipc_hw_*`, `stress_hw_*`) to `ERET`, and verified **31/31 `make test-rohd` PASS** (including live `R0=0xBEEF`/`0xACED` preservation across async Trap 14 and `EPC` R/W + `ERET` 4-register context switch), `make apps` PASS, and **Icarus Verilog 4-Core `96 MHz` SDRAM Stress PASS (`0` errors)**:
    - **4-Core SDRAM @ `96 MHz`:** `8547 LUT4` (`+26 LUT4/core`), `3557 TRELLIS_FF` (`+17 FF/core`), `80 DPR16X4`, `16 DP16KD`, `17 IOLOGIC` — **`96.33 MHz`** (PASS at `96.01 MHz`)
- [x] **C.3 4-Stage In-Order Pipelined `CpuCore` (`IF → ID/RF → EX → WB`)**
  - Refactored `CpuCore` (`hdl/rohd/lib/cpu_core.dart`) into a balanced 4-stage in-order pipeline (`IF → ID/RF → EX → WB`) with an 8-entry `DPR16X4` distributed-RAM prefetch queue + pure-FF FWFT `idWordQ` head (zero-bubble `1.0` cycle/`PUSH8`), pre-selected adder operands (`exAddAQ`/`exAddBQ`) + pre-computed pure-FF `WB→EX`/`WB→ID` forwarding (including single-cycle `XCHG` shadow forwarding and stalled-`EX` forward capture), 2-LUT `exHold` via 4-bit one-hot `exRegMaskQ`/`memDestMaskQ`, parallel non-blocking Port B Memory/MMIO/`DCache` unit with exact `RAW`/`WAW` interlock, clean Slot-0 Trap 14 / branch flush, configurable `CpuConfig.memReadLatency` (`2`-cycle ECP5 `TdpBram` default, `1`-cycle ASIC SRAM ready), and `CpuConfig.isPipelined = true` (`CAP_PIPELINED = 0x0400` in `CPU_CAPS`).
  - Verified **34/34 `make test-rohd` PASS** (including dedicated pipeline `RAW`/`WAW`/`XCHG`/stalled-`EX`/store-to-load/`EPC→ERET` hazard tests and zero-bubble `PUSH8` throughput verification), **`make apps` + `make os-test` (17/17) PASS**, and **Icarus Verilog 4-Core `96 MHz` SDRAM Stress PASS** across both slow (`tAC=5.4ns`) and fast (`tAC=2.0ns`) corners (`0` errors; runtime improved `4.85 ms / 638 refreshes → 4.25 ms / 558 refreshes`, **`−12.4%` wall-clock / `~1.18×` faster active execution** even while SDRAM-bound):
    - **1-Core 2K BRAM (No SDRAM, timing-driven ceiling):** `1464 LUT4`, `546 TRELLIS_FF`, `4 DPR16X4`, `2 DP16KD`, `0 IOLOGIC` — **`132.49 MHz`** (**surpassed `>130 MHz` target!**)
    - **1-Core 2K BRAM + I/D Cache + SDRAM:** `2268 LUT4`, `1198 TRELLIS_FF`, `20 DPR16X4`, `4 DP16KD`, `17 IOLOGIC` — **`114.89 MHz`** (`+9.5 MHz` vs `105.39 MHz` baseline)
    - **4-Core `4×2K` + Lean NoC + SDRAM @ `96 MHz`:** `9270 LUT4`, `4428 TRELLIS_FF`, `96 DPR16X4`, `16 DP16KD`, `17 IOLOGIC` — **`104.00 MHz`** (PASS at `96.01 MHz`, `+4.8 MHz` vs `99.23 MHz` baseline)
    - **Yosys Generic 2-Input ASIC Gate Depth (`TdpBram`/`NocFifoRam` blackboxed):** **`30` levels** (down from `35` — strictly **5 non-adder gate levels** [`2` pre-adder + `3` post-adder] + `25`-level default ripple/LCU adder, projecting **`<= 15` gate levels** with a standard 24 nm ASIC prefix adder).

### Track D: Road to OpenROAD (ASIC RTL-to-GDS Flow)
*(Implements [Road_to_OpenROAD.md](Road_to_OpenROAD.md) without disturbing the ULX3S ECP5 flow.)*
- [x] **D.1 Target-Selectable Memory Abstraction (`MemoryFactory`) & Boot ROM Strategy**
  - Added `hdl/rohd/lib/memory_factory.dart` (`MemoryTarget.fpgaEcp5` / `asicSram` / `asicFlop`, `DualPortMemory` interface, foundry-ready `AsicSramDpMacro` / `AsicSramSpMacro` black-box-under-`SYNTHESIS` wrappers, pure standard-cell `AsicDualPortSram` / `AsicSinglePortFlopRam` / `AsicSmallRam`, and synthesizable `AsicBootRom` + write-protected `DualPortRamWithBootRom` cold-start overlay supporting both 1-cycle and 2-cycle read latency).
  - Decoupled `CpuCore`, `CpuConfig`, `TdpBram`, `ICache`/`DCache`, `SdramCacheCluster`, `NocRouterNi`, and `NocMultiCoreCacheWrapper` via `MemoryFactory`, eliminating FPGA-only `(* ram_style *)` attributes and `$readmemh` on ASIC targets while keeping the ULX3S-85F FPGA SystemVerilog **100% byte-for-byte identical** (`0` non-timestamp diff across 792 KB 4-core MR4OS SV).
  - Verified **40/40 `make test-rohd` PASS** (including `memory_factory_test.dart`: cold-boot from uninitialized `0xA5A5` SRAM via `AsicBootRom` at both `memReadLatency = 1` and `2`, ROM write-protection, `asicFlop` zero-blackbox mode, and `ICache`/`DCache`/`NocRouterNi` ASIC RTL cleanliness) and **Yosys ASIC preflight (`read_verilog -sv -DSYNTHESIS; hierarchy -check -top CpuCore; proc; opt; check -assert; stat`) PASS** (`0` errors, `1 × mr4_sram_dp_2048x16` macro preserved, `0` SRAM flop explosions, `128`-bit prefetch queue only).
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

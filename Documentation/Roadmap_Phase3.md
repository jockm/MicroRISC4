# MicroRISC4 Phase 3 Roadmap: 130 nm Real Silicon, Multi-GHz Exploration, CSP Mesh Scaling & MR4OS Polish

> **Status:** Active (supersedes Phase 2 [Roadmap_Phase2.md](Roadmap_Phase2.md), which is 100% complete across all 13 items in Tracks A–D).
> **Related Documents:** [Roadmap.md](Roadmap.md) (Phase 1) · [Roadmap_Phase2.md](Roadmap_Phase2.md) (Phase 2 Archive) · [RoadmapOS.md](RoadmapOS.md) (MR4OS) · [Road_to_OpenROAD.md](Road_to_OpenROAD.md) (ASIC Flow Guide) · [GettingStarted.md](../GettingStarted.md)

---

## 1. Phase 2 Verified Baseline (Starting Point)

All Phase 3 work builds on these hardware-verified ULX3S-85F FPGA and OpenROAD RTL-to-GDSII baselines while keeping `make apps`, `make test-rohd` (45/45), and `make os-test` (18/18) green:

### ULX3S-85F (Lattice ECP5-85F) Verified Baselines
| Configuration | `LUT4` | `TRELLIS_FF` | `DPR16X4` | `DP16KD` | `IOLOGIC` | **`nextpnr` $F_{\max}$** | Verification |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **1-Core 2K BRAM (4-stage)** | `1,464` | `546` | `4` | `2` | `0` | **`132.49 MHz`** | Timing ceiling |
| **1-Core + I/D Cache + SDRAM** | `2,268` | `1,198` | `20` | `4` | `17` | **`114.89 MHz`** | Live HW @ `96 MHz` (`0` err) |
| **4-Core MR4OS + SDRAM + SPI + 4× Math** | `14,617` | `5,318` | `82` | `77` | `17` | **`104.74 MHz`** | Live HW @ `72 MHz` (FAT32 `/BIN`, `/WORK`) |
| **16-Core (`16×2K` BRAM) + Lean Ring** | `21,230` | `10,210` | `128` | `32` | `0` | **`93.12 MHz`** | Verilator 64-round PASS (`0` err) |
| **32-Core (`32×2K` BRAM) + Lean Ring** | `41,668` | `20,561` | `256` | `64` | `0` | **`85.06 MHz`** | Live HW @ `60 MHz` (`42,816+` rounds, `0` err) |

### OpenROAD ASIC (RTL-to-GDSII) Verified Baselines
| Process Node | Configuration | Achieved $F_{\max}$ | Stdcell / Die Area | Power | Notes |
| :--- | :--- | :---: | :---: | :---: | :--- |
| **SkyWater 130 nm (`sky130hd`)** | `CpuCore` + Boot ROM + UART *(SRAM mocked)* | **`305.2 MHz`** | `0.0390 mm²` (`5,100` cells) | `18.8 mW` @ 303 MHz | `0` viols/errors; Tiny Tapeout-scale |
| **IHP 130 nm (`ihp-sg13g2`)** | `CpuCore` + Boot ROM + UART *(SRAM mocked)* | **`360.9 MHz`** | `0.0804 mm²` (`5,137` cells) | `22.0 mW` @ 333 MHz | `0` viols/errors; `+229 ps` slack |
| **Nangate45 (45 nm)** | `mr4_asic_top` (1024w flop RAM + Boot ROM + UART) | **`309.0 MHz`** | `0.139 mm²` / `0.349 mm²` | `18.0 mW` @ 100 MHz | `6_final.gds` (64 MB), LEC PASS |
| **Nangate45 (45 nm)** | Hierarchical 4-Tile `mr4_quad_top` (`4× mr4_tile`) | **`180.8 MHz`** tile / **`262.8 MHz`** ring | `3.09 mm²` die (`2` top FFs) | `19.5 mW`/tile | `6_final.gds` (83 MB), flat $F_{\max}$ |
| **Nangate45 (45 nm)** | `CpuCore` + Boot ROM + UART *(SRAM mocked)* | **`1.048 GHz`** | `0.00742 mm²` (`4,179` cells) | `8.82 mW` @ 1.0 GHz | `0` viols/errors (`+46 ps` slack) |
| **ASAP7 (7 nm `RVt`)** | `mr4_asic_top` (1024w flop RAM + Boot ROM + UART) | **`1.001 GHz`** | `0.00784 mm²` / `0.0235 mm²` | `15.7 mW` @ 500 MHz | `0` viols/errors (`6.0 µW` leakage) |
| **ASAP7 (7 nm `RVt`)** | `CpuCore` + Boot ROM + UART *(SRAM mocked)* | **`3.009 GHz`** | `0.000595 mm²` (`4,823` cells) | `7.34 mW` @ 3.0 GHz | `0` viols/errors (`+0.68 ps` slack) |

---

## 2. Phase 3 Execution Order & Detailed Checklist

> **Discipline:** Follow the exact execution order **E.1 → E.2 → G → F → H**. Record verified ROHD/Verilator tests, FPGA resource/`nextpnr` $F_{\max}$, and ORFS area/power/slack/error metrics on every item, and confirm before starting each new item.

### Track E.1: Tiny Tapeout MicroRISC4 (`Mr4TinyTop` — Real Packaged 130 nm Silicon)
*Goal: Produce a shuttle-ready, affordable (`~$500–$700`) 2×2 Tiny Tapeout MicroRISC4 ASIC on `sky130hd` / `ihp-sg13g2` that boots real programs via off-chip QSPI PSRAM/Flash and UART.*

- [x] **E.1.1 Compact QSPI PSRAM / Flash Memory Controller (`hdl/mr4/lib/qspi_mem_controller.dart`)**
  - Implemented ASIC-clean `QspiMemController` targeting the standard Tiny Tapeout QSPI PMOD pinout (`uio[0]=CS0 Flash`, `uio[1,2,4,5]=SD[0..3]`, `uio[3]=SCK`, `uio[6]=CS1 APS6404L PSRAM`, `uio[7]=CS2`), supporting 1-4-4 `0xEB` Fast Read Quad I/O (6 dummy cycles) and `0x38` Quad Input Write (0 dummy cycles) right out of reset, Mode-0 half-rate `SCK`, 1-cycle `tCPH` CS-high deselect guard, and a coherent 1-line (4-word / 64-bit) Instruction Prefetch Cache (1-cycle sequential IF hits, 4-word burst misses, immediate DC-write tag invalidation) bridging directly onto `CpuCore`'s native `ic_*`/`dc_*` external bus.
  - Verified **`691` generic cells** (`204` FFs + `487` gates, `0` FPGA primitives, `0` memories) in Yosys `check -assert; synth` and **47/47 `make test-rohd` PASS** (including `qspi_mem_controller_test.dart`: behavioral APS6404L PSRAM + W25Q Flash slave, direct Quad Write/Read, 4-word I-cache 1-cycle hits, coherent write invalidation, Flash CS0 routing, and end-to-end `CpuCore` executing real code and read/write data directly out of external QSPI PSRAM).
- [x] **E.1.2 `Mr4TinyTop` Wrapper (`tt_um_mr4`) & Compact Bootloader (`mr4src/asm/tiny_boot.asm`)**
  - Added compact `localRamWords` (`sramDepth`) support to `CpuConfig` / `CpuCore` / `DualPortRamWithBootRom` so `tt_um_mr4` allocates only a **16-word (256-FF)** local scratchpad (`0x0000..0x000F`: `SAVEALL`/`LOADALL`, `RSP`, `ASP`, boot temps) plus a **256-word** synthesizable `AsicBootRom` (`0x0100..0x01FF`), while routing all addresses `0x0200..0xFFFF` (127.5 KB) to external QSPI PSRAM/Flash with **zero mocked memories**.
  - Implemented `hdl/mr4/lib/mr4_tiny_top.dart` (`Mr4TinyTop`, `definitionName => 'tt_um_mr4'`) exposing the exact Tiny Tapeout pin interface (`ui_in[7:0]`, `uo_out[7:0]`, `uio_in[7:0]`, `uio_out[7:0]`, `uio_oe[7:0]`, `ena`, `clk`, `rst_n`), wiring standard QSPI PMOD on `uio[7:0]`, UART RX/TX on `ui_in[0]`/`uo_out[0]`, Flash XIP select on `ui_in[1]`, and live QSPI/UART/PC heartbeat LEDs on `uo_out[7:1]`.
  - Wrote `mr4src/asm/tiny_boot.asm` (`186` non-zero words in `0x0100..0x01F2`): initializes `RSP`/`ASP` in QSPI PSRAM, auto-boots from QSPI Flash/PSRAM when `[0x0400] == 0x4D34` (`"M4"`), prints `"MR4 TT\r\n"`, and implements a compact binary UART monitor/loader (`?` ping, `L` load words into QSPI PSRAM, `P` peek word, `G` execute).
  - Added `hdl/mr4/bin/generate_tiny.dart`, `asic/mr4_tiny/{config.mk,constraint.sdc}` (2×2 Tiny Tapeout tile constraints for `sky130hd` `330×220 µm` and `ihp-sg13g2`), and `Makefile` targets (`generate-tiny`, `tiny-check`, `tiny-flow`).
  - Verified **`5,792` generic cells** (`1,190` FFs + `4,602` gates, `0` memories, `0` FPGA primitives) in `make tiny-check` (Yosys `check -assert; synth -top tt_um_mr4`), Verilator `--lint-only` PASS, and **50/50 `make test-rohd` PASS** (including `mr4_tiny_top_test.dart`: end-to-end cold-boot banner, UART ping/load/peek/execute out of external QSPI PSRAM, and QSPI Flash CS0 XIP auto-boot).
- [x] **E.1.3 Tiny Tapeout Tile Fit, ORFS Closure & Gate-Level Verification**
  - Shrank `tt_um_mr4` by **`-29.6%`** (`5,792 → 4,077` Yosys generic cells, `1,190 → 928` FFs, `0` memories, `0` FPGA primitives) via 8-word Port-B-only local scratchpad (`AsicSinglePortFlopRam`), single-port Port-A-only `AsicBootRom` (inline banner in `tiny_boot.asm`), 4-entry `iqRam` (`iqAddrWidth=2`), and 2-word coherent QSPI I-cache.
  - **SkyWater 130 nm (`sky130hd`, exact 2×2 Tiny Tapeout tile `331.66 × 225.76 µm` = `0.0749 mm²`, zero mocked memories):** closed end-to-end RTL-to-GDSII at **`129.42 MHz`** (`+12.27 ns` setup slack @ `50 MHz`, `+278 ps` hold slack), **`6,210` stdcells** (`49,644 µm²`, `71.2%` util), **`3.63 mW`** @ `50 MHz`, `0` violations/errors.
  - **IHP 130 nm (`ihp-sg13g2`, exact 3×2 Tiny Tapeout tile `629.28 × 313.74 µm` = `0.1974 mm²`, zero mocked memories):** closed end-to-end RTL-to-GDSII at **`145.97 MHz`** (`+13.15 ns` setup slack @ `50 MHz`, `+133 ps` hold slack), **`7,254` stdcells** (`112,244 µm²`, `71.0%` util), **`4.44 mW`** @ `50 MHz`, `0` violations/errors, `6_final_lec` PASS.
  - **Post-Route Gate-Level Simulation (`make tiny-gls` via `asic/mr4_tiny/tb_tt_um_mr4.sv` + `tools/lib2vlog.py`):** **PASS 5/5 on BOTH routed `sky130hd` (`6,210` cells) and `ihp-sg13g2` (`7,254` cells) `6_final.v` netlists** — cycle-for-cycle identical to RTL (`591,208` cycles, `345` QSPI tx @ `50 MHz / 115.7 kbaud`): cold-boot `"MR4 TT\r\n"`, ping `'?'→'!'`, 49-word UART upload into APS6404L QSPI PSRAM, peek `[0x0400]==0x05f8`, and direct execution out of QSPI PSRAM (`"GOK!"`, `[0x0500]=0xCAFE`, `[0x0501]=0xCAFF`).

---

### Track E.2: Full 130 nm Multi-Core Shuttle Chip with Real Hard SRAM Macros
*Goal: Replace the standalone flop RAM with genuine, silicon-proven 130 nm SRAM macros (`sky130` OpenRAM and `ihp-sg13g2` foundry 1P SRAM) and verify full post-route gate-level timing closure.*

- [ ] **E.2.1 Single-Port (`1P`) SRAM Adapter & Interleaved Wrapper (`memory_factory.dart`)**
  - Add a clean `AsicSinglePortSramAdapter` in `hdl/mr4/lib/memory_factory.dart` wrapping foundry 1-port (`1P`) macros (such as IHP's `RM_IHPSG13_1P_1024x16` / `2048x16`) into the `DualPortMemory` interface — via either 2-bank odd/even interleaving or Port-B-priority arbitration with 1-cycle IF stall when Port A & Port B collide — with zero ISA changes.
  - Verify cycle-exact hazard/collision behavior in `make test-rohd` and Verilator.
- [ ] **E.2.2 Real 130 nm Hard SRAM Macro Integration (`sky130hd` OpenRAM & `ihp-sg13g2` Foundry SRAM)**
  - Wire `sky130_sram_2kbyte_1rw1r_32x512_8` (OpenRAM 1RW+1R dual-port) for `sky130hd` and `RM_IHPSG13_1P_1024x16_c2_bm_bist` (or `2048x16`) for `ihp-sg13g2` into ORFS (`asic/mr4_sram/` + `asic/mr4_tile/`) via `ADDITIONAL_LEFS`/`LIBS`/`GDS` with `ASIC_MEM_TARGET=sram`.
  - Verify dramatic area/power reduction vs. flop-RAM builds and record real macro-inclusive $F_{\max}$, area, IR drop, and power on both 130 nm PDKs.
- [ ] **E.2.3 4-Tile 130 nm Shuttle Cluster Assembly & Post-Route Gate-Level Timing Simulation (GLS)**
  - Harden `mr4_tile` with real 130 nm SRAM macros and assemble a 4-tile hierarchical `mr4_quad_top` chip on `sky130hd` / `ihp-sg13g2` (including clean macro/top PDN and pad-ring readiness).
  - Run post-route gate-level simulation (`6_final.v` + standard-cell/SRAM Verilog behavioral models + SDF timing) confirming cold-boot + 4-tile Lean Ring Trap 14 round-trip (`MR4 TILE0 OK` + `RING PASS`) on the actual routed netlist.

---

### Track G: Microarchitecture & Speed Exploration
*Goal: Push the architectural frequency/IPC frontier across 130 nm, 45 nm, and 7 nm while preserving MicroRISC4's minimalist 4-register ethos.*

- [ ] **G.1 FakeRAM Macro Closure on 45 nm (`nangate45`) & 7 nm (`asap7`) with 2-Cycle Pipelined SRAM**
  - Integrate ORFS FakeRAM macros (`2048×16`) with `CpuConfig.memReadLatency = 2` on `nangate45` and `asap7` to verify full macro-inclusive `1+ GHz` (45 nm) and `2.5–3+ GHz` (7 nm) timing closure, including a 4-tile hierarchical cluster on `asap7`.
- [ ] **G.2 5-Stage Pipeline Split (EX/ALU vs. Branch/PC-Select) & Compact Branch Predictor**
  - Evaluate splitting the critical EX path (`ex_arith_sub_q → prefix adder → wb_data_q / port_b_addr / branch target`) into a balanced 5-stage pipeline (`IF → ID/RF → EX → BR/MEM → WB`) paired with a tiny 16–32 entry BTB/1-bit branch predictor so branch flushes don't erode IPC.
  - Benchmark CPI (via `mr4sim.py --profile`), ECP5 FPGA $F_{\max}$, and ASIC $F_{\max}$ across 130 nm / 45 nm / 7 nm (`>400 MHz` 130 nm, `>1.4 GHz` 45 nm, `>3.5 GHz` 7 nm targets).
- [ ] **G.3 Optional Compact Floating-Point / Fixed-Point Accelerator (`CPU_CAPS.b4`)**
  - Implement an optional MMIO Q16.16 or IEEE-754 binary16/binary32 accelerator behind `CpuConfig.enableFpu` (`CAP_FPU = 0x0010` already reserved in `CPU_CAPS`), with matching `mr4sim.py` support, ROHD tests, and ACT4 helper library.

---

### Track F: CSP Multi-Core Architecture & Scaling
*Goal: Scale MicroRISC4's Transputer/CSP multi-core architecture to higher core counts, 2D mesh bisection bandwidth, and first-class language primitives.*

- [ ] **F.1 Pipelined Per-Core Reset Tree → 48–56 Live ULX3S Cores & 8–16 Core Live MR4OS**
  - Register a 1-FF local reset repeater per core in `Ulx3sTop` (removing the global `sys_rst_n` fanout bottleneck that capped 32 cores at `85.06 MHz`), then build and verify a **48-core** (and test ceiling toward **56 cores**) ULX3S-85F stress bitstream.
  - Scale `MR4OS` (`MAX_PROCS`, `os_proc.a4`) and add `make ulx3s-mr4os-8core` so 8–16 live OS cores run concurrently on ULX3S-85F.
- [ ] **F.2 2D Mesh / Torus NoC (`Mr4MeshTile`)**
  - Extend `Mr4Tile` with a lean 2D XY-routed registered router (`N/S/E/W` + Local elastic hops, zero combinational loops) so 16–64 core ASIC clusters scale in bisection bandwidth and hop latency ($O(\sqrt{N})$ vs. $O(N)$) while preserving flat $F_{\max}$.
  - Verify a 4×4 (16-tile) mesh in ROHD/Verilator and hierarchical ORFS assembly.
- [ ] **F.3 First-Class CSP Primitives in ACT4 (`chan`, `send`, `recv`, `select`, `spawn`)**
  - Add native CSP channel syntax and runtime lowering in `tools/act4c.py` mapping directly onto the Hardware Lean Ring / Mesh (`0x0020`–`0x002A`) and Hardware Trap 14 doorbells, with multi-core CSP demo apps and regression tests in `make os-test`.

---

### Track H: MR4OS & Toolchain Polish
*Goal: Make MicroRISC4 a joy to program and use interactively directly on the ULX3S-85F.*

- [ ] **H.1 Fix `xi` Editor Bug & Refine MR4OS `/BIN` + `/WORK` Experience**
  - Reproduce and fix the `xi` bug encountered during live ULX3S-85F bring-up, add a regression test to `tools/test_os.py`, and polish shell ergonomics (e.g., default boot into `/WORK`, `/BIN/AUTOEXEC.DO` startup script support).
  **NOTE:** `xi` bug has been fixed, along with auto run file named `/BIN/BOOT.DO`, user boots into `/WORK`, and shell prompt shows currect directory. This should all be reviewed and tests updated as needed.
  - [ ] **H.2 ACT4 Optimizing Backend (Register Caching & Peephole Pass)**
  - Add a peephole optimizer and basic-block register-value tracker in `tools/act4c.py` to eliminate redundant loads/pushes, shrink `.PRG` binaries further, and improve real-world IPC across MR4OS and userland apps (verified bit-exact across 18/18 `make os-test` + ROHD co-sim).
- [ ] **H.3 On-Board Self-Hosting Dev Workflow**
  - Build a compact on-board assembler (`ASM.PRG`) or MuL-assisted build script so small MicroRISC4 assembly programs can be edited in `xi`, assembled into `.PRG` files in `/WORK`, and executed directly on worker cores *on the live ULX3S-85F with no host PC required*.

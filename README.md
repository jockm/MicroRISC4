# MicroRISC4 Processor & Software System

A minimalist, in-order, 16-bit word-addressed Von Neumann processor architecture implemented in Intel ROHD (Dart), currently targeted at FPGA synthesis on the Lattice ECP5 (ULX3S board) using OSS CAD Suite.

The project origin was to explore the idea of a small fast multi core system that could emulate other CPUs while being isolated from each other and communicating only by FIFOs — encouraging a Transputer like CSP approach. When it became it was unsuited for this job — because of it's odd architecture and hardware limits — the focus shifted.

Now it is a testbed for CSP multi-core systems, and exploring the engineering required to make a core that can operate at gigahertz speeds.

MicroRISC4 (MR4 or "Mister 4") is a 16 bit, word addressed system with 8-bit instructions.  It has 4 regitsers and a total of 25 possible instructions.  It relies on MMIO for any additional functions.  It is like a cross between early Data General minicomputers and early RISC designs, with a little CSP for flavor.

In addition to assembler there is a small systems language called Act4, inpsired by the Action! programming language for Atari 8-bit computers.

The idea of using small risc cores to emulate larger architectures is being carried forward in the *Particle* project.

## Hardware & ASIC Verification

MicroRISC4 has been synthesized, timed, and verified on both live **Lattice ECP5-85F FPGA hardware (ULX3S-85F)** — including 96 MHz SDRAM with ODDR clock forwarding, onboard microSD SPI, the optional 1-DSP Math Accelerator, live 4-core MR4OS with FAT32 userland apps, and a live 32-core Lean Ring stress test — and end-to-end through **OpenROAD-flow-scripts (RTL-to-GDSII)** on public **SkyWater 130 nm (`sky130hd`)**, **Nangate45 (45 nm)**, and **ASAP7 (7 nm)** reference PDKs (both standalone `mr4_asic_top` and a hierarchical 4-tile `mr4_quad_top` macro layout). See [GettingStarted.md](GettingStarted.md) to build, simulate, program the ULX3S, or run the Dockerized OpenROAD flow.

### Measured Speeds & Configurations

| Target / Flow | Configuration | Achieved $F_{\max}$ | Area / Resources | Notes |
|---|---|---|---|---|
| **ULX3S-85F (ECP5 FPGA)** | 1-Core 2K BRAM (4-stage pipeline) | **132.49 MHz** | 1,464 LUT4, 546 FF, 2 DP16KD | Timing-driven FPGA ceiling (`nextpnr-ecp5`) |
| **ULX3S-85F (ECP5 FPGA)** | 1-Core + I/D Cache + 32 MB SDRAM | **114.89 MHz** | 2,268 LUT4, 1,198 FF, 4 DP16KD | Live HW verified at **96 MHz** (`0` errors) |
| **ULX3S-85F (ECP5 FPGA)** | 4-Core MR4OS + SDRAM + Lean Ring + SPI + 4× Math | **104.74 MHz** | 14,617 LUT4 (17%), 5,318 FF, 4 DSP, 77 DP16KD | Live HW verified at **72 MHz** (`+32.7 MHz` slack; FAT32 + userland apps) |
| **ULX3S-85F (ECP5 FPGA)** | 4-Core (`4×2K`) + Lean Ring + SDRAM | **104.00 MHz** | 9,270 LUT4, 4,428 FF, 16 DP16KD | Passes **96 MHz** timing cleanly |
| **ULX3S-85F (ECP5 FPGA)** | 16-Core (`16×2K` BRAM) + 16-Node Lean Ring | **93.12 MHz** | 21,230 LUT4 (25%), 10,210 FF, 128 DPR16X4, 32 DP16KD | Passes **72 MHz** (`+21.1 MHz` slack); Verilator 64-round stress PASS (`0` errors) |
| **ULX3S-85F (ECP5 FPGA)** | 32-Core (`32×2K` BRAM) + 32-Node Lean Ring | **85.06 MHz** | 41,668 LUT4 (50%), 20,561 FF, 256 DPR16X4, 64 DP16KD | Live HW verified at **60 MHz** (`42,816+` rounds, `0` errors) |
| **OpenROAD — Sky130HD (130 nm)** | 1-Core `CpuCore` + Boot ROM + UART *(SRAM mocked)* | **241.9 MHz** | `0.0370 mm²` stdcell (`4,861` cells), `7.79 mW` @ 125 MHz | `0` setup/hold violations, `0` errors (`+3.87 ns` slack @ 125 MHz; Tiny Tapeout-scale!) |
| **OpenROAD — Nangate45 (45 nm)** | 1-Core `mr4_asic_top` (1024w flop RAM + Boot ROM + UART) | **309.0 MHz** | `0.139 mm²` stdcell (`0.349 mm²` die), `18.0 mW` @ 100 MHz | `6_final.gds` (64 MB), LEC PASS, `0` errors, `+6.76 ns` slack @ 100 MHz target |
| **OpenROAD — Nangate45 (45 nm)** | Hierarchical 4-Tile `mr4_quad_top` (4× hardened `mr4_tile`) | **180.8 MHz** tile / **262.8 MHz** top ring | `3.09 mm²` die (4× `0.377 mm²` macros, `2` top FFs) | `6_final.gds` (83 MB), `0` warnings/errors — **flat $F_{\max}$ scaling** across core counts |
| **OpenROAD — Nangate45 (45 nm)** | 1-Core `CpuCore` + Boot ROM + UART *(SRAM mocked)* | **1,048.2 MHz (1.048 GHz)** | `0.00742 mm²` stdcell (`4,179` cells), `8.82 mW` @ 1.0 GHz | `0` setup/hold violations, `0` errors (`+46 ps` slack @ 1.0 GHz even with `250 ps` uncertainty) |
| **OpenROAD — ASAP7 (7 nm `RVt`)** | 1-Core `mr4_asic_top` (1024w flop RAM + Boot ROM + UART) | **1,001.3 MHz (1.001 GHz)** | `0.00784 mm²` stdcell (`0.0235 mm²` die), `15.7 mW` @ 500 MHz | `0` setup/hold violations, `0` errors (`+1,001 ps` slack @ 500 MHz, `6.0 µW` leakage) |
| **OpenROAD — ASAP7 (7 nm `RVt`)** | 1-Core `CpuCore` + Boot ROM + UART *(SRAM mocked)* | **3,009.1 MHz (3.009 GHz)** | `0.000595 mm²` stdcell (`4,823` cells), `7.34 mW` @ 3.0 GHz | `0` setup/hold violations, `0` errors (`+0.68 ps` setup / `+10.5 ps` hold slack @ 3.0 GHz) |

*Note: The full-chip OpenROAD runs include a standalone 1024×16 flip-flop RAM (~94% of die area) so they run end-to-end without external foundry SRAM macros. The `SRAM mocked` rows (`SYNTH_MOCK_LARGE_MEMORIES=1`) isolate the true 4-stage `CpuCore` + `AsicBootRom` + `Uart` pipeline ceiling when paired with compiled foundry SRAM macros (using `CpuConfig.memReadLatency = 2` for pipelined multi-GHz SRAM reads).*

## How LLMs Are Used in This Project.
The project makes use of LLM's in a Spec -> Revise -> Generate -> Test loop.  Normally for specific features or goals.  Each step is reviewed by a human, as is the output.

In addition human hands have revised code and documents directly and created original code.

Decisions and the direction of development are always made by a human, all research and references are always checked.

Multiple LLMs have been used:
- Google Gemini
- Antropic Claude
- Microsoft Copilot
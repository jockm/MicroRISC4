# MicroRISC4 Processor & Software System

A minimalist, in-order, 16-bit word-addressed Von Neumann processor architecture implemented in Intel ROHD (Dart), currently targeted at FPGA synthesis on the Lattice ECP5 (ULX3S board) using OSS CAD Suite.

The project origin was to explore the idea of a small fast multi core system that could emulate other CPUs while being isolated from each other and communicating only by FIFOs — encouraging a Transputer like CSP approach. When it became it was unsuited for this job — because of it's odd architecture and hardware limits — the focus shifted.

Now it is a testbed for CSP multi-core systems, and exploring the engineering required to make a core that can operate at gigahertz speeds.

MicroRISC4 (MR4 or "Mister 4") is a 16 bit, word addressed system with 8-bit instructions.  It has 4 regitsers and a total of 25 possible instructions.  It relies on MMIO for any additional functions.  It is like a cross between early Data General minicomputers and early RISC designs, with a little CSP for flavor.

In addition to assembler there is a small systems language called Act4, inpsired by the Action! programming language for Atari 8-bit computers.

The idea of using small risc cores to emulate larger architectures is being carried forward in the *Particle* project.

## Hardware & ASIC Verification

MicroRISC4 has been synthesized, timed, and tested on both live **Lattice ECP5-85F FPGA hardware (ULX3S-85F)** — including 96 MHz SDRAM with ODDR clock forwarding, onboard microSD SPI, the optional 1-DSP Math Accelerator, and multi-core Lean Ring configurations — and end-to-end through **OpenROAD-flow-scripts (RTL-to-GDSII)** on public **Nangate45 (45 nm)** and **ASAP7 (7 nm)** reference PDKs (both standalone `mr4_asic_top` and a hierarchical 4-tile `mr4_quad_top` macro layout). See [GettingStarted.md](GettingStarted.md) to build, simulate, program the ULX3S, or run the Dockerized OpenROAD flow.

### Measured Speeds & Configurations

| Target / Flow | Configuration | Achieved $F_{\max}$ | Area / Resources | Notes |
|---|---|---|---|---|
| **ULX3S-85F (ECP5 FPGA)** | 1-Core 2K BRAM (4-stage pipeline) | **132.49 MHz** | 1,464 LUT4, 546 FF, 2 DP16KD | Timing-driven FPGA ceiling (`nextpnr-ecp5`) |
| **ULX3S-85F (ECP5 FPGA)** | 1-Core + I/D Cache + 32 MB SDRAM | **114.89 MHz** | 2,268 LUT4, 1,198 FF, 4 DP16KD | Live HW verified at **96 MHz** (`0` errors) |
| **ULX3S-85F (ECP5 FPGA)** | 4-Core MR4OS + SDRAM + Lean Ring + SPI + 4× Math | **104.74 MHz** | 14,617 LUT4 (17%), 5,318 FF, 4 DSP, 77 DP16KD | Built for 72 MHz (+32.7 MHz slack); Verilator 4-core FAT32 boot PASS |
| **ULX3S-85F (ECP5 FPGA)** | 4-Core (`4×2K`) + Lean Ring + SDRAM | **104.00 MHz** | 9,270 LUT4, 4,428 FF, 16 DP16KD | Passes 96 MHz timing cleanly |
| **OpenROAD — Nangate45 (45 nm)** | 1-Core `mr4_asic_top` (1024w flop RAM + Boot ROM + UART) | **309.0 MHz** | `0.139 mm²` stdcell (`0.349 mm²` die), `18.0 mW` @ 100 MHz | `6_final.gds` (64 MB), LEC PASS, `0` errors, `+6.76 ns` slack @ 100 MHz target |
| **OpenROAD — Nangate45 (45 nm)** | Hierarchical 4-Tile `mr4_quad_top` (4× hardened `mr4_tile`) | **180.8 MHz** tile / **262.8 MHz** top ring | `3.09 mm²` die (4× `0.377 mm²` macros, `2` top FFs) | `6_final.gds` (83 MB), `0` warnings/errors — **flat $F_{\max}$ scaling** across core counts |
| **OpenROAD — ASAP7 (7 nm)** | 1-Core `mr4_asic_top` (1024w flop RAM + Boot ROM + UART) | **1,001.3 MHz (1.001 GHz)** | `0.00784 mm²` stdcell (`0.0235 mm²` die), `15.7 mW` @ 500 MHz | `0` errors, `+1,001 ps` slack @ 500 MHz target (`6.0 µW` leakage) |

*Note: The OpenROAD runs above used conservative clock targets (100 MHz on 45 nm, 500 MHz on 7 nm) and a standalone 1024×16 flip-flop RAM (~94% of die area) with zero foundry SRAM macros. With compiled foundry SRAM macros and tightened clock targets, the current 4-stage RTL projects to ~700–900 MHz on 45 nm and ~2+ GHz on 7 nm (with 1 GHz @ 45 nm / 3 GHz @ 7 nm reachable via a 5–6 stage EX/branch split and 2-cycle pipelined SRAM).*

## How LLMs Are Used in This Project.
The project makes use of LLM's in a Spec -> Revise -> Generate -> Test loop.  Normally for specific features or goals.  Each step is reviewed by a human, as is the output.

In addition human hands have revised code and documents directly and created original code.

Decisions and the direction of development are always made by a human, all research and references are always checked.

Multiple LLMs have been used:
- Google Gemini
- Antropic Claude
- Microsoft Copilot
# MiniRISC4 Architecture Baseline, Current Status, Roadmap & LLM Technical Guide

---

## 0. Priority 1 (CRITICAL): Hardware UART TX Bring-Up on ULX3S-85F
- [ ] **Diagnose and Fix Zero-Byte Output on `make ulx3s-term`:**
  - **Symptom:** `make ulx3s-bit && make ulx3s-prog` synthesizes and programs the ECP5-85k successfully. `openFPGALoader` finishes at 100%, `pll.locked` (`led[7]`) lights up, and typing keys in `make ulx3s-term` causes `debug_pc` / `led[6:0]` to flicker (confirming `ftdi_txd` input and execution response). However, `ulx3s_term.py` receives 0 bytes from `ftdi_rxd` (no monitor banner, no echo).
  - [ ] **Verify `PUTC` / `0x000F` Write Strobe Execution:**
    - [ ] Trace `_reset_vector` (`0x0100`) -> `_main` (`0x0200`) -> `msg_banner` `puts` loop in `mr4src/asm/monitor.asm`.
    - [ ] Confirm whether `PUTC` (`LD R0, 15`, polling `(R0)` for `0`, then `LD (R0), reg`) gets stuck in the polling wait loop (`._PUTC_WAIT_%`) or if `txBusyLatch` / `txd_ready` polarity prevents `ready` from reading as `0` (idle).
  - [ ] **Verify `UartTx` Strobe & Shift Logic in Hardware:**
    - [ ] Inspect generated SystemVerilog `build/ulx3s/ulx3s_top_rohd.sv` to ensure `cpu.txStrobe` pulse reaches `uart.txd_strobe` and `uart_tx.data_strobe`.
    - [ ] Verify `ftdi_rxd` pin assignment (`L4` on ULX3S) and ensure pin direction / pullup settings in `ulx3s_v20.lpf` do not conflict with FTDI chip pin mapping.
  - [ ] **Validate 3 Mbaud UART Transmission on Host:**
    - [ ] Confirm `DivideByN_0` counter limit (`32'hf` = 16 clocks per bit at 48 MHz) matches exact `3,000,000` baud.
    - [ ] Test serial reception with an external logic analyzer / oscilloscope or raw serial utility to isolate hardware `ftdi_rxd` output from host driver speed configuration.

---

## 1. LLM Technical Guide & Architecture Quick Reference

### Core Architecture Summary
* **Word Size:** 16-bit word-addressed memory and registers (`r0`, `r1`, `r2`, `r3`, plus shadow registers `shadowR`).
* **Instruction Staging:** Multi-cycle FSM executing two 8-bit instruction slots (`slotByte0`, `slotByte1`) per 16-bit word fetch (`_stReset` -> `_stFetch` -> `_stFetchWait` -> `_stMemWait2` -> `_stFetchLatch` -> `_stExec`).
* **Vector Table:** Direct Stride Vector Table starting at `0x0100` (`config.trapTableBase`). Stride = 16 words (32 bytes) per vector slot. Hardware jump dispatch calculates `PC <- 0x0100 + (vector << 4)`. Reset trap is at `0x0100`.
* **Execution Start:** Reset vector jumps to `_main` at `0x0200` in `monitor.asm`.

### Peripheral & MMIO Address Map
| Word Address | Symbol | Description / Function |
| :--- | :--- | :--- |
| `0x0004` | `RSP` | Hardware Register Stack Pointer |
| `0x0005` | `ASP` | Hardware Auxiliary Stack Pointer |
| `0x000D` | `CPUID` | Local Core ID Register (returns `0` for Core 0) |
| `0x000E` | `UART_RX` | UART RX Data (Read) / RX Status |
| `0x000F` | `UART_TX` | UART TX Data (Write) / TX Status (Read `0` = Ready, `1` = Busy) |
| `0x0010` | `UART_STAT`| Alternative UART Status Register |
| `0x0020`–`0x0029` | `NOC_NI` | NoC Network Interface Registers (Control, Status, TX/RX Data) |
| `0x002A` | `NOC_INFO` | Hardware NoC Topology Discovery (`numCores` [7:0], `numChannels` [15:8]) |
| `0x0100` | `TRAP_BASE`| Trap Table Base (Reset Vector = 0x0100) |
| `0x0200` | `MAIN_ENTRY`| Standard Application / Monitor Entry Point |

### Clocking & Baud Rate Math
* **FPGA Clock Source:** 25 MHz onboard crystal (`clk_25mhz`).
* **PLL Module:** `Ecp5Pll25To24` generates a **48 MHz** system clock (`clk48mhz`) via ECP5 `EHXPLLM` primitive (`CLKOS` / 480 MHz VCO).
* **UART Baud Rate:** Target is **3 Mbaud** (`3,000,000` baud).
* **UART Clock Divisor:** $48\,\text{MHz} / 3\,\text{Mbaud} = 16$. The `DivideByN` module counts 0 to 15 (`32'hf`), producing exact 3 Mbaud timing.

---

## 2. Tooling & Makefile Command Reference for LLMs

All hardware build, software assembly, testing, and programming tasks MUST be executed through the project `Makefile`.

```zsh
# 1. Build software applications & assembler targets (generates system_image.hex)
make apps

# 2. Run ROHD Dart hardware unit tests & simulation validation
make test-rohd

# 3. Synthesize SystemVerilog from Dart ROHD and run Yosys + nextpnr for ECP5-85k
make ulx3s-bit

# 4. Program bitstream directly to ULX3S SRAM over USB JTAG (via openFPGALoader)
make ulx3s-prog

# 5. Open high-speed interactive UART terminal (defaults to 3000000 baud)
make ulx3s-term ULX3S_PORT=/dev/tty.usbserial-D00050

# 6. Check nextpnr static timing analysis log
make ulx3s-timing
```

### Key Tooling Dependencies & File Locations
* **ROHD Hardware Definitions:** `hdl/rohd/lib/`
  * `cpu_core.dart`: MiniRISC4 CPU core FSM, execution unit, vector dispatch.
  * `ulx3s_top.dart`: Top-level ECP5 wrapper, PLL, clocking, peripheral mapping.
  * `uart.dart` / `tdp_bram.dart` / `noc_router.dart`: Hardware sub-modules.
* **Assembler & Toolchain:** `tools/`
  * `act4c.py`: ACT4 compiler generating MiniRISC4 assembly.
  * `mr4asm.py`: MiniRISC4 assembler producing memory hex images.
* **Assembly Sources:** `mr4src/asm/`
  * `monitor.asm`: System monitor application, vector table, banner, `puts`/`PUTC`.
* **Generated Hardware Verilog:** `build/ulx3s/ulx3s_top_rohd.sv`

---

## 3. Architecture Vision & Target Baseline

- [ ] **Scalable Multi-Core / Heterogeneous Architecture (`nocCores = 3..4` -> up to 255 Cores):**
  - Independent MiniRISC4 cores with localized `memWords` communicating over ring/mesh NoC.
- [ ] **Internal Memory & Caches (`memWords`):**
  - Local SRAM (`2048` words per worker core) backed by I-Cache/D-Cache and ULX3S SDRAM controller rather than monolithic 64k BRAM per core.
- [ ] **True Pipelined Execution & High Clock Speed (`>100 MHz`):**
  - Eliminate multi-cycle BRAM read mux bottlenecks to allow `nextpnr` to pass timing above 100 MHz.
- [ ] **Verified End-to-End I/O on Hardware:**
  - Robust 3 Mbaud bidirectional UART, cross-traps, and hardware debugging capabilities.

---

## 4. Current Implementation Status Checklist

### Fully Implemented & Working
- [x] Assembly & ACT4 toolchain (`make apps`).
- [x] ROHD Dart test suites passing (`make test-rohd`).
- [x] 48 MHz PLL clock generation (`Ecp5Pll25To24`) with 3 Mbaud UART divisor (`16`).
- [x] ACT4 array indexing fix (`LD R1, R0` instead of `LD R1, (R0)`).
- [x] FPGA synthesis (`Yosys`), P&R (`nextpnr-ecp5`), bitstream packing, and JTAG flashing (`openFPGALoader`).
- [x] RX path hardware activity (typing in terminal triggers `debug_pc` LED changes).

### In Progress / Pending Verification
- [ ] **Hardware UART TX output on `make ulx3s-term` (Priority 1).**
- [ ] Pipeline staging to eliminate wide BRAM mux critical path and raise $F_{\max}$ from 68.25 MHz to `>100 MHz`.
- [ ] Integration of I-Cache, D-Cache, and ULX3S SDRAM controller.
- [ ] Multi-word per-channel RX FIFOs with backpressure in `NocRouterNi` (`hdl/rohd/lib/noc_router.dart`).
- [ ] Multi-hop ring routing in `RegisteredNocHop` (`hdl/rohd/lib/noc_cache_wrapper.dart`).
- [ ] Multi-core top-level instantiation and cross-trap wiring in `Ulx3sTop` (`hdl/rohd/lib/ulx3s_top.dart`).
- [ ] Topology discovery register (`NOC_INFO` at `0x002A`).

---

## 5. Detailed Task Roadmap

### Priority 1: Hardware UART TX Bring-Up
- [ ] Verify `PUTC` macro execution and UART TX status register (`0x000F`) read polarity.
- [ ] Audit `txBusyLatch` and `txd_ready` signaling in `hdl/rohd/lib/ulx3s_top.dart`.
- [ ] Inspect generated `build/ulx3s/ulx3s_top_rohd.sv` for `serial_txd` signal connectivity.
- [ ] Confirm FTDI `ftdi_rxd` pin mapping (`L4`) in FPGA configuration.
- [ ] Validate character output on host terminal emulator at 3 Mbaud.

### Priority 2: Timing & Pipeline Bottlenecks (`>100 MHz`)
- [ ] Redesign `TdpBram` read staging to remove wide multi-BRAM output muxes from critical path.
- [ ] Separate instruction fetch pipeline from execution FSM states to achieve 1-cycle throughput per slot.
- [ ] Optimize nextpnr timing parameters to reach `>100 MHz` clock target on ECP5-85k.

### Priority 3: Hardware NoC MMIO Transport (`0x0020`–`0x002A`)
- [ ] Implement multi-word FIFO buffers in `NocRouterNi` with full/empty backpressure flags.
- [ ] Add multi-hop ring packet forwarding in `NocMulticoreCacheWrapper`.
- [ ] Implement `NOC_INFO` hardware register at `0x002A` for dynamic core discovery.
- [ ] Wire worker `CpuCore`s (`1..N`) and `mboxTrapReq` cross-traps in `Ulx3sTop`.

### Priority 4: I/D Cache & SDRAM Controller Integration
- [ ] Develop I-Cache and D-Cache controllers in ROHD.
- [ ] Interface cache controllers with external ULX3S SDRAM memory controller.
- [ ] Reduce local core BRAM size (`memWords = 2048`) while maintaining high-capacity backing storage.

### Priority 5: Full System Verification
- [ ] Run full software regression suite: `make apps`, `make test-rohd`, `make os-test`.
- [ ] Validate multi-core inter-processor communication (IPC) via cross-traps on hardware.
- [ ] Perform long-duration stress testing on ULX3S-85F board.
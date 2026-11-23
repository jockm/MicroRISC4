# MiniRISC4 Architecture Baseline, Current Status, and Roadmap

## 1. What We Need This Core & System to Be
* **Scalable Multi-Core / Heterogeneous Architecture (`nocCores = 3..4` now, scaling up toward `36` cores if fabric resources allow):** Independent MiniRISC4 cores (`nocCores = 3..4` is a current working target/step, not a hard architectural ceiling; scaling up as far as ECP5-85k / ULX3S-85F resources permit, potentially up to ~36 cores over time) with per-core `memWords` and `addrWidth` (`2048` vs. `65536` or smaller worker sizes), communicating via NoC / mailbox / FIFO / cross-trap mechanisms rather than one monolithic flat block.
* **Internal Memory & Caches (`memWords`):** Tightly sized local `memWords` (`2048` or smaller local SRAM for cache/worker cores) for local code, stacks, registers, and I/D cache structures, with I-Cache and D-Cache controllers/subsystems managing access to larger backing memory (such as ULX3S SDRAM) rather than packing `65536` words of flat `DP16KD` BRAM per core.
* **True Pipelined Execution & High Clock (`>100 MHz`):** Cleanly staged execution (avoiding unpipelined multi-BRAM mux bottlenecks and multi-cycle FSM stalls) so the ECP5-85k design meets timing above `100 MHz` while keeping clock, PLL, `3 Mbaud` (`divisor: 16`), and timing constraints in lockstep.
* **Working End-to-End I/O on ULX3S-85F:** Clean assembly/ACT4 builds (`make apps`), passing ROHD tests (`make test-rohd`), and working UART TX/RX on `make ulx3s-term` at `3000000` baud.

## 2. Where We Actually Are Right Now
* **What IS in place:**
  * ASM and ACT4 compilation (`make apps`) and the 21 ROHD tests (`make test-rohd`) pass.
  * `Ecp5Pll25To24` (`hdl/rohd/lib/ecp5_pll.dart`) and `Ulx3sTop` (`hdl/rohd/lib/ulx3s_top.dart`) are aligned for `48 MHz` (`480 MHz` VCO / `CLKOS`) with UART `divisor: 16` (`3 Mbaud`) and `ULX3S_CLOCK_MHZ=48`.
  * `tools/act4c.py` has the `is_array_expr` fix (`LD R1, R0` for arrays instead of `LD R1, (R0)`).
  * Typing in `make ulx3s-term` flickers LEDs (`debug_pc`), showing RX and core execution activity.
* **What is NOT in place (do not claim these are done):**
  * `CpuCore` is **not** a true multi-stage pipeline—it is a multi-cycle state machine over two 8-bit slots (`slotByte0` / `slotByte1`) with `_stFetch` / `_stFetchWait` / `_stMemWait2` / `_stFetchLatch` / `_stExec` / `_stMemWait` / `_stMemRd` and Slot-0 prefetch.
  * There is **no** active hardware I-Cache / D-Cache + ULX3S SDRAM controller wired into the active `Ulx3sTop` build.
  * `memWords` currently sizes each core's internal `TdpBram` directly (`65536` words = `128/208` `DP16KD` blocks in `nextpnr.log`, where a long BRAM read/mux path currently limits `Fmax` to `68.25 MHz`).
  * Visible UART TX output in `make ulx3s-term` at `3000000` baud is still not confirmed working end-to-end.
  * **NoC RX FIFO & Backpressure (`hdl/rohd/lib/noc_router.dart`):** `NocRouterNi` currently stores only a single 16-bit data word per channel (`rxDataQ[i]`) even though `rxCntQ[i]` counts up to `fifoDepth`, so back-to-back words overwrite unread data and there is no RX-full backpressure to senders.
  * **NoC Multi-Hop Forwarding (`hdl/rohd/lib/noc_cache_wrapper.dart`):** `RegisteredNocHop` only delivers when `hopInDc[c] == c` and drops packets destined for cores 2+ hops away instead of forwarding/arbitrating them around the ring.
  * **Multi-Core Top-Level NoC & Trap Wiring (`hdl/rohd/lib/ulx3s_top.dart`):** Only Core 0's NoC MMIO bus (`0x0020`–`0x0029`) is connected to node 0; worker `CpuCore`s (`1..N`) are not yet instantiated/attached to NoC nodes `1..N`, nor is `mboxTrapReq` wired to external Trap 1 (syscall) / Trap 14 (kill/reset) inputs.

## 3. What Steps Remain & The Plan to Get There
1. **Finish UART TX Bring-Up on Hardware (`3 Mbaud`):** Verify why `ftdi_rxd` produces no visible text in `make ulx3s-term` even though `debug_pc` responds to `ftdi_txd`, and confirm clean character output from the board.
2. **Fix Timing & Pipeline/Memory Bottlenecks for `>100 MHz`:** Eliminate the long multi-BRAM read/mux critical path and introduce real pipeline staging / banking so `nextpnr` clears `>100 MHz` with `nocCores=3..4` (and scales cleanly toward higher core counts) and `memWords=2048` or `65536`.
3. **Complete Hardware NoC MMIO Transport (`0x0020`–`0x0029`):** Implement true multi-word per-channel RX FIFOs with backpressure in `NocRouterNi`, add multi-hop ring/crossbar forwarding in `NocMulticoreCacheWrapper`, and wire worker `CpuCore`s (`1..N`) + `mboxTrapReq` cross-traps in `Ulx3sTop` so the OS/worker stack can move off the simulator `0x000A`/`0x000B`/`0x000C` shim onto real hardware NoC transport (2–255 cores).
4. **Wire I/D Caches & SDRAM Backing:** Build and integrate the I-Cache, D-Cache, and ULX3S SDRAM controller (`memWords` for local/cache/registers + SDRAM backing for larger memory), keeping `Makefile` targets, PLL/baud settings (`48 MHz` / `divisor: 16` / `3 Mbaud`), and constraints locked together.
5. **Verify Full Multi-Core + Timing + Board Run:** Re-run `make apps`, `make test-rohd`, `make os-test`, `make ulx3s-bit`, `make ulx3s-timing` (`>100 MHz`), `make ulx3s-prog`, and `make ulx3s-term` with real verified output—no skipping steps or claiming unverified changes.

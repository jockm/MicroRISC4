# MicroRISC4 Track C.1: CPI & Critical-Path Profiling Baseline

> **Date:** 2026-11-24 · **Hardware Baseline:** Track A.2 (`b427dce`, 4-Core SDRAM @ `96 MHz` / `100.79 MHz` $F_{\max}$)
> **Profiler Tool:** `python3 tools/mr4sim.py <bin> --profile [--max-steps N]` (`ExecutionProfiler` in `tools/mr4sim.py`)

---

## 1. Executive Summary

Before refactoring `CpuCore` into a 4-stage in-order pipeline (`IF → ID/RF → EX → WB` in Track C.3), Track C.1 quantified **both** the dynamic software CPI bottlenecks across real MicroRISC4 workloads and the physical critical paths in Yosys/ECP5 synthesis:

1. **Software CPI (`1.61 – 2.13` today → `1.15 – 1.40` pipelined):**
   - **#1 single cycle sink (`12.5% – 22.0%` of all cycles):** `PUSH8` (`20% – 47%` of dynamic slots!) pays a `+1` cycle `_stFetchLatch` bubble on every single 8-bit immediate push (4 cycles per 16-bit constant/address). Eliminating `PUSH8` bubbles alone cuts cycles by **13–22%**!
   - **#2 cycle sink (`12.2% – 16.8%`):** Loads (`PEEK` + `POP`) currently stall **3 cycles** (`4` cycles/load) unconditionally — even though `38% – 95%` of loads are not consumed on the immediate next slot (except tight assembly copy loops).
   - **#3 cycle sink (`10.3% – 14.8%`):** Taken branches, `JMP`, `LINK`, and `TRAP` pay 3 flush/refill cycles (`4` cycles total).
   - **ACT4 Compiler insight:** Compiled ACT4 code (`os_main.bin`) executes **`29% – 34%` `XCHG`** instructions (shadow-register spills/swaps) and **`20% – 23%` `PUSH8`**, confirming that single-cycle `XCHG` + zero-bubble `PUSH8` are essential in Track C.3.
2. **Hardware Critical Path (`35` 2-input ASIC gates / `9` ECP5 LUT4 levels = `9.92 ns`):**
   - **ECP5 #1 path (`9.92 ns`, `100.79 MHz`):** `dec_rl_q/dec_imm4_q` → 4:1 regfile mux → `regL == 0` 16-bit zero-comparator (`JMP.Z`) → `_advanceFromExec`/`_branchTo` next-state decode → `inst_reg`/`dec_*_q` `.CE` (`2.79 ns` logic + `7.13 ns` routing).
   - **ASIC #1 path (`35` generic 2-input gates via `yosys ltp`):** `dec_rl_q[1]` → 4:1 regfile mux (4 levels) → 16-bit ripple/LCU adder `arithRes` (27 levels) → `port_b_addr[14]` mux (3 levels).
   - Splitting `ID/RF` (regfile read), `EX` (parallel-prefix 16-bit ALU + branch eval), and `WB` (forwarding + regfile write) drops ASIC depth from **`35` → `<= 12` gate levels** (GHz-ready on 24 nm!) and ECP5 depth from **`9` → `4–5` LUT levels** (`>130–150 MHz`).
3. **Combined Projected Wall-Clock Speedup (Track C.3):**
   - **ECP5 ULX3S-85F:** `1.25× – 1.52×` IPC × `~1.35×` higher $F_{\max}$ ≈ **`1.7× – 2.0×` faster wall-clock execution**.
   - **24 nm ASIC (1-cycle SRAM):** `1.39× – 1.72×` IPC × `~2.5× – 3.0×` higher $F_{\max}$ (`>1.5 GHz`).

---

## 2. Dynamic Workload CPI & Pipeline Projections (`mr4sim.py --profile`)

All cycle counts reflect the exact hardware `CpuCore` local-BRAM FSM (`ALU/Move/Store/NT-Branch = 1`, `PUSH8 = 2`, `Load = 4`, `Taken Branch/JMP/LINK/TRAP = 4`):

| Workload | Dynamic Slots | Current `CpuCore` CPI | Load Stalls | Branch Flushes | `PUSH8` Bubbles | NOP Slots | Load-Use (`d=1`) | Proj. 4-Stage (2-cyc BRAM) | Proj. 4-Stage (1-cyc SRAM) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **`monitor.bin`** *(boot + `c`/`e`/`d`)* | `80,000` | **`1.989`** | `15.0%` | `14.8%` | `20.0%` | `9.7%` | `4.8%` | **`1.307`** (`1.52×`) | **`1.201`** (`1.66×`) |
| **`stress_hw_master.bin`** *(4-core soak)* | `150,000` | **`1.853`** | `14.3%` | `11.3%` | `20.4%` | `6.1%` | `62.4%` | **`1.369`** (`1.35×`) | **`1.195`** (`1.55×`) |
| **`stress_hw_worker.bin`** *(4-core soak)* | `150,000` | **`2.125`** | `16.8%` | `14.2%` | `22.0%` | `5.5%` | `30.3%` | **`1.399`** (`1.52×`) | **`1.237`** (`1.72×`) |
| **`os_main.bin`** *(FAT32 mount + boot)* | `208,996` | **`1.634`** | `13.5%` | `11.1%` | `14.2%` | `4.4%` | `50.7%` | **`1.305`** (`1.25×`) | **`1.158`** (`1.41×`) |
| **`os_main.bin`** *(FAT32 `ls`)* | `735,075` | **`1.632`** | `14.8%` | `10.6%` | `13.3%` | `3.7%` | `51.3%` | **`1.311`** (`1.25×`) | **`1.157`** (`1.41×`) |
| **`os_main.bin`** *(load + spawn `! mul`)* | `2,000,002` | **`1.606`** | `15.0%` | `10.3%` | `12.5%` | `3.6%` | `52.9%` | **`1.308`** (`1.23×`) | **`1.152`** (`1.39×`) |
| **`MUL.PRG`** *(Worker 1 ACT4 init → `MuL>`)* | `3,180,140` | **`1.739`** | `12.2%` | `10.7%` | `19.6%` | `6.8%` | `61.5%` | **`1.296`** (`1.34×`) | **`1.167`** (`1.49×`) |

---

## 3. Dynamic Instruction Mix (%)

| Workload | `PUSH8` | `XCHG` | `Move/LDI4` | `ALU` | `Shift/Rot/Inc/Dec` | `Load` (`PEEK+POP`) | `Store` (`POKE+PUSH`) | `CF Taken` (`Br+JMP+LINK+TRAP`) | `Br Not-Taken` | `NOP` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **`monitor.bin`** | `39.7%` | `6.0%` | `1.6%` | `1.4%` | `1.9%` | `9.9%` | `0.9%` | `9.8%` | `9.4%` | `19.3%` |
| **`stress_hw_master`** | `37.8%` | `11.0%` | `3.0%` | `2.6%` | `8.2%` | `8.8%` | `6.6%` | `7.0%` | `3.5%` | `11.4%` |
| **`stress_hw_worker`** | `46.7%` | `4.9%` | `1.2%` | `1.7%` | `4.8%` | `11.9%` | `5.1%` | `10.0%` | `1.8%` | `11.8%` |
| **`os_main` (boot)** | `23.2%` | `29.0%` | `8.9%` | `4.3%` | `5.1%` | `7.4%` | `7.0%` | `6.1%` | `2.0%` | `7.2%` |
| **`os_main` (`ls`)** | `21.7%` | `32.1%` | `9.8%` | `4.7%` | `3.8%` | `8.0%` | `6.7%` | `5.8%` | `1.3%` | `6.1%` |
| **`MUL.PRG` (Core 1)** | `34.1%` | `8.2%` | `5.2%` | `2.7%` | `12.4%` | `7.1%` | `9.3%` | `6.2%` | `3.1%` | `11.8%` |

---

## 4. Hardware Critical-Path & Logic-Depth Breakdown (`CpuCore`)

### 4.1 ECP5-85F Physical Timing (`nextpnr-ecp5`, 4-Core SDRAM @ `96 MHz`)
- **Achieved $F_{\max}$:** **`100.79 MHz`** (`9.92 ns` = **`2.79 ns` logic** [`28%`] + **`7.13 ns` routing** [`72%`])
- **#1 Critical Path (Control/Branch → Fetch CE):**
  `cpu_core.dec_imm4_q` (0.52 ns) → 4:1 regfile mux (`regL`, 3.12 ns) → 16-bit zero compare (`regL == 0`, 5.55 ns) → `_advanceFromExec` / `icache.resp_valid` control (8.17 ns) → `inst_reg` / `dec_*_q` `.CE` (**`9.92 ns`**, **9 LUT/PFUMX levels**).
- **#2 Critical Path (ALU Carry Chain → Regfile Writeback, 1-Core `105.39 MHz` / 4-Core `101.78 MHz`):**
  `dec_op_q` / `pc` → 16-bit `CCU2C` carry chain (`arithRes` / `pcPlus1`) → writeback mux → `r0..r3` `.M`/`.CE` (**`9.49 – 9.82 ns`**).

### 4.2 Generic ASIC 2-Input Gate Depth (`yosys abc -g AND,OR,XOR,MUX; ltp -noff`, `TdpBram` blackboxed)
- **Longest Topological Path:** **`35` 2-input gate levels**
  - Levels `1–4`: `dec_rl_q[1]` → 4:1 register-file read mux (`regL`)
  - Levels `5–32`: `addBInv` + 16-bit ripple/LCU adder (`arithSum17`)
  - Levels `33–35`: `port_b_addr[14]` next-address mux → `port_b_addr[14]` FF
- **Track C.3 Pipeline Budget (`IF → ID/RF → EX → WB`):**
  - **`IF`:** `PC + 1` / next-PC mux + SRAM/BRAM address launch (`<= 6` gates)
  - **`ID/RF`:** slot decode + 4:1 register file read + hazard/forward control (`<= 6` gates)
  - **`EX`:** parallel-prefix 16-bit ALU (`<= 10` gates) + branch compare (`<= 6` gates) + `EX→EX` forward mux (`<= 2` gates) → **`<= 12` gates total**
  - **`WB`:** `MEM`/ALU result mux + register-file write enable (`<= 5` gates)

---

## 5. Actionable Design Takeaways for Tracks C.2 & C.3

1. **Zero-bubble `PUSH8` in `IF/ID`:** A 1-word prefetch queue (`if_word_q` + `if_next_q`) eliminates the `+1` cycle `_stFetchLatch` stall on `PUSH8`, delivering an immediate **13–22% cycle reduction** across every single workload.
2. **Full `EX→EX` and `WB→EX` Forwarding + `XCHG` Forwarding:** Because ACT4 code is **`29%–34%` `XCHG`** and **`50%–62%` dist-1 load-use**, `XCHG` must execute cleanly in 1 cycle with forwarding (zero pipeline flush!) and loads must support 1-cycle load-use interlock (`1` bubble on 1-cyc SRAM, `2` bubbles on 2-cyc BRAM) instead of unconditionally stalling 3 cycles on every load.
3. **Separate `ID/RF` from `EX`:** Breaking `dec_rl_q → regfile mux → ALU / regL==0 → FSM CE` removes both the `35`-level ASIC adder path and the `9`-LUT ECP5 branch-to-CE path simultaneously.
4. **Track C.2 (`EPC` hardware trap link):** Adding a dedicated `EPC` register (so async Trap 14 never clobbers `R0`) must land **before** Track C.3 so the 4-stage pipeline's trap-flush logic writes `EPC` cleanly without contending on the `R0` writeback port.

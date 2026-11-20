# MiniRISC4 Processor Architecture & System Specification

---

## 1. Architectural Dimensions
- **Word Width**: 16 bits data, 16 bits address (64K words / 128 KB total).
- **Execution Units**: Non-pipelined multi-cycle FSM with dual-slot prefetching.
- **Instruction Slots**: Slot 0 in bits `[7:0]`, Slot 1 in bits `[15:8]`.
- **Registers**: 4 primary registers (`R0`–`R3`) and 4 hardware shadow registers (`shadow_r[0..3]`).
- **Memory**: Single True Dual-Port 64K RAM (Port A: Instruction Fetch, Port B: Data & MMIO).
- **Peripherals**: Hardware 3 Mbps 8-N-1 UART mapped to MMIO `0x000E` (RX) and `0x000F` (TX).

---

## 2. Complete Opcode Map

| Opcode [7:4] | Sub [3:2] | Mnemonic | Operands | Description |
| :---: | :---: | :--- | :--- | :--- |
| `0x0` | — | `LD` | `Rr, Rl` | Copy register `Rl` to `Rr` |
| `0x1` | — | `LD` | `R0, imm4` | Load 4-bit unsigned immediate into `R0` |
| `0x2` | — | `LD` | `Rr, (Rl)` | Memory peek: read `mem[Rl]` into `Rr` |
| `0x3` | — | `LD` | `(Rr), Rl` | Memory poke: write `Rl` into `mem[Rr]` |
| `0x4` | — | `LD` | `Rr, (Rl++)` | Pop: read `mem[Rl]` into `Rr`, increment `Rl` |
| `0x5` | — | `LD` | `(--Rr), Rl` | Push: decrement `Rr`, write `Rl` into `mem[Rr]` |
| `0x6` | — | `ADD` | `Rr, Rl` | `Rr = Rr + Rl` |
| `0x7` | — | `SUB` | `Rr, Rl` | `Rr = Rr - Rl` |
| `0x8` | — | `OR` | `Rr, Rl` | `Rr = Rr \| Rl` |
| `0x9` | — | `XOR` | `Rr, Rl` | `Rr = Rr ^ Rl` |
| `0xA` | — | `AND` | `Rr, Rl` | `Rr = Rr & Rl` (Native single-cycle AND) |
| `0xB` | `0` | `SHIFT.L` | `Rr` | Logical shift left by 1 bit |
| `0xB` | `1` | `SHIFT.R` | `Rr` | Logical shift right by 1 bit |
| `0xB` | `2` | `SHIFT.AR` | `Rr` | Arithmetic shift right by 1 bit |
| `0xB` | `3` | `XCHG` | `Rr` | Exchange `Rr` with hardware shadow register `shadow_r[Rr]` |
| `0xC` | `0` | `ROT.L` | `Rr` | Rotate left by 1 bit |
| `0xC` | `1` | `ROT.R` | `Rr` | Rotate right by 1 bit |
| `0xC` | `2` | `INC` | `Rr` | Increment `Rr` by 1 |
| `0xC` | `3` | `DEC` | `Rr` | Decrement `Rr` by 1 |
| `0xD` | — | `JMP.Z` | `Rr, Rl` | Branch to `Rr` if `Rl == 0` |
| `0xE` | — | `JMP.M` | `Rr, Rl` | Branch to `Rr` if `Rl[15] == 1` |
| `0xF` | `0` | `JMP` | `Rr` | Unconditional branch to `Rr` |
| `0xF` | `1` | `LINK` | `Rr, R0` | Save the return address in `R0`, then branch to `Rr` |
| `0xF` | `2` | `PUSH8` | `Rr, imm8` | Shift `Rr` left by 8 bits and insert `imm8` |
| `0xF` | `3` | `TRAP` | `Rr, byte8` | Software trap using `Rr` and `byte8` |

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

| Opcode [7:4] | Mnemonic | Operands | Description |
| :---: | :--- | :--- | :--- |
| `0x0` | `LD` | `Rr, Rl` | Copy register `Rl` to `Rr` |
| `0x1` | `LD` | `R0, imm4` | Load 4-bit unsigned immediate into `R0` |
| `0x2` | `LD` | `Rr, (Rl)` | Memory peek: read `mem[Rl]` into `Rr` |
| `0x3` | `LD` | `(Rr), Rl` | Memory poke: write `Rl` into `mem[Rr]` |
| `0x4` | `LD` | `Rr, (Rl++)` | Pop: read `mem[Rl]` into `Rr`, increment `Rl` |
| `0x5` | `LD` | `(--Rr), Rl` | Push: decrement `Rr`, write `Rl` into `mem[Rr]` |
| `0x6` | `ADD` | `Rr, Rl` | `Rr = Rr + Rl` |
| `0x7` | `SUB` | `Rr, Rl` | `Rr = Rr - Rl` |
| `0x8` | `OR` | `Rr, Rl` | `Rr = Rr \| Rl` |
| `0x9` | `XOR` | `Rr, Rl` | `Rr = Rr ^ Rl` |
| `0xA` | `AND` | `Rr, Rl` | `Rr = Rr & Rl` (Native single-cycle AND) |
| `0xB` | `SHIFT` / `XCHG` | sub, `Rr` | Sub 0: `SHIFT.L`, Sub 1: `SHIFT.R`, Sub 2: `SHIFT.AR`, Sub 3: `XCHG Rr` |
| `0xC` | `ROT` / `STEP` | sub, `Rr` | Sub 0: `ROT.L`, Sub 1: `ROT.R`, Sub 2: `INC Rr`, Sub 3: `DEC Rr` |
| `0xD` | `JMP.Z` | `Rr, Rl` | Branch to `Rr` if `Rl == 0` |
| `0xE` | `JMP.M` | `Rr, Rl` | Branch to `Rr` if `Rl[15] == 1` |
| `0xF` | `SPECIAL` | sub, `Rr` | Sub 0: `JMP Rr`, Sub 1: `LINK Rr, R0`, Sub 2: `PUSH8 Rr, imm8`, Sub 3: `TRAP Rr, byte8` |

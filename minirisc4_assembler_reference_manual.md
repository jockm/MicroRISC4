# MiniRISC4 Macro Assembler Reference Manual

---

## 1. Overview

`mr4asm.py` is a two-pass macro assembler for the MiniRISC4 16-bit word-addressed processor architecture. It handles macro expansion, file inclusion, dual-instruction packing, label resolution, and multiple output binary formats.

---

## 2. Dual-Instruction Slot Packing

MiniRISC4 packs two 8-bit instructions per 16-bit word:
- **Slot 0**: Bits `[7:0]` (executed first).
- **Slot 1**: Bits `[15:8]` (executed second).

### Word-Aligned Instructions:
The instructions `LINK`, `PUSH8`, and `TRAP` must be word-aligned (starting in Slot 0). If encountered when the assembler is in Slot 1, the assembler automatically emits a `NOP` into Slot 1 of the current word and advances to Slot 0 of the next word.

---

## 3. Directives

| Directive | Syntax | Description |
| :--- | :--- | :--- |
| `.org` | `.org <expr>` | Sets the current word address origin. |
| `.define` | `.define <NAME> <expr>` | Defines a symbolic constant. |
| `.word` | `.word <v1>, <v2>...` | Emits one or more 16-bit words. |
| `.byte` | `.byte <v1>, <v2>...` | Emits one or more 8-bit bytes into instruction slots. |
| `.asciz` | `.asciz "<string>"` | Emits null-terminated string packed into 16-bit words. |
| `.align` | `.align` | If currently in Slot 1, emits a `NOP` to align to Slot 0. |
| `.include` | `.include "<filename>"` | Recursively includes another source file. |
| `.macro` | `.macro <NAME> <params>` | Begins a macro definition. Parameters referenced as `%param`. |
| `.endmacro`| `.endmacro` | Ends a macro definition. |

---

## 4. Instruction Set Syntax

- **Registers**: `R0`, `R1`, `R2`, `R3`.
- **Register Copy**: `LD Rr, Rl`
- **Immediate Load**: `LD R0, imm4` ($0$ to $15$)
- **Memory Peek**: `LD Rr, (Rl)`
- **Memory Poke**: `LD (Rr), Rl`
- **Stack Pop**: `LD Rr, (Rl++)` (Post-increment load, Opcode `0x4`)
- **Stack Push**: `LD (--Rr), Rl` (Pre-decrement store, Opcode `0x5`)
- **ALU Operations**: `ADD Rr, Rl`, `SUB Rr, Rl`, `AND Rr, Rl`, `OR Rr, Rl`, `XOR Rr, Rl`
- **Shifts & Exchange**: `SHIFT.L Rr`, `SHIFT.R Rr`, `SHIFT.AR Rr`, `XCHG Rr`
- **Rotates & Step**: `ROT.L Rr`, `ROT.R Rr`, `INC Rr`, `DEC Rr`
- **Branches**: `JMP.Z Rr, Rl`, `JMP.M Rr, Rl`, `JMP Rr`
- **Link & Traps**: `LINK Rr, R0`, `PUSH8 Rr, byte8`, `TRAP Rr, byte8`

---

## 5. CLI Usage & Formats

```bash
python3 tools/mr4asm.py <inputs...> [-o <output>] [-l <listing.lst>] [-I <dir>] [format]
```

### Formats:
- `--bin`: Raw binary from address 0 up to highest defined address (default).
- `--fullbin`: Complete 64K-word (128 KB) raw binary file.
- `--sparsebin`: Raw binary starting at lowest `.org` up to highest defined address.
- `--hex`: 65,536-line Verilog `$readmemh` format.
- `-l, --listing`: Generates detailed assembly listing file (`.lst`).

# MicroRISC4 Macro Assembler Reference Manual

This document is the official reference manual for `mr4asm.py` (and `assembler.py`), the two-pass macro assembler for the 16-bit word-addressed MicroRISC4 processor architecture.

---

## 1. System & Architectural Overview

- **Word-Addressed Memory Space**: Memory consists of 64K 16-bit words (`0x0000` to `0xFFFF`, 128 KB total). All labels, offsets, origins (`.org`), and Program Counter increments evaluate strictly in **16-bit word addresses**, never byte offsets.
- **Dual-Instruction Packing**: Every 16-bit memory word holds two 8-bit instruction slots:
  - **Slot 0**: Low byte (bits `[7:0]`, executed first).
  - **Slot 1**: High byte (bits `[15:8]`, executed second).
- **Register Architecture**: Four 16-bit general-purpose registers: `R0`, `R1`, `R2`, `R3`.
  - Four hardware shadow registers (`shadow_r[0..3]`) toggled single-cycle via `XCHG Rr`.
- **Case Insensitivity**: Mnemonics, register names, assembler directives, macro definitions, parameter names, and symbol labels are completely case-insensitive.
- **Comments**: Single-line comments start with a semicolon (`;`) or `//` and extend to the end of the line.

---

## 2. Instruction Set & Syntax Reference

Where an instruction takes two operands, they are comma-separated (`<dest>, <src>`). Parentheses `(...)` strictly denote memory dereference.

### 2.1 Data Movement & Immediates
| Syntax | Bitform (Slot) | Description |
| :--- | :---: | :--- |
| `NOP` | `00000000` | Pseudo-instruction emitting `LD R0, R0` (1-byte canonical NOP). |
| `LD Rr, Rl` | `0000rrll` | Register copy: $Rr \leftarrow Rl$. |
| `LD R0, imm4` | `0001iiii` | 4-bit unsigned immediate ($0$–$15$) into scratch `R0`. |
| `LD Rr, (Rl)` | `0010rrll` | Memory load (Peek): $Rr \leftarrow \text{mem}[Rl]$. |
| `LD (Rr), Rl` | `0011rrll` | Memory store (Poke): $\text{mem}[Rr] \leftarrow Rl$. |
| `LD Rr, (Rl++)` | `0100rrll` | **Pop (Post-increment load)**: $Rr \leftarrow \text{mem}[Rl]$; $Rl \leftarrow Rl + 1$. |
| `LD (--Rr), Rl` | `0101rrll` | **Push (Pre-decrement store)**: $Rr \leftarrow Rr - 1$; $\text{mem}[Rr] \leftarrow Rl$. |
| `PUSH8 Rr, const8` | `111110rr` + *data8* | Shift $Rr$ left by 8 bits and insert byte constant: $Rr \leftarrow (Rr \ll 8) \mid \text{const8}$. **Word-aligned** (Slot 0 + Slot 1). |

### 2.2 ALU & Logic Operations
| Syntax | Bitform (Slot) | Description |
| :--- | :---: | :--- |
| `ADD Rr, Rl` | `0110rrll` | Addition: $Rr \leftarrow Rr + Rl$. |
| `SUB Rr, Rl` | `0111rrll` | Subtraction: $Rr \leftarrow Rr - Rl$. |
| `OR Rr, Rl` | `1000rrll` | Bitwise OR: $Rr \leftarrow Rr \mid Rl$. |
| `XOR Rr, Rl` | `1001rrll` | Bitwise XOR: $Rr \leftarrow Rr \oplus Rl$. |
| `AND Rr, Rl` | `1010rrll` | **Native Hardware AND**: $Rr \leftarrow Rr \ \& \ Rl$ (Opcode `0xA`). Standard 1-byte ALU instruction. |

### 2.3 Shifts, Rotates & Register Exchange
| Syntax | Bitform (Slot) | Description |
| :--- | :---: | :--- |
| `SHIFT.L Rr` | `101100rr` | Logical shift left by 1 bit: $Rr \leftarrow Rr \ll 1$. |
| `SHIFT.R Rr` | `101101rr` | Logical shift right by 1 bit: $Rr \leftarrow Rr \gg 1$. |
| `SHIFT.AR Rr` | `101110rr` | Arithmetic shift right by 1 bit (preserves sign bit `[15]`). |
| `ROT.L Rr` | `110000rr` | Rotate left by 1 bit through bit `[15]` to `[0]`. |
| `ROT.R Rr` | `110001rr` | Rotate right by 1 bit through bit `[0]` to `[15]`. |
| `INC Rr` | `110010rr` | Increment: $Rr \leftarrow Rr + 1$. |
| `DEC Rr` | `110011rr` | Decrement: $Rr \leftarrow Rr - 1$. |
| `XCHG Rr` | `101111rr` | **Shadow Register Exchange**: Exchanges $Rr$ with $shadow\_r[r]$ in 1 clock cycle. |

### 2.4 Control Flow & Exceptions
MicroRISC4 branches and jumps are strictly **register-indirect**. Branch targets cannot be bare labels; they must be loaded into a register prior to branching.

| Syntax | Bitform (Slot) | Description |
| :--- | :---: | :--- |
| `JMP.Z Rr, Rl` | `1101rrll` | Branch if Zero: if $Rl == 0$ then $PC \leftarrow Rr$. |
| `JMP.M Rr, Rl` | `1110rrll` | Branch if Negative: if $Rl[15] == 1$ then $PC \leftarrow Rr$. |
| `JMP Rr` | `111100rr` | Unconditional jump: $PC \leftarrow Rr$. |
| `LINK Rr, R0` | `111101rr` | Call Subroutine: $R0 \leftarrow PC + 1$; $PC \leftarrow Rr$. Must target $R0$. **Word-aligned** (occupies Slot 0; Slot 1 is auto-padded with `NOP`). |
| `TRAP Rr, val8` | `111111rr` + *val8* | Software trap: $R0 \leftarrow PC + 1$; $PC \leftarrow \text{TRAP\_BASE} + ((Rr \ \& \ 0xF) \ll 4)$. **Word-aligned** (Slot 0 + Slot 1 byte). The Slot 1 byte is emitted to occupy the word but ignored by the CPU. If omitted, it defaults to `0x00`. |

---

## 3. Slot Packing & Automatic Alignment Rules

1. **Word-Aligned Instructions**:
   - `PUSH8 Rr, const8`, `LINK Rr, R0`, and `TRAP Rr, val8` must start on a word boundary (**Slot 0**).
   - If one of these instructions is encountered while the assembler is in **Slot 1**, the assembler **automatically inserts a `NOP` (`0x00`) into Slot 1 of the preceding word** and places the aligned instruction at Slot 0 of the new word.
2. **Explicit Slot Alignment**:
   - `.align` explicitly emits a `NOP` (`0x00`) to force the assembler to Slot 0 of the next word if currently in Slot 1.

---

## 4. Assembler Directives

| Directive | Syntax | Description |
| :--- | :--- | :--- |
| `.org` | `.org <expr>` | Sets the active word address origin. |
| `.define` | `.define <NAME> <expr>` | Defines a symbolic constant. |
| `.word` | `.word <v1>, <v2>...` | Emits 16-bit word values at current word boundaries. Aligns to Slot 0 if in Slot 1. |
| `.byte` | `.byte <v1>, <v2>...` | Emits raw 8-bit bytes into sequential instruction slots. |
| `.asciz` | `.asciz "<string>"` | Emits a null-terminated ASCII string, packed 2 characters per 16-bit word (little-endian: 1st char in bits `[7:0]`, 2nd char in bits `[15:8]`). |
| `.align` | `.align` | Pads current word with a `NOP` if in Slot 1. |
| `.include` | `.include "<filename>"` | Inlines source or macro file recursively. |
| `.macro` | `.macro <NAME> <p1>, <p2>...` | Begins a multi-line macro block. Formal parameters are referenced inside using `%p1`. |
| `.endmacro` | `.endmacro` | Terminates a macro definition block. |
| `.ifdef` | `.ifdef <NAME>` | Assembles inner block if `<NAME>` is defined. |
| `.ifndef` | `.ifndef <NAME>` | Assembles inner block if `<NAME>` is NOT defined. |
| `.else` | `.else` | Alternative conditional branch. |
| `.endif` | `.endif` | Terminates conditional assembly block. |

### Macro Expansion & Unique Local Labels
- Macro parameters are substituted strictly at word boundaries (`%<param>\b`) to avoid mangling label names that contain substring matches.
- Local labels within macros can use `%` (e.g., `._WAIT_%:`, `JMP.Z R3, ._WAIT_%`). Each macro expansion substitutes `%` with a unique numeric tag (`_M1`, `_M2`, etc.) to prevent label collisions.

---

## 5. Built-in Symbols & Expressions

### 5.1 Pre-seeded Symbols
The assembler automatically defines standard system symbols in its symbol table:
* `TRAP_BASE`, `_TRAP_BASE`: Default `0x0100` (or set via `--trap-base`).
* `CPUID_ADDR`: `0x000D` (Hardware Core ID register).
* `FIFO_IN`: `0x000A` (reserved symbol; ordinary RAM in the current ROHD CPU).
* `FIFO_OUT`: `0x000B` (reserved symbol; ordinary RAM in the current ROHD CPU).
* `MAILBOX`: `0x000C` (ordinary RAM in the current ROHD CPU; writes are additionally observed by the two-core `CacheSubsystemTop` glue).
* `UART_RX`: `0x000E` (Serial receive port).
* `UART_TX`: `0x000F` (Serial transmit port).
* `RSP_INIT`: `0xFEFF` (Default Return Stack base).
* `ASP_INIT`: `0xFAFF` (Default Argument Stack base).

### 5.2 Operators & Immediate Byte Extraction
* Standard arithmetic: `+`, `-`, `*`, `/`, `&`, `|`, `^`.
* **Byte Extraction Operators**:
  * `>(expr)`: High byte extraction (`(expr >> 8) & 0xFF`).
  * `<(expr)`: Low byte extraction (`expr & 0xFF`).

Used by the `LOAD16` macro to synthesize 16-bit loads:
```assembly
.macro LOAD16 reg, value
    PUSH8   %reg, >(%value)
    PUSH8   %reg, <(%value)
.endmacro
```

---

## 6. Command-Line Interface (CLI)

```bash
python3 tools/mr4asm.py [options] <source_files...>
```

### Options & Flags
| Flag | Parameter | Description |
| :--- | :---: | :--- |
| `-o`, `--output` | `<file>` | Name of output binary, hex, or image file. |
| `-I`, `-i`, `--include-dir` | `<dir>` | Add directory to recursive include search path. Can be passed multiple times. |
| `-l`, `--listing` | `<file.lst>` | Generates a line-by-line listing with word addresses and hex bytes. |
| `--bin` | *(none)* | **Default Output Mode**. Emits contiguous binary from `0x0000` up to highest defined address. |
| `--fullbin` | *(none)* | Emits the complete 64K-word (131,072-byte / 128 KB) raw binary image (zero-padded). |
| `--sparsebin` | *(none)* | Emits compact binary spanning lowest `.org` address to highest defined address. |
| `--hex` | *(none)* | Emits 65,536 lines of 4-digit hex for Verilog `$readmemh` memory initialization. |
| `--trap-base` | `<addr>` | Overrides default vector base symbol `TRAP_BASE` (default: `0x0100`). |

## 7. Resident OS Assembler

The OS includes `ASM.PRG`, a two-pass assembler for use on the machine:

```text
! ASM.PRG <source.asm> <output.prg>
```

The output is a compact raw binary spanning the lowest through highest emitted
word address. It can be run as an OS program when the source is laid out for the
program load address (normally `.org 0x0400`). The assembler supports the
instructions, pseudo-instructions, directives, and expressions described
above, and recognizes and expands the fixed macro set in `lib/common.inc`.
`.include "common.inc"` is accepted as a declaration of those built-in macros.

The resident assembler does not implement general preprocessing: user-defined
`.macro` blocks, conditional assembly, and includes other than `common.inc`
are reported as errors. It also does not expand the polled UART `PUTC` and
`GETC` macros; MR4OS applications should use the console syscalls instead.
Source lines are limited to 127 bytes.

---

## 8. Assembly Listing Format (`.lst`)

When `-l <file.lst>` is passed, `mr4asm.py` produces an annotated listing:

```text
; =============================================================================
; MicroRISC4 Assembler Listing
; ADDR    SOURCE LINE                                ; [HEX]
; =============================================================================
0100    LOAD16 R1, 0x1234                          ; [F2 12 F2 34]
0102    LD R2, (R1++)                              ; [42]
0102    ADD R0, R2                                 ; [62]
0103    LINK R3, R0                                ; [F7 00]
0104    TRAP R1, 0x03                              ; [FF 03]
```
- Dual instructions sharing a single word address display their respective Slot 0 and Slot 1 encodings together under that address.
- Word-aligned instructions in Slot 0 that take a full word (like `LINK`) display their auto-padded `00` `NOP` in Slot 1.
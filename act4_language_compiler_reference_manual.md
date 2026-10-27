# ACT4 Systems Programming Language & Compiler Reference Manual

---

## 1. Language Overview

**ACT4** is a minimalist, high-performance systems programming language designed specifically for the MiniRISC4 16-bit word-addressed processor architecture. Modeled after Clinton Parker's *Action!* language for the 6502, ACT4 pairs a familiar C-style syntax with Action!'s design principles:
- **Word-Addressed Architecture**: Memory addresses correspond to 16-bit words (64K words total).
- **Strictly Unsigned 16-Bit Types**: The fundamental integer type is `u16` ($0$ to $65,535$), avoiding signed arithmetic complexity.
- **Action!-Style Static Variable Allocation**: Functions allocate local variables and parameters as fixed global memory cells in RAM rather than dynamic stack frames, resulting in fast execution without stack frame overhead.
- **Hardware Memory-Mapped I/O**: Direct binding of variables to hardware MMIO registers via the `@ <address>` syntax.
- **Packed Byte Manipulations**: High-performance extraction and insertion of 8-bit bytes within 16-bit words via `getbyte()` and `setbyte()`.
- **First-Class Subroutine Linkage**: Direct integration with MiniRISC4 hardware linkage (`LINK Rr, R0`) and Return Stack (`0x0004`).
- **Flexible Code Origin & Startup**: Command-line control over memory origin (`--org`) and optional suppression of the startup preamble (`--nopreamble`).

---

## 2. Types & Declarations

### 2.1 Primitive Types
- `u16`: Unsigned 16-bit integer ($0$ to $65,535$).
- `void`: Used exclusively to indicate no return value or an empty parameter list.

```c
u16 counter;
u16 *ptr;
u16 table[16];
```

### 2.2 Compile-Time Constants
Constants defined using `const` are evaluated at compile time and emitted as immediate literals or assembler definitions:
```c
const u16 UART_RX_ADDR = 0x000E;
const u16 BUFFER_SIZE  = 64;
```

### 2.3 Memory-Mapped Variables
Variables can be explicitly mapped to physical memory or MMIO registers using `@ <address>`:
```c
u16 uart_rx @ 0x000E; // UART receive register (bit 15 = valid flag)
u16 uart_tx @ 0x000F; // UART transmit register (0 = idle)
```
Reading or writing these variables generates direct memory loads/stores to the specified hardware address.

### 2.4 Structures (`type`)
Structures are declared using the `type` keyword. Struct members are allocated sequentially at 1-word offsets:
```c
type Point {
    u16 x;
    u16 y;
};

type Point pt;
type Point *pt_ptr;
```
Members are accessed using dot notation (`pt.x`) or pointer arrow notation (`pt_ptr->x`). Direct assignment between entire structures is prohibited.

### 2.5 Function Pointers
Function pointers are defined using the `func` signature:
```c
func(u16, u16) : u16 *callback;
```
Arguments to function pointers are transferred through global parameter registers `_act4_arg0` through `_act4_arg7`.

---

## 3. Byte Operations & Strings

Because MiniRISC4 is word-addressed, each 16-bit word stores two 8-bit bytes (low byte in bits `[7:0]`, high byte in bits `[15:8]`):
- `getbyte(base, index)`: Retrieves the 8-bit byte at byte index `index` from word array `base`.
- `setbyte(base, index, val)`: Stores byte `val` into the word array `base` at byte index `index`.

String literals (`"..."`) are emitted as `.asciz` packed strings in static memory.

---

## 4. Control Flow & Inline Assembly

ACT4 provides standard structured control flow:
- `if (cond) { ... } else { ... }`
- `while (cond) { ... }`
- `break;` and `continue;`
- `return [expr];`
- `asm { ... }`: Direct inline assembly blocks passed verbatim to the assembler.
- `trap(vector, data_byte)`: Emits hardware `TRAP` instruction.

---

## 5. Compiler CLI Reference (`act4c.py`)

```bash
python3 tools/act4c.py <input.a4> [options]
```

### Options:
- `-o, --output <file>`: Specify output assembly file path (`.asm`).
- `-I, --include-dir <dir>`: Add directory to search for `import` files.
- `--org <addr>`: Specify the code origin word address (default: `0x0100`).
- `--nopreamble`: Suppress emission of the `_start: START_PROGRAM` preamble and `_halt` loop.

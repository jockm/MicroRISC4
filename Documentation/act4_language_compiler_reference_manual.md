# ACT4 Systems Programming Language & Compiler Reference Manual

---

## 1. Language Overview

**ACT4** is a minimalist, high-performance systems programming language designed specifically for the 16-bit word-addressed MiniRISC4 processor architecture. Modeled after Clinton Parker's *Action!* language for the 8-bit 6502, ACT4 combines a clean C-family syntax with the raw execution speed, static variable allocation, and zero-overhead calling model of *Action!*.

### Architectural Fundamentals
- **Word-Addressed Architecture**: Memory addresses correspond strictly to 16-bit words (64K words total, `0x0000` to `0xFFFF`). All pointers, offsets, and Program Counter values increment in word units.
- **Strictly Unsigned Type System**: Only `u16` (unsigned 16-bit integer, $0$ to $65,535$) and `void` are supported.
- **Action!-Style Static Variable Allocation**: Functions allocate local variables and formal parameters as labeled static storage cells in RAM rather than dynamic stack frames, eliminating stack-frame setup and teardown overhead.
- **Hardware Memory-Mapped I/O**: Direct binding of variables to hardware MMIO registers via the `@ <address>` syntax.
- **Packed Byte Manipulations**: High-performance extraction and insertion of 8-bit bytes within 16-bit words via built-in `getbyte()` and `setbyte()` primitives.
- **Dual Stacks**: Direct integration with the hardware Link register (`LINK Rr, R0`), the software Return Stack (`RSP` at `0x0004`), and the Argument Stack (`ASP` at `0x0005`).
- **Direct Stride Vector Architecture**: Hardware vectors branch directly to `0x0100 + (N * 16)`. Compiled application functions, string literals, and static variables begin at `.org 0x0200`.

---

## 2. Types & Declarations

### 2.1 Primitive Types
- `u16`: Unsigned 16-bit integer ($0$ to $65,535$).
- `void`: Used exclusively to indicate no return value or an empty parameter list.

```c
u16 counter = 0;
u16 *ptr;
u16 table[16];
u16 buffer[] = {10, 20, 30, 40};
```
*Note: Variables must be declared strictly one per statement (comma-separated variable chains are not permitted).*

### 2.2 Compile-Time Constants
Constants defined using `const` are evaluated at compile time and emitted as symbolic `.define` directives into the assembly output:
```c
const u16 BUFFER_SIZE = 64;
const u16 UART_BASE   = 0x000E;
```

### 2.3 Memory-Mapped Variables (`@ <address>`)
Variables can be explicitly bound to physical memory or MMIO registers using `@ <address>`:
```c
u16 fifo_in   @ 0x000A; // Inter-core streaming FIFO (read-only pop)
u16 fifo_out  @ 0x000B; // Inter-core streaming FIFO (write-only push)
u16 mailbox   @ 0x000C; // Cross-core interrupt / trap trigger
u16 cpuid     @ 0x000D; // Hardware Core ID register (read-only)
u16 uart_rx   @ 0x000E; // UART receive register (bit 15 = valid flag)
u16 uart_tx   @ 0x000F; // UART transmit register (0 = idle)
```
Reading or writing these variables produces single-cycle direct loads and stores to the specified hardware address without pointer setup.

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
- Members are accessed using dot notation (`pt.x`) or pointer arrow notation (`pt_ptr->x`).
- Struct variables cannot be copied directly (e.g., `p1 = p2;` is prohibited). Structs should be passed or manipulated via pointers.

### 2.5 Function Pointers
Function pointers use an Action!-inspired syntax:
```c
func(<param_types>) : <return_type> *<variable_name>;
```

#### Example:
```c
func(u16, u16) : u16 *operation;
func(void) : void *target;

void test(void) {
    operation = &add;
    u16 result = operation(10, 20);

    target = 0x0300;
    target();
}
```
Arguments passed to function pointers are transferred through standardized global argument slots (`_act4_arg0` through `_act4_arg7`) to prevent stack overhead while enabling dynamic dispatch.

---

## 3. Memory Map & Execution Model

Compiled ACT4 binaries follow the unified MiniRISC4 memory architecture:

| Address Range | Size | Description |
| :---: | :---: | :--- |
| `0x0000` – `0x0003` | 4 words | Scratchpad RAM for register save/restore (`SAVEALL` / `LOADALL`). |
| `0x0004` | 1 word | **Return Stack Pointer (RSP)** (default: `0xFEFF`). |
| `0x0005` | 1 word | **Argument Stack Pointer (ASP)** (default: `0xFAFF`). |
| `0x0006` – `0x0009` | 4 words | General scratchpad workspace. |
| `0x000A` | 1 word | **FIFO_IN**: Inter-core inbound pop port. |
| `0x000B` | 1 word | **FIFO_OUT**: Inter-core outbound push port. |
| `0x000C` | 1 word | **MAILBOX**: Cross-core trap strobe register. |
| `0x000D` | 1 word | **CPUID**: Hardware Core ID register. |
| `0x000E` | 1 word | **UART_RX**: Bit 15 = valid; bits [7:0] = byte. |
| `0x000F` | 1 word | **UART_TX**: Read 0 = idle; write transmits byte. |
| `0x0100` – `0x01FF` | 256 words | **Direct Stride Vector Table** (16 slots $\times$ 16 words). |
| `0x0200` – `TOP` | Variable | **Program Space**: Compiled functions, static variables, heap, and stacks. |

### 3.1 Direct Stride Vector Table & Startup
- **Trap 0 (Reset Entry at `0x0100`)**: Emits `START_PROGRAM`, which initializes `RSP` (`0x0004` $\leftarrow$ `0xFEFF`) and `ASP` (`0x0005` $\leftarrow$ `0xFAFF`), then executes a register-indirect jump to `_main`.
- **Trap Handlers (`@ trap(N)`)**: Functions declared with `@ trap(N)` generate direct jump trampolines into vector slot $N$ (`0x0100 + N * 16`). Unused slots emit a fast single-cycle return (`JMP R0`).
- **Application Code Origin (`0x0200`)**: All compiled user code, helper functions, string literals, and static variables begin at `.org 0x0200` to prevent overlapping with vector slots 1–15 (`0x0110`–`0x01FF`).

---

## 4. Subroutines & Calling Conventions

### 4.1 Direct Function Calls
Functions are non-recursive by default. Formal parameters and local variables are allocated as labeled static `.word` memory cells:
```c
u16 add(u16 a, u16 b) {
    u16 temp = a + b;
    return temp;
}
```
The compiler allocates:
```assembly
_add_a:     .word 0
_add_b:     .word 0
_add_temp:  .word 0
```
When calling `add(10, 20)`:
1. The caller writes `10` to `_add_a` and `20` to `_add_b`.
2. The caller invokes `RCALL add` (`LOAD16 R0, _add; LINK R0, R0`).
3. The callee preserves the return address on the Return Stack via `RPUSH R0`.
4. The return value is placed into `R1`.
5. The callee exits via `RRET` (`RPOP R0; JMP R0`).

### 4.2 Hardware Trap Binding (`@ trap(N)`)
Functions can be bound directly to hardware interrupts or software traps:
```c
void on_serial_rx(void) @ trap(1) {
    u16 ch = uart_rx;
    if ((ch & 0x8000) != 0) {
        uart_tx = ch & 0x00FF; // Echo character
    }
}

void on_fault(void) @ trap(15) {
    uart_tx = '!';
    while (true) { }
}
```
- $N$ must evaluate to a compile-time constant ($0$–$15$).
- Functions bound to traps must take `(void)` and return `void`.
- The compiler automatically generates the trampoline at `.org 0x0100 + (N * 16)`:
```assembly
.org 0x0110
    LOAD16  R0, _on_serial_rx
    JMP     R0
```

---

## 5. Control Flow & Language Statements

### 5.1 Conditional Statements
Braces `{ ... }` and condition parentheses are strictly mandatory:
```c
if (status == 0) {
    do_reset();
} else if (status == 1) {
    do_step();
} else {
    do_fault();
}
```

### 5.2 Loops
ACT4 provides `while` loops. Loop control supports `break;` and `continue;`:
```c
while (count != 0) {
    if (fifo_in != 0) {
        break;
    }
    count--;
}
```

### 5.3 Inline Assembly (`asm { ... }`)
Assembly blocks are emitted verbatim into the generated assembly stream:
```c
void fast_swap(void) {
    asm {
        XCHG R1
        XCHG R2
    }
}
```

### 5.4 Traps & Software Exceptions
Hardware traps can be invoked directly from ACT4:
```c
trap(vector);
trap(vector, data_byte);
```
- `vector`: Can be an arbitrary runtime expression ($0$–$15$).
- `data_byte`: Optional 8-bit immediate payload constant ($0$–$255$).

---

## 6. Strings & Byte Operations

MiniRISC4 words hold two 8-bit bytes (little-endian: low byte in bits `[7:0]`, high byte in bits `[15:8]`).

- **String Literals**: String constants (`"Hello\r\n"`) are emitted into the data segment as packed `.asciz` sequences.
- **`getbyte(base, index)`**: Retrieves the 8-bit unsigned byte at byte index `index` from word array/pointer `base`.
- **`setbyte(base, index, val)`**: Stores the 8-bit byte `val` into word array/pointer `base` at byte index `index`.

```c
void print_str(u16 *str) {
    u16 i = 0;
    u16 ch = getbyte(str, i);
    while (ch != 0) {
        while (uart_tx != 0) { }
        uart_tx = ch;
        i++;
        ch = getbyte(str, i);
    }
}
```

---

## 7. Writing Efficient Code on MiniRISC4

Because MiniRISC4 is an ultra-minimalist architecture lacking a hardware division unit, hardware multiplier, and condition code flags, writing high-performance code in ACT4 requires understanding its low-level cost model.

### 7.1 Relational Comparisons Cost Model
MiniRISC4 branches strictly via `JMP.Z` (zero) and `JMP.M` (sign bit is 1). It does not have dedicated greater-than or less-than condition flags.

1. **Tests for Zero (`== 0` and `!= 0`) are Single Instructions**:
   Testing against zero requires no arithmetic. The compiler loads the operand and jumps directly:
   ```c
   // Optimal (1 cycle branch test)
   if (status == 0) { ... }
   if (count != 0) { ... }
   ```
2. **Equality Comparisons (`a == b` and `a != b`) are Inlined**:
   Comparing two values for equality inlines a single `SUB` and `JMP.Z`. No library subroutines are invoked:
   ```c
   // Inlined subtraction (2 cycles + branch)
   if (a == b) { ... }
   ```
3. **Relational Inequality (`<`, `<=`, `>`, `>=`) Incurs Subroutine Overhead**:
   Unsigned multi-bit comparisons require testing borrow and sign conditions. These operations invoke `_CMP_LT`, `_CMP_LE`, `_CMP_GT`, or `_CMP_GE` helper routines in `M4R_LIB.asm` across the Return Stack:
   ```c
   // Incurs RCALL / RRET and stack overhead (~15-25 cycles)
   if (a < b) { ... }
   ```
   *Efficiency Tip*: Prefer `while (count != 0)` down-counting loops over `for (i = 0; i < N; i++)` up-counting loops.

### 7.2 Arithmetic Operations Cost Model
| Operation | Implementation | Latency (Cycles) | Recommendation |
| :---: | :---: | :---: | :--- |
| `+`, `-` | Native ALU (`ADD`, `SUB`) | 1 cycle | Use freely. |
| `&`, `\|`, `^` | Native ALU (`AND`, `OR`, `XOR`) | 1 cycle | Use freely. |
| `~` | Macro (`XOR 0xFFFF`) | 2 cycles | Fast. |
| `<<`, `>>` (constant) | Unrolled `SHIFT.L`, `SHIFT.R` | $1$ cycle per bit | Fast for small shifts ($1$–$4$ bits). |
| `*` | Runtime routine `MULT` | 60–90 cycles | Dispatch via Argument Stack. Avoid in tight loops. |
| `/`, `%` | Restoring division `DIV` / `MOD` | 90–150 cycles | Dispatch via Argument Stack. Avoid in tight loops. |

#### Optimizing Multiplications and Divisions:
Replace multiplication and division by powers of two with bitwise shifts and masks:
```c
// SLOW: Invokes MULT (~75 cycles)
u16 word_offset = index * 8;

// FAST: Inlines 3 single-cycle SHIFT.L instructions (3 cycles)
u16 word_offset = index << 3;

// SLOW: Invokes MOD (~110 cycles)
u16 slot = hash % 16;

// FAST: Inlines single-cycle native AND (1 cycle)
u16 slot = hash & 15;
```

### 7.3 Pointer Walking vs. Array Indexing
In ACT4, array indexing (`table[i]`) recalculates the address (`base + i`) on every evaluation:
```c
// Slower: Recalculates buffer + i on every iteration
u16 i = 0;
while (i < 32) {
    buffer[i] = 0;
    i++;
}

// Faster: Walks memory using a pointer increment
u16 *ptr = buffer;
u16 count = 32;
while (count != 0) {
    *ptr = 0;
    ptr++;
    count--;
}
```

### 7.4 Down-Counting Loops
Because `DEC Rr` sets the ALU result directly and can be followed immediately by `JMP.Z`, down-counting loops compile to exceptionally tight machine code:
```c
// Optimal loop idiom in ACT4:
u16 n = 100;
while (n != 0) {
    // Loop body
    n--;
}
```

---

## 8. Compiler Command-Line Interface (`act4c.py`)

```bash
python3 tools/act4c.py [options] <input.a4>
```

### Options & Flags
| Flag | Parameter | Description |
| :--- | :---: | :--- |
| `-o`, `--output` | `<file.asm>` | Destination assembly output filename. Defaults to `<input>.asm`. |
| `-I`, `-i`, `--include` | `<dir>` | Add directory to recursive `import` search path. Can be specified multiple times. |
| `--org` | `<addr>` | Starting code origin for application code (default: `0x0200`). |
| `--nopreamble` | *(none)* | Suppresses emission of the vector dispatch table at `0x0100` and `START_PROGRAM`. |

### Build Pipeline Example
```bash
# 1. Compile ACT4 to MiniRISC4 Assembly
python3 tools/act4c.py -I lib mr4src/act4/monitor.a4 -o build/monitor.asm

# 2. Assemble to Verilog Hex Image and Listing
python3 tools/mr4asm.py lib/common.inc lib/M4R_LIB.asm build/monitor.asm --hex -o system_image.hex -l build/monitor.lst

# 3. Simulate and Test
python3 tools/mr4sim.py system_image.hex --trapbase 0x0100
```
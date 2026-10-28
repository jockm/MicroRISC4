# MiniRISC4 Memory Map & Software Conventions

This document specifies the official word-addressed memory map, register allocation, calling conventions, stack mechanics, and trap vector handling for the **MiniRISC4** processor.

---

## 1. Architectural Memory Map

MiniRISC4 features a unified 16-bit word-addressed address space (up to 64K words / 128 KB total) implemented as True Dual-Port Block RAM without write-protected ROM boundaries.

All addresses are **16-bit word addresses**. Each memory word packs two 8-bit instruction slots: Slot 0 in bits `[7:0]` and Slot 1 in bits `[15:8]`.

| Word Address Range | Size | Classification | Purpose & Description |
| :---: | :---: | :---: | :--- |
| **`0x0000` – `0x0003`** | 4 words | Scratchpad RAM | **Register Save/Restore Workspace**: Dedicated memory cells used by `SAVEALL` and `LOADALL` macros. |
| **`0x0004`** | 1 word | Pointer | **Return Stack Pointer (RSP)**: Holds the current top-of-stack address for subroutine call/return frames. |
| **`0x0005`** | 1 word | Pointer | **Argument Stack Pointer (ASP)**: Holds the current top-of-stack address for expression evaluation and parameter passing. |
| **`0x0006` – `0x0009`** | 4 words | Scratchpad RAM | **Compiler / General Workspace**: Dedicated temporary cells (`_act4_t0`–`_act4_t3`) for expression evaluation and fast scratches. |
| **`0x000A`** | 1 word | **MMIO / RAM** | **Inter-Core Inbound Stream FIFO (`FIFO_IN`)**: Reading pops incoming 16-bit payload from upstream core queue. Reverts to RAM if unused. |
| **`0x000B`** | 1 word | **MMIO / RAM** | **Inter-Core Outbound Stream FIFO (`FIFO_OUT`)**: Writing pushes 16-bit payload to downstream core queue. Reverts to RAM if unused. |
| **`0x000C`** | 1 word | **MMIO / RAM** | **Inter-Core Mailbox Trigger (`MAILBOX`)**: Writing `(target_core << 8) | trap_num` fires cross-core hardware strobe. Reverts to RAM if unused. |
| **`0x000D`** | 1 word | **MMIO / RAM** | **Hardware `CPUID` Register**: Read-only register returning `CORE_ID`. Reverts to standard read/write scratchpad RAM if CPUID is disabled. |
| **`0x000E`** | 1 word | **MMIO / RAM** | **UART RX Register**: Read: bit 15 = valid; bits `[7:0]` = data byte. Reading pops FIFO. Reverts to RAM if UART is disabled. |
| **`0x000F`** | 1 word | **MMIO / RAM** | **UART TX Register**: Read: 0 = idle, 1 = busy. Write: bits `[7:0]` transmitted via serial port. Reverts to RAM if UART is disabled. |
| **`0x0010` – `0x00FF`** | 240 words | Scratchpad RAM | **Kernel & System Scratchpad Workspace**: Static OS kernel variables, buffer pointers, descriptors, and I/O driver buffers. |
| **`0x0100` – `0x01FF`** | 256 words | **Direct Vectors** | **Hardware Direct Stride Vector Table**: 16 vectors spaced 16 words (32 bytes) apart. Reset / Trap 0 entry point is `0x0100`. |
| **`0x0200` – `TOP - 1280`** | Variable | RAM | **Application Code, Heap, & Static Data Space**: High-level application code, compiled functions, and heap data. |
| **`TOP - 1280` – `TOP - 256`** | 1,024 words | Stack Space | **Argument Stack (ASP)**: Full Descending stack (default initial base: `MEM_WORDS - 0x0501`). |
| **`TOP - 255` – `TOP`** | 256 words | Stack Space | **Return Stack (RSP)**: Full Descending stack (default initial base: `MEM_WORDS - 0x0101`). |

*Note: For a full 64K core (`MEM_WORDS = 65536`), `TOP = 0xFFFF`. Default initial `RSP = 0xFEFF` and `ASP = 0xFAFF`.*

---

## 2. Low-Memory Register Access Conventions

Addresses `0x0000` through `0x000F` can be loaded into `R0` using the single-byte immediate instruction `LD R0, imm4` (Opcode `0x1`). 

Consequently, any read or write to these low-memory control words takes **only two single-byte instructions packed into a single 16-bit word (2 clock cycles)**:

```assembly
; Read Hardware CPUID into R1 (1 word, 2 clock cycles):
    LD      R0, 13          ; Slot 0: R0 = 0x000D
    LD      R1, (R0)        ; Slot 1: R1 = PEEK16(0x000D)

; Pop 1 word from Inbound Stream FIFO into R2 (1 word, 2 clock cycles):
    LD      R0, 10          ; Slot 0: R0 = 0x000A
    LD      R2, (R0)        ; Slot 1: R2 = PEEK16(0x000A)
```

---

## 3. Direct Stride Vector Table (`0x0100` – `0x01FF`)

The processor uses **Direct Stride Vectoring** with a fixed stride of **16 words (32 bytes)** per vector slot.

When an exception or trap occurs, hardware does not read an address pointer from memory. Instead, it computes the target address combinationally in 0 wait cycles and immediately sets:

$$	ext{PC} \leftarrow 	ext{TRAP\_BASE} + (	ext{trap\_num} \ll 4)$$

```text
Address Range      Vector        Architectural Role
0x0100 - 0x010F    Trap 0        Reset / Cold Boot Entry Point
0x0110 - 0x011F    Trap 1        TRAP_MSG_READY (Inbound FIFO Data Ready)
0x0120 - 0x012F    Trap 2        TRAP_BURST_DONE (DMA / SDRAM Transfer Complete)
0x0130 - 0x013F    Trap 3        TRAP_CACHE_MISS (Cache Fill Request)
0x0140 - 0x014F    Trap 4        TRAP_TIMER_TICK (Timer / Scheduler Strobe)
...
0x01E0 - 0x01EF    Trap 14       TRAP_CORE_FAULT (Inter-Core Fault Strobe)
0x01F0 - 0x01FF    Trap 15       TRAP_ALIGN_FAULT (Slot 1 Word-Alignment Fault)
```

### Reset & Startup Constraint (`START_PROGRAM`)
On power-on or hardware reset, the core loads $	ext{PC} \leftarrow 	ext{0x0100}$ and begins execution in Trap 0's slot.

> **CRITICAL ARCHITECTURAL CONSTRAINT**:  
> Because Trap 0 occupies `0x0100`–`0x010F` (exactly 16 words / 32 bytes), **the `START_PROGRAM` initialization sequence MUST NOT exceed 16 words**. Any extended application initialization must be performed inside `_main` or after `0x0200`.

---

## 4. Stack Architecture & Conventions

MiniRISC4 utilizes a **dual-stack, Full Descending (FD)** model:
1. **Return Stack (RSP at `0x0004`)**: Dedicated solely to call/return return addresses (`LINK` and subroutine nesting).
2. **Argument Stack (ASP at `0x0005`)**: Dedicated to expression evaluation, parameter passing, and dynamic spills.

### Stack Operations
* **Push (Pre-decrement store)**: `LD (--Rr), Rl` (Opcode `0x5`)  
  Decrements pointer in `Rr` by 1, then stores `Rl` at `mem[Rr]`.
* **Pop (Post-increment load)**: `LD Rr, (Rl++)` (Opcode `0x4`)  
  Loads word from `mem[Rl]` into `Rr`, then increments pointer in `Rl` by 1.

---

## 5. Register Usage & Calling Conventions

| Register | Calling Role | Preserved by Callee? | Description |
| :---: | :--- | :---: | :--- |
| **`R0`** | Link / Scratch | No | Subroutine return link; immediate destination for `LD R0, imm4`; overwritten by `LINK` and `TRAP`. |
| **`R1`** | Accumulator / Return | No | Primary expression evaluation and function return value. |
| **`R2`** | Scratch / Argument 2 | No | Secondary operand, scratch pointer. |
| **`R3`** | Index / Frame Base | No | General pointer manipulation, memory index base. |
| **`shadow_r[0..3]`**| Shadow Bank | Yes (Context) | Hardware shadow registers exchanged in 1 cycle using `XCHG Rr`. |

### Subroutine Linkage via `LINK`
```assembly
; Call Subroutine at target_func:
    LOAD16  R3, target_func
    LINK    R3, R0          ; Overwrites R0 with PC + 1, branches to R3

; Inside target_func:
    ; (If non-leaf function, push R0 to RSP):
    PUSH_R  R0              ; Stores R0 on Return Stack via RSP (0x0004)
    ...
    POP_R   R0              ; Restores return address into R0
    JMP     R0              ; Subroutine return
```

### Fast Trap Handler Context Preservation
Handlers preserve and restore registers with zero stack spill latency using the hardware shadow bank:

```assembly
trap_handler:
    XCHG    R0              ; Preserve interrupted R0 (contains return address)
    XCHG    R1              ; Preserve interrupted R1
    
    ; ... Handler body ...
    
    XCHG    R1              ; Restore R1
    XCHG    R0              ; Restore R0
    JMP     R0              ; Return to interrupted thread
```

### 32-Bit Math & Barrel Shift Hardware Accelerator (0x0010–0x0016)

When `ENABLE_MATH_ACCEL` is enabled on a core, addresses `0x0010`–`0x0016` decode to a hardware coprocessor backed by FPGA DSP blocks (e.g., Lattice ECP5 18x18 MULT slices) and an iterative restoring divider:

| Address | Symbolic Identifier | Access | Description |
| :---: | :--- | :---: | :--- |
| `0x0010` | `MATH_A_LO` | W | Operand A Low Word (`A[15:0]`) |
| `0x0011` | `MATH_A_HI` | W | Operand A High Word (`A[31:16]`) |
| `0x0012` | `MATH_B_LO` | W | Operand B Low Word (`B[15:0]`) |
| `0x0013` | `MATH_B_HI` | W | Operand B High Word (`B[31:16]`) / Shift Amount (`B[4:0]`) |
| `0x0014` | `MATH_CMD_STAT` | R/W | **Write**: Opcode trigger (see table below)<br>**Read**: Status (`bit 0`: Busy, `bit 1`: Div-by-Zero) |
| `0x0015` | `MATH_RES_LO` | R | Result Low Word (`RES[15:0]`) |
| `0x0016` | `MATH_RES_HI` | R | Result High Word (`RES[31:16]`) |

#### Opcode Definitions (`MATH_CMD_STAT` @ `0x0014`)

| Opcode | Mnemonic | Operation | Description | Latency |
| :---: | :---: | :--- | :--- | :---: |
| `0x0` | `MUL` | $A \times B \pmod{2^{32}}$ | Lower 32 bits of product (Unsigned/Signed identical) | 1 cycle |
| `0x1` | `MULH` | $\lfloor (A_{\text{signed}} \times B_{\text{signed}}) / 2^{32} \rfloor$ | Upper 32 bits of signed product | 1 cycle |
| `0x2` | `MULHU` | $\lfloor (A_{\text{unsigned}} \times B_{\text{unsigned}}) / 2^{32} \rfloor$ | Upper 32 bits of unsigned product | 1 cycle |
| `0x3` | `MULHSU` | $\lfloor (A_{\text{signed}} \times B_{\text{unsigned}}) / 2^{32} \rfloor$ | Upper 32 bits of signed $\times$ unsigned | 1 cycle |
| `0x4` | `DIVU` | $\lfloor A_{\text{unsigned}} / B_{\text{unsigned}} \rfloor$ | 32-bit unsigned quotient | 32 cycles |
| `0x5` | `REMU` | $A_{\text{unsigned}} \pmod{B_{\text{unsigned}}}$ | 32-bit unsigned remainder | 32 cycles |
| `0x6` | `DIV` | $\lfloor A_{\text{signed}} / B_{\text{signed}} \rfloor$ | 32-bit signed quotient (handles two's-complement signs) | 34 cycles |
| `0x7` | `REM` | $A_{\text{signed}} \pmod{B_{\text{signed}}}$ | 32-bit signed remainder (sign matches dividend $A$) | 34 cycles |
| `0x8` | `SLL` | $A \ll (B \ \& \ \text{0x1F})$ | 32-bit Logical Shift Left by $0\dots31$ bits | 1 cycle |
| `0x9` | `SRL` | $A \gg (B \ \& \ \text{0x1F})$ | 32-bit Logical Shift Right by $0\dots31$ bits | 1 cycle |
| `0xA` | `SRA` | $A \ggg (B \ \& \ \text{0x1F})$ | 32-bit Arithmetic Shift Right by $0\dots31$ bits | 1 cycle |
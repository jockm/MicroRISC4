# MicroRISC4 Memory Map & Software Conventions

This document specifies the official word-addressed memory map, register allocation, calling conventions, stack mechanics, and trap vector handling for the **MicroRISC4** processor.

---

## 1. Architectural Memory Map

MicroRISC4 features a unified 16-bit word-addressed address space (up to 64K words / 128 KB total) implemented as True Dual-Port Block RAM without write-protected ROM boundaries.

All addresses are **16-bit word addresses**. Each memory word packs two 8-bit instruction slots: Slot 0 in bits `[7:0]` and Slot 1 in bits `[15:8]`.

| Word Address Range | Size | Classification | Purpose & Description |
| :---: | :---: | :---: | :--- |
| **`0x0000` – `0x0003`** | 4 words | Scratchpad RAM | **Register Save/Restore Workspace**: Dedicated memory cells used by `SAVEALL` and `LOADALL` macros. |
| **`0x0004`** | 1 word | Pointer | **Return Stack Pointer (RSP)**: Holds the current top-of-stack address for subroutine call/return frames. |
| **`0x0005`** | 1 word | Pointer | **Argument Stack Pointer (ASP)**: Holds the current top-of-stack address for expression evaluation and parameter passing. |
| **`0x0006` – `0x0009`** | 4 words | Scratchpad RAM | **Compiler / General Workspace**: Dedicated temporary cells (`_act4_t0`–`_act4_t3`) for expression evaluation and fast scratches. |
| **`0x000A`** | 1 word | Scratchpad RAM | Ordinary RAM in the current ROHD CPU; no inbound FIFO is implemented at this address. |
| **`0x000B`** | 1 word | Scratchpad RAM | Ordinary RAM in the current ROHD CPU; no outbound FIFO is implemented at this address. |
| **`0x000C`** | 1 word | **RAM / top-level glue** | Ordinary RAM in `CpuCore`. `CacheSubsystemTop` additionally observes writes here to signal traps between its two cores; this is not a generic CPU MMIO peripheral. |
| **`0x000D`** | 1 word | **MMIO / RAM** | **Hardware `CPUID` Register**: Read-only register returning `CORE_ID`. Reverts to standard read/write scratchpad RAM if CPUID is disabled. |
| **`0x000E`** | 1 word | **MMIO / RAM** | **UART RX Register**: Read: bit 15 = valid; bits `[7:0]` = data byte. Reading pops FIFO. Reverts to RAM if UART is disabled. |
| **`0x000F`** | 1 word | **MMIO / RAM** | **UART TX Register**: Read: 0 = idle, 1 = busy. Write: bits `[7:0]` transmitted via serial port. Reverts to RAM if UART is disabled. |
| **`0x0010` – `0x00FF`** | 240 words | RAM / optional MMIO | RAM except for optional Math MMIO at `0x0010`–`0x0016`, SPI MMIO at `0x0018`–`0x001A`, CPU Info constants at `0x001B`–`0x001D`, Hardware `EPC` at `0x001E`, and Lean Ring NoC MMIO at `0x0020`–`0x002A`. |
| **`0x001B`** | 1 word | **MMIO (RO)** | **`CPU_VER` (Architecture Version)**: Read-only hardware constant `{major[7:0], minor[7:0]}` (currently **`0x0001`** = v0.1). Writes are ignored. |
| **`0x001C`** | 1 word | **MMIO (RO)** | **`CPU_CAPS` (Capability Flags)**: Read-only 16-bit bitmask auto-derived from `CpuConfig`: `b0`=ShadowRegs (`XCHG`), `b1`=`CPUID`, `b2`=`UART`, `b3`=`MathAccel`, `b4`=`FPU`, `b5`=`SPI`, `b6`=`NoC`, `b7`=`CrossTraps`, `b8`=`EPC`/`ERET`, `b9`=`SdramCache`, `b10`=`Pipelined`, `b11..15`=reserved (`0`). Writes are ignored. |
| **`0x001D`** | 1 word | **MMIO (RO)** | **`CPU_CAPS2` (Expansion Capabilities)**: Read-only 16-bit expansion capability word reserved for future features (currently **`0x0000`**). Writes are ignored. |
| **`0x001E`** | 1 word | **MMIO / RAM** | **Hardware `EPC` (Exception Program Counter)**: Read/Write 16-bit trap return PC (active when `enableCrossTraps`/`enableEpc` is enabled). Automatically latched on asynchronous hardware Trap 14 **without clobbering `R0`** (and also latched on synchronous `TRAP` / Trap 15). Return atomically via 1-byte **`ERET`** (`0x0F`), which sets `PC ← EPC` while preserving all four `R0`–`R3`. |
| **`0x0020` – `0x002A`** | 11 words | Optional NoC MMIO | Direct-addressed Lean Ring NoC registers when `enableNoc` is enabled; otherwise ordinary RAM. Separate from the simulator-only `0x000A`/`0x000B` stream FIFOs. |
| **`0x0100` – `0x01FF`** | 256 words | **Direct Vectors** | **Hardware Direct Stride Vector Table**: 16 vectors spaced 16 words (32 bytes) apart. Reset / Trap 0 entry point is `0x0100`. |
| **`0x0200` – `TOP - 1280`** | Variable | RAM | **Application Code, Heap, & Static Data Space**: High-level application code, compiled functions, and heap data. |
| **`TOP - 1280` – `TOP - 256`** | 1,024 words | Stack Space | **Argument Stack (ASP)**: Full Descending stack (default initial base: `MEM_WORDS - 0x0501`). |
| **`TOP - 255` – `TOP`** | 256 words | Stack Space | **Return Stack (RSP)**: Full Descending stack (default initial base: `MEM_WORDS - 0x0101`). |

*Note: For a full 64K core (`MEM_WORDS = 65536`), `TOP = 0xFFFF`. Default initial `RSP = 0xFEFF` and `ASP = 0xFAFF`. When `enableSdramCache` is enabled with reduced local BRAM (e.g., `MEM_WORDS = 2048`), addresses `0x0000`–`0x07FF` hit local 2K BRAM directly while `0x0800`–`0xFFFF` transparently access the core's private 64K-word ULX3S SDRAM partition via hardware BRAM I-Cache and write-back D-Cache — keeping the full 64K-word software memory map unchanged.*

---

## 2. Low-Memory Register Access Conventions

Addresses `0x0000` through `0x000F` can be loaded into `R0` using the single-byte immediate instruction `LD R0, imm4` (Opcode `0x1`). 

The address can be loaded and used with two instruction slots packed into one 16-bit word. This does not imply a two-clock memory access: the CPU's synchronous RAM/MMIO read path adds wait and read-latch cycles.

```assembly
; Read Hardware CPUID into R1 (two instruction slots; the memory read adds cycles):
    LD      R0, 13          ; Slot 0: R0 = 0x000D
    LD      R1, (R0)        ; Slot 1: R1 = PEEK16(0x000D)
```

The Lean Ring NoC peripheral, when enabled, uses its MMIO range at `0x0020`–`0x002A` (direct-addressed via `NOC_DST_CORE` at `0x0021`, with a shared multi-word RX FIFO and priority Doorbell/MBOX); it is separate from the simulator-only `0x000A`/`0x000B` stream FIFOs.

---

## 3. Direct Stride Vector Table (`0x0100` – `0x01FF`)

The processor uses **Direct Stride Vectoring** with a fixed stride of **16 words (32 bytes)** per vector slot.

When a trap occurs, hardware does not read an address pointer from memory. It computes the direct-stride target combinationally; the subsequent instruction fetch still follows the normal synchronous memory path:

$$\text{PC} \leftarrow \text{TRAP\_BASE} + (\text{trap\_num} \ll 4)$$

```text
Address Range      Vector        Architectural Role
0x0100 - 0x010F    Trap 0        Reset / Cold Boot Entry Point
0x0110 - 0x011F    Trap 1        Suggested software convention (syscalls / messages)
0x0120 - 0x012F    Trap 2        Suggested software convention
0x0130 - 0x013F    Trap 3        Suggested software convention
0x0140 - 0x014F    Trap 4        Suggested software convention
...
0x01E0 - 0x01EF    Trap 14       NoC Doorbell/MBOX hardware trap (when enableNoc & enableCrossTraps)
0x01F0 - 0x01FF    Trap 15       TRAP_ALIGN_FAULT (Slot 1 Word-Alignment Fault)
```

Trap 0 is the reset entry, Trap 14 is triggered by an incoming NoC Doorbell/MBOX flit (`NOC_MBOX_SEND`) when `enableNoc` and `enableCrossTraps` are enabled, and Trap 15 is the hardware slot-1 alignment fault. Other vector meanings are software conventions.

### Reset & Startup Constraint (`START_PROGRAM`)
On power-on or hardware reset, the core loads $\text{PC} \leftarrow \text{0x0100}$ and begins execution in Trap 0's slot.

> **CRITICAL ARCHITECTURAL CONSTRAINT**:  
> Because Trap 0 occupies `0x0100`–`0x010F` (exactly 16 words / 32 bytes), **the `START_PROGRAM` initialization sequence MUST NOT exceed 16 words**. Any extended application initialization must be performed inside `_main` or after `0x0200`.

---

## 4. Stack Architecture & Conventions

MicroRISC4 utilizes a **dual-stack, Full Descending (FD)** model:
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
| `0x0` | `MUL` | $A \times B \pmod{2^{32}}$ | Lower 32 bits of product (Unsigned/Signed identical, 1× `MULT18X18D`) | 6 cycles |
| `0x1` | `MULH` | $\lfloor (A_{\text{signed}} \times B_{\text{signed}}) / 2^{32} \rfloor$ | Upper 32 bits of signed product (1× `MULT18X18D`) | 6 cycles |
| `0x2` | `MULHU` | $\lfloor (A_{\text{unsigned}} \times B_{\text{unsigned}}) / 2^{32} \rfloor$ | Upper 32 bits of unsigned product (1× `MULT18X18D`) | 6 cycles |
| `0x3` | `MULHSU` | $\lfloor (A_{\text{signed}} \times B_{\text{unsigned}}) / 2^{32} \rfloor$ | Upper 32 bits of signed $\times$ unsigned (1× `MULT18X18D`) | 6 cycles |
| `0x4` | `DIVU` | $\lfloor A_{\text{unsigned}} / B_{\text{unsigned}} \rfloor$ | 32-bit unsigned quotient (`B==0` → `0xFFFFFFFF`, `STAT[1]=1`) | 34 cycles |
| `0x5` | `REMU` | $A_{\text{unsigned}} \pmod{B_{\text{unsigned}}}$ | 32-bit unsigned remainder (`B==0` → `A`, `STAT[1]=1`) | 34 cycles |
| `0x6` | `DIV` | $\lfloor A_{\text{signed}} / B_{\text{signed}} \rfloor$ | 32-bit signed quotient (trunc toward 0; `-2^31/-1` → `-2^31`) | 34 cycles |
| `0x7` | `REM` | $A_{\text{signed}} \pmod{B_{\text{signed}}}$ | 32-bit signed remainder (sign matches dividend $A$) | 34 cycles |
| `0x8` | `SLL` | $A \ll (B \ \& \ \text{0x1F})$ | 32-bit Logical Shift Left by $0\dots31$ bits | 1 cycle |
| `0x9` | `SRL` | $A \gg (B \ \& \ \text{0x1F})$ | 32-bit Logical Shift Right by $0\dots31$ bits | 1 cycle |
| `0xA` | `SRA` | $A \ggg (B \ \& \ \text{0x1F})$ | 32-bit Arithmetic Shift Right by $0\dots31$ bits | 1 cycle |

---

### SPI Mode 0 Master Interface — microSD Slot (`0x0018`–`0x001A`)

When `enableSpi` is enabled on Core 0 (`ULX3S_ENABLE_SPI=1`, advertised via `CAP_SPI = 0x0020` in `CPU_CAPS`), addresses `0x0018`–`0x001A` drive the ULX3S-85F onboard microSD slot (`sd_clk`=`H2`, `sd_cmd`=`J1`, `sd_d0`=`J3`, `sd_d3`=`K2`) with clock dividers auto-scaled from `clkFreqMhz` (`<= 400 kHz` slow init clock, `<= 12 MHz` fast transfer clock):

| Address | Register | Access | Description |
| :---: | :--- | :---: | :--- |
| `0x0018` | `SPI_CTRL` | R/W | `[0]` `cs_n` (reset `1` = deselected), `[1]` `fast_clk` (`0` = 400 kHz, `1` = 12 MHz) |
| `0x0019` | `SPI_STAT` | R | `[0]` `busy` (`1` while 8-bit shift is in progress, `0` when idle) |
| `0x001A` | `SPI_DATA` | R/W | **Write**: starts full-duplex 8-bit SPI Mode 0 transfer (`wdata[7:0]`).<br>**Read**: last received byte (`rx[7:0]`). |

---

### Lean Ring NoC MMIO Interface (`0x0020`–`0x002A`)

When `enableNoc` is enabled (`ULX3S_NOC_CORES=N`), each core connects to a lossless elastic ring via a direct-addressed Network Interface (`NocRouterNi`) with one shared multi-word RX FIFO (`nocFifoDepth`, default 16 words), a 1-entry 1.0 word/cycle TX flit buffer, and a 1-entry priority Doorbell/MBOX register (firing hardware Trap 14):

| Address | Register | Access | Description |
| :---: | :--- | :---: | :--- |
| `0x0020` | `NOC_TX_DATA` | W | Send 16-bit data word to `NOC_DST_CORE` (requires `tx_ready=1` and valid `NOC_DST_CORE < numCores`). |
| `0x0021` | `NOC_DST_CORE` | R/W | Target core ID for subsequent `NOC_TX_DATA` / `NOC_MBOX_SEND` writes (defaults to own `coreId` on reset). |
| `0x0022` | `NOC_RX_DATA` | R | Pop oldest 16-bit word from shared RX FIFO (returns `0x0000` if empty). |
| `0x0023` | `NOC_STAT` | R | `[0]` `rx_not_empty`, `[1]` `rx_full`, `[2]` `tx_ready`, `[3]` `tx_empty`, `[4]` `mbox_valid`, `[7:5]` `0`, `[15:8]` `rx_count`. |
| `0x0024` | `NOC_RX_TRYR` | R | Non-blocking pop from shared RX FIFO (identical to `0x0022`; returns `0x0000` if empty). |
| `0x0025` | `NOC_MBOX_SEND` | W | Send 16-bit priority Doorbell/MBOX word to `NOC_DST_CORE`, asserting hardware **Trap 14** on the receiver. |
| `0x0026` | `NOC_MBOX_DATA` | R | Read and clear the pending incoming Doorbell/MBOX payload word (returns `0x0000` if empty). |
| `0x0027` | `NOC_MBOX_SRC` | R | Source core ID of the most recent incoming Doorbell/MBOX flit. |
| `0x0028`–`0x0029` | *(Reserved)* | R | Unused in the direct-addressed Lean Ring (former channel-table slots; reads `0x0000`). |
| `0x002A` | `NOC_INFO` | R | Hardware topology discovery: `{fifoDepth[7:0], numCores[7:0]}`. |

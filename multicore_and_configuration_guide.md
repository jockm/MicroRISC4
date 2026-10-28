# MiniRISC4 CPU Configuration & Multi-Core Subsystem Guide

This guide documents the parameterization, configuration architecture, and inter-core communication mechanisms for the **MiniRISC4** processor.

---

## 1. Architectural Philosophy: Decoupled Heterogeneous Multi-Core

Rather than relying on rigid microcode engines or hardwired Finite State Machines (FSMs) for complex peripherals and pipeline stages, the architecture stamps out the **same unified MiniRISC4 core engine** across multiple specialized blocks:

* **Dedicated Subsystem Controllers**:
  * **Memory / Bus Controller**: Manages SDRAM / HyperRAM burst queueing and refresh timing.
  * **Instruction Cache (I-Cache) Manager**: Manages line-fills, cache tags, and branch prediction tables.
  * **Data Cache (D-Cache) Manager**: Handles write-back/write-through policies and snooping.
  * **Decoupled Pipeline / Execution Stages**: Offloads parsing, decoding, or compute tasks.
* **Independent Programs & Address Spaces**: Each core executes its own specialized binary image (`sdram_ctl.bin`, `icache.bin`, `monitor.bin`, etc.) in its own private memory.
* **Hardware Reusability**: All cores share the same instruction set architecture (ISA), register model (`R0`–`R3` plus 4 shadow registers), and software conventions.

---

## 2. Hardware Configuration Parameters

Every core can be instantiated either as a **standalone single-core system** or as a **node in a multi-core topology**. To eliminate unused logic and minimize silicon area, all multi-core and peripheral features are fully optional and parameter-controlled.

### Configuration Parameters Summary

| Parameter / Field | Dart (`CpuConfig`) | Verilog Parameter | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Core Identifier** | `coreId` | `CORE_ID` | `0` | Unique integer ID assigned to this core instance. |
| **CPUID Register** | `enableCpuid` | `ENABLE_CPUID` | `1` (`true`) | When enabled, reading `0x000D` returns `CORE_ID`. When disabled, `0x000D` is ordinary scratchpad RAM. |
| **UART MMIO** | `enableUart` | `ENABLE_UART` | `1` (`true`) | When enabled, `0x000E`/`0x000F` map to the hardware UART transceiver. When disabled, they act as SRAM. |
| **Inter-Core Traps** | `enableCrossTraps` | `ENABLE_CROSS_TRAPS` | `0` (`false`) | Enables external interrupt/trap strobe inputs (`ext_trap_req`, `ext_trap_num`). |
| **Shadow Registers** | `enableShadowRegs` | `ENABLE_SHADOW_REGS` | `1` (`true`) | Enables 4 hardware shadow registers and single-cycle `XCHG`. |
| **Vector Table Base**| `trapTableBase` | `TRAP_TABLE_BASE` | `16'h0100` | Base address for Direct Stride Vector Table (default: `0x0100`). |
| **Memory Capacity** | `memWords` | `MEM_WORDS` | `65536` | Dedicated memory depth in 16-bit words (e.g., 512, 1024, 4096, 65536). |

---

### Hardware Sizing & Bus Truncation

Instantiating smaller memories (e.g., 1024 words for an I-Cache tag manager) automatically sizes the core's address buses:

$$\text{ADDR\_WIDTH} = \lceil\log_2(\text{MEM\_WORDS})\rceil$$

For example, a 1024-word memory requires only a 10-bit address bus (`[9:0]`), pruning unnecessary multiplexers, high-order address decoders, and FPGA routing resources.

---

## 3. Low-Memory Map (`0x0000` – `0x01FF`)

Low memory hosts the execution workspace, stack pointers, MMIO ports, streaming FIFOs, and the Direct Stride Vector Table:

| Word Address Range | Size | Classification | Purpose & Behavior |
| :---: | :---: | :---: | :--- |
| **`0x0000` – `0x0003`** | 4 words | Scratchpad RAM | Register save/restore workspace (`SAVEALL` / `LOADALL`). |
| **`0x0004`** | 1 word | Pointer | **Return Stack Pointer (RSP)** (default base: `MEM_WORDS - 0x0101`). |
| **`0x0005`** | 1 word | Pointer | **Argument Stack Pointer (ASP)** (default base: `MEM_WORDS - 0x0501`). |
| **`0x0006` – `0x0009`** | 4 words | Scratchpad RAM | General-purpose workspace cells (`_act4_t0`–`_act4_t3`). |
| **`0x000A`** | 1 word | **MMIO / RAM** | **Inter-Core Inbound Stream FIFO (`FIFO_IN`)**: Reading pops incoming 16-bit payload from upstream queue. Reverts to RAM if unused. |
| **`0x000B`** | 1 word | **MMIO / RAM** | **Inter-Core Outbound Stream FIFO (`FIFO_OUT`)**: Writing pushes 16-bit payload to downstream queue. Reverts to RAM if unused. |
| **`0x000C`** | 1 word | **MMIO / RAM** | **Inter-Core Mailbox Trigger (`MAILBOX`)**: Writing `(target_core << 8) | trap_num` fires cross-core hardware strobe. Reverts to RAM if unused. |
| **`0x000D`** | 1 word | **MMIO / RAM** | **Hardware `CPUID` Register**: Read-only register returning `CORE_ID`. If `ENABLE_CPUID=0`, functions as normal scratchpad RAM. |
| **`0x000E`** | 1 word | **MMIO / RAM** | **UART RX Register**: Reading returns serial data byte (bit 15 = valid flag). If `ENABLE_UART=0`, functions as normal RAM. |
| **`0x000F`** | 1 word | **MMIO / RAM** | **UART TX Register**: Writing transmits byte over serial pin. If `ENABLE_UART=0`, functions as normal RAM. |
| **`0x0010` – `0x00FF`** | 240 words | Scratchpad RAM | Low memory kernel workspace, buffer pointers, descriptors, and I/O driver buffers. |
| **`0x0100` – `0x01FF`** | 256 words | **Direct Vectors** | **Hardware Direct Stride Vector Table** (16 vectors × 16 words). Reset / Trap 0 entry point is `0x0100`. |

### Reading `CPUID` in Assembly

Because `0x000D` ($13$) is an immediate value $\le 15$, reading the CPU ID requires only two single-byte instructions packed into a single 16-bit word (taking 2 clock cycles):

```assembly
; Read hardware CPUID into R1 in 1 word (Opcode 0x1 LD R0, imm4):
    LD      R0, 13          ; Slot 0: R0 = 0x000D
    LD      R1, (R0)        ; Slot 1: R1 = PEEK16(0x000D) -> returns CORE_ID
```

Using the standard macro from `lib/common.inc`:

```assembly
    GET_CPUID R1            ; R1 now contains the hardware Core ID
```

---

## 4. Inter-Core Communication Architecture

MiniRISC4 multi-core systems employ a **hybrid decoupled signaling and streaming model**:

```
+-------------------------------------------------------------+
|                      Cross-Core Interconnect                |
|  +---------------------+           +---------------------+  |
|  | Inter-Core Mailbox  |           | Point-to-Point      |  |
|  | MMIO Register (0x0C)|           | Hardware FIFOs      |  |
|  +----------+----------+           +----------+----------+  |
+-------------|---------------------------------|-------------+
              | ext_trap_req / ext_trap_num     | Stream Data (0x000A/B)
              v                                 v
      +---------------+                 +---------------+
      |  Core A (IO)  |                 | Core B (Work) |
      |  ID = 0       |                 | ID = 1        |
      |  RAM: 64K     |                 | RAM: 2K       |
      +---------------+                 +---------------+
```

### 4.1 Private Semantic Trap Tables (No Range Slicing)

MiniRISC4 avoids partitioning the 16 hardware traps among cores (e.g., Core 0 getting 1–3, Core 1 getting 4–6). With only 14 general-purpose slots available, range splitting exhausts vectors quickly and breaks consistency.

Instead, **each core maintains its own independent 16-entry vector table at `0x0100`–`0x01FF`**. Vectors are assigned uniform **event semantics**:

| Vector | Symbolic Name | Meaning Across Cores |
| :---: | :---: | :--- |
| **Trap 0** | `TRAP_RESET` | Cold boot / initialization entry point (`0x0100`). |
| **Trap 1** | `TRAP_MSG_READY` | Upstream stage/core pushed a command into this core's inbound FIFO (`0x0110`). |
| **Trap 2** | `TRAP_BURST_DONE`| Memory controller finished a DMA or burst transfer (`0x0120`). |
| **Trap 3** | `TRAP_CACHE_MISS`| Pipeline or core signaling a cache miss to the memory manager (`0x0130`). |
| **Trap 4** | `TRAP_TIMER_TICK`| Local hardware timer or scheduler tick (`0x0140`). |
| **Trap 14**| `TRAP_CORE_FAULT`| Inter-core bus fault or neighbor error alert (`0x01E0`). |
| **Trap 15**| `TRAP_ALIGN_FAULT`| Hardware Slot 1 alignment violation or invalid instruction (`0x01F0`). |

### 4.2 Hardware Mailbox MMIO Trigger (`0x000C`)

When Core A needs to signal Core B:
1. Core A writes a 16-bit word to its local Mailbox register at `0x000C`:
   * **Bits `[15:8]`**: Destination `target_core_id`.
   * **Bits `[7:0]`**: Target `trap_vector_num` ($0$–$15$).
2. The interconnect routes the pulse to Core B:
   * Asserts `ext_trap_req = 1` for 1 clock cycle on Core B.
   * Presents `ext_trap_num = trap_vector_num` on Core B's trap port.
3. Core B completes its current instruction word, writes its return address ($PC + 1$) to `R0`, and branches combinationally to:

$$\text{Vector Target} = \text{TRAP\_TABLE\_BASE} + (\text{ext\_trap\_num} \ll 4)$$

### 4.3 Zero-Spill Context Switching via `XCHG`

Because MiniRISC4 includes 4 hardware shadow registers (`shadow_r[0..3]`), an inter-core trap handler can preserve and restore its registers in single cycles without memory overhead:

```assembly
; ==============================================================================
; Inter-Core Trap Handler (Trap 1: TRAP_MSG_READY at 0x0110)
; ==============================================================================
.org 0x0110
trap1_msg_handler:
    XCHG    R0              ; 1 cycle: preserve interrupted R0 (contains return address)
    XCHG    R1              ; 1 cycle: preserve interrupted R1

    ; Read command from inbox FIFO at 0x000A:
    LD      R0, 10          ; R0 = 0x000A
    LD      R1, (R0)        ; Read incoming command word

    ; ... Process message / update pointers ...

    XCHG    R1              ; 1 cycle: restore R1
    XCHG    R0              ; 1 cycle: restore R0
    JMP     R0              ; Return to interrupted execution
```

### 4.4 Point-to-Point Hardware Streaming FIFOs (`0x000A` / `0x000B`)

* **`0x000A` (`FIFO_IN`)**: Reading pops 16-bit data from the upstream queue.
* **`0x000B` (`FIFO_OUT`)**: Writing pushes 16-bit data to the downstream queue.

---

## 5. Software Conventions for Multi-Core Systems

### 5.1 Dynamic Stack Placement (`common.inc`)

When memory capacity (`MEM_WORDS`) varies, stacks are computed relative to the core's physical RAM limit:

```assembly
.ifndef MEM_WORDS
    .define MEM_WORDS   0x10000     ; Default 64K words
.endif

.define MEM_TOP         (MEM_WORDS - 1)
.define RSP_INIT        (MEM_WORDS - 0x0101)  ; Return stack in top 256 words
.define ASP_INIT        (MEM_WORDS - 0x0501)  ; Argument stack 1K below RSP
```

### 5.2 Direct Stride Startup Constraint (`START_PROGRAM`)

Because Trap 0 occupies `0x0100`–`0x010F` (16 words / 32 bytes), `START_PROGRAM` must remain $\le 16$ words:

```assembly
.macro START_PROGRAM
    LOAD16  R1, RSP_INIT    ; 2 words
    LD      R0, 4           ; 1 word
    LD      (R0), R1        ; 1 word
    LOAD16  R1, ASP_INIT    ; 2 words
    INC     R0              ; 1 word (R0 = 5)
    LD      (R0), R1        ; 1 word
    LOAD16  R0, _main       ; 2 words
    JMP     R0              ; 1 word
.endmacro                   ; Total: 11 words (<= 16 words limit)
```

### 5.3 Symmetric Bootstrapping

Cores sharing a single unified binary can differentiate their roles dynamically at startup:

```assembly
_start:
    GET_CPUID   R1          ; R1 = Core ID
    LD0         R2          ; R2 = 0 (Primary core ID)
    SUB         R1, R2      ; Compare R1 == 0
    LOAD16      R3, _worker_init
    JMP.NZ      R3, R1      ; If not Core 0, jump to worker initialization

_primary_init:
    ; Core 0: Initialize hardware, boot OS, and release worker cores
    ...
```

---

## 6. Implementation Examples

### 6.1 ROHD Core Instantiation (Dart)

```dart
import 'package:rohd/rohd.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';

// 1. Primary Core (Core 0: 64K RAM, UART enabled, Cross-Traps enabled)
final core0 = CpuCore(
  clk: clk,
  rstN: rstN,
  mmioRxData: uartRxData,
  mmioTxStatus: uartTxStatus,
  config: CpuConfig.multiCorePrimary(),
);

// 2. Worker Core (Core 1: 1K RAM, UART disabled, Cross-Traps enabled)
final core1 = CpuCore(
  clk: clk,
  rstN: rstN,
  extTrapReq: core1TrapReq,
  extTrapNum: core1TrapNum,
  config: CpuConfig.worker(coreId: 1, memWords: 1024),
);
```

### 6.2 Verilog Core Instantiation

```verilog
// Instantiate a 2K SDRAM controller worker core:
cpu_core #(
    .DATA_WIDTH        (16),
    .ADDR_WIDTH        (11),           // ceil(log2(2048)) = 11 bits
    .MEM_WORDS         (2048),
    .TRAP_TABLE_BASE   (16'h0100),     // Direct Stride Vector Table
    .CORE_ID           (2),
    .ENABLE_CPUID      (1),
    .ENABLE_UART       (0),            // Local UART disabled
    .ENABLE_CROSS_TRAPS(1)             // Inter-core interrupts enabled
) u_sdram_worker (
    .clk               (clk),
    .rst_n             (rst_n),
    .ext_trap_req      (sdram_trap_req),
    .ext_trap_num      (sdram_trap_num)
    // ...
);
```

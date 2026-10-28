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
| **UART MMIO** | `enableUart` | `ENABLE_UART` | `1` (`true`) | When enabled, `0x000E`/`0x000F` map to the hardware UART transceiver. When disabled, they act as SRAM or FIFO queues. |
| **Inter-Core Traps** | `enableCrossTraps` | `ENABLE_CROSS_TRAPS` | `0` (`false`) | Enables external interrupt/trap strobe inputs (`ext_trap_req`, `ext_trap_num`). |
| **Shadow Registers** | `enableShadowRegs` | `ENABLE_SHADOW_REGS` | `1` (`true`) | Enables 4 hardware shadow registers and single-cycle `XCHG`. |
| **Vector Table Base**| `trapTableBase` | `TRAP_TABLE_BASE` | `16'h0010` | Base address for the 16-word trap/vector table. |
| **Memory Capacity** | `memWords` | `MEM_WORDS` | `65536` | Dedicated memory depth in 16-bit words (e.g., 512, 1024, 4096, 65536). |

---

### Hardware Sizing & Bus Truncation

Instantiating smaller memories (e.g., 1024 words for an I-Cache tag manager) automatically sizes the core's address buses:

$$\text{ADDR\_WIDTH} = \lceil\log_2(\text{MEM\_WORDS})\rceil$$

For example, a 1024-word memory requires only a 10-bit address bus (`[9:0]`), pruning unnecessary multiplexers, high-order address decoders, and FPGA routing resources.

---

## 3. Low-Memory Map & The `0x000D` CPUID Register

Low memory (`0x0000`–`0x001F`) hosts the execution workspace, stack pointers, MMIO ports, and the exception vector table:

| Address Range | Size | Classification | Purpose & Behavior |
| :---: | :---: | :--- | :--- |
| `0x0000` – `0x0003` | 4 words | Scratchpad RAM | Register save/restore workspace (`SAVEALL` / `LOADALL`). |
| `0x0004` | 1 word | Pointer | **Return Stack Pointer (RSP)** (default base: `MEM_WORDS - 0x0101`). |
| `0x0005` | 1 word | Pointer | **Argument Stack Pointer (ASP)** (default base: `MEM_WORDS - 0x0501`). |
| `0x0006` – `0x000C` | 7 words | Scratchpad RAM | General-purpose workspace cells (`_act4_t0`–`_act4_t6`). |
| `0x000D` | 1 word | **MMIO / RAM** | **Hardware `CPUID` Register**: Read-only access returning `CORE_ID`. If `ENABLE_CPUID=0`, functions as normal scratchpad RAM. |
| `0x000E` | 1 word | **MMIO / FIFO / RAM** | **UART RX / Inbound Stream**: Reading returns serial data (or pops incoming inter-core FIFO). If `ENABLE_UART=0`, functions as normal RAM. |
| `0x000F` | 1 word | **MMIO / FIFO / RAM** | **UART TX / Outbound Stream**: Writing transmits byte (or pushes to inter-core FIFO). If `ENABLE_UART=0`, functions as normal RAM. |
| `0x0010` – `0x001F` | 16 words | **Hardware Vectors** | **Trap & Exception Vector Table** (Trap 0 at `0x0010` is Reset; Trap 15 at `0x001F` is Alignment Fault). |

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

```text
+-------------------------------------------------------------+
|                      Cross-Core Interconnect                |
|  +---------------------+           +---------------------+  |
|  | Inter-Core Mailbox  |           | Point-to-Point      |  |
|  | MMIO Register       |           | Hardware FIFOs      |  |
|  +----------+----------+           +----------+----------+  |
+-------------|---------------------------------|-------------+
              | ext_trap_req / ext_trap_num     | Stream Data (0x000E/F)
              v                                 v
      +---------------+                 +---------------+
      |  Core A (IO)  |                 | Core B (Work) |
      |  ID = 0       |                 | ID = 1        |
      |  RAM: 64K     |                 | RAM: 2K       |
      +---------------+                 +---------------+
```

### 4.1 Private Semantic Trap Tables (No Range Slicing)

MiniRISC4 avoids partitioning the 16 hardware traps among cores (e.g., Core 0 getting 1–3, Core 1 getting 4–6). With only 14 general-purpose slots available, range splitting exhausts vectors quickly and breaks consistency.

Instead, **each core maintains its own independent 16-entry vector table at `0x0010`–`0x001F`**. Vectors are assigned uniform **event semantics**:

| Vector | Symbolic Name | Meaning Across Cores |
| :---: | :---: | :--- |
| **Trap 0** | `TRAP_RESET` | Cold boot / initialization entry point. |
| **Trap 1** | `TRAP_MSG_READY` | Upstream stage/core pushed a command into this core's inbox FIFO. |
| **Trap 2** | `TRAP_BURST_DONE`| Memory controller finished a DMA or burst transfer. |
| **Trap 3** | `TRAP_CACHE_MISS`| Pipeline or core signaling a cache miss to the memory manager. |
| **Trap 4** | `TRAP_TIMER_TICK`| Local hardware timer or scheduler tick. |
| **Trap 14**| `TRAP_CORE_FAULT`| Inter-core bus fault or neighbor error alert. |
| **Trap 15**| `TRAP_ALIGN_FAULT`| Hardware Slot 1 alignment violation or invalid instruction. |

### 4.2 Hardware Mailbox MMIO Trigger

When Core A needs to signal Core B:
1. Core A writes a 16-bit word to an interconnect mailbox register:
   * **Bits `[15:8]`**: Destination `target_core_id`.
   * **Bits `[7:0]`**: Target `trap_vector_num` ($0$–$15$).
2. The interconnect routes the pulse to Core B:
   * Asserts `ext_trap_req = 1` for 1 clock cycle on Core B.
   * Presents `ext_trap_num = trap_vector_num` on Core B's trap port.
3. Core B completes its current instruction word, writes its return address ($PC + 1$) to `R0`, and branches to:

$$\text{Vector Target} = \text{mem}[\text{TRAP\_TABLE\_BASE} + \text{ext\_trap\_num}]$$

### 4.3 Zero-Spill Context Switching via `XCHG`

Because MiniRISC4 includes 4 hardware shadow registers (`shadow_r[0..3]`), an inter-core trap handler can swap its entire register context in 4 single-cycle instructions without memory overhead:

```assembly
; ==============================================================================
; Inter-Core Trap Handler (e.g., Trap 1: TRAP_MSG_READY)
; ==============================================================================
trap_msg_handler:
    XCHGALL                 ; 4 cycles: Swap R0-R3 with shadow registers
                            ; Active registers are now clean scratch space!

    ; Read command from inbox FIFO at 0x000E:
    LD      R0, 14          ; R0 = 0x000E
    LD      R1, (R0)        ; Read incoming command word

    ; ... Process message / update pointers ...

    XCHGALL                 ; 4 cycles: Restore interrupted thread's registers!
    JMP     R0              ; Return to interrupted execution (R0 preserved)
```

### 4.4 Point-to-Point Hardware Streaming FIFOs

For worker cores where `ENABLE_UART=0`, addresses `0x000E` and `0x000F` can be mapped to hardware FIFO stream ports:
* **`0x000E` (Inbox FIFO)**: Reading pops data from the upstream core's queue.
* **`0x000F` (Outbox FIFO)**: Writing pushes data to the downstream core's queue.

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

### 5.2 Symmetric Bootstrapping

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
    .TRAP_TABLE_BASE   (16'h0010),
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
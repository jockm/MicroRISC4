# MiniRISC4 CPU Configuration & Multi-Core Subsystem Guide

This guide documents the parameterization, configuration architecture, and inter-core communication mechanisms for the **MiniRISC4** processor.

---

## 1. Architectural Philosophy: Decoupled Heterogeneous Multi-Core

The design explores reusing the **same MiniRISC4 core engine** in specialized blocks. The repository contains core, NoC, SDRAM, and peripheral modules, but the current top-levels do not yet assemble them into the complete communicating worker-core pipeline described here: `Mr4RiscvTop` creates five unconnected cores, while `CacheSubsystemTop` connects two cores for a limited mailbox-trap and SDRAM-controller example.

* **Intended Subsystem Controller Roles**:
  * **Memory / Bus Controller**: A worker core could manage SDRAM / HyperRAM requests and refresh timing.
  * **Instruction Cache (I-Cache) Manager**: A worker core could manage line fills, cache tags, and branch prediction.
  * **Data Cache (D-Cache) Manager**: A worker core could handle write policies and snooping.
  * **Decoupled Pipeline / Execution Stages**: Separate cores could offload parsing, decoding, or compute tasks.
* **Independent Programs & Address Spaces**: Each `CpuCore` instance has private memory and can be initialized with its own image. The current top-level examples do not load and connect a complete set of stage-specific programs.
* **Hardware Reusability**: All cores share the same instruction set architecture (ISA), register model (`R0`–`R3` plus 4 shadow registers), and software conventions.

---

## 2. Hardware Configuration Parameters

`CpuCore` can be instantiated standalone or connected to external glue. CPUID, UART, cross-trap inputs, shadow registers, math, SPI, and NoC support are controlled by `CpuConfig`. Low-address FIFO and mailbox behavior is not a generic `CpuCore` feature: FIFOs at `0x000A`/`0x000B` are not implemented, and mailbox wiring at `0x000C` exists only in the two-core `CacheSubsystemTop` example.

### Configuration Parameters Summary

| Parameter / Field | Dart (`CpuConfig`) | Verilog Parameter | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Core Identifier** | `coreId` | `CORE_ID` | `0` | Unique integer ID assigned to this core instance. |
| **CPUID Register** | `enableCpuid` | `ENABLE_CPUID` | `1` (`true`) | When enabled, reading `0x000D` returns `CORE_ID`. When disabled, `0x000D` is ordinary scratchpad RAM. |
| **UART MMIO** | `enableUart` | `ENABLE_UART` | `1` (`true`) | When enabled, `0x000E`/`0x000F` map to the hardware UART transceiver. When disabled, they act as SRAM. |
| **Inter-Core Traps** | `enableCrossTraps` | `ENABLE_CROSS_TRAPS` | `0` (`false`) | Enables external trap inputs. A request is accepted only while the core is in its execute state; there is no pending-request latch. |
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

Low memory hosts the execution workspace, stack pointers, optional MMIO, RAM, and the Direct Stride Vector Table:

| Word Address Range | Size | Classification | Purpose & Behavior |
| :---: | :---: | :---: | :--- |
| **`0x0000` – `0x0003`** | 4 words | Scratchpad RAM | Register save/restore workspace (`SAVEALL` / `LOADALL`). |
| **`0x0004`** | 1 word | Pointer | **Return Stack Pointer (RSP)** (default base: `MEM_WORDS - 0x0101`). |
| **`0x0005`** | 1 word | Pointer | **Argument Stack Pointer (ASP)** (default base: `MEM_WORDS - 0x0501`). |
| **`0x0006` – `0x0009`** | 4 words | Scratchpad RAM | General-purpose workspace cells (`_act4_t0`–`_act4_t3`). |
| **`0x000A`** | 1 word | Scratchpad RAM | Ordinary RAM in `CpuCore`; no inbound FIFO is implemented here. |
| **`0x000B`** | 1 word | Scratchpad RAM | Ordinary RAM in `CpuCore`; no outbound FIFO is implemented here. |
| **`0x000C`** | 1 word | **RAM / top-level glue** | Ordinary RAM in `CpuCore`. `CacheSubsystemTop` also observes writes here to signal traps between its two cores; the write still reaches RAM. |
| **`0x000D`** | 1 word | **MMIO / RAM** | **Hardware `CPUID` Register**: Read-only register returning `CORE_ID`. If `ENABLE_CPUID=0`, functions as normal scratchpad RAM. |
| **`0x000E`** | 1 word | **MMIO / RAM** | **UART RX Register**: Reading returns serial data byte (bit 15 = valid flag). If `ENABLE_UART=0`, functions as normal RAM. |
| **`0x000F`** | 1 word | **MMIO / RAM** | **UART TX Register**: Writing transmits byte over serial pin. If `ENABLE_UART=0`, functions as normal RAM. |
| **`0x0010` – `0x00FF`** | 240 words | RAM / optional MMIO | RAM except for optional Math MMIO at `0x0010`–`0x0016`, SPI MMIO at `0x0018`–`0x001A`, and NoC MMIO at `0x0020`–`0x0029`. |
| **`0x0020` – `0x0029`** | 10 words | Optional NoC MMIO | NoC registers when `enableNoc` is enabled; otherwise ordinary RAM. These are not the `0x000A`/`0x000B` FIFOs. |
| **`0x0100` – `0x01FF`** | 256 words | **Direct Vectors** | **Hardware Direct Stride Vector Table** (16 vectors × 16 words). Reset / Trap 0 entry point is `0x0100`. |

### Reading `CPUID` in Assembly

Because `0x000D` ($13$) is an immediate value $\le 15$, the CPUID read fits in two single-byte instruction slots packed into one 16-bit word. The synchronous memory read path adds wait/read-latch cycles, so this is not a two-clock operation:

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

The intended system uses decoupled signaling and streaming. In the current ROHD implementation, `CpuCore` exposes optional external trap inputs, but does not implement low-address stream FIFOs. `CacheSubsystemTop` has fixed two-core mailbox glue; the NoC is a separate module, not a connected set of worker `CpuCore` instances.

### 4.1 Private Trap Tables and Suggested Vector Conventions

MiniRISC4 avoids partitioning the 16 hardware traps among cores (e.g., Core 0 getting 1–3, Core 1 getting 4–6). With only 14 general-purpose slots available, range splitting exhausts vectors quickly and breaks consistency.

Each core has its own vector address space at `0x0100`–`0x01FF`. The table below proposes uniform software meanings; except for reset (Trap 0) and the slot-alignment fault (Trap 15), these events are not generated automatically by the current core:

| Vector | Symbolic Name | Meaning Across Cores |
| :---: | :---: | :--- |
| **Trap 0** | `TRAP_RESET` | Cold boot / initialization entry point (`0x0100`). |
| **Trap 1** | `TRAP_MSG_READY` | Suggested convention for an inbound message (`0x0110`); no `0x000A` FIFO is implemented. |
| **Trap 2** | `TRAP_BURST_DONE`| Suggested convention for a completed transfer (`0x0120`). |
| **Trap 3** | `TRAP_CACHE_MISS`| Suggested convention for a cache-miss request (`0x0130`). |
| **Trap 4** | `TRAP_TIMER_TICK`| Suggested convention for a timer/scheduler event (`0x0140`). |
| **Trap 14**| `TRAP_CORE_FAULT`| Suggested convention for an inter-core fault (`0x01E0`). |
| **Trap 15**| `TRAP_ALIGN_FAULT`| Hardware fault when a word-aligned instruction appears in Slot 1 (`0x01F0`). |

### 4.2 Hardware Mailbox MMIO Trigger (`0x000C`)

In the current `CacheSubsystemTop` example, Core A can signal the other core by writing to `0x000C`:
1. The write data is interpreted as:
   * **Bits `[15:8]`**: Destination `target_core_id`.
   * **Bits `[3:0]`**: Target `trap_vector_num` ($0$–$15$); bits `[7:4]` are ignored.
2. The two-core glue routes a one-cycle pulse to the selected core:
   * Asserts `ext_trap_req = 1` for 1 clock cycle on Core B.
   * Presents `ext_trap_num = trap_vector_num` on Core B's trap port.
3. The pulse is accepted only if Core B is in its execute state on that cycle; otherwise it is lost. On acceptance, the core branches to:

$$\text{Vector Target} = \text{TRAP\_TABLE\_BASE} + (\text{ext\_trap\_num} \ll 4)$$

The interrupted return address saved in `R0` depends on the current slot: Slot 0 saves `PC` (so that instruction is retried after return), and Slot 1 saves `PC + 1`.

### 4.3 Zero-Spill Context Switching via `XCHG`

Because MiniRISC4 includes 4 hardware shadow registers (`shadow_r[0..3]`), a trap handler can preserve and restore its registers with `XCHG` without memory spills:

```assembly
; ==============================================================================
; Example external-trap handler at Trap 1 (0x0110)
; ==============================================================================
.org 0x0110
trap1_msg_handler:
    XCHG    R0              ; 1 cycle: preserve interrupted R0 (contains return address)
    XCHG    R1              ; 1 cycle: preserve interrupted R1

    ; ... Handle the event. The current CpuCore has no FIFO at 0x000A. ...

    XCHG    R1              ; 1 cycle: restore R1
    XCHG    R0              ; 1 cycle: restore R0
    JMP     R0              ; Return to interrupted execution
```

### 4.4 NoC Registers and FIFO Implementation Status

`0x000A` and `0x000B` are ordinary RAM in the current `CpuCore`; no point-to-point FIFOs are attached there. The optional NoC network interface uses MMIO addresses `0x0020`–`0x0029`. In `Ulx3sTop`, only the CPU's NoC MMIO bus is connected to node 0; the other network-interface nodes are not connected to additional CPU cores.

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

// 1. Primary Core (Core 0: 64K RAM, UART and Cross-Traps enabled)
final core0 = CpuCore(
  clk: clk,
  rstN: rstN,
  mmioRxData: uartRxData,
  mmioTxStatus: uartTxStatus,
  config: const CpuConfig(
    coreId: 0,
    memWords: 65536,
    enableUart: true,
    enableCrossTraps: true,
  ),
);

// 2. Worker Core (Core 1: 1K RAM, UART disabled, Cross-Traps enabled).
// External glue must route the trap signals; this alone does not connect the
// cores or provide an inter-core FIFO.
final core1 = CpuCore(
  clk: clk,
  rstN: rstN,
  extTrapReq: core1TrapReq,
  extTrapNum: core1TrapNum,
  config: const CpuConfig(
    coreId: 1,
    memWords: 1024,
    enableUart: false,
    enableCrossTraps: true,
  ),
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

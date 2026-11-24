# MicroRISC4 CPU Configuration & Multi-Core Subsystem Guide

This guide documents the parameterization, configuration architecture, and inter-core communication mechanisms for the **MicroRISC4** processor.

---

## 1. Architectural Philosophy: Decoupled Heterogeneous Multi-Core

The design reuses the **same MicroRISC4 core engine** across primary and worker cores connected by an ultra-lean direct-addressed ring NoC (`NocRouterNi` + `RegisteredNocHop` + `NocMultiCoreCacheWrapper`) and optionally backed by per-core BRAM I/D caches sharing the ULX3S-85F 32 MB SDRAM (`SdramCacheCluster` + `SdramController`).

* **Live Multi-Core ULX3S Top-Level (`Ulx3sTop`)**:
  * Passing `ULX3S_NOC_CORES=N` (`N >= 2`, e.g., `4` or `8`) instantiates Core 0 (UART + primary image) plus `N-1` worker cores (`1..N-1`) wired onto a lossless elastic ring with hardware Doorbell/MBOX Trap 14 delivery.
  * Passing `ULX3S_SDRAM_CACHE=1` shrinks each core's local BRAM to `2048` words (`2 DP16KD`) and attaches a private BRAM I-Cache + write-back D-Cache (`2 DP16KD`) backed by a private, non-overlapping 64K-word partition `{coreId[7:0], addr[15:0]}` in external SDRAM — giving every core the full 64K-word software address space while using 16× fewer BRAM blocks.
* **Independent Programs & Address Spaces**: Each `CpuCore` instance has private memory (local BRAM + optional private SDRAM partition) and can load its own image (`ULX3S_PROGRAM` for Core 0, `ULX3S_WORKER_PROGRAM` for workers `1..N-1`).
* **Hardware Reusability**: All cores share the same instruction set architecture (ISA), register model (`R0`–`R3` plus 4 shadow registers), and software conventions.

---

## 2. Hardware Configuration Parameters

`CpuCore` can be instantiated standalone or connected to the Lean Ring NoC and SDRAM cache cluster in `Ulx3sTop`. CPUID, UART, cross-traps, shadow registers, math, SPI, NoC, and SDRAM cache support are controlled by `CpuConfig`. Low-address stream FIFOs at `0x000A`/`0x000B` are simulator-only (`mr4sim.py`); real FPGA multi-core communication uses the Lean Ring NoC MMIO range at `0x0020`–`0x002A`.

### Configuration Parameters Summary

| Parameter / Field | Dart (`CpuConfig`) | Verilog / `Makefile` | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Core Identifier** | `coreId` | `CORE_ID` | `0` | Unique integer ID assigned to this core instance (`0..N-1`). |
| **CPUID Register** | `enableCpuid` | `ENABLE_CPUID` | `1` (`true`) | When enabled, reading `0x000D` returns `CORE_ID`. When disabled, `0x000D` is ordinary scratchpad RAM. |
| **UART MMIO** | `enableUart` | `ENABLE_UART` | `1` (`true`) | When enabled, `0x000E`/`0x000F` map to the hardware UART transceiver. Disabled on worker cores `1..N-1`. |
| **Inter-Core Traps** | `enableCrossTraps` | `ENABLE_CROSS_TRAPS` | `0` (`false`) | Enables external trap input + `ext_trap_ack` handshake (driven one-shot per MBOX arrival by `NocRouterNi` on Trap 14). |
| **Shadow Registers** | `enableShadowRegs` | `ENABLE_SHADOW_REGS` | `1` (`true`) | Enables 4 hardware shadow registers and single-cycle `XCHG`. |
| **Lean Ring NoC** | `enableNoc` | `ULX3S_NOC_CORES` | `false` (`0`) | Enables direct-addressed NoC MMIO (`0x0020`–`0x002A`) and wires `ULX3S_NOC_CORES` cores into a lossless elastic ring. |
| **NoC RX FIFO Depth** | `nocFifoDepth` | `ULX3S_NOC_FIFO_DEPTH` | `16` | Shared per-core RX FIFO depth in words (`16` words = `4 TRELLIS_DPR16X4`). |
| **SDRAM I/D Cache** | `enableSdramCache` | `ULX3S_SDRAM_CACHE` | `false` (`0`) | Routes `addr >= memWords` to private BRAM I/D caches (`cacheLines=64`, `cacheLineWords=8`) backed by ULX3S SDRAM. |
| **Vector Table Base**| `trapTableBase` | `TRAP_TABLE_BASE` | `16'h0100` | Base address for Direct Stride Vector Table (default: `0x0100`). |
| **Memory Capacity** | `memWords` | `ULX3S_MEM_WORDS` | `65536` (`2048` w/ SDRAM) | Dedicated local BRAM depth in 16-bit words (`2048` auto-selected when `ULX3S_SDRAM_CACHE=1`). |

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
| **`0x0010` – `0x00FF`** | 240 words | RAM / optional MMIO | RAM except for optional Math MMIO at `0x0010`–`0x0016`, SPI MMIO at `0x0018`–`0x001A`, and Lean Ring NoC MMIO at `0x0020`–`0x002A`. |
| **`0x0020` – `0x002A`** | 11 words | Optional NoC MMIO | Direct-addressed Lean Ring NoC registers when `enableNoc` is enabled; otherwise ordinary RAM. Separate from the simulator-only `0x000A`/`0x000B` FIFOs. |
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

Hardware multi-core communication uses the **direct-addressed Lean Ring NoC** (`0x0020`–`0x002A`) wired across all cores in `Ulx3sTop` when `ULX3S_NOC_CORES >= 2`. Each node costs only `126 LUT4 / 115 FF / 4 DPR16X4`, sustains `1.0 word/cycle` TX injection, enforces lossless registered ring backpressure (`netInReady` / `netOutReady`), and delivers hardware Trap 14 doorbells via `NOC_MBOX_SEND`.

### 4.1 Private Trap Tables and Vector Conventions

MicroRISC4 avoids partitioning the 16 hardware traps among cores. Each core has its own vector address space at `0x0100`–`0x01FF`:

| Vector | Symbolic Name | Meaning Across Cores |
| :---: | :---: | :--- |
| **Trap 0** | `TRAP_RESET` | Hardware cold boot / initialization entry point (`0x0100`). |
| **Trap 1** | `TRAP_MSG_READY` | Software convention for inbound messages / syscalls (`0x0110`). |
| **Trap 2** | `TRAP_BURST_DONE`| Software convention for a completed transfer (`0x0120`). |
| **Trap 3** | `TRAP_CACHE_MISS`| Software convention for a cache-miss request (`0x0130`). |
| **Trap 4** | `TRAP_TIMER_TICK`| Software convention for a timer/scheduler event (`0x0140`). |
| **Trap 14**| `TRAP_MBOX` / `TRAP_CORE_FAULT` | **Hardware NoC Doorbell/MBOX trap** (`0x01E0`): asserted one-shot per incoming `NOC_MBOX_SEND` flit when `enableNoc` and `enableCrossTraps` are enabled. |
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

Because MicroRISC4 includes 4 hardware shadow registers (`shadow_r[0..3]`), a trap handler can preserve and restore its registers with `XCHG` without memory spills:

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

### 4.4 Lean Ring NoC Registers (`0x0020`–`0x002A`) and Multi-Word FIFO Architecture

`0x000A` and `0x000B` are ordinary RAM in `CpuCore` (used only by the Python simulator `mr4sim.py`). On real FPGA hardware, `NocRouterNi` (`hdl/mr4/lib/noc_router.dart`) and `NocMultiCoreCacheWrapper` (`hdl/mr4/lib/noc_cache_wrapper.dart`) connect all `ULX3S_NOC_CORES` cores into a registered 2-slot elastic ring with **direct target-core addressing** (no channel tables) and full lossless backpressure:

* **1 shared multi-word RX FIFO per core** (`NocFifoRam`, default `16 × 16-bit` = `4 TRELLIS_DPR16X4` slices).
* **1-entry registered TX flit** sustaining `1.0 word/cycle` injection with simultaneous push/drain.
* **1-entry priority Doorbell/MBOX register** asserting a one-shot hardware **Trap 14** (`ext_trap_req` + `ext_trap_ack`) per arrival.
* **Hardware topology discovery** via `NOC_INFO` (`0x002A`).

| Address | Register | Access | Behavior |
| :---: | :--- | :---: | :--- |
| `0x0020` | `NOC_TX_DATA` | W | Push one 16-bit data word toward `NOC_DST_CORE` (accepted when `tx_ready=1` and `NOC_DST_CORE < numCores`). |
| `0x0021` | `NOC_DST_CORE` | R/W | Direct target core ID (`0..numCores-1`) for subsequent `NOC_TX_DATA` and `NOC_MBOX_SEND` writes (resets to own `coreId`). |
| `0x0022` | `NOC_RX_DATA` | R | Pop oldest 16-bit word from the core's shared RX FIFO (returns `0x0000` when empty). |
| `0x0023` | `NOC_STAT` | R | `[0]` `rx_not_empty`, `[1]` `rx_full`, `[2]` `tx_ready`, `[3]` `tx_empty`, `[4]` `mbox_valid`, `[7:5]` `0`, `[15:8]` `rx_count`. |
| `0x0024` | `NOC_RX_TRYR` | R | Non-blocking pop from shared RX FIFO (same semantics as `0x0022`; returns `0x0000` when empty). |
| `0x0025` | `NOC_MBOX_SEND` | W | Send one 16-bit priority Doorbell/MBOX word to `NOC_DST_CORE` and trigger **Trap 14** on the destination core. |
| `0x0026` | `NOC_MBOX_DATA` | R | Pop and clear the pending incoming Doorbell/MBOX payload word (returns `0x0000` when empty). |
| `0x0027` | `NOC_MBOX_SRC` | R | Source core ID of the incoming Doorbell/MBOX flit. |
| `0x0028`–`0x0029` | *(Reserved)* | R | Former channel-table registers removed in the Lean Ring; reads return `0x0000`. |
| `0x002A` | `NOC_INFO` | R | Read-only topology info: bits `[15:8]` = `fifoDepth`, bits `[7:0]` = `numCores`. |

### 4.5 Example: Send Data Words + Doorbell Trap 14 from Core 0 to Core 1

With `ULX3S_NOC_CORES=4` (or any `N >= 2`), Core 0 sets `NOC_DST_CORE = 1`, checks `tx_ready` (bit 2 of `NOC_STAT`), sends `0xBEEF` into Core 1's 16-word RX FIFO, and optionally rings Core 1's Trap 14 doorbell:

```assembly
; Core 0: select target Core 1 (no channel-table setup needed)
    LOAD16  R0, 0x0021
    LOAD16  R1, 1                ; NOC_DST_CORE = Core 1
    LD      (R0), R1

.align
_tx_wait:
    LOAD16  R0, 0x0023
    LD      R1, (R0)             ; Read NOC_STAT
    SHIFT.R R1
    SHIFT.R R1                   ; Move tx_ready (bit 2) to bit 0
    LOAD16  R2, 1
    AND     R1, R2
    LOAD16  R3, _tx_wait
    JMP.Z   R3, R1

    LOAD16  R0, 0x0020
    LOAD16  R1, 0xBEEF
    LD      (R0), R1             ; Push 0xBEEF to Core 1's shared RX FIFO

    ; Optional: ring Core 1's Trap 14 hardware doorbell with payload 0xCAFE
    LOAD16  R0, 0x0025
    LOAD16  R1, 0xCAFE
    LD      (R0), R1             ; Triggers Trap 14 on Core 1
```

Core 1 polls `NOC_STAT` bit 0 (`rx_not_empty`) and pops `0xBEEF` from `NOC_RX_DATA` (`0x0022`) or `NOC_RX_TRYR` (`0x0024`), and handles the doorbell in Trap 14 (`0x01E0`) by reading `NOC_MBOX_DATA` (`0x0026`) and `NOC_MBOX_SRC` (`0x0027`):

```assembly
.align
_rx_wait:
    LOAD16  R0, 0x0023
    LD      R1, (R0)
    LOAD16  R2, 1
    AND     R1, R2               ; Isolate rx_not_empty (bit 0)
    LOAD16  R3, _rx_wait
    JMP.Z   R3, R1

    LOAD16  R0, 0x0022
    LD      R2, (R0)             ; Pop word from 16-word RX FIFO; R2 = 0xBEEF
```

### 4.6 Local 2K BRAM + Hardware I/D Cache + ULX3S SDRAM (`ULX3S_SDRAM_CACHE=1`)

Building with `make ulx3s-bit ULX3S_SDRAM_CACHE=1` (optionally combined with `ULX3S_NOC_CORES=4`) shrinks each core's local BRAM from `65536` words (`64 DP16KD`) to `2048` words (`2 DP16KD`) and attaches a private `ICache` + write-back `DCache` (`2 DP16KD` total, 64 lines × 8 words) connected via `SdramBurstArbiter` to the ULX3S-85F 32 MB `IS42S16160G` SDRAM (`SdramController`):

* **Non-overlapping per-core SDRAM partitions**: External addresses `addr >= memWords` (`0x0800`–`0xFFFF`) map transparently to 24-bit SDRAM address `{coreId[7:0], addr[15:0]}`, giving up to 256 cores each a private 64K-word address space with zero overlap.
* **Hardware coherency**: Any D-Cache write automatically invalidates a matching I-Cache line, and any I-Cache miss snoops/cleans a dirty D-Cache line first so self-modifying code and dynamic loaders work transparently.
* **Verified ULX3S-85F timing**: `ODDRX1F` 180° `sdram_clk` + `16/16 IOLOGIC` `PosedgeIobReg16` true JEDEC `CL=2` capture achieves **`108.83 MHz`** (`4 DP16KD`, `2008 LUT4`, `844 FF`, `16 DPR16X4`, `17 IOLOGIC`) for 1-core and **`93.29 MHz`** (`16 DP16KD`, `8781 LUT4`, `3232 FF`, `80 DPR16X4`, `17 IOLOGIC`) for 4-core + Lean NoC + shared SDRAM.

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

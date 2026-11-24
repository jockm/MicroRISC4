# `mr4riscv`: Heterogeneous Multi-Core RV32IM Subsystem

`mr4riscv` is a decoupled, multi-core implementation of the RISC-V **RV32IM** instruction set architecture running on the 16-bit word-addressed MicroRISC4 computing fabric. 

Rather than implementing a monolithic 32-bit hardware core, the pipeline is partitioned across five cooperating MicroRISC4 cores communicating over hardware streaming FIFOs (`0x000A`/`0x000B`) and Mailbox trap strobes (`0x000C`).

---

## 1. Subsystem Architecture

```
                                  [ Inter-Core Ring Interconnect ]
                        +--------------------------------------------------+
                        | Streaming FIFOs (0x000A/0x000B) + Traps (0x000C) |
                        +--+--------+-------------+------------+--------+--+
                           |        |             |            |        |
                           v        v             v            v        v
                        +-----+  +-----+       +-----+      +-----+  +-----+
                        | C0  |  | C1  |       | C2  |      | C3  |  | C4  |
                        |FETCH|  | DEC |       |EXEC |      |MEMWB|  |CACHE|
                        +--+--+  +--+--+       +--+--+      +--+--+  +--+--+
                           |        |             |            |        |
    [I-Cache Requests] <---+        |             |            |        |
                                    |             v            v        |
                           [Register File]   [MMIO Math]  [FTDI UART]   |
                                              (0x10-0x16)  (0x0E-0x0F)  |
                                                                        v
                                                               [ sdram_controller ]
                                                                        |
                                                                        v
                                                                  [ 32 MB SDRAM ]
```

---

## 2. Core Topology & Configuration Matrix

All cores use `TRAP_TABLE_BASE = 0x0100` (Direct Stride Vectoring, 16 words/slot).

| Core | ID | Firmware | RAM Size (`MEM_WORDS`) | UART (`0x000E`/`0x000F`) | Math Accel (`0x0010`–`0x0016`) | Interconnect & External I/O |
| :---: | :---: | :--- | :---: | :---: | :---: | :--- |
| **0** | `0` | `fetch.asm` | 1,024 words (2 KB) | Disabled (`0`) | Disabled (`0`) | Issues I-Cache reads to C4; pushes instructions to C1; receives PC flushes from C2. |
| **1** | `1` | `decode.asm` | 1,024 words (2 KB) | Disabled (`0`) | Disabled (`0`) | Houses RV32 register file ($x0$–$x31$); unpacks immediates; accepts writeback from C2 and C3. |
| **2** | `2` | `execute.asm` | 1,024 words (2 KB) | Disabled (`0`) | **Enabled (`1`)** | Evaluates branches; computes 32-bit ALU ops; offloads RV32M operations (`MUL`/`DIV`) and barrel shifts to MMIO math coprocessor; routes memory ops to C3. |
| **3** | `3` | `mem_wb.asm` | 2,048 words (4 KB) | **Enabled (`1`)** | Disabled (`0`) | Direct interface to FTDI UART pins (`0x10000000`/`0x10000004`); formats sub-word accesses (`LB`, `LH`, `LW`); drives D-Cache on C4; forwards writeback to C1. |
| **4** | `4` | `cache_controller.asm` | 2,048 words (4 KB) | Disabled (`0`) | Disabled (`0`) | 512B/1KB direct-mapped I/D caches; write-behind queue; directly drives `sdram_controller.v` command and data pins (`0x0010`–`0x0014`). |

---

## 3. Emulated Memory & MMIO Map

The emulated RV32 program executes within a flat 32-bit address space:

| RV32 Address Range | Target Subsystem | Description |
| :--- | :--- | :--- |
| **`0x00000000` – `0x01FFFFFF`** | Physical SDRAM (32 MB) | Cached via Core 4 (512B/1KB I-Cache & D-Cache, 8-word line bursts). |
| **`0x10000000`** | Console UART RX / Status | Intercepted by Core 3. Read bit 15 = valid byte; bits `[7:0]` = character byte. |
| **`0x10000004`** | Console UART TX / Status | Intercepted by Core 3. Read bit 0 = busy; write bits `[7:0]` transmits byte over serial. |

---

## 4. Inter-Core Communication Protocols

### 4.1 Memory & Cache Protocol (Cores 0 & 3 $\rightarrow$ Core 4)
* **Word 0: Header** (`[15:12]` Opcode, `[11:10]` Target, `[9:8]` Size, `[7:0]` Client ID)
  * Opcode: `1` = READ, `2` = WRITE, `3` = FLUSH
  * Target: `0` = I-Cache, `1` = D-Cache
  * Size: `0` = 8-bit, `1` = 16-bit, `2` = 32-bit
* **Word 1**: Address Low (`addr[15:0]`)
* **Word 2**: Address High (`{8'h00, addr[23:16]}`)
* **Words 3–4 (Writes)**: Write Data (`DATA_LO`, optional `DATA_HI`)

### 4.2 Pipeline Inter-Stage Packets
* **Fetch $\rightarrow$ Decode**: 4 words (`[PC_LO, PC_HI, INST_LO, INST_HI]`) + `TRAP_MSG_READY` (Trap 1).
* **Decode $\rightarrow$ Execute**: 5 words (`[UOP_HDR, OP1_LO, OP1_HI, OP2_LO, OP2_HI]`) + `TRAP_MSG_READY` (Trap 1).
* **Writeback Commit (Execute/Mem $\rightarrow$ Decode)**: 3 words (`[rd, VAL_LO, VAL_HI]`) + `TRAP_BURST_DONE` (Trap 2).
* **Pipeline Flush (Execute $\rightarrow$ Fetch/Decode)**: 2 words target PC (`[PC_LO, PC_HI]`) + `TRAP_PIPE_FLUSH` (Trap 3).

---

## 5. Source Tree & Build Flow

```text
mr4riscv/
├── Makefile                 # Builds all stage binaries via bin/assemble
├── README.md                # This specification
├── riscv_common.inc         # Shared pipeline constants, opcodes, and macros
├── fetch.asm                # Core 0: Program Counter & I-Cache fetch
├── decode.asm               # Core 1: Decoder, register file (x0..x31), issue
├── execute.asm              # Core 2: 32-bit ALU, branches, and RV32M coprocessor
├── mem_wb.asm               # Core 3: Loads/stores, console UART MMIO, writeback
└── cache_controller.asm     # Core 4: I/D-cache manager & SDRAM controller interface
```

### Building Firmware Binaries
Run `make` inside the `mr4riscv/` directory to generate the memory images:
```bash
make
```

All compiled Verilog `$readmemh` hex images and listings are emitted into `mr4riscv/build/`:
* `build/fetch.hex` & `fetch.lst`
* `build/decode.hex` & `decode.lst`
* `build/execute.hex` & `execute.lst`
* `build/mem_wb.hex` & `mem_wb.lst`
* `build/cache_controller.hex` & `cache_controller.lst`
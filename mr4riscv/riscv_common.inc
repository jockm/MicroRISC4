; ==============================================================================
; FILE: mr4riscv/riscv_common.inc
; Architecture: MiniRISC4 Heterogeneous Multi-Core RISC-V (RV32I/M) Engine[cite: 2, 10]
; Target: Lattice ECP5 FPGA (ULX3S) / Verilog-2001 & Intel ROHD (Dart)[cite: 2, 11]
; Description:
;   Common architectural definitions, core role IDs, inter-core messaging
;   protocols, packet formats, and helper macros for the mr4riscv pipeline.
; ==============================================================================

.ifndef _RISCV_COMMON_INC_
.define _RISCV_COMMON_INC_  1

; ------------------------------------------------------------------------------
; 1. Core ID Topology & Subsystem Assignments (CPUID @ 0x000D)[cite: 1, 2]
; ------------------------------------------------------------------------------
.define CORE_ID_FETCH       0       ; Core 0: RV32 PC Management & Instruction Fetch
.define CORE_ID_DECODE      1       ; Core 1: RV32 Instruction Decode & Register File[cite: 2]
.define CORE_ID_EXEC        2       ; Core 2: RV32 ALU / Branch / Math Accelerator[cite: 2, 10]
.define CORE_ID_MEM_WB      3       ; Core 3: RV32 Load/Store & Writeback Commit
.define CORE_ID_CACHE_MGR   4       ; Core 4: I-Cache & D-Cache Manager (SDRAM worker)[cite: 1, 2]

; ------------------------------------------------------------------------------
; 2. Low-Memory Hardware MMIO & Streaming Addresses (0x0000 - 0x001F)[cite: 1, 8]
; ------------------------------------------------------------------------------
.define SCRATCH_0           0x0000  ; Scratchpad save/restore R0[cite: 1, 8]
.define SCRATCH_1           0x0001  ; Scratchpad save/restore R1[cite: 1, 8]
.define SCRATCH_2           0x0002  ; Scratchpad save/restore R2[cite: 1, 8]
.define SCRATCH_3           0x0003  ; Scratchpad save/restore R3[cite: 1, 8]
.define RSP_PTR_ADDR        0x0004  ; Return Stack Pointer storage[cite: 1, 8]
.define ASP_PTR_ADDR        0x0005  ; Argument Stack Pointer storage[cite: 1, 8]

.define FIFO_IN_ADDR        0x000A  ; Inbound Stream FIFO pop (16-bit word)
.define FIFO_OUT_ADDR       0x000B  ; Outbound Stream FIFO push (16-bit word)
.define MAILBOX_ADDR        0x000C  ; Cross-Core Mailbox Trigger: (dest << 8) | trap[cite: 1, 8]
.define CPUID_ADDR          0x000D  ; Hardware Core ID Register (Read-Only)[cite: 1]
.define UART_RX_ADDR        0x000E  ; Serial Receiver MMIO (if Core 0 UART enabled)[cite: 1, 8]
.define UART_TX_ADDR        0x000F  ; Serial Transmit MMIO (if Core 0 UART enabled)[cite: 1, 8]

; Direct Stride Vector Table Constants[cite: 8]
.define TRAP_TABLE_BASE     0x0100  ; Vector base address[cite: 8]
.define TRAP_STRIDE         16      ; 16 words (32 bytes) per direct stride slot[cite: 8]

; ------------------------------------------------------------------------------
; 3. Universal Semantic Inter-Core Trap Vectors (0x0100 - 0x01FF)[cite: 2, 8]
; ------------------------------------------------------------------------------
.define TRAP_RESET          0       ; 0x0100: Reset / Cold Boot initialization[cite: 8]
.define TRAP_MSG_READY      1       ; 0x0110: FIFO_IN has new incoming packet / request[cite: 2, 8]
.define TRAP_BURST_DONE     2       ; 0x0120: Memory / cache transaction completed[cite: 2, 8]
.define TRAP_PIPE_FLUSH     3       ; 0x0130: Branch taken / pipeline flush strobe[cite: 2]
.define TRAP_TIMER_TICK     4       ; 0x0140: Periodic hardware timer tick[cite: 2, 8]
.define TRAP_CORE_FAULT     14      ; 0x01E0: Subsystem fault / illegal operation[cite: 2, 8]
.define TRAP_ALIGN_FAULT    15      ; 0x01F0: Hardware Slot 1 alignment fault[cite: 2, 8]

; ------------------------------------------------------------------------------
; 4. Cache & SDRAM Controller Messaging Protocol (Core 4)[cite: 1, 2]
; ------------------------------------------------------------------------------
; Packet Word 0: Control Header Bitfield
;   Bits [15:12] : Command Opcode
.define MEM_CMD_READ        0x1     ; Burst/Sub-word read
.define MEM_CMD_WRITE       0x2     ; Write-behind store
.define MEM_CMD_FLUSH       0x3     ; Sync / wait write buffer drain
.define MEM_CMD_INVAL       0x4     ; Invalidate line (Coherency strobe)[cite: 2]

;   Bits [11:10] : Cache Target
.define CACHE_SEL_ICACHE    0x0     ; Target Instruction Cache (read-only)
.define CACHE_SEL_DCACHE    0x1     ; Target Data Cache (read/write)

;   Bits [9:8]   : Granularity / Access Size
.define MEM_SIZE_8          0x0     ; 8-bit Byte
.define MEM_SIZE_16         0x1     ; 16-bit Half-word
.define MEM_SIZE_32         0x2     ; 32-bit Word

; Header Assembly Helpers:
; Form Header = (cmd << 12) | (cache << 10) | (size << 8) | client_id
.define ICACHE_READ_32(client)      (0x1000 | (MEM_SIZE_32 << 8) | (client))
.define DCACHE_READ_32(client)      (0x1400 | (MEM_SIZE_32 << 8) | (client))
.define DCACHE_WRITE_32(client)     (0x2400 | (MEM_SIZE_32 << 8) | (client))
.define DCACHE_WRITE_16(client)     (0x2400 | (MEM_SIZE_16 << 8) | (client))
.define DCACHE_WRITE_8(client)      (0x2400 | (MEM_SIZE_8 << 8)  | (client))

; ------------------------------------------------------------------------------
; 5. Inter-Stage Pipeline Protocol (Fetch -> Decode -> Exec -> Mem/WB)[cite: 2]
; ------------------------------------------------------------------------------
; Instruction Packet (Fetch -> Decode):
;   Word 0 : PC[15:0]
;   Word 1 : PC[31:16]
;   Word 2 : RV32 Instruction Low Word (inst[15:0])
;   Word 3 : RV32 Instruction High Word (inst[31:16])

; Decoded Micro-Op Descriptor Header (Decode -> Exec):
;   Word 0 : Control & Register Map
;     Bits [15:12] : ALU Operation / Function Class
;     Bits [11:7]  : Destination Register (rd: 0..31)
;     Bits [6:5]   : Branch Condition Type
;     Bit  [4]     : Has Immediate (1 = uses Imm, 0 = rs2)
;     Bit  [3]     : Is Memory Load/Store
;     Bits [2:0]   : Memory Width / Signedness
;   Word 1 : Source Operand 1 (rs1_val[15:0])
;   Word 2 : Source Operand 1 (rs1_val[31:16])
;   Word 3 : Source Operand 2 / Immediate Low (op2[15:0])
;   Word 4 : Source Operand 2 / Immediate High (op2[31:16])

; ALU / Operation Class Opcodes (Word 0 [15:12]):
.define RV_ALU_ADD          0x0
.define RV_ALU_SUB          0x1
.define RV_ALU_AND          0x2
.define RV_ALU_OR           0x3
.define RV_ALU_XOR          0x4
.define RV_ALU_SLL          0x5
.define RV_ALU_SRL          0x6
.define RV_ALU_SRA          0x7
.define RV_ALU_SLT          0x8
.define RV_ALU_SLTU         0x9
.define RV_ALU_BRANCH       0xA
.define RV_ALU_JALR         0xB
.define RV_ALU_LUI          0xC
.define RV_ALU_MATH_EXT     0xD     ; RV32M Extension (MUL/DIV via accelerator)[cite: 10]

; ------------------------------------------------------------------------------
; 6. System Synchronization & Inter-Core Messaging Macros
; ------------------------------------------------------------------------------

; MACRO: SEND_MAILBOX dest_core, trap_num
; Fires a 1-cycle external trap strobe to target core over 0x000C[cite: 1, 8].
.macro SEND_MAILBOX dest_core, trap_num
    LOAD16  R1, (((%dest_core) << 8) | (%trap_num))
    LD      R0, 12                  ; R0 = 0x000C (MAILBOX_ADDR)[cite: 8]
    LD      (R0), R1                ; Strobe interconnect[cite: 8]
.endmacro

; MACRO: FIFO_PUSH reg
; Pushes the 16-bit word in reg onto the outbound stream FIFO (0x000B)[cite: 8].
.macro FIFO_PUSH reg
    LD      R0, 11                  ; R0 = 0x000B (FIFO_OUT_ADDR)[cite: 8]
    LD      (R0), %reg
.endmacro

; MACRO: FIFO_POP dest_reg
; Pops a 16-bit word from the inbound stream FIFO (0x000A) into dest_reg[cite: 8].
.macro FIFO_POP dest_reg
    LD      R0, 10                  ; R0 = 0x000A (FIFO_IN_ADDR)[cite: 8]
    LD      %dest_reg, (R0)
.endmacro

; MACRO: GET_CPUID dest_reg
; Reads this core's hardware Core ID into dest_reg in 2 single-byte instructions (1 word)[cite: 1].
.macro GET_CPUID dest_reg
    LD      R0, 13                  ; Slot 0: R0 = 0x000D (CPUID_ADDR)[cite: 1]
    LD      %dest_reg, (R0)         ; Slot 1: Read CORE_ID[cite: 1]
.endmacro

.endif ; _RISCV_COMMON_INC_
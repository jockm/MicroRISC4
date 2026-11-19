; ==============================================================================
; FILE: mr4riscv/mem_wb.asm
; Architecture: MiniRISC4 Heterogeneous RV32IM Multi-Core Engine[cite: 2]
; Component: Core 3 - Memory Access (Loads/Stores), UART MMIO, and Writeback
; Target: Lattice ECP5 FPGA (ULX3S) / Verilog-2001 & Intel ROHD (Dart)[cite: 2]
;
; Core MMIO Map (Core 3):
;   0x0000 - 0x000F : Standard Low-Memory Control & Streaming[cite: 1]
;     0x000A        : FIFO_IN (From Core 2 Execute or Core 4 Cache Controller)
;     0x000B        : FIFO_OUT (To Core 1 Decode/RegFile or Core 4 Cache)
;     0x000C        : MAILBOX (Cross-core trap strobe trigger)[cite: 1]
;     0x000D        : CPUID (Core 3)[cite: 1]
;     0x000E        : UART_RX (Direct hardware FTDI UART receiver)[cite: 2]
;     0x000F        : UART_TX (Direct hardware FTDI UART transmitter)[cite: 2]
;
; Emulated RV32 Memory-Mapped I/O (MMIO) Map:
;   0x10000000      : UART_RX (Bit 15 = valid byte flag, Bits [7:0] = data byte)[cite: 2]
;   0x10000004      : UART_TX (Bit 0 = transmitter busy flag, write transmits)[cite: 2]
; ==============================================================================

.include "common.inc"
.include "riscv_common.inc"

; ------------------------------------------------------------------------------
; Static Scratchpad RAM Storage Offsets (Local to Core 3)
; ------------------------------------------------------------------------------
.define MEM_HDR_ADDR        0x0020  ; Inbound micro-op control header
.define ADDR_LO_ADDR        0x0021  ; Effective Address [15:0]
.define ADDR_HI_ADDR        0x0022  ; Effective Address [31:16]
.define VAL_LO_ADDR         0x0023  ; Store data payload [15:0] / Load temp
.define VAL_HI_ADDR         0x0024  ; Store data payload [31:16]
.define FLUSH_FLAG_ADDR     0x0025  ; Pipeline flush flag

; RV32 Memory Width Encodings (funct3 in Header Bits [2:0])
.define RV_MEM_LB           0x0     ; Load Byte (Signed)
.define RV_MEM_LH           0x1     ; Load Halfword (Signed)
.define RV_MEM_LW           0x2     ; Load Word (32-bit)
.define RV_MEM_LBU          0x4     ; Load Byte (Unsigned)
.define RV_MEM_LHU          0x5     ; Load Halfword (Unsigned)

.define RV_MEM_SB           0x0     ; Store Byte (8-bit)
.define RV_MEM_SH           0x1     ; Store Halfword (16-bit)
.define RV_MEM_SW           0x2     ; Store Word (32-bit)

; ==============================================================================
; DIRECT STRIDE VECTOR TABLE (0x0100 - 0x01FF)
; 16 words (32 bytes) per direct stride entry slot
; ==============================================================================
.org 0x0100

; --- Trap 0: Reset / Cold Boot Entry ---
_trap0_reset:
    START_PROGRAM                   ; Initialize RSP/ASP and branch to _main
    .align

; --- Trap 1: Inbound Message / Descriptor Ready ---[cite: 2]
.org 0x0110
_trap1_msg_ready:
    JMP     R0                      ; Serviced inline by main event loop
    .align

; --- Trap 2: Memory / D-Cache Burst Completed (from Core 4) ---[cite: 2]
.org 0x0120
_trap2_burst_done:
    JMP     R0                      ; Unblocks pending cache reads
    .align

; --- Trap 3: Pipeline Flush (Branch taken redirect from Core 2) ---[cite: 2]
.org 0x0130
_trap3_pipe_flush:
    LOAD16  R1, FLUSH_FLAG_ADDR
    LD      R2, 1
    LD      (R1), R2                ; Mark flush flag active
    JMP     R0
    .align

; Traps 4-15 default fast return
.org 0x01F0
_trap15_align_fault:
    JMP     R0
    .align

; ==============================================================================
; Main Memory / Writeback Stage Initialization & Event Loop (0x0200)
; ==============================================================================
.org 0x0200

_main:
    ; Clear Pipeline Flush Flag
    LOAD16  R1, FLUSH_FLAG_ADDR
    LD      R2, 0
    LD      (R1), R2

_mem_loop:
    ; 1. Check and handle pipeline flush flag
    LOAD16  R0, FLUSH_FLAG_ADDR
    LD      R1, (R0)
    JMP.Z   _wait_for_uop, R1
    LD      R1, 0
    LD      (R0), R1                ; Reset flush flag

_wait_for_uop:
    ; --------------------------------------------------------------------------
    ; 2. Pop Memory Micro-Op Descriptor from Core 2 Execute over FIFO_IN (0x000A)
    ; Packet: [HDR, ADDR_LO, ADDR_HI, DATA_LO, DATA_HI]
    ; --------------------------------------------------------------------------
    FIFO_POP R1                     ; Read HDR (0 if FIFO is currently empty)
    JMP.Z   _mem_loop, R1           ; No packet, poll again

    LOAD16  R0, MEM_HDR_ADDR
    LD      (R0), R1                ; Latch Header

    FIFO_POP R2                     ; Pop ADDR_LO
    LOAD16  R0, ADDR_LO_ADDR
    LD      (R0), R2

    FIFO_POP R3                     ; Pop ADDR_HI
    LOAD16  R0, ADDR_HI_ADDR
    LD      (R0), R3

    FIFO_POP R1                     ; Pop DATA_LO
    LOAD16  R0, VAL_LO_ADDR
    LD      (R0), R1

    FIFO_POP R2                     ; Pop DATA_HI
    LOAD16  R0, VAL_HI_ADDR
    LD      (R0), R2

    ; --------------------------------------------------------------------------
    ; 3. Check for Emulated RV32 UART MMIO Range (Base: 0x1000xxxx)
    ; --------------------------------------------------------------------------
    LOAD16  R0, ADDR_HI_ADDR
    LD      R1, (R0)
    LOAD16  R2, 0x1000              ; Compare ADDR_HI with 0x1000
    SUB     R1, R2
    JMP.Z   _handle_uart_mmio, R1   ; Match -> Route to local hardware UART[cite: 2]

    ; --------------------------------------------------------------------------
    ; 4. Standard SDRAM / D-Cache Route[cite: 1]
    ; Check Header Bit 12: 0 = Load (READ), 1 = Store (WRITE)
    ; --------------------------------------------------------------------------
    LOAD16  R0, MEM_HDR_ADDR
    LD      R1, (R0)
    AND     R1, 0x1000
    JMP.NZ  _dispatch_dcache_store, R1

; ==============================================================================
; D-Cache Load Processing (LB, LH, LW, LBU, LHU)
; ==============================================================================
_dispatch_dcache_load:
    ; Form DCACHE READ Request Packet for Core 4 (Cache Controller)[cite: 1]
    ; Header = 0x1603 (CMD=READ, TARGET=D-Cache, SIZE=32-bit, CLIENT=Core 3)[cite: 1]
    LOAD16  R1, 0x1603
    FIFO_PUSH R1                    ; Word 0: Header

    LOAD16  R0, ADDR_LO_ADDR
    LD      R2, (R0)
    FIFO_PUSH R2                    ; Word 1: ADDR_LO

    LOAD16  R0, ADDR_HI_ADDR
    LD      R3, (R0)
    FIFO_PUSH R3                    ; Word 2: ADDR_HI

    ; Signal Cache Controller (Core 4, Trap 1: TRAP_MSG_READY)[cite: 1]
    SEND_MAILBOX CORE_ID_CACHE_MGR, TRAP_MSG_READY[cite: 1]

    ; Await Response Words from Cache Controller[cite: 1]
_wait_dcache_resp:
    LOAD16  R0, FLUSH_FLAG_ADDR
    LD      R1, (R0)
    JMP.NZ  _drain_and_discard, R1

    FIFO_POP R1                     ; Read data_lo
    JMP.Z   _wait_dcache_resp, R1
    FIFO_POP R2                     ; Read data_hi

    ; --------------------------------------------------------------------------
    ; Sub-Word Formatting & Sign/Zero Extension based on funct3
    ; --------------------------------------------------------------------------
    LOAD16  R0, MEM_HDR_ADDR
    LD      R3, (R0)
    AND     R3, 0x0007              ; R3 = funct3

    ; 32-bit Word: LW (0x2)
    LOAD16  R0, RV_MEM_LW
    SUB     R0, R3
    JMP.Z   _commit_wb_load, R0

    ; 8-bit Signed: LB (0x0)
    LOAD16  R0, RV_MEM_LB
    SUB     R0, R3
    JMP.Z   _format_lb, R0

    ; 8-bit Unsigned: LBU (0x4)
    LOAD16  R0, RV_MEM_LBU
    SUB     R0, R3
    JMP.Z   _format_lbu, R0

    ; 16-bit Signed: LH (0x1)
    LOAD16  R0, RV_MEM_LH
    SUB     R0, R3
    JMP.Z   _format_lh, R0

    ; 16-bit Unsigned: LHU (0x5)
    LD0     R2                      ; High word zero-extended
    JMP     _commit_wb_load

_format_lb:
    LOAD16  R0, ADDR_LO_ADDR
    LD      R0, (R0)
    AND     R0, 0x0001              ; Check address bit 0
    JMP.Z   _lb_low_byte, R0
    BYTE_GET_HI R1, R1              ; Extract upper byte [15:8]
    JMP     _lb_sign_extend
_lb_low_byte:
    BYTE_GET_LO R1, R1              ; Extract lower byte [7:0]
_lb_sign_extend:
    LOAD16  R0, 0x0080
    AND     R0, R1
    JMP.Z   _lb_positive, R0
    OR      R1, 0xFF00              ; Sign-extend lower 16 bits
    LOAD16  R2, 0xFFFF              ; Upper 16 bits = 0xFFFF
    JMP     _commit_wb_load
_lb_positive:
    LD0     R2                      ; Upper 16 bits = 0x0000
    JMP     _commit_wb_load

_format_lbu:
    LOAD16  R0, ADDR_LO_ADDR
    LD      R0, (R0)
    AND     R0, 0x0001
    JMP.Z   _lbu_low_byte, R0
    BYTE_GET_HI R1, R1
    JMP     _lbu_finish
_lbu_low_byte:
    BYTE_GET_LO R1, R1
_lbu_finish:
    LD0     R2                      ; Upper 16 bits = 0x0000
    JMP     _commit_wb_load

_format_lh:
    JMP.M   _lh_negative, R1
    LD0     R2                      ; Positive -> Upper 16 bits = 0x0000
    JMP     _commit_wb_load
_lh_negative:
    LOAD16  R2, 0xFFFF              ; Negative -> Upper 16 bits = 0xFFFF
    JMP     _commit_wb_load

; ==============================================================================
; D-Cache Store Processing (SB, SH, SW) - Write-Behind[cite: 1]
; ==============================================================================
_dispatch_dcache_store:
    LOAD16  R0, MEM_HDR_ADDR
    LD      R3, (R0)
    AND     R3, 0x0007              ; R3 = funct3

    ; Form DCACHE WRITE Header = 0x2403 (CMD=WRITE, TARGET=D-Cache, CLIENT=Core 3)[cite: 1]
    LOAD16  R1, 0x2403

    ; Set Size bits [9:8]: 0=8-bit, 1=16-bit, 2=32-bit
    LOAD16  R0, RV_MEM_SW
    SUB     R0, R3
    JMP.NZ  _store_check_sh, R0
    OR      R1, 0x0200              ; Size = 32-bit
    JMP     _store_push_header
_store_check_sh:
    LOAD16  R0, RV_MEM_SH
    SUB     R0, R3
    JMP.NZ  _store_push_header, R0
    OR      R1, 0x0100              ; Size = 16-bit

_store_push_header:
    FIFO_PUSH R1                    ; Word 0: Header

    LOAD16  R0, ADDR_LO_ADDR
    LD      R2, (R0)
    FIFO_PUSH R2                    ; Word 1: ADDR_LO

    LOAD16  R0, ADDR_HI_ADDR
    LD      R2, (R0)
    FIFO_PUSH R2                    ; Word 2: ADDR_HI

    LOAD16  R0, VAL_LO_ADDR
    LD      R2, (R0)
    FIFO_PUSH R2                    ; Word 3: DATA_LO

    ; If SW (32-bit), push DATA_HI
    LOAD16  R0, RV_MEM_SW
    SUB     R0, R3
    JMP.NZ  _store_notify_cache, R0

    LOAD16  R0, VAL_HI_ADDR
    LD      R2, (R0)
    FIFO_PUSH R2                    ; Word 4: DATA_HI

_store_notify_cache:
    ; Strobe Cache Controller (Core 4, Trap 1) to commit into Write-Behind Buffer[cite: 1]
    SEND_MAILBOX CORE_ID_CACHE_MGR, TRAP_MSG_READY[cite: 1]

    ; Stores produce no register writeback; return immediately to event loop
    LOAD16  R0, _mem_loop
    JMP     R0

; ==============================================================================
; Emulated RV32 UART MMIO Handler (Addresses 0x10000000 & 0x10000004)[cite: 2]
; ==============================================================================
_handle_uart_mmio:
    LOAD16  R0, MEM_HDR_ADDR
    LD      R1, (R0)
    AND     R1, 0x1000              ; Check Load (0) vs Store (1)
    JMP.NZ  _uart_mmio_store, R1

_uart_mmio_load:
    ; RV32 Load from UART: inspect ADDR_LO
    LOAD16  R0, ADDR_LO_ADDR
    LD      R2, (R0)
    AND     R2, 0x000F              ; Check low nibble offset

    ; Offset 0x00: Read UART_RX register (MMIO 0x000E)[cite: 2]
    JMP.NZ  _uart_read_tx_status, R2

    LD      R0, 14                  ; R0 = 0x000E (ADDR_UART_RX)[cite: 2, 4]
    LD      R1, (R0)                ; R1 = {rx_valid, 7'b0, rx_byte}[cite: 2]
    LD0     R2                      ; res_hi = 0x0000
    JMP     _commit_wb_load

_uart_read_tx_status:
    ; Offset 0x04: Read UART_TX status (MMIO 0x000F)[cite: 2, 4]
    LD      R0, 15                  ; R0 = 0x000F (ADDR_UART_TX)[cite: 2, 4]
    LD      R1, (R0)                ; R1 = {15'b0, tx_busy}[cite: 2]
    LD0     R2
    JMP     _commit_wb_load

_uart_mmio_store:
    ; RV32 Store to UART: Write byte to hardware UART_TX (MMIO 0x000F)[cite: 2, 4]
    ; Poll TX status until transmitter is not busy[cite: 2]
_uart_tx_busy_wait:
    LD      R0, 15                  ; 0x000F[cite: 2, 4]
    LD      R1, (R0)[cite: 2]
    JMP.NZ  _uart_tx_busy_wait, R1  ; Busy? Keep polling[cite: 2]

    ; Write byte to UART TX register[cite: 2]
    LOAD16  R0, VAL_LO_ADDR
    LD      R1, (R0)
    AND     R1, 0x00FF              ; Mask low byte
    LD      R0, 15                  ; 0x000F[cite: 2, 4]
    LD      (R0), R1                ; Hardware MMIO transmits byte out[cite: 2]

    LOAD16  R0, _mem_loop
    JMP     R0

; ==============================================================================
; Commit Load Result to RV32 Register File (Core 1 Decode)
; Sends: [rd, res_lo, res_hi] across FIFO_OUT (0x000B)
; ==============================================================================
_commit_wb_load:
    ; Extract destination register rd from Header bits [11:7]
    LOAD16  R0, MEM_HDR_ADDR
    LD      R3, (R0)
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    AND     R3, 0x001F              ; R3 = rd (0..31)

    ; If rd == x0, skip register writeback commit entirely
    JMP.Z   _commit_wb_done, R3

    ; Push packet to Core 1 Register File
    FIFO_PUSH R3                    ; Word 0: rd index
    FIFO_PUSH R1                    ; Word 1: res_lo
    FIFO_PUSH R2                    ; Word 2: res_hi

    ; Fire Writeback Commit Trap to Core 1 (Trap 2: TRAP_BURST_DONE / TRAP_WB_COMMIT)[cite: 2]
    SEND_MAILBOX CORE_ID_DECODE, TRAP_BURST_DONE[cite: 2]

_commit_wb_done:
    LOAD16  R0, _mem_loop
    JMP     R0

; ------------------------------------------------------------------------------
; Discard Handler (When Pipeline Flushed during Pending Memory Transaction)
; ------------------------------------------------------------------------------
_drain_and_discard:
    FIFO_POP R1                     ; Drain data_lo
    FIFO_POP R2                     ; Drain data_hi
    LOAD16  R0, FLUSH_FLAG_ADDR
    LD      R1, 0
    LD      (R0), R1                ; Clear flush flag
    LOAD16  R0, _mem_loop
    JMP     R0
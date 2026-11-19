; ==============================================================================
; FILE: mr4riscv/fetch.asm
; Architecture: MiniRISC4 Heterogeneous RV32IM Pipeline
; Component: Core 0 - Instruction Fetch Stage
; Target: Lattice ECP5 FPGA (ULX3S) / Verilog-2001 & Intel ROHD (Dart)[cite: 2]
; Description:
;   Manages the 32-bit RV32 Program Counter, coordinates with the Cache
;   Controller (Core 4) to fetch 32-bit instructions from the I-Cache, and
;   pushes instruction packets to the Decode stage (Core 1)[cite: 1, 2].
; ==============================================================================

.include "common.inc"
.include "riscv_common.inc"

; ------------------------------------------------------------------------------
; Local Static Storage Addresses (in local scratchpad RAM)
; ------------------------------------------------------------------------------
.define PC_LO_ADDR          0x0020  ; Emulated RV32 PC [15:0]
.define PC_HI_ADDR          0x0021  ; Emulated RV32 PC [31:16]
.define FLUSH_FLAG_ADDR     0x0022  ; Set non-zero if branch redirect received

; Default RV32 Reset Entry Point: 0x00000000 (or SDRAM base)[cite: 1]
.define RV32_RESET_PC_LO    0x0000
.define RV32_RESET_PC_HI    0x0000

; ==============================================================================
; DIRECT STRIDE VECTOR TABLE (0x0100 - 0x01FF)[cite: 8]
; Fixed 16-word stride (32 bytes per slot)[cite: 8]
; ==============================================================================
.org 0x0100

; --- Trap 0: Reset / Boot Entry (0x0100 - 0x010F: strictly <= 16 words)[cite: 8] ---
_trap0_reset:
    START_PROGRAM                   ; Sets up RSP/ASP and jumps to _main[cite: 8]
    .align

; --- Trap 1: Inbound Message Ready (FIFO_IN has data)[cite: 8] ---
.org 0x0110
_trap1_msg_ready:
    JMP     R0                      ; Polled in-line or returns to loop[cite: 8]
    .align

; --- Trap 2: Memory / Burst Transaction Done (from Core 4)[cite: 1, 8] ---
.org 0x0120
_trap2_burst_done:
    JMP     R0                      ; Unblocks waiting loop[cite: 8]
    .align

; --- Trap 3: Pipeline Flush / Branch Redirect (from Core 2 Execute) ---
.org 0x0130
_trap3_pipe_flush:
    ; Read redirect target PC from FIFO_IN: [ADDR_LO, ADDR_HI][cite: 8]
    XCHG    R2
    XCHG    R3
    LD      R2, 10                  ; FIFO_IN_ADDR (0x000A)[cite: 8]
    LD      R3, (R2)                ; R3 = New Target PC_LO[cite: 8]
    LOAD16  R2, PC_LO_ADDR
    LD      (R2), R3                ; Update PC_LO

    LD      R2, 10                  ; FIFO_IN_ADDR[cite: 8]
    LD      R3, (R2)                ; R3 = New Target PC_HI[cite: 8]
    LOAD16  R2, PC_HI_ADDR
    LD      (R2), R3                ; Update PC_HI

    ; Mark FLUSH_FLAG so any pending in-flight fetch is discarded
    LOAD16  R2, FLUSH_FLAG_ADDR
    LD      R3, 1
    LD      (R2), R3

    XCHG    R3
    XCHG    R2
    JMP     R0                      ; Return from trap[cite: 8]
    .align

; Default Fast Returns for Traps 4-15
.org 0x01F0
_trap15_align_fault:
    JMP     R0                      ; Hardware slot alignment trap stub[cite: 8]
    .align

; ==============================================================================
; Core 0 Entry & Main Fetch Loop (0x0200)
; ==============================================================================
.org 0x0200

_main:
    ; 1. Initialize RV32 Program Counter
    LOAD16  R1, RV32_RESET_PC_LO
    LOAD16  R2, PC_LO_ADDR
    LD      (R2), R1

    LOAD16  R1, RV32_RESET_PC_HI
    LOAD16  R2, PC_HI_ADDR
    LD      (R2), R1

    ; 2. Clear Flush Flag
    LOAD16  R2, FLUSH_FLAG_ADDR
    LD      R1, 0
    LD      (R2), R1

; ------------------------------------------------------------------------------
; Main Fetch Loop
; ------------------------------------------------------------------------------
_fetch_loop:
    ; Read current RV32 PC into R2 (PC_LO) and R3 (PC_HI)
    LOAD16  R0, PC_LO_ADDR
    LD      R2, (R0)
    LOAD16  R0, PC_HI_ADDR
    LD      R3, (R0)

    ; --------------------------------------------------------------------------
    ; Step A: Request 32-bit Instruction from Cache Controller (Core 4)[cite: 1, 2]
    ; Packet: [Header, ADDR_LO, ADDR_HI]
    ; --------------------------------------------------------------------------
    ; Word 0: ICACHE_READ_32(CORE_ID_FETCH) = 0x1200
    LOAD16  R1, 0x1200              ; Op=READ(1), Target=I-Cache(0), Size=32(2), Client=0[cite: 1]
    FIFO_PUSH R1                    ; Push to FIFO_OUT (0x000B)[cite: 8]

    ; Word 1: ADDR_LO
    FIFO_PUSH R2                    ; Push PC_LO[cite: 8]

    ; Word 2: ADDR_HI
    FIFO_PUSH R3                    ; Push PC_HI[cite: 8]

    ; Notify Cache Controller (Core 4, Trap 1: TRAP_MSG_READY)[cite: 1, 8]
    SEND_MAILBOX CORE_ID_CACHE_MGR, TRAP_MSG_READY[cite: 1, 2, 8]

    ; --------------------------------------------------------------------------
    ; Step B: Wait for Response from Cache Controller[cite: 1]
    ; Returns 2 words on FIFO_IN: [INST_LO, INST_HI][cite: 8]
    ; --------------------------------------------------------------------------
_wait_cache_resp:
    ; Check if branch flush arrived while waiting
    LOAD16  R0, FLUSH_FLAG_ADDR
    LD      R1, (R0)
    JMP.NZ  _handle_discard, R1

    ; Poll FIFO_IN for the 2-word instruction response[cite: 8]
    FIFO_POP R1                     ; Read INST_LO (0 if FIFO empty)[cite: 8]
    JMP.Z   _wait_cache_resp, R1    ; Keep waiting until data arrives

    FIFO_POP R0                     ; Read INST_HI[cite: 8]
    XCHG    R0                      ; Store INST_HI safely in shadow_r[0]

    ; Check one more time if a flush trap hit during pop
    LOAD16  R0, FLUSH_FLAG_ADDR
    LD      R2, (R0)
    JMP.NZ  _handle_discard_popped, R2

    ; --------------------------------------------------------------------------
    ; Step C: Forward Complete Instruction Packet to Decode Stage (Core 1)[cite: 2]
    ; Packet: [PC_LO, PC_HI, INST_LO, INST_HI]
    ; --------------------------------------------------------------------------
    ; Push PC_LO
    LOAD16  R2, PC_LO_ADDR
    LD      R3, (R2)
    FIFO_PUSH R3                    ; Push PC_LO[cite: 8]

    ; Push PC_HI
    LOAD16  R2, PC_HI_ADDR
    LD      R3, (R2)
    FIFO_PUSH R3                    ; Push PC_HI[cite: 8]

    ; Push INST_LO
    FIFO_PUSH R1                    ; Push INST_LO[cite: 8]

    ; Push INST_HI
    XCHG    R0                      ; Restore INST_HI from shadow_r[0]
    FIFO_PUSH R0                    ; Push INST_HI[cite: 8]

    ; Notify Decode Stage (Core 1, Trap 1: TRAP_MSG_READY)[cite: 2, 8]
    SEND_MAILBOX CORE_ID_DECODE, TRAP_MSG_READY[cite: 2, 8]

    ; --------------------------------------------------------------------------
    ; Step D: Advance PC by 4 (RV32 standard instruction length)
    ; --------------------------------------------------------------------------
    LOAD16  R0, PC_LO_ADDR
    LD      R1, (R0)
    LOAD16  R2, 4
    ADD     R1, R2                  ; PC_LO += 4
    LD      (R0), R1

    ; Check 16-bit carry-out (if R1 < 4, overflow occurred)
    SUB     R1, R2                  ; Recover previous
    ADD     R1, R2                  ; Recompute
    ; (If PC_LO rolled over past 0xFFFF, increment PC_HI)
    LOAD16  R2, 4
    SUB     R2, R1
    JMP.M   _no_carry, R2           ; If R1 >= 4, no carry
    LOAD16  R0, PC_HI_ADDR
    LD      R1, (R0)
    INC     R1                      ; PC_HI++
    LD      (R0), R1

_no_carry:
    LOAD16  R0, _fetch_loop
    JMP     R0

; ------------------------------------------------------------------------------
; Flush / Discard Handlers
; ------------------------------------------------------------------------------
_handle_discard_popped:
    ; Instruction already popped from FIFO; simply clear flag and resume at new PC
    XCHG    R0                      ; Clean shadow register

_handle_discard:
    LOAD16  R0, FLUSH_FLAG_ADDR
    LD      R1, 0
    LD      (R0), R1                ; Reset flush flag

    ; Loop back immediately to fetch from the newly redirected PC
    LOAD16  R0, _fetch_loop
    JMP     R0
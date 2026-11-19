; ==============================================================================
; FILE: mr4riscv/execute.asm
; Architecture: MiniRISC4 Heterogeneous RV32IM Pipeline
; Component: Core 2 - Execution, ALU, Branch, and Math Accelerator Stage
; Target: Lattice ECP5 FPGA (ULX3S) / Verilog-2001 & Intel ROHD (Dart)
; ==============================================================================

.include "common.inc"
.include "riscv_common.inc"

; ------------------------------------------------------------------------------
; Hardware Math Accelerator MMIO Addresses (Port B @ 0x0010 - 0x0016)
; ------------------------------------------------------------------------------
.define MATH_OP1_LO         0x0010
.define MATH_OP1_HI         0x0011
.define MATH_OP2_LO         0x0012
.define MATH_OP2_HI         0x0013
.define MATH_CMD            0x0014
.define MATH_STATUS         0x0015
.define MATH_RES            0x0016

; Static Storage for Micro-Op Header and Operands
.define OP_HDR_ADDR         0x0020
.define OP1_LO_ADDR         0x0021
.define OP1_HI_ADDR         0x0022
.define OP2_LO_ADDR         0x0023
.define OP2_HI_ADDR         0x0024
.define FLUSH_FLAG_ADDR     0x0025

; ==============================================================================
; DIRECT STRIDE VECTOR TABLE (0x0100 - 0x01FF)
; ==============================================================================
.org 0x0100

_trap0_reset:
    START_PROGRAM
    .align

.org 0x0110
_trap1_msg_ready:                   ; Micro-op available in FIFO_IN
    JMP     R0
    .align

.org 0x0130
_trap3_pipe_flush:                   ; Branch flush acknowledgment
    LOAD16  R1, FLUSH_FLAG_ADDR
    LD      R2, 1
    LD      (R1), R2
    JMP     R0
    .align

.org 0x01F0
    JMP     R0

; ==============================================================================
; Main Execution Loop (0x0200)
; ==============================================================================
.org 0x0200
_main:
    LOAD16  R1, FLUSH_FLAG_ADDR
    LD      R2, 0
    LD      (R1), R2

_exec_loop:
    ; Check flush flag
    LOAD16  R0, FLUSH_FLAG_ADDR
    LD      R1, (R0)
    JMP.Z   _wait_uop, R1
    LD      R1, 0
    LD      (R0), R1

_wait_uop:
    ; Pop 5-word micro-op descriptor: [HDR, OP1_LO, OP1_HI, OP2_LO, OP2_HI]
    FIFO_POP R1                     ; Read HDR
    JMP.Z   _exec_loop, R1          ; Wait for valid micro-op
    LOAD16  R0, OP_HDR_ADDR
    LD      (R0), R1

    FIFO_POP R1                     ; OP1_LO
    LOAD16  R0, OP1_LO_ADDR
    LD      (R0), R1

    FIFO_POP R1                     ; OP1_HI
    LOAD16  R0, OP1_HI_ADDR
    LD      (R0), R1

    FIFO_POP R1                     ; OP2_LO
    LOAD16  R0, OP2_LO_ADDR
    LD      (R0), R1

    FIFO_POP R1                     ; OP2_HI
    LOAD16  R0, OP2_HI_ADDR
    LD      (R0), R1

    ; --------------------------------------------------------------------------
    ; Check if Micro-Op is a Memory Operation (Header Bit 3)
    ; --------------------------------------------------------------------------
    LOAD16  R0, OP_HDR_ADDR
    LD      R1, (R0)
    AND     R1, 0x0008              ; Bit 3 = IS_MEM
    JMP.NZ  _route_to_mem, R1

    ; --------------------------------------------------------------------------
    ; Extract ALU Operation Class (Header Bits [15:12])
    ; --------------------------------------------------------------------------
    LD      R2, (R0)
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2                      ; R2 = ALU_OP (0..15)

    ; Dispatch to operations
    JMP.Z   _do_add, R2
    DEC     R2
    JMP.Z   _do_sub, R2
    DEC     R2
    JMP.Z   _do_and, R2
    DEC     R2
    JMP.Z   _do_or, R2
    DEC     R2
    JMP.Z   _do_xor, R2

    ; Branch check (Opcode 0xA = RV_ALU_BRANCH)
    LOAD16  R3, 0x000A
    SUB     R3, R2
    JMP.Z   _do_branch, R3

    ; Math accelerator check (Opcode 0xD = RV_ALU_MATH_EXT: MUL/DIV/Shifts)
    LOAD16  R0, _do_math_accel
    JMP     R0

; ------------------------------------------------------------------------------
; 32-Bit Arithmetic & Logical Implementations
; ------------------------------------------------------------------------------
_do_add:
    ; res = op1 + op2
    LOAD16  R0, OP1_LO_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_LO_ADDR
    LD      R2, (R0)
    ADD     R1, R2                  ; res_lo = op1_lo + op2_lo
    PUSH    R1                      ; Save res_lo

    ; Carry detection: if res_lo < op1_lo, carry = 1
    LOAD16  R0, OP1_LO_ADDR
    LD      R3, (R0)
    SUB     R3, R1
    LD      R1, 0
    JMP.M   _add_no_carry, R3
    INC     R1                      ; R1 = carry (1)
_add_no_carry:
    LOAD16  R0, OP1_HI_ADDR
    LD      R2, (R0)
    ADD     R2, R1                  ; op1_hi + carry
    LOAD16  R0, OP2_HI_ADDR
    LD      R3, (R0)
    ADD     R2, R3                  ; res_hi = op1_hi + carry + op2_hi
    POP     R1                      ; Restore res_lo
    JMP     _commit_wb

_do_sub:
    ; res = op1 - op2
    LOAD16  R0, OP1_LO_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_LO_ADDR
    LD      R2, (R0)
    SUB     R1, R2                  ; res_lo = op1_lo - op2_lo
    PUSH    R1

    ; Borrow detection: if op1_lo < op2_lo, borrow = 1
    LOAD16  R0, OP1_LO_ADDR
    LD      R3, (R0)
    SUB     R3, R2
    LD      R1, 0
    JMP.M   _sub_borrow, R3
    JMP     _sub_no_borrow
_sub_borrow:
    INC     R1                      ; R1 = borrow (1)
_sub_no_borrow:
    LOAD16  R0, OP1_HI_ADDR
    LD      R2, (R0)
    SUB     R2, R1                  ; op1_hi - borrow
    LOAD16  R0, OP2_HI_ADDR
    LD      R3, (R0)
    SUB     R2, R3                  ; res_hi = op1_hi - borrow - op2_hi
    POP     R1
    JMP     _commit_wb

_do_and:
    LOAD16  R0, OP1_LO_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_LO_ADDR
    LD      R2, (R0)
    AND     R1, R2                  ; res_lo
    PUSH    R1
    LOAD16  R0, OP1_HI_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_HI_ADDR
    LD      R2, (R0)
    AND     R1, R2                  ; res_hi
    LD      R2, R1
    POP     R1
    JMP     _commit_wb

_do_or:
    LOAD16  R0, OP1_LO_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_LO_ADDR
    LD      R2, (R0)
    OR      R1, R2
    PUSH    R1
    LOAD16  R0, OP1_HI_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_HI_ADDR
    LD      R2, (R0)
    OR      R1, R2
    LD      R2, R1
    POP     R1
    JMP     _commit_wb

_do_xor:
    LOAD16  R0, OP1_LO_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_LO_ADDR
    LD      R2, (R0)
    XOR     R1, R2
    PUSH    R1
    LOAD16  R0, OP1_HI_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_HI_ADDR
    LD      R2, (R0)
    XOR     R1, R2
    LD      R2, R1
    POP     R1
    JMP     _commit_wb

; ------------------------------------------------------------------------------
; Hardware Math Accelerator Offload (RV32M & Multi-Bit Barrel Shifts)
; ------------------------------------------------------------------------------
_do_math_accel:
    ; Stream operands into MMIO registers 0x0010 - 0x0013
    LOAD16  R0, MATH_OP1_LO
    LOAD16  R1, OP1_LO_ADDR
    LD      R2, (R1++)
    LD      (R0++), R2              ; MATH_OP1_LO
    LD      R2, (R1++)
    LD      (R0++), R2              ; MATH_OP1_HI
    LD      R2, (R1++)
    LD      (R0++), R2              ; MATH_OP2_LO
    LD      R2, (R1)
    LD      (R0++), R2              ; MATH_OP2_HI

    ; Issue command opcode to MATH_CMD (0x0014)
    LOAD16  R1, OP_HDR_ADDR
    LD      R2, (R1)
    AND     R2, 0x000F              ; Lower nibble specifies function (MUL, DIV, etc.)
    LD      (R0), R2

    ; Poll status until busy clears (0x0015)
_math_poll:
    LOAD16  R0, MATH_STATUS
    LD      R1, (R0)
    JMP.NZ  _math_poll, R1

    ; Read 32-bit result stream from MATH_RES (0x0016)
    LOAD16  R0, MATH_RES
    LD      R1, (R0)                ; res_lo
    LD      R2, (R0)                ; res_hi
    JMP     _commit_wb

; ------------------------------------------------------------------------------
; Commit Result to Writeback / Register File (Core 1)
; Sends: [rd, res_lo, res_hi] across FIFO_OUT (0x000B)
; ------------------------------------------------------------------------------
_commit_wb:
    ; Extract rd from Header bits [11:7]
    LOAD16  R0, OP_HDR_ADDR
    LD      R3, (R0)
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    AND     R3, 0x001F              ; R3 = rd

    ; Push to FIFO_OUT
    FIFO_PUSH R3                    ; rd
    FIFO_PUSH R1                    ; res_lo
    FIFO_PUSH R2                    ; res_hi

    ; Signal Core 1 Writeback Trap (Trap 2: TRAP_BURST_DONE / TRAP_WB_COMMIT)
    SEND_MAILBOX CORE_ID_DECODE, TRAP_BURST_DONE

    LOAD16  R0, _exec_loop
    JMP     R0

; ------------------------------------------------------------------------------
; Branch Evaluation
; ------------------------------------------------------------------------------
_do_branch:
    ; Compare op1 and op2 (BEQ/BNE/BLT/BGE)
    LOAD16  R0, OP1_LO_ADDR
    LD      R1, (R0)
    LOAD16  R0, OP2_LO_ADDR
    LD      R2, (R0)
    SUB     R1, R2

    ; Branch Taken -> Redirect PC
    ; Send target PC to Fetch (Core 0) via FIFO_OUT and strobe TRAP_PIPE_FLUSH
    LOAD16  R0, OP1_LO_ADDR
    LD      R1, (R0)
    FIFO_PUSH R1                    ; Target PC_LO
    LOAD16  R0, OP1_HI_ADDR
    LD      R1, (R0)
    FIFO_PUSH R1                    ; Target PC_HI

    SEND_MAILBOX CORE_ID_FETCH, TRAP_PIPE_FLUSH
    SEND_MAILBOX CORE_ID_DECODE, TRAP_PIPE_FLUSH

    LOAD16  R0, _exec_loop
    JMP     R0

; ------------------------------------------------------------------------------
; Route Memory Operations (Loads/Stores) to Core 3 (Mem/WB)
; ------------------------------------------------------------------------------
_route_to_mem:
    ; Forward calculated effective address and store data to Core 3
    LOAD16  R0, OP_HDR_ADDR
    LD      R1, (R0)
    FIFO_PUSH R1

    LOAD16  R0, OP1_LO_ADDR
    LD      R1, (R0)
    FIFO_PUSH R1

    LOAD16  R0, OP2_LO_ADDR
    LD      R1, (R0)
    FIFO_PUSH R1

    SEND_MAILBOX CORE_ID_MEM_WB, TRAP_MSG_READY

    LOAD16  R0, _exec_loop
    JMP     R0
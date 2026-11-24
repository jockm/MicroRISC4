; ==============================================================================
; FILE: mr4riscv/decode.asm
; Architecture: MicroRISC4 Heterogeneous RV32IM Pipeline
; Component: Core 1 - Instruction Decode, Register File, and Issue Stage
; Target: Lattice ECP5 FPGA (ULX3S) / Verilog-2001 & Intel ROHD (Dart)
; Description:
;   Maintains the 32-entry RV32 architectural register file (x0..x31), decodes
;   RV32I and RV32M instructions, unpacks immediates, and issues micro-ops
;   to Core 2 (Execute)[cite: 2, 10].
; ==============================================================================

.include "common.inc"
.include "riscv_common.inc"

; ------------------------------------------------------------------------------
; Memory Addresses for Decoded Fields & Scratch
; ------------------------------------------------------------------------------
.define RF_BASE_ADDR        0x0300  ; x0..x31 base address (64 words)
.define CURR_PC_LO          0x0020  ; PC of instruction being decoded
.define CURR_PC_HI          0x0021
.define INST_LO_ADDR        0x0022  ; inst[15:0]
.define INST_HI_ADDR        0x0023  ; inst[31:16]
.define IMM_LO_ADDR         0x0024  ; Unpacked 32-bit immediate [15:0]
.define IMM_HI_ADDR         0x0025  ; Unpacked 32-bit immediate [31:16]
.define FLUSH_FLAG_ADDR     0x0026  ; Pipeline flush flag

; ==============================================================================
; DIRECT STRIDE VECTOR TABLE (0x0100 - 0x01FF)[cite: 8]
; ==============================================================================
.org 0x0100

_trap0_reset:
    START_PROGRAM                   ; Initialize stacks and enter _main[cite: 8]
    .align

.org 0x0110
_trap1_msg_ready:                   ; Fetch pushed new instruction packet[cite: 8]
    JMP     R0
    .align

.org 0x0120
_trap2_wb_commit:                   ; Writeback stage pushing rd value[cite: 8]
    ; Reads: [rd_num, val_lo, val_hi] from FIFO_IN and updates register file[cite: 8]
    XCHG    R2
    XCHG    R3
    LD      R2, 10                  ; FIFO_IN_ADDR[cite: 8]
    LD      R3, (R2)                ; R3 = rd index (0..31)[cite: 8]
    JMP.Z   _wb_discard_x0, R3      ; x0 is read-only zero!

    SHIFT.L R3                      ; R3 = rd * 2
    LOAD16  R1, RF_BASE_ADDR
    ADD     R1, R3                  ; R1 = &RF[rd]

    LD      R3, (R2)                ; R3 = val_lo[cite: 8]
    LD      (R1++), R3              ; RF[rd].lo = val_lo
    LD      R3, (R2)                ; R3 = val_hi[cite: 8]
    LD      (R1), R3                ; RF[rd].hi = val_hi
    JMP     _wb_done

_wb_discard_x0:
    LD      R3, (R2)                ; Discard dummy val_lo[cite: 8]
    LD      R3, (R2)                ; Discard dummy val_hi[cite: 8]

_wb_done:
    XCHG    R3
    XCHG    R2
    JMP     R0
    .align

.org 0x0130
_trap3_pipe_flush:                   ; Flush strobe from Execute stage[cite: 8]
    LOAD16  R1, FLUSH_FLAG_ADDR
    LD      R2, 1
    LD      (R1), R2
    JMP     R0
    .align

.org 0x01F0
    JMP     R0

; ==============================================================================
; Main Decode Loop (0x0200)
; ==============================================================================
.org 0x0200
_main:
    ; 1. Zero out entire RV32 Register File (64 words)
    LOAD16  R1, RF_BASE_ADDR
    LD      R2, 0
    LD      R3, 64
_init_rf_loop:
    LD      (R1++), R2
    DEC     R3
    JMP.NZ  _init_rf_loop, R3

    ; 2. Clear Flush Flag
    LOAD16  R1, FLUSH_FLAG_ADDR
    LD      (R1), R2

_decode_loop:
    ; Check and clear flush flag
    LOAD16  R0, FLUSH_FLAG_ADDR
    LD      R1, (R0)
    JMP.Z   _wait_inst, R1
    LD      R1, 0
    LD      (R0), R1

_wait_inst:
    ; --------------------------------------------------------------------------
    ; Pop 4-word instruction packet from Core 0: [PC_LO, PC_HI, INST_LO, INST_HI][cite: 8]
    ; --------------------------------------------------------------------------
    FIFO_POP R1                     ; Read PC_LO (0 if empty)[cite: 8]
    JMP.Z   _decode_loop, R1        ; Wait for packet
    LOAD16  R0, CURR_PC_LO
    LD      (R0), R1

    FIFO_POP R1                     ; PC_HI[cite: 8]
    LOAD16  R0, CURR_PC_HI
    LD      (R0), R1

    FIFO_POP R1                     ; INST_LO (inst[15:0])[cite: 8]
    LOAD16  R0, INST_LO_ADDR
    LD      (R0), R1

    FIFO_POP R2                     ; INST_HI (inst[31:16])[cite: 8]
    LOAD16  R0, INST_HI_ADDR
    LD      (R0), R2

    ; --------------------------------------------------------------------------
    ; Extract Opcode (inst[6:0] from INST_LO)
    ; --------------------------------------------------------------------------
    LD      R3, R1
    AND     R3, 0x007F              ; R3 = Opcode

    ; --------------------------------------------------------------------------
    ; Extract rd (inst[11:7] from INST_LO)
    ; --------------------------------------------------------------------------
    LD      R0, R1
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0                      ; R0 = INST_LO >> 7
    AND     R0, 0x001F              ; R0 = rd (0..31)
    PUSH    R0                      ; Save rd on argument stack

    ; --------------------------------------------------------------------------
    ; Extract rs1 (inst[19:15]: bits [15] of INST_LO and [19:16] of INST_HI)
    ; --------------------------------------------------------------------------
    ; Low bit of rs1 from INST_LO[15]
    LD      R0, R1
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0
    SHIFT.R R0                      ; R0 = INST_LO[15]
    ; Upper 4 bits of rs1 from INST_HI[3:0]
    LD      R1, R2
    AND     R1, 0x000F
    SHIFT.L R1                      ; (INST_HI[3:0] << 1)
    OR      R0, R1                  ; R0 = rs1 index (0..31)

    ; Read rs1 32-bit value from Register File into shadow_r[0]:shadow_r[1]
    CALL    _read_rs_reg            ; In: R0 = reg_id -> Out: R1=lo, R2=hi
    XCHG    R1                      ; Save rs1_lo to shadow_r[1]
    XCHG    R2                      ; Save rs1_hi to shadow_r[2]

    ; --------------------------------------------------------------------------
    ; Extract rs2 (inst[24:20] from INST_HI[8:4])
    ; --------------------------------------------------------------------------
    LOAD16  R0, INST_HI_ADDR
    LD      R1, (R0)
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1                      ; R1 = INST_HI >> 4
    AND     R1, 0x001F              ; R1 = rs2 index (0..31)
    LD      R0, R1
    CALL    _read_rs_reg            ; Out: R1=rs2_lo, R2=rs2_hi

    ; --------------------------------------------------------------------------
    ; Decode Opcode Family & Unpack Immediate
    ; --------------------------------------------------------------------------
    ; 0x33: R-type (ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND, and RV32M)
    LOAD16  R0, 0x33
    SUB     R0, R3
    JMP.Z   _emit_rtype, R0

    ; 0x13: I-type ALU (ADDI, SLTI, XORI, ORI, ANDI, SLLI, SRLI, SRAI)
    LOAD16  R0, 0x13
    SUB     R0, R3
    JMP.Z   _emit_itype, R0

    ; 0x03: Load (LB, LH, LW, LBU, LHU)
    LOAD16  R0, 0x03
    SUB     R0, R3
    JMP.Z   _emit_load, R0

    ; 0x23: Store (SB, SH, SW)
    LOAD16  R0, 0x23
    SUB     R0, R3
    JMP.Z   _emit_store, R0

    ; 0x63: Branch (BEQ, BNE, BLT, BGE, BLTU, BGEU)
    LOAD16  R0, 0x63
    SUB     R0, R3
    JMP.Z   _emit_branch, R0

    ; 0x6F: JAL / 0x67: JALR / 0x37: LUI / 0x17: AUIPC
    LOAD16  R0, _emit_generic_imm
    JMP     R0

; ------------------------------------------------------------------------------
; R-Type Dispatch (Opcode 0x33)
; ------------------------------------------------------------------------------
_emit_rtype:
    ; Word 0: Micro-Op Header: [ALU_OP[15:12], RD[11:7], FLAGS[6:0]]
    POP     R0                      ; Restore rd
    SHIFT.L R0
    SHIFT.L R0
    SHIFT.L R0
    SHIFT.L R0
    SHIFT.L R0
    SHIFT.L R0
    SHIFT.L R0                      ; rd << 7

    ; Extract funct3 from INST_LO[14:12]
    LOAD16  R3, INST_LO_ADDR
    LD      R3, (R3)
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3                      ; R3 = funct3
    AND     R3, 0x0007
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3                      ; funct3 << 12
    OR      R0, R3                  ; Combine ALU_OP and RD into Header

    ; Push 5-word micro-op descriptor to Execute (Core 2) over FIFO_OUT (0x000B)
    FIFO_PUSH R0                    ; Word 0: Header[cite: 8]

    ; Push rs1 value (retrieved from shadow registers)
    XCHG    R1                      ; Restore rs1_lo
    FIFO_PUSH R1[cite: 8]
    XCHG    R2                      ; Restore rs1_hi
    FIFO_PUSH R2[cite: 8]

    ; Push rs2 value
    FIFO_PUSH R1                    ; Word 3: rs2_lo[cite: 8]
    FIFO_PUSH R2                    ; Word 4: rs2_hi[cite: 8]

    ; Signal Execute Core (Core 2, Trap 1: TRAP_MSG_READY)[cite: 2, 8]
    SEND_MAILBOX CORE_ID_EXEC, TRAP_MSG_READY[cite: 2, 8]

    LOAD16  R0, _decode_loop
    JMP     R0

; ------------------------------------------------------------------------------
; I-Type Dispatch (Opcode 0x13): Imm unpacked from inst[31:20]
; ------------------------------------------------------------------------------
_emit_itype:
    ; Extract sign-extended 12-bit immediate from INST_HI[15:4]
    LOAD16  R3, INST_HI_ADDR
    LD      R3, (R3)
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3
    SHIFT.R R3                      ; R3 = inst[31:20]
    AND     R3, 0x0FFF
    ; Sign-extend bit 11 into upper bits
    LOAD16  R0, 0x0800
    AND     R0, R3
    JMP.Z   _itype_pos, R0
    OR      R3, 0xF000              ; Negative 16-bit
    LOAD16  R0, 0xFFFF              ; imm_hi = 0xFFFF
    JMP     _itype_done
_itype_pos:
    LOAD16  R0, 0x0000              ; imm_hi = 0x0000
_itype_done:
    ; Form Micro-Op Header with Bit 4 = 1 (Uses Immediate)
    POP     R1                      ; rd
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    OR      R1, 0x0010              ; Set HAS_IMM bit 4
    FIFO_PUSH R1                    ; Word 0: Header[cite: 8]

    ; Push rs1
    XCHG    R1
    FIFO_PUSH R1[cite: 8]
    XCHG    R2
    FIFO_PUSH R2[cite: 8]

    ; Push Immediate
    FIFO_PUSH R3                    ; Word 3: imm_lo[cite: 8]
    FIFO_PUSH R0                    ; Word 4: imm_hi[cite: 8]

    SEND_MAILBOX CORE_ID_EXEC, TRAP_MSG_READY[cite: 2, 8]
    LOAD16  R0, _decode_loop
    JMP     R0

; ------------------------------------------------------------------------------
; Helper: Read 32-bit register from RF. Input: R0 = reg_id (0..31)
; Returns: R1 = val_lo, R2 = val_hi
; ------------------------------------------------------------------------------
_read_rs_reg:
    ; If reg_id == 0, return 0x00000000
    JMP.Z   _read_x0, R0
    SHIFT.L R0                      ; offset = reg_id * 2
    LOAD16  R1, RF_BASE_ADDR
    ADD     R1, R0                  ; R1 = &RF[reg_id]
    LD      R2, (R1++)              ; R2 = val_lo
    LD      R1, (R1)                ; R1 = val_hi
    XCHG    R1                      ; R1 = val_lo, R2 = val_hi
    RET
_read_x0:
    LD      R1, 0
    LD      R2, 0
    RET

_emit_load:
_emit_store:
_emit_branch:
_emit_generic_imm:
    ; Default: Issue control packet to Core 2/Core 3
    POP     R0                      ; Clean rd stack
    LOAD16  R0, _decode_loop
    JMP     R0
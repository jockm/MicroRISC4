; ==============================================================================
; FILE: M4R_LIB32.asm
; Description:
;   Standard 32-bit Math, Logic, Shift, and Relational Library for MiniRISC4.
;   Operates via the Argument Stack (pointer at RAM address 0x0005) and Return
;   Stack (pointer at RAM address 0x0004).
;
; 32-Bit Representation & Stack Convention:
;   - A 32-bit integer consists of two 16-bit words:
;       High word: bits [31:16]
;       Low word:  bits [15:0]
;   - Values are pushed LOW word first, then HIGH word.
;     Therefore, upon function entry:
;       First pop (TOS): High word
;       Second pop:      Low word
;   - For binary operations (A op B):
;       Caller pushes A (low then high), then B (low then high).
;       Callee pops: B_hi, B_lo, A_hi, A_lo.
;       Result pushed: Res_lo, then Res_hi (Res_hi on top).
; ==============================================================================

.include "common.inc"

; ==============================================================================
; SUBROUTINE: ADD32
; Stack In : [..., A_lo, A_hi, B_lo, B_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
ADD32:
    RPUSH   R0

    APOP    R2                  ; R2 = B_hi
    APOP    R3                  ; R3 = B_lo
    XCHG    R2                  ; shadow_r[2] = B_hi
    XCHG    R3                  ; shadow_r[3] = B_lo

    APOP    R2                  ; R2 = A_hi
    APOP    R1                  ; R1 = A_lo

    XCHG    R3                  ; R3 = B_lo, shadow_r[3] = scratch
    ADD     R1, R3              ; R1 = Res_lo

    XCHG    R0
    LD      R0, R1
    XOR     R0, R3
    LOAD16  R3, _ADD32_DIFF_SIGNS
    JMP.M   R3, R0
    XCHG    R0

    XCHG    R0
    LD      R0, R1
    SUB     R0, R3
    LOAD16  R3, _ADD32_CARRY
    JMP.M   R3, R0
    XCHG    R0
    LOAD16  R0, _ADD32_NO_CARRY
    JMP     R0

_ADD32_DIFF_SIGNS:
    XCHG    R0
    XCHG    R3
    LOAD16  R0, _ADD32_CARRY
    JMP.M   R0, R3
    XCHG    R3
    LOAD16  R0, _ADD32_NO_CARRY
    JMP     R0

_ADD32_CARRY:
    XCHG    R0
    INC     R2                  ; A_hi += carry (1)

_ADD32_NO_CARRY:
    XCHG    R2                  ; R2 = B_hi, shadow_r[2] = A_hi
    XCHG    R3
    LD      R3, R2              ; R3 = B_hi
    XCHG    R2                  ; R2 = A_hi
    ADD     R2, R3              ; R2 = Res_hi

    APUSH   R1                  ; Push Res_lo
    APUSH   R2                  ; Push Res_hi
    RRET

; ==============================================================================
; SUBROUTINE: SUB32
; Stack In : [..., A_lo, A_hi, B_lo, B_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
SUB32:
    RPUSH   R0

    APOP    R2                  ; R2 = B_hi
    APOP    R3                  ; R3 = B_lo
    XCHG    R2                  ; shadow_r[2] = B_hi
    XCHG    R3                  ; shadow_r[3] = B_lo

    APOP    R2                  ; R2 = A_hi
    APOP    R1                  ; R1 = A_lo

    XCHG    R3                  ; R3 = B_lo
    XCHG    R0
    LD      R0, R1
    XOR     R0, R3
    LOAD16  R3, _SUB32_DIFF_SIGNS
    JMP.M   R3, R0
    XCHG    R0

    XCHG    R0
    LD      R0, R1
    SUB     R0, R3
    LOAD16  R3, _SUB32_BORROW
    JMP.M   R3, R0
    XCHG    R0
    LOAD16  R0, _SUB32_NO_BORROW
    JMP     R0

_SUB32_DIFF_SIGNS:
    XCHG    R0
    LOAD16  R0, _SUB32_NO_BORROW
    JMP.M   R0, R1
    LOAD16  R0, _SUB32_BORROW
    JMP     R0

_SUB32_BORROW:
    DEC     R2                  ; A_hi -= borrow (1)

_SUB32_NO_BORROW:
    SUB     R1, R3              ; R1 = Res_lo = A_lo - B_lo

    XCHG    R2                  ; R2 = B_hi, shadow_r[2] = A_hi
    XCHG    R3
    LD      R3, R2              ; R3 = B_hi
    XCHG    R2                  ; R2 = A_hi
    SUB     R2, R3              ; R2 = Res_hi

    APUSH   R1                  ; Push Res_lo
    APUSH   R2                  ; Push Res_hi
    RRET

; ==============================================================================
; SUBROUTINE: NOT32
; Stack In : [..., A_lo, A_hi]
; Stack Out: [..., ~A_lo, ~A_hi]
; ==============================================================================
NOT32:
    RPUSH   R0
    APOP    R2                  ; R2 = A_hi
    APOP    R1                  ; R1 = A_lo
    NOT     R1                  ; R1 = ~A_lo
    NOT     R2                  ; R2 = ~A_hi
    APUSH   R1                  ; Push ~A_lo
    APUSH   R2                  ; Push ~A_hi
    RRET

; ==============================================================================
; SUBROUTINE: NEG32
; Stack In : [..., A_lo, A_hi]
; Stack Out: [..., -A_lo, -A_hi]
; ==============================================================================
NEG32:
    RPUSH   R0
    APOP    R2                  ; A_hi
    APOP    R1                  ; A_lo
    NOT     R1
    NOT     R2
    INC     R1
    LOAD16  R0, _NEG32_DONE
    JMP.Z   R0, R1
    INC     R2
_NEG32_DONE:
    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: AND32
; Stack In : [..., A_lo, A_hi, B_lo, B_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
AND32:
    RPUSH   R0
    APOP    R2                  ; B_hi
    APOP    R3                  ; B_lo
    XCHG    R2
    XCHG    R3
    APOP    R2                  ; A_hi
    APOP    R1                  ; A_lo

    XCHG    R3                  ; R3 = B_lo
    AND     R1, R3              ; Res_lo = A_lo & B_lo
    XCHG    R2                  ; R2 = B_hi, shadow_r[2] = A_hi
    XCHG    R3
    LD      R3, R2
    XCHG    R2
    AND     R2, R3              ; Res_hi = A_hi & B_hi

    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: OR32
; Stack In : [..., A_lo, A_hi, B_lo, B_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
OR32:
    RPUSH   R0
    APOP    R2                  ; B_hi
    APOP    R3                  ; B_lo
    XCHG    R2
    XCHG    R3
    APOP    R2                  ; A_hi
    APOP    R1                  ; A_lo

    XCHG    R3                  ; R3 = B_lo
    OR      R1, R3              ; Res_lo = A_lo | B_lo
    XCHG    R2
    XCHG    R3
    LD      R3, R2
    XCHG    R2
    OR      R2, R3              ; Res_hi = A_hi | B_hi

    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: XOR32
; Stack In : [..., A_lo, A_hi, B_lo, B_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
XOR32:
    RPUSH   R0
    APOP    R2                  ; B_hi
    APOP    R3                  ; B_lo
    XCHG    R2
    XCHG    R3
    APOP    R2                  ; A_hi
    APOP    R1                  ; A_lo

    XCHG    R3                  ; R3 = B_lo
    XOR     R1, R3              ; Res_lo = A_lo ^ B_lo
    XCHG    R2
    XCHG    R3
    LD      R3, R2
    XCHG    R2
    XOR     R2, R3              ; Res_hi = A_hi ^ B_hi

    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: SHL32 / ASL32
; Stack In : [..., A_lo, A_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
SHL32:
ASL32:
    RPUSH   R0
    APOP    R2                  ; R2 = A_hi
    APOP    R1                  ; R1 = A_lo

    SHIFT.L R2                  ; A_hi <<= 1
    LOAD16  R0, _SHL32_NO_CARRY
    JMP.M   R0, R1
    INC     R2
_SHL32_NO_CARRY:
    SHIFT.L R1                  ; A_lo <<= 1

    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: SHR32
; Stack In : [..., A_lo, A_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
SHR32:
    RPUSH   R0
    APOP    R2                  ; R2 = A_hi
    APOP    R1                  ; R1 = A_lo

    SHIFT.R R1                  ; A_lo >>= 1

    ROT.R   R2
    LOAD16  R0, _SHR32_CARRY
    JMP.M   R0, R2

    ROT.L   R2
    SHIFT.R R2                  ; A_hi >>= 1
    LOAD16  R0, _SHR32_DONE
    JMP     R0

_SHR32_CARRY:
    ROT.L   R2
    SHIFT.R R2                  ; A_hi >>= 1
    XCHG    R0
    LOAD16  R0, 0x8000
    OR      R1, R0
    XCHG    R0

_SHR32_DONE:
    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: ASR32
; Stack In : [..., A_lo, A_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
ASR32:
    RPUSH   R0
    APOP    R2                  ; R2 = A_hi
    APOP    R1                  ; R1 = A_lo

    SHIFT.R R1                  ; A_lo >>= 1

    ROT.R   R2
    LOAD16  R0, _ASR32_CARRY
    JMP.M   R0, R2

    ROT.L   R2
    SHIFT.AR R2                 ; A_hi >>= 1 with sign preservation
    LOAD16  R0, _ASR32_DONE
    JMP     R0

_ASR32_CARRY:
    ROT.L   R2
    SHIFT.AR R2                 ; A_hi >>= 1 with sign preservation
    XCHG    R0
    LOAD16  R0, 0x8000
    OR      R1, R0
    XCHG    R0

_ASR32_DONE:
    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: ROTL32
; Stack In : [..., A_lo, A_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
ROTL32:
    RPUSH   R0
    APOP    R2                  ; R2 = A_hi
    APOP    R1                  ; R1 = A_lo

    LOAD16  R0, _ROTL32_MSB1
    JMP.M   R0, R2
    LD0     R3                  ; Carry to low word = 0
    LOAD16  R0, _ROTL32_SHIFT
    JMP     R0

_ROTL32_MSB1:
    LD0     R3
    INC     R3                  ; Carry to low word = 1

_ROTL32_SHIFT:
    SHIFT.L R2                  ; A_hi <<= 1
    LOAD16  R0, _ROTL32_NO_MID
    JMP.M   R0, R1
    INC     R2
_ROTL32_NO_MID:
    SHIFT.L R1                  ; A_lo <<= 1
    OR      R1, R3

    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: ROTR32
; Stack In : [..., A_lo, A_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
ROTR32:
    RPUSH   R0
    APOP    R2                  ; R2 = A_hi
    APOP    R1                  ; R1 = A_lo

    ROT.R   R1
    LOAD16  R0, _ROTR32_LSB1
    JMP.M   R0, R1
    LD0     R3                  ; Carry to high word = 0
    ROT.L   R1
    LOAD16  R0, _ROTR32_SHIFT
    JMP     R0

_ROTR32_LSB1:
    ROT.L   R1
    XCHG    R0
    LOAD16  R0, 0x8000
    LD      R3, R0
    XCHG    R0

_ROTR32_SHIFT:
    SHIFT.R R1                  ; A_lo >>= 1

    ROT.R   R2
    LOAD16  R0, _ROTR32_MID1
    JMP.M   R0, R2

    ROT.L   R2
    SHIFT.R R2                  ; A_hi >>= 1
    OR      R2, R3
    LOAD16  R0, _ROTR32_DONE
    JMP     R0

_ROTR32_MID1:
    ROT.L   R2
    SHIFT.R R2                  ; A_hi >>= 1
    OR      R2, R3
    XCHG    R0
    LOAD16  R0, 0x8000
    OR      R1, R0
    XCHG    R0

_ROTR32_DONE:
    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: MULT32
; Stack In : [..., A_lo, A_hi, B_lo, B_hi]
; Stack Out: [..., Res_lo, Res_hi]
; ==============================================================================
MULT32:
    RPUSH   R0

    APOP    R2                  ; B_hi
    APOP    R1                  ; B_lo
    LOAD16  R0, 7
    LD      (R0), R2
    DEC     R0
    LD      (R0), R1            ; [0x0006] = B_lo

    APOP    R2                  ; A_hi
    APOP    R1                  ; A_lo
    LOAD16  R0, 9
    LD      (R0), R2
    DEC     R0
    LD      (R0), R1            ; [0x0008] = A_lo

    LD0     R1
    LOAD16  R0, 10
    LD      (R0), R1
    INC     R0
    LD      (R0), R1

    XCHG    R0
    LOAD16  R0, 32
    XCHG    R0

_MULT32_LOOP:
    LOAD16  R0, 6
    LD      R1, (R0)            ; R1 = B_lo
    ROT.R   R1
    LOAD16  R0, _MULT32_ADD
    JMP.M   R0, R1
    LOAD16  R0, _MULT32_SHIFT
    JMP     R0

_MULT32_ADD:
    LOAD16  R0, 10
    LD      R1, (R0)            ; Res_lo
    INC     R0
    LD      R2, (R0)            ; Res_hi
    APUSH   R1
    APUSH   R2

    LOAD16  R0, 8
    LD      R1, (R0)            ; A_lo
    INC     R0
    LD      R2, (R0)            ; A_hi
    APUSH   R1
    APUSH   R2

    RCALL   ADD32
    APOP    R2                  ; Updated Res_hi
    APOP    R1                  ; Updated Res_lo
    LOAD16  R0, 10
    LD      (R0), R1
    INC     R0
    LD      (R0), R2

_MULT32_SHIFT:
    LOAD16  R0, 8
    LD      R1, (R0)
    INC     R0
    LD      R2, (R0)
    APUSH   R1
    APUSH   R2
    RCALL   SHL32
    APOP    R2
    APOP    R1
    LOAD16  R0, 8
    LD      (R0), R1
    INC     R0
    LD      (R0), R2

    LOAD16  R0, 6
    LD      R1, (R0)
    INC     R0
    LD      R2, (R0)
    APUSH   R1
    APUSH   R2
    RCALL   SHR32
    APOP    R2
    APOP    R1
    LOAD16  R0, 6
    LD      (R0), R1
    INC     R0
    LD      (R0), R2

    XCHG    R0
    DEC     R0
    LOAD16  R1, _MULT32_EXIT
    JMP.Z   R1, R0
    XCHG    R0
    LOAD16  R0, _MULT32_LOOP
    JMP     R0

_MULT32_EXIT:
    XCHG    R0

    LOAD16  R0, 10
    LD      R1, (R0)            ; Res_lo
    INC     R0
    LD      R2, (R0)            ; Res_hi
    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; HELPER: DIVMOD32_CORE
; Stack In : [..., N_lo, N_hi, D_lo, D_hi]
; Stack Out: [..., Rem_lo, Rem_hi, Quot_lo, Quot_hi]
; ==============================================================================
DIVMOD32_CORE:
    RPUSH   R0

    APOP    R2                  ; D_hi
    APOP    R1                  ; D_lo
    LOAD16  R0, 7
    LD      (R0), R2            ; [0x0007] = D_hi
    DEC     R0
    LD      (R0), R1            ; [0x0006] = D_lo

    APOP    R2                  ; N_hi
    APOP    R1                  ; N_lo
    LOAD16  R0, 9
    LD      (R0), R2            ; [0x0009] = N_hi
    DEC     R0
    LD      (R0), R1            ; [0x0008] = N_lo

    LD0     R1
    LOAD16  R0, 10
    LD      (R0), R1
    INC     R0
    LD      (R0), R1

    XCHG    R0
    LOAD16  R0, 32
    XCHG    R0

_DIV32_BIT_LOOP:
    LOAD16  R0, 10
    LD      R1, (R0)
    INC     R0
    LD      R2, (R0)
    APUSH   R1
    APUSH   R2
    RCALL   SHL32
    APOP    R2
    APOP    R1

    LOAD16  R0, 9
    LD      R3, (R0)            ; N_hi
    LOAD16  R0, _DIV32_NO_CARRY
    JMP.M   R0, R3
    INC     R1                  ; Rem_lo |= 1
_DIV32_NO_CARRY:
    LOAD16  R0, 10
    LD      (R0), R1
    INC     R0
    LD      (R0), R2

    LOAD16  R0, 8
    LD      R1, (R0)
    INC     R0
    LD      R2, (R0)
    APUSH   R1
    APUSH   R2
    RCALL   SHL32
    APOP    R2
    APOP    R1
    LOAD16  R0, 8
    LD      (R0), R1
    INC     R0
    LD      (R0), R2

    LOAD16  R0, 10
    LD      R1, (R0)
    INC     R0
    LD      R2, (R0)
    APUSH   R1
    APUSH   R2
    LOAD16  R0, 6
    LD      R1, (R0)
    INC     R0
    LD      R2, (R0)
    APUSH   R1
    APUSH   R2
    RCALL   CMP32_GE
    APOP    R1
    LOAD16  R0, _DIV32_DEC
    JMP.Z   R0, R1

    LOAD16  R0, 10
    LD      R1, (R0)
    INC     R0
    LD      R2, (R0)
    APUSH   R1
    APUSH   R2
    LOAD16  R0, 6
    LD      R1, (R0)
    INC     R0
    LD      R2, (R0)
    APUSH   R1
    APUSH   R2
    RCALL   SUB32
    APOP    R2
    APOP    R1
    LOAD16  R0, 10
    LD      (R0), R1
    INC     R0
    LD      (R0), R2

    LOAD16  R0, 8
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1

_DIV32_DEC:
    XCHG    R0
    DEC     R0
    LOAD16  R1, _DIV32_EXIT
    JMP.Z   R1, R0
    XCHG    R0
    LOAD16  R0, _DIV32_BIT_LOOP
    JMP     R0

_DIV32_EXIT:
    XCHG    R0

    LOAD16  R0, 10
    LD      R1, (R0)            ; Rem_lo
    INC     R0
    LD      R2, (R0)            ; Rem_hi
    APUSH   R1
    APUSH   R2

    LOAD16  R0, 8
    LD      R1, (R0)            ; Quot_lo
    INC     R0
    LD      R2, (R0)            ; Quot_hi
    APUSH   R1
    APUSH   R2
    RRET

; ==============================================================================
; SUBROUTINE: DIV32
; Stack In : [..., Dividend_lo, Dividend_hi, Divisor_lo, Divisor_hi]
; Stack Out: [..., Quotient_lo, Quotient_hi]
; ==============================================================================
DIV32:
    RPUSH   R0
    RCALL   DIVMOD32_CORE
    APOP    R2                  ; Quot_hi
    APOP    R1                  ; Quot_lo
    APOP    R0                  ; Discard Rem_hi
    APOP    R0                  ; Discard Rem_lo
    APUSH   R1                  ; Push Quot_lo
    APUSH   R2                  ; Push Quot_hi
    RRET

; ==============================================================================
; SUBROUTINE: MOD32
; Stack In : [..., Dividend_lo, Dividend_hi, Divisor_lo, Divisor_hi]
; Stack Out: [..., Remainder_lo, Remainder_hi]
; ==============================================================================
MOD32:
    RPUSH   R0
    RCALL   DIVMOD32_CORE
    APOP    R0                  ; Discard Quot_hi
    APOP    R0                  ; Discard Quot_lo
    RRET

; ==============================================================================
; 32-BIT UNSIGNED COMPARISONS: CMP32_EQ, CMP32_LT, CMP32_GE
; ==============================================================================
CMP32_EQ:
    RPUSH   R0
    APOP    R2                  ; B_hi
    APOP    R3                  ; B_lo
    XCHG    R2
    XCHG    R3
    APOP    R2                  ; A_hi
    APOP    R1                  ; A_lo

    SUB     R2, R3              ; A_hi - B_hi
    LOAD16  R0, _CMP32_NEQ
    JMP.Z   R0, R2
    LOAD16  R1, 0
    LOAD16  R0, _CMP32_EQ_DONE
    JMP     R0

_CMP32_NEQ:
    XCHG    R3                  ; R3 = B_lo
    SUB     R1, R3              ; A_lo - B_lo
    LOAD16  R0, _CMP32_MATCH
    JMP.Z   R0, R1
    LOAD16  R1, 0
    LOAD16  R0, _CMP32_EQ_DONE
    JMP     R0

_CMP32_MATCH:
    LOAD16  R1, 1

_CMP32_EQ_DONE:
    APUSH   R1
    RRET

CMP32_LT:
    RPUSH   R0
    APOP    R2                  ; B_hi
    APOP    R3                  ; B_lo
    XCHG    R2
    XCHG    R3
    APOP    R2                  ; A_hi
    APOP    R1                  ; A_lo

    XCHG    R2                  ; R2 = B_hi, shadow_r[2] = A_hi
    XCHG    R3
    LD      R3, R2              ; R3 = B_hi
    XCHG    R2                  ; R2 = A_hi
    SUB     R2, R3              ; A_hi - B_hi
    LOAD16  R0, _CMP32_LT_LO
    JMP.Z   R0, R2

    LD      R1, R2              ; Restore A_hi
    ADD     R1, R3              ; R1 = A_hi
    LD      R2, R3              ; R2 = B_hi
    RCALL   _CMP_LT
    APUSH   R1
    RRET

_CMP32_LT_LO:
    XCHG    R3                  ; R3 = B_lo
    LD      R2, R3              ; R2 = B_lo
    RCALL   _CMP_LT
    APUSH   R1
    RRET

CMP32_GE:
    RPUSH   R0
    RCALL   CMP32_LT
    APOP    R1                  ; R1 = (A < B)
    XOR     R1, 1               ; R1 = (A >= B)
    APUSH   R1
    RRET

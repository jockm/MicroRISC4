; ==============================================================================
; FILE: lib/M4R_LIB.asm
; Architecture: MiniRISC4 16-Bit Word-Addressed Processor
; Target Hardware: Lattice ECP5 FPGA (ULX3S) / Verilog Core
; Description:
;   Standard Math & Relational Runtime Subroutine Library for MiniRISC4.
;   Provides 16-bit unsigned multiplication (MULT), restoring integer division (DIV),
;   modulo/remainder (MOD), and unsigned relational comparisons (_CMP_*).
;
; Table of Contents:
;   1. SUBROUTINE: MULT        - 16-bit unsigned binary multiplication
;   2. HELPER:     DIVMOD_CORE - 16-bit binary restoring division engine
;   3. SUBROUTINE: DIV         - 16-bit unsigned integer division
;   4. SUBROUTINE: MOD         - 16-bit unsigned integer remainder / modulo
;   5. RELATIONAL: _CMP_LT     - Unsigned Less-Than comparison (<)
;   6. RELATIONAL: _CMP_LE     - Unsigned Less-Than-or-Equal comparison (<=)
;   7. RELATIONAL: _CMP_GT     - Unsigned Greater-Than comparison (>)
;   8. RELATIONAL: _CMP_GE     - Unsigned Greater-Than-or-Equal comparison (>=)
;
; Calling Conventions & Stack Rules:
;   - Argument Stack (ASP @ 0x0005, Base 0xFAFF):
;       Math routines (MULT, DIV, MOD) receive operands on the Argument Stack.
;       Binary operands (A op B):
;         Top of Stack (first popped)  : Operand B (RHS / Multiplier / Divisor)
;         Second on Stack (next popped): Operand A (LHS / Multiplicand / Dividend)
;       Result is pushed back onto the Argument Stack and returned in R1.
;   - Return Stack (RSP @ 0x0004, Base 0xFEFF):
;       All routines preserve caller return linkage on the Return Stack via
;       RPUSH R0 upon entry, returning via RRET (RPOP R0; JMP R0).
;   - Comparison Helpers (_CMP_*):
;       Operands passed in primary registers: R1 = LHS (A), R2 = RHS (B).
;       Boolean result returned in R1 (1 = True, 0 = False).
;   - Register-Indirect Branching:
;       All branches (JMP, JMP.Z, JMP.M, LINK) are strictly register-indirect.
;       Target addresses are pre-loaded into registers via LOAD16 prior to branching.
; ==============================================================================


; ==============================================================================
; SECTION 1: 16-Bit Binary Multiplication (MULT)
; ==============================================================================

; ==============================================================================
; SUBROUTINE: MULT
; Description:
;   Performs 16-bit unsigned multiplication: Product = A * B (modulo 65536).
;   Uses the classic shift-and-add binary multiplication algorithm with an
;   explicit 16-step iteration counter.
;
; Algorithm:
;   1. Pop Multiplier (B) into R2 and Multiplicand (A) into R1 from ASP.
;   2. Clear product accumulator (R3 = 0).
;   3. For each of the 16 bits:
;      a. Test LSB of Multiplier by rotating right (ROT.R R2) into bit 15 (sign bit).
;      b. If bit 15 is 1, jump to _MULT_ADD to add Multiplicand to Accumulator.
;      c. Restore Multiplier bit alignment (ROT.L R2), shift Multiplier right by 1,
;         and shift Multiplicand left by 1.
;      d. Decrement loop counter. Exit early if Multiplier reaches 0.
;   4. Return 16-bit product in R1 and push onto ASP.
;
; Stack Layout:
;   Entry: [ASP]   = Multiplier (B)
;          [ASP+1] = Multiplicand (A)
;   Exit:  [ASP]   = Product (A * B & 0xFFFF)
;
; Registers:
;   R1 = Multiplicand (A) -> Product output
;   R2 = Multiplier (B)
;   R3 = Product Accumulator (caller R3 preserved in shadow_r[3])
;   shadow_r[0] = 16-step loop counter
; ==============================================================================
MULT:
    RPUSH   R0                  ; Save subroutine return address onto Return Stack (0x0004)

    ; Pop operands from Argument Stack (0x0005)
    APOP    R2                  ; R2 = Multiplier (B)
    APOP    R1                  ; R1 = Multiplicand (A)

    ; Free R3 to act as product accumulator; preserve caller R3 in hardware shadow
    XCHG    R3                  ; shadow_r[3] = caller R3
    LD0     R3                  ; R3 = 0x0000 (accumulator initialized to zero)

    ; Initialize 16-iteration loop counter in shadow_r[0]
    XCHG    R0                  ; shadow_r[0] = caller R0
    LOAD16  R0, 16              ; Loop counter = 16 bits
    XCHG    R0                  ; R0 restored; shadow_r[0] = 16

_MULT_LOOP:
    ; Optimization: check if remaining Multiplier bits are zero -> exit early
    LOAD16  R0, _MULT_DONE
    JMP.Z   R0, R2              ; If R2 == 0, multiplication complete

    ; Test LSB (bit 0) of Multiplier: rotate right shifts bit 0 into bit 15 (sign bit)
    ROT.R   R2
    LOAD16  R0, _MULT_ADD
    JMP.M   R0, R2              ; If bit 15 is 1 (negative), bit 0 was set -> add

    ; Bit 0 was 0: no addition, proceed with bit shifts
    ROT.L   R2                  ; Restore original bit alignment of R2
    SHIFT.R R2                  ; Multiplier >>= 1 (logical right shift)
    SHIFT.L R1                  ; Multiplicand <<= 1 (logical left shift)
    LOAD16  R0, _MULT_DEC
    JMP     R0                  ; Decrement iteration counter

_MULT_ADD:
    ROT.L   R2                  ; Restore original bit alignment of R2
    ADD     R3, R1              ; Accumulator += Multiplicand
    SHIFT.R R2                  ; Multiplier >>= 1
    SHIFT.L R1                  ; Multiplicand <<= 1

_MULT_DEC:
    XCHG    R0                  ; Access loop counter from shadow_r[0]
    DEC     R0                  ; counter--
    LOAD16  R1, _MULT_DONE_CTR  ; Scratch jump target in R1 (Multiplicand dead here)
    JMP.Z   R1, R0              ; If counter == 0, loop finished
    XCHG    R0                  ; Save updated counter back to shadow_r[0]

    LOAD16  R0, _MULT_LOOP      ; Branch back to process next bit
    JMP     R0

_MULT_DONE_CTR:
    XCHG    R0                  ; Restore shadow_r[0] / caller R0

_MULT_DONE:
    LD      R1, R3              ; R1 = Final 16-bit Product
    XCHG    R3                  ; Restore caller R3 from shadow_r[3]
    APUSH   R1                  ; Push product onto Argument Stack (0x0005)
    RRET                        ; Return to caller (pops return address from RSP)


; ==============================================================================
; SECTION 2: 16-Bit Restoring Division Engine (DIVMOD_CORE)
; ==============================================================================

; ==============================================================================
; HELPER: DIVMOD_CORE
; Description:
;   Core 16-bit unsigned restoring division routine.
;   Computes both quotient and remainder simultaneously using shift-and-subtract.
;
; Inputs:
;   R1 = Dividend (N)
;   R2 = Divisor (D)
; Outputs:
;   R1 = Quotient (N / D)
;   R3 = Remainder (N % D)
;
; Special Cases:
;   Division by Zero: If D == 0, returns Quotient = 0xFFFF, Remainder = Dividend (N).
;
; Registers:
;   R1 = Dividend (shifts left; quotient bits shifted into LSB) -> returns Quotient
;   R2 = Divisor (preserved in shadow_r[2] during loop)
;   R3 = Remainder accumulator -> returns Remainder
;   shadow_r[0] = 16-iteration loop counter
; ==============================================================================
DIVMOD_CORE:
    RPUSH   R0                  ; Save return link onto Return Stack (0x0004)

    ; Check for divide-by-zero condition (Divisor R2 == 0)
    LOAD16  R0, _DIV_ZERO
    JMP.Z   R0, R2              ; If R2 == 0, branch to error handler

    LD0     R3                  ; R3 = 0x0000 (Remainder initialized to zero)

    ; Preserve Divisor in shadow_r[2] so R2 is available for branch scratch
    XCHG    R2

    ; Initialize 16-bit loop counter in shadow_r[0]
    XCHG    R0
    LOAD16  R0, 16              ; 16 iterations for 16-bit division
    XCHG    R0

_DIV_BIT_LOOP:
    SHIFT.L R3                  ; Remainder <<= 1

    ; Shift MSB of Dividend into LSB of Remainder
    LOAD16  R2, _DIV_CARRY_IN
    JMP.M   R2, R1              ; Test bit 15 (MSB) of Dividend

    LOAD16  R2, _DIV_SHIFT_CONT
    JMP     R2

_DIV_CARRY_IN:
    INC     R3                  ; Remainder |= 1 (MSB shifted out of Dividend was 1)

_DIV_SHIFT_CONT:
    SHIFT.L R1                  ; Dividend <<= 1 (shifts quotient bit into LSB)

    ; Compare current Remainder (R3) with Divisor (held in shadow_r[2])
    XCHG    R2                  ; R2 = Divisor, shadow_r[2] = scratch
    XCHG    R0                  ; R0 = loop counter, shadow_r[0] = scratch
    XCHG    R0                  ; Restore R0

    ; Compute test trial subtraction: difference = Remainder - Divisor
    XCHG    R0
    LD      R0, R3
    SUB     R0, R2              ; R0 = Remainder - Divisor
    XCHG    R0                  ; shadow_r[0] = difference, R0 restored

    ; Check if trial subtraction produced a negative result
    XCHG    R0                  ; R0 = difference
    LOAD16  R2, _DIV_NO_SUB
    JMP.M   R2, R0              ; If negative, cannot subtract -> skip
    XCHG    R0                  ; shadow_r[0] = difference, R0 restored

    ; Successful subtraction: Remainder gets difference, Quotient LSB = 1
    XCHG    R0
    LD      R3, R0              ; Remainder = difference (subtraction committed)
    XCHG    R0
    INC     R1                  ; Quotient LSB = 1

    LOAD16  R2, _DIV_DEC_LOOP
    JMP     R2

_DIV_NO_SUB:
    XCHG    R0                  ; Restore R0

_DIV_DEC_LOOP:
    XCHG    R2                  ; Restore Divisor back into shadow_r[2]
    XCHG    R0                  ; Access loop counter
    DEC     R0                  ; counter--
    LOAD16  R2, _DIV_EXIT
    JMP.Z   R2, R0              ; If counter == 0, division complete
    XCHG    R0                  ; Save counter back to shadow_r[0]

    LOAD16  R0, _DIV_BIT_LOOP   ; Loop for next bit
    JMP     R0

_DIV_EXIT:
    XCHG    R0                  ; Restore original R0
    XCHG    R2                  ; Restore original R2 (Divisor)
    RRET                        ; Return with R1 = Quotient, R3 = Remainder

_DIV_ZERO:
    ; Divide by zero: Remainder = original Dividend, Quotient = 0xFFFF
    LD      R3, R1              ; Remainder = Dividend
    LD0     R1                  ; R1 = 0x0000
    DEC     R1                  ; R1 = 0xFFFF (standard unsigned error quotient)
    RRET


; ==============================================================================
; SECTION 3: 16-Bit Unsigned Integer Division (DIV)
; ==============================================================================

; ==============================================================================
; SUBROUTINE: DIV
; Description:
;   16-bit unsigned integer division: Quotient = Dividend / Divisor.
; Stack In : [ASP]   = Divisor (D)
;            [ASP+1] = Dividend (N)
; Stack Out: [ASP]   = Quotient (N / D)
; Register : R1 = Quotient
; ==============================================================================
DIV:
    RPUSH   R0                  ; Preserve return address on Return Stack
    APOP    R2                  ; R2 = Divisor (D)
    APOP    R1                  ; R1 = Dividend (N)
    RCALL   DIVMOD_CORE         ; Returns Quotient in R1, Remainder in R3
    APUSH   R1                  ; Push Quotient onto Argument Stack
    RRET


; ==============================================================================
; SECTION 4: 16-Bit Unsigned Integer Modulo (MOD)
; ==============================================================================

; ==============================================================================
; SUBROUTINE: MOD
; Description:
;   16-bit unsigned integer remainder: Remainder = Dividend % Divisor.
; Stack In : [ASP]   = Divisor (D)
;            [ASP+1] = Dividend (N)
; Stack Out: [ASP]   = Remainder (N % D)
; Register : R1 = Remainder
; ==============================================================================
MOD:
    RPUSH   R0                  ; Preserve return address on Return Stack
    APOP    R2                  ; R2 = Divisor (D)
    APOP    R1                  ; R1 = Dividend (N)
    RCALL   DIVMOD_CORE         ; Returns Quotient in R1, Remainder in R3
    LD      R1, R3              ; Move Remainder to return register R1
    APUSH   R1                  ; Push Remainder onto Argument Stack
    RRET


; ==============================================================================
; SECTION 5: Unsigned Relational Comparisons (_CMP_LT, _CMP_LE, _CMP_GT, _CMP_GE)
; Description:
;   Evaluates 16-bit unsigned inequalities across the entire 0x0000-0xFFFF range.
;   Because MiniRISC4 only supports JMP.M (sign bit is 1) and JMP.Z (zero) on
;   register contents, unsigned comparison must differentiate between numbers
;   with differing MSBs (where bit 15 represents the 0x8000 boundary) and numbers
;   with identical MSBs (where standard subtraction gives the correct magnitude).
;
; Inputs:
;   R1 = Left-Hand Side (LHS / A)
;   R2 = Right-Hand Side (RHS / B)
; Outputs:
;   R1 = 1 if the condition is True
;   R1 = 0 if the condition is False
; ==============================================================================

; ==============================================================================
; SUBROUTINE: _CMP_LT  (Unsigned Less-Than: A < B)
; ==============================================================================
_CMP_LT:
    RPUSH   R0                  ; Preserve return address on Return Stack

    ; Step 1: Compare MSBs (bit 15) using XOR
    XCHG    R0
    LD      R0, R1
    XOR     R0, R2              ; If bit 15 is set, operands have opposite signs
    LOAD16  R3, _CMP_LT_DIFF_SIGNS
    JMP.M   R3, R0              ; Branch if MSBs are different
    XCHG    R0                  ; Restore R0

    ; Step 2: MSBs are identical -> standard subtraction A - B gives correct relation
    SUB     R1, R2              ; R1 = A - B
    LOAD16  R0, _CMP_RET_TRUE
    JMP.M   R0, R1              ; If difference is negative, A < B -> True
    LOAD16  R0, _CMP_RET_FALSE
    JMP     R0                  ; Else A >= B -> False

_CMP_LT_DIFF_SIGNS:
    XCHG    R0                  ; Restore R0
    ; When MSBs differ: the operand with MSB=1 is in range [0x8000..0xFFFF],
    ; while the operand with MSB=0 is in range [0x0000..0x7FFF].
    ; Therefore, if LHS (R1) has bit 15 set, LHS is strictly larger -> False.
    LOAD16  R0, _CMP_RET_FALSE
    JMP.M   R0, R1              ; If R1[15] == 1, A > B -> False
    LOAD16  R0, _CMP_RET_TRUE
    JMP     R0                  ; Else A < B -> True

; ==============================================================================
; SUBROUTINE: _CMP_LE  (Unsigned Less-Than-or-Equal: A <= B)
; ==============================================================================
_CMP_LE:
    RPUSH   R0                  ; Preserve return address on Return Stack

    ; Step 1: Check equality (A == B)
    XCHG    R0
    LD      R0, R1
    SUB     R0, R2              ; Test difference A - B
    LOAD16  R3, _CMP_LE_EQUAL
    JMP.Z   R3, R0              ; If A == B, branch to True
    XCHG    R0                  ; Restore R0

    ; Step 2: Not equal -> evaluate A < B
    RCALL   _CMP_LT             ; Returns result in R1
    RRET

_CMP_LE_EQUAL:
    XCHG    R0                  ; Restore R0
    LOAD16  R1, 1               ; Return True
    RRET

; ==============================================================================
; SUBROUTINE: _CMP_GT  (Unsigned Greater-Than: A > B)
; Note: A > B is logically equivalent to B < A
; ==============================================================================
_CMP_GT:
    RPUSH   R0                  ; Preserve return address on Return Stack
    SWAP    R1, R2              ; Swap operands so test becomes: B < A
    RCALL   _CMP_LT             ; Evaluate B < A
    RRET

; ==============================================================================
; SUBROUTINE: _CMP_GE  (Unsigned Greater-Than-or-Equal: A >= B)
; Note: A >= B is logically equivalent to B <= A
; ==============================================================================
_CMP_GE:
    RPUSH   R0                  ; Preserve return address on Return Stack
    SWAP    R1, R2              ; Swap operands so test becomes: B <= A
    RCALL   _CMP_LE             ; Evaluate B <= A
    RRET

; ==============================================================================
; Boolean Return Exit Points
; ==============================================================================
_CMP_RET_TRUE:
    LOAD16  R1, 1               ; Return boolean 1 (True)
    RRET

_CMP_RET_FALSE:
    LD0     R1                  ; Return boolean 0 (False)
    RRET
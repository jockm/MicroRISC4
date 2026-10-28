; ==============================================================================
; FILE: examples/asm/trap_math_hook.asm
; Description: Direct Stride Vector Table Trampoline for Hardware Math Traps
; ==============================================================================
.include "lib/common.inc"

; ------------------------------------------------------------------------------
; Direct Stride Vector Slot 2: Math Accelerator Trap (0x0120 - 0x012F)
; Hardware vectors here with R0 = Return PC
; ------------------------------------------------------------------------------
.org 0x0120
_trap2_math_entry:
    XCHGALL                     ; 4 cycles: R0-R3 swapped to shadow_r[0..3]
                                ; shadow_r[0] now safely holds the return address!
    LOAD16  R0, _trap2_handler
    JMP     R0

; ------------------------------------------------------------------------------
; Core Math Trap Handler
; Inputs (in primary registers before XCHGALL):
;   R1 = A_LO, R2 = A_HI, R3 = B_LO, R0 = Opcode
; ------------------------------------------------------------------------------
.org 0x0250
_trap2_handler:
    ; R0..R3 here are shadow registers! We can manipulate them freely.
    ; Setup pointer to MMIO block:
    LD      R3, 8
    ADD     R3, R3              ; R3 = 0x0010 (MATH_A_LO)

    ; Exchange to access input arguments and stream them:
    XCHG    R1                  ; R1 = input A_LO
    LD      (R3++), R1          ; POKE 0x0010 (A_LO)
    XCHG    R1

    XCHG    R2                  ; R2 = input A_HI
    LD      (R3++), R2          ; POKE 0x0011 (A_HI)
    XCHG    R2

    ; Write B operands and Opcode...
    ; (Execute operation in MMIO engine)
    ; ...

    ; Latch result from 0x0015 into R1/R2
    LD      R3, 0x0015
    LD      R1, (R3++)          ; R1 = RES_LO
    LD      R2, (R3)            ; R2 = RES_HI

    ; Restore primary registers:
    XCHGALL                     ; R1 and R2 now contain the 32-bit math result!
    JMP     R0                  ; Return to caller via saved PC
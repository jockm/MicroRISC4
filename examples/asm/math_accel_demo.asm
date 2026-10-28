; ==============================================================================
; FILE: examples/asm/math_accel_demo.asm
; Description: 32-bit Multiply & Multi-Bit Shift using Hardware MMIO Engine
; ==============================================================================
.include "lib/common.inc"

.org 0x0200
_main:
    ; --------------------------------------------------------------------------
    ; 1. Synthesize MMIO Base Address 0x0010 into R3 (1 word / 2 bytes)
    ; --------------------------------------------------------------------------
    LD      R3, 8
    ADD     R3, R3              ; R3 = 0x0010 (MATH_A_LO)

    ; --------------------------------------------------------------------------
    ; 2. Multiply: 100,000 * 20 = 2,000,000 (0x001E8480)
    ;    A = 0x000186A0 (A_LO = 0x86A0, A_HI = 0x0001)
    ;    B = 20         (B_LO = 0x0014, B_HI = 0x0000)
    ; --------------------------------------------------------------------------
    LOAD16  R1, 0x86A0          ; A_LO
    LOAD16  R2, 0x0001          ; A_HI
    LD      (R3++), R1          ; POKE 0x0010 (A_LO), R3 -> 0x0011
    LD      (R3++), R2          ; POKE 0x0011 (A_HI), R3 -> 0x0012

    LD      R1, 20              ; B_LO
    LD0     R2                  ; B_HI
    LD      (R3++), R1          ; POKE 0x0012 (B_LO), R3 -> 0x0013
    LD      (R3++), R2          ; POKE 0x0013 (B_HI), R3 -> 0x0014

    ; Trigger CMD: 0 = MUL (R3 is now pointing at 0x0014)
    LD0     R1                  ; Opcode 0 = MUL
    LD      (R3++), R1          ; POKE 0x0014 (CMD), R3 -> 0x0015

    ; Read Result from 0x0015 (RES_LO) and 0x0016 (RES_HI)
    LD      R1, (R3++)          ; R1 = RES_LO (0x8480), R3 -> 0x0016
    LD      R2, (R3)            ; R2 = RES_HI (0x001E)
    ; Product {R2, R1} is 0x001E8480 (2,000,000). Done!

    ; --------------------------------------------------------------------------
    ; 3. Barrel Shift: 0x00000001 << 12 = 0x00001000 in 1 cycle
    ; --------------------------------------------------------------------------
    LD      R3, 8
    ADD     R3, R3              ; R3 = 0x0010
    LD      R1, 1               ; A_LO = 1
    LD0     R2                  ; A_HI = 0
    LD      (R3++), R1          ; 0x0010
    LD      (R3++), R2          ; 0x0011
    LD      R1, 12              ; B_LO = 12 (shamt)
    LD      (R3++), R1          ; 0x0012
    LD      (R3++), R2          ; 0x0013
    LD      R1, 8               ; Opcode 8 = SLL
    LD      (R3++), R1          ; 0x0014 (Trigger SLL)
    LD      R1, (R3++)          ; 0x0015 -> R1 = 0x1000
    LD      R2, (R3)            ; 0x0016 -> R2 = 0x0000

_halt:
    LOAD16  R0, _halt
    JMP     R0
; ==============================================================================
; FILE: asic/mr4_tiny/tiny_payload.asm
; Test payload uploaded over UART into external QSPI PSRAM (0x0400) during
; RTL and Post-Route Gate-Level Simulation (GLS) of `tt_um_mr4`.
;
; Actions:
;   1. Write 0xCAFE -> PSRAM [0x0500]
;   2. Read back [0x0500], increment to 0xCAFF, write -> PSRAM [0x0501]
;   3. Transmit "OK!" over UART TX (0x000F)
;   4. Halt cleanly
; ==============================================================================

.include "common.inc"

.org 0x0400
_tiny_payload:
    LOAD16  R0, 0x0500
    LOAD16  R1, 0xCAFE
    LD      (R0), R1
    LD      R2, (R0)
    INC     R2
    INC     R0
    LD      (R0), R2
    LOAD16  R1, 0x004F          ; 'O'
    PUTC    R1
    LOAD16  R1, 0x004B          ; 'K'
    PUTC    R1
    LOAD16  R1, 0x0021          ; '!'
    PUTC    R1
_halt:
    LOAD16  R0, _halt
    JMP     R0

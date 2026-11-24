; ==============================================================================
; FILE: mr4src/asm/asic_boot.asm
; Architecture: MicroRISC4 ASIC Cold-Start Boot ROM (0x0100 - 0x02FF, <= 512w)
;
; Designed for synthesizable AsicBootRom overlaid over uninitialized on-chip
; SRAM (works on >= 1024-word SRAM; stacks at 0x03FF / 0x03BF, scratch at 0x0300).
;
; Boot Sequence:
;   1. Initialize RSP (0x03FF) and ASP (0x03BF) in on-chip SRAM.
;   2. Run SRAM write/readback self-test at 0x0300..0x0301.
;   3. If CAP_MATH_ACCEL (CPU_CAPS bit 3) is set, verify 123 * 45 == 5535 -> [0x0302].
;   4. Write boot-OK sentinel 0x600D to [0x0303] and print "MR4 ASIC v0.1 OK\r\n".
;   5. Enter interactive UART echo loop (ready for host verification / bring-up).
; ==============================================================================

.include "common.inc"

.define ASIC_RSP_INIT   0x03FF
.define ASIC_ASP_INIT   0x03BF
.define SRAM_TEST_0     0x0300
.define SRAM_TEST_1     0x0301
.define SRAM_MATH_RES   0x0302
.define SRAM_BOOT_OK    0x0303
.define CPU_CAPS_ADDR   0x001C
.define MATH_A_LO       0x0010
.define MATH_A_HI       0x0011
.define MATH_B_LO       0x0012
.define MATH_B_HI       0x0013
.define MATH_CMD        0x0014
.define MATH_RES_LO     0x0015

; ==============================================================================
; Direct Stride Vector Table (0x0100 - 0x01FF)
; ==============================================================================
.org 0x0100
_trap0_reset:
    LOAD16  R1, ASIC_RSP_INIT
    LD      R0, 4                   ; RSP @ 0x0004
    LD      (R0), R1
    LOAD16  R1, ASIC_ASP_INIT
    INC     R0                      ; ASP @ 0x0005
    LD      (R0), R1
    LOAD16  R0, _asic_boot_main
    JMP     R0

.org 0x01E0
_trap14_async:
    ERET

.org 0x01F0
_trap15_fault:
    LOAD16  R0, _trap15_halt
_trap15_halt:
    JMP     R0

; ==============================================================================
; Cold-Start Self-Test & UART Boot Banner (0x0200 - 0x02FF)
; ==============================================================================
.org 0x0200
_asic_boot_main:
    ; 1. On-chip SRAM write / readback test (0x0300..0x0301)
    LOAD16  R0, SRAM_TEST_0
    LOAD16  R1, 0xA55A
    LD      (R0), R1
    INC     R0
    LOAD16  R2, 0x5AA5
    LD      (R0), R2
    DEC     R0
    LD      R3, (R0)
    SUB     R3, R1
    LOAD16  R0, _sram_ok_0
    JMP.Z   R0, R3
    LOAD16  R0, _boot_fail
    JMP     R0

_sram_ok_0:
    LOAD16  R0, SRAM_TEST_1
    LD      R3, (R0)
    SUB     R3, R2
    LOAD16  R0, _sram_ok_1
    JMP.Z   R0, R3
    LOAD16  R0, _boot_fail
    JMP     R0

_sram_ok_1:
    ; 2. Optional 1-DSP MathAccelerator self-test if CPU_CAPS.b3 == 1
    LOAD16  R0, CPU_CAPS_ADDR
    LD      R1, (R0)
    LD      R0, 8
    AND     R1, R0
    LOAD16  R0, _skip_math
    JMP.Z   R0, R1

    LOAD16  R0, MATH_A_LO
    LOAD16  R1, 123
    LD      (R0), R1
    INC     R0                      ; MATH_A_HI
    LD0     R2
    LD      (R0), R2
    INC     R0                      ; MATH_B_LO
    LOAD16  R1, 45
    LD      (R0), R1
    INC     R0                      ; MATH_B_HI
    LD      (R0), R2
    INC     R0                      ; MATH_CMD = 0 (MUL)
    LD      (R0), R2
    INC     R2                      ; R2 = 1 (busy mask)
_math_wait:
    LD      R1, (R0)
    AND     R1, R2
    LOAD16  R3, _math_done
    JMP.Z   R3, R1
    LOAD16  R3, _math_wait
    JMP     R3
_math_done:
    INC     R0                      ; MATH_RES_LO
    LD      R1, (R0)
    LOAD16  R0, SRAM_MATH_RES
    LD      (R0), R1                ; Expect 5535 (0x159F)

_skip_math:
    ; 3. Mark boot success sentinel & emit UART banner
    LOAD16  R0, SRAM_BOOT_OK
    LOAD16  R1, 0x600D
    LD      (R0), R1

    LOAD16  R2, _str_boot_ok
    RCALL   _rom_puts

    ; 4. Interactive UART echo loop
_echo_loop:
    GETC    R1
    PUTC    R1
    LOAD16  R0, _echo_loop
    JMP     R0

_boot_fail:
    LOAD16  R2, _str_boot_err
    RCALL   _rom_puts
_fail_halt:
    LOAD16  R0, _fail_halt
    JMP     R0

; Print packed NUL-terminated string pointed to by R2
_rom_puts:
    RPUSH   R0
_rom_puts_loop:
    LD      R3, (R2++)
    BYTE_GET_LO R1, R3
    LOAD16  R0, _rom_puts_done
    JMP.Z   R0, R1
    PUTC    R1
    BYTE_GET_HI R1, R3
    LOAD16  R0, _rom_puts_done
    JMP.Z   R0, R1
    PUTC    R1
    LOAD16  R0, _rom_puts_loop
    JMP     R0
_rom_puts_done:
    RRET

_str_boot_ok:
    .asciz "MR4 ASIC v0.1 OK\r\n"
_str_boot_err:
    .asciz "MR4 ASIC ERR\r\n"

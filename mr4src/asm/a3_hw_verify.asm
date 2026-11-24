; ==============================================================================
; FILE: mr4src/asm/a3_hw_verify.asm
; Track A.3 Hardware Bring-Up Verification Firmware (ULX3S-85F)
;
; Verifies on live silicon (3.000 Mbaud UART):
;   1. CPU_VER (0x001B) & CPU_CAPS (0x001C) discovery (CAP_SPI, CAP_MATH_ACCEL, CAP_PIPELINED)
;   2. Lean 1-DSP MathAccelerator (0x0010-0x0016): all 11 opcodes + signed & div-by-0
;   3. microSD SPI Mode 0 Master (0x0018-0x001A): SDHC init (CMD0/CMD8/CMD55/ACMD41)
;      at 400 kHz -> switch to 12 MHz -> CMD17 Sector 0 MBR read & 0xAA55 signature check!
; ==============================================================================

.include "common.inc"

.define MATH_A_LO    0x0010
.define MATH_A_HI    0x0011
.define MATH_B_LO    0x0012
.define MATH_B_HI    0x0013
.define MATH_CMD     0x0014
.define MATH_RES_LO  0x0015
.define MATH_RES_HI  0x0016

.define SPI_CTRL     0x0018
.define SPI_STAT     0x0019
.define SPI_DATA     0x001A

.define CPU_VER      0x001B
.define CPU_CAPS     0x001C

.define VAR_FAIL     0x0B00
.define VAR_TMP      0x0B01
.define VAR_CNT      0x0B02
.define VAR_PTR      0x0B03
.define VAR_STR_PTR  0x0B04
.define VAR_HEX_VAL  0x0B05
.define VAR_HEX_CNT  0x0B06
.define VAR_R1_CNT   0x0B07
.define VAR_STR_W    0x0B08
.define SD_BUF       0x0900      ; 256 words (512 bytes) for Sector 0 MBR

.org 0x0100
_reset:
    LOAD16  R3, 0x0FFF
    LD      R0, 4               ; RSP_ADDR = 0x0004
    LD      (R0), R3
    LOAD16  R3, _main
    JMP     R3

.org 0x0200
_main:
    LOAD16  R1, str_banner
    RCALL   print_str

    ; Print CPU_VER & CPU_CAPS
    LOAD16  R1, str_ver
    RCALL   print_str
    LOAD16  R0, CPU_VER
    LD      R1, (R0)
    RCALL   print_hex4
    LOAD16  R1, str_caps
    RCALL   print_str
    LOAD16  R0, CPU_CAPS
    LD      R1, (R0)
    RCALL   print_hex4
    RCALL   print_crlf

    ; --------------------------------------------------------------------------
    ; Phase 1: 1-DSP Math Accelerator Self-Test (all 11 opcodes + div-by-zero)
    ; --------------------------------------------------------------------------
    LOAD16  R1, str_math_hdr
    RCALL   print_str
    LOAD16  R0, VAR_FAIL
    LOAD16  R1, 0
    LD      (R0), R1

    ; Test 1: MUL (123456 * 78901 = 0x00000002_4498D740)
    LOAD16  R1, 0xE240
    LOAD16  R2, 0x0001
    RCALL   math_set_a
    LOAD16  R1, 0x3435
    LOAD16  R2, 0x0001
    RCALL   math_set_b
    LOAD16  R1, 0               ; MUL
    RCALL   math_exec
    LOAD16  R1, 0xD740
    LOAD16  R2, 0x4498
    RCALL   math_check

    ; Test 2: MULHU (same operands -> 0x00000002)
    LOAD16  R1, 2               ; MULHU
    RCALL   math_exec
    LOAD16  R1, 0x0002
    LOAD16  R2, 0x0000
    RCALL   math_check

    ; Test 3: MULH (-100000 * 100000 = 0xFFFFFFFD_ABF41C00)
    LOAD16  R1, 0x7960
    LOAD16  R2, 0xFFFE          ; -100000 = 0xFFFE7960
    RCALL   math_set_a
    LOAD16  R1, 0x86A0
    LOAD16  R2, 0x0001          ; +100000 = 0x000186A0
    RCALL   math_set_b
    LOAD16  R1, 1               ; MULH
    RCALL   math_exec
    LOAD16  R1, 0xFFFD
    LOAD16  R2, 0xFFFF
    RCALL   math_check

    ; Test 4: MULHSU (-1 * 0xFFFFFFFF = 0xFFFFFFFF_00000001)
    LOAD16  R1, 0xFFFF
    LOAD16  R2, 0xFFFF
    RCALL   math_set_a
    LOAD16  R1, 0xFFFF
    LOAD16  R2, 0xFFFF
    RCALL   math_set_b
    LOAD16  R1, 3               ; MULHSU
    RCALL   math_exec
    LOAD16  R1, 0xFFFF
    LOAD16  R2, 0xFFFF
    RCALL   math_check

    ; Test 5 & 6: DIVU / REMU (0x12345678 / 1000 = 0x0004A90B rem 0x00000380)
    LOAD16  R1, 0x5678
    LOAD16  R2, 0x1234
    RCALL   math_set_a
    LOAD16  R1, 1000
    LOAD16  R2, 0
    RCALL   math_set_b
    LOAD16  R1, 4               ; DIVU
    RCALL   math_exec
    LOAD16  R1, 0xA90B
    LOAD16  R2, 0x0004
    RCALL   math_check
    LOAD16  R1, 5               ; REMU
    RCALL   math_exec
    LOAD16  R1, 0x0380
    LOAD16  R2, 0x0000
    RCALL   math_check

    ; Test 7 & 8: DIV / REM (-100 / 7 = -14 [0xFFFFFFF2], rem -2 [0xFFFFFFFE])
    LOAD16  R1, 0xFF9C
    LOAD16  R2, 0xFFFF          ; -100
    RCALL   math_set_a
    LOAD16  R1, 7
    LOAD16  R2, 0
    RCALL   math_set_b
    LOAD16  R1, 6               ; DIV
    RCALL   math_exec
    LOAD16  R1, 0xFFF2
    LOAD16  R2, 0xFFFF
    RCALL   math_check
    LOAD16  R1, 7               ; REM
    RCALL   math_exec
    LOAD16  R1, 0xFFFE
    LOAD16  R2, 0xFFFF
    RCALL   math_check

    ; Test 9: Div-by-Zero (DIVU -> 0xFFFFFFFF & STAT bit 1 == 1)
    LOAD16  R1, 0
    LOAD16  R2, 0
    RCALL   math_set_b
    LOAD16  R1, 4               ; DIVU by 0
    RCALL   math_exec
    LOAD16  R1, 0xFFFF
    LOAD16  R2, 0xFFFF
    RCALL   math_check

    ; Test 10, 11, 12: SLL / SRL / SRA (0x80000010 by 4)
    LOAD16  R1, 0x0010
    LOAD16  R2, 0x8000
    RCALL   math_set_a
    LOAD16  R1, 4
    LOAD16  R2, 0
    RCALL   math_set_b
    LOAD16  R1, 8               ; SLL -> 0x00000100
    RCALL   math_exec
    LOAD16  R1, 0x0100
    LOAD16  R2, 0x0000
    RCALL   math_check
    LOAD16  R1, 9               ; SRL -> 0x08000001
    RCALL   math_exec
    LOAD16  R1, 0x0001
    LOAD16  R2, 0x0800
    RCALL   math_check
    LOAD16  R1, 10              ; SRA -> 0xF8000001
    RCALL   math_exec
    LOAD16  R1, 0x0001
    LOAD16  R2, 0xF800
    RCALL   math_check

    ; Report Math result
    LOAD16  R0, VAR_FAIL
    LD      R1, (R0)
    LOAD16  R3, math_ok
    JMP.Z   R3, R1
    LOAD16  R1, str_fail
    RCALL   print_str
    LOAD16  R0, VAR_FAIL
    LD      R1, (R0)
    RCALL   print_hex4
    RCALL   print_crlf
    LOAD16  R3, sd_phase
    JMP     R3
math_ok:
    LOAD16  R1, str_math_pass
    RCALL   print_str

    ; --------------------------------------------------------------------------
    ; Phase 2: microSD SPI Mode 0 SDHC Bring-Up (CMD0 -> CMD8 -> ACMD41 -> CMD17)
    ; --------------------------------------------------------------------------
sd_phase:
    LOAD16  R1, str_sd_hdr
    RCALL   print_str

    ; 1. CS_N=1, slow clock (~400 kHz), send 10 dummy bytes (80 clocks)
    LOAD16  R0, SPI_CTRL
    LOAD16  R1, 0x0001
    LD      (R0), R1
    LOAD16  R0, VAR_CNT
    LOAD16  R1, 10
    LD      (R0), R1
sd_dummy_loop:
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    LOAD16  R0, VAR_CNT
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R3, sd_cmd0
    JMP.Z   R3, R1
    LOAD16  R3, sd_dummy_loop
    JMP     R3

    ; 2. CMD0 (GO_IDLE_STATE, arg=0, crc=0x95) -> expect R1 == 0x01
sd_cmd0:
    RCALL   sd_select
    LOAD16  R1, 0x0040          ; CMD0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0x0095
    RCALL   spi_xfer
    RCALL   sd_wait_r1          ; R1 = response
    LOAD16  R0, VAR_TMP
    LD      (R0), R1
    RCALL   sd_deselect
    LOAD16  R1, str_cmd0
    RCALL   print_str
    LOAD16  R0, VAR_TMP
    LD      R1, (R0)
    RCALL   print_hex4
    RCALL   print_crlf
    LOAD16  R0, VAR_TMP
    LD      R1, (R0)
    DEC     R1                  ; expect 0x01 -> 0
    LOAD16  R3, sd_cmd8
    JMP.Z   R3, R1
    LOAD16  R1, str_sd_nocard
    RCALL   print_str
    LOAD16  R3, halt_loop
    JMP     R3

    ; 3. CMD8 (SEND_IF_COND, arg=0x000001AA, crc=0x87) -> expect R1 == 0x01
sd_cmd8:
    RCALL   sd_select
    LOAD16  R1, 0x0048
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0x0001
    RCALL   spi_xfer
    LOAD16  R1, 0x00AA
    RCALL   spi_xfer
    LOAD16  R1, 0x0087
    RCALL   spi_xfer
    RCALL   sd_wait_r1
    LOAD16  R0, VAR_TMP
    LD      (R0), R1
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    RCALL   sd_deselect
    LOAD16  R1, str_cmd8
    RCALL   print_str
    LOAD16  R0, VAR_TMP
    LD      R1, (R0)
    RCALL   print_hex4
    RCALL   print_crlf

    ; 4. Loop CMD55 + ACMD41 (HCS=1, arg=0x40000000) until R1 == 0x00
    LOAD16  R0, VAR_CNT
    LOAD16  R1, 2000
    LD      (R0), R1
sd_acmd41_loop:
    RCALL   sd_select
    LOAD16  R1, 0x0077          ; CMD55 = 0x40 | 55
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0x0065
    RCALL   spi_xfer
    RCALL   sd_wait_r1
    RCALL   sd_deselect

    RCALL   sd_select
    LOAD16  R1, 0x0069          ; ACMD41 = 0x40 | 41
    RCALL   spi_xfer
    LOAD16  R1, 0x0040          ; HCS=1
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0x0077
    RCALL   spi_xfer
    RCALL   sd_wait_r1
    LOAD16  R0, VAR_TMP
    LD      (R0), R1
    RCALL   sd_deselect

    LOAD16  R0, VAR_TMP
    LD      R1, (R0)
    LOAD16  R3, sd_ready
    JMP.Z   R3, R1

    LOAD16  R0, VAR_CNT
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R3, sd_acmd_timeout
    JMP.Z   R3, R1
    LOAD16  R3, sd_acmd41_loop
    JMP     R3

sd_acmd_timeout:
    LOAD16  R1, str_sd_timeout
    RCALL   print_str
    LOAD16  R3, halt_loop
    JMP     R3

    ; 5. Switch to fast clock (~12 MHz, CS_N=1, FAST=1 -> 0x0003) & CMD17 Sector 0!
sd_ready:
    LOAD16  R0, SPI_CTRL
    LOAD16  R1, 0x0003
    LD      (R0), R1
    LOAD16  R1, str_sd_init_ok
    RCALL   print_str

    RCALL   sd_select
    LOAD16  R1, 0x0051          ; CMD17 = 0x40 | 17 (READ_SINGLE_BLOCK LBA 0)
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0
    RCALL   spi_xfer
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    RCALL   sd_wait_r1
    LOAD16  R3, sd_wait_tok
    JMP.Z   R3, R1
    RCALL   sd_deselect
    LOAD16  R1, str_sd_rd_fail
    RCALL   print_str
    LOAD16  R3, halt_loop
    JMP     R3

sd_wait_tok:
    LOAD16  R0, VAR_CNT
    LOAD16  R1, 10000
    LD      (R0), R1
sd_tok_loop:
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    LOAD16  R2, 0x00FE
    SUB     R1, R2
    LOAD16  R3, sd_read_512
    JMP.Z   R3, R1
    LOAD16  R0, VAR_CNT
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R3, sd_tok_fail
    JMP.Z   R3, R1
    LOAD16  R3, sd_tok_loop
    JMP     R3

sd_tok_fail:
    RCALL   sd_deselect
    LOAD16  R1, str_sd_rd_fail
    RCALL   print_str
    LOAD16  R3, halt_loop
    JMP     R3

sd_read_512:
    LOAD16  R0, VAR_PTR
    LOAD16  R1, SD_BUF
    LD      (R0), R1
    LOAD16  R0, VAR_CNT
    LOAD16  R1, 256
    LD      (R0), R1
sd_rd_word_loop:
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    LOAD16  R0, VAR_TMP
    LD      (R0), R1            ; low byte
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer            ; high byte in R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    LOAD16  R0, VAR_TMP
    LD      R2, (R0)
    OR      R1, R2              ; word = (hi << 8) | lo
    LOAD16  R0, VAR_PTR
    LD      R2, (R0)
    LD      (R2), R1
    INC     R2
    LD      (R0), R2
    LOAD16  R0, VAR_CNT
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R3, sd_rd_done
    JMP.Z   R3, R1
    LOAD16  R3, sd_rd_word_loop
    JMP     R3

sd_rd_done:
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    RCALL   sd_deselect

    ; Print MBR word[0..1] and word[255] (expected 0xAA55 little-endian!)
    LOAD16  R1, str_mbr
    RCALL   print_str
    LOAD16  R0, SD_BUF
    LD      R1, (R0)
    RCALL   print_hex4
    LOAD16  R1, 0x0020
    RCALL   uart_putc
    LOAD16  R0, SD_BUF + 1
    LD      R1, (R0)
    RCALL   print_hex4
    LOAD16  R1, str_sig
    RCALL   print_str
    LOAD16  R0, SD_BUF + 255
    LD      R1, (R0)
    RCALL   print_hex4
    RCALL   print_crlf

halt_loop:
    LOAD16  R3, halt_loop
    JMP     R3

; ==============================================================================
; Subroutines (uniform RPUSH R0 / RRET discipline)
; ==============================================================================
math_set_a:
    RPUSH   R0
    LOAD16  R0, MATH_A_LO
    LD      (R0), R1
    LOAD16  R0, MATH_A_HI
    LD      (R0), R2
    RRET

math_set_b:
    RPUSH   R0
    LOAD16  R0, MATH_B_LO
    LD      (R0), R1
    LOAD16  R0, MATH_B_HI
    LD      (R0), R2
    RRET

math_exec:
    RPUSH   R0
    LOAD16  R0, MATH_CMD
    LD      (R0), R1
math_poll:
    LOAD16  R0, MATH_CMD
    LD      R1, (R0)
    LD      R0, 1
    AND     R1, R0
    LOAD16  R3, math_done
    JMP.Z   R3, R1
    LOAD16  R3, math_poll
    JMP     R3
math_done:
    RRET

; Expects R1 = exp_lo, R2 = exp_hi; increments VAR_FAIL on mismatch
math_check:
    RPUSH   R0
    LOAD16  R0, MATH_RES_LO
    LD      R3, (R0)
    SUB     R3, R1
    LOAD16  R0, math_chk_hi
    JMP.Z   R0, R3
    LOAD16  R0, VAR_FAIL
    LD      R3, (R0)
    INC     R3
    LD      (R0), R3
    RRET
math_chk_hi:
    LOAD16  R0, MATH_RES_HI
    LD      R3, (R0)
    SUB     R3, R2
    LOAD16  R0, math_chk_ok
    JMP.Z   R0, R3
    LOAD16  R0, VAR_FAIL
    LD      R3, (R0)
    INC     R3
    LD      (R0), R3
math_chk_ok:
    RRET

sd_select:
    RPUSH   R0
    LOAD16  R0, SPI_CTRL
    LD      R1, (R0)
    LOAD16  R2, 0xFFFE
    AND     R1, R2
    LD      (R0), R1
    RRET

sd_deselect:
    RPUSH   R0
    LOAD16  R0, SPI_CTRL
    LD      R1, (R0)
    LOAD16  R2, 1
    OR      R1, R2
    LD      (R0), R1
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    RRET

; R1 = tx byte -> returns R1 = rx byte
spi_xfer:
    RPUSH   R0
    LOAD16  R0, SPI_DATA
    LD      (R0), R1
spi_wait:
    LOAD16  R0, SPI_STAT
    LD      R1, (R0)
    LD      R0, 1
    AND     R1, R0
    LOAD16  R3, spi_done
    JMP.Z   R3, R1
    LOAD16  R3, spi_wait
    JMP     R3
spi_done:
    LOAD16  R0, SPI_DATA
    LD      R1, (R0)
    LOAD16  R2, 0x00FF
    AND     R1, R2
    RRET

; Wait up to 16 bytes for SD R1 (bit 7 == 0), returns in R1
sd_wait_r1:
    RPUSH   R0
    LOAD16  R0, VAR_R1_CNT
    LOAD16  R1, 16
    LD      (R0), R1
sd_r1_lp:
    LOAD16  R1, 0x00FF
    RCALL   spi_xfer
    LOAD16  R2, 0x0080
    AND     R2, R1
    LOAD16  R3, sd_r1_ret
    JMP.Z   R3, R2
    LOAD16  R0, VAR_R1_CNT
    LD      R2, (R0)
    DEC     R2
    LD      (R0), R2
    LOAD16  R3, sd_r1_ret
    JMP.Z   R3, R2
    LOAD16  R3, sd_r1_lp
    JMP     R3
sd_r1_ret:
    RRET

uart_putc:
    RPUSH   R0
    LOAD16  R0, UART_TX_ADDR
uart_wait:
    LD      R2, (R0)
    LOAD16  R3, uart_send
    JMP.Z   R3, R2
    LOAD16  R3, uart_wait
    JMP     R3
uart_send:
    LD      (R0), R1
    RRET

print_crlf:
    RPUSH   R0
    LOAD16  R1, 0x000D
    RCALL   uart_putc
    LOAD16  R1, 0x000A
    RCALL   uart_putc
    RRET

; R1 = pointer to packed .asciz string (2 bytes per 16-bit word, lo then hi)
print_str:
    RPUSH   R0
    LOAD16  R0, VAR_STR_PTR
    LD      (R0), R1
ps_loop:
    LOAD16  R0, VAR_STR_PTR
    LD      R2, (R0)
    LD      R3, (R2)
    INC     R2
    LD      (R0), R2
    LOAD16  R0, VAR_STR_W
    LD      (R0), R3
    BYTE_GET_LO R1, R3
    LOAD16  R3, ps_done
    JMP.Z   R3, R1
    RCALL   uart_putc
    LOAD16  R0, VAR_STR_W
    LD      R3, (R0)
    BYTE_GET_HI R1, R3
    LOAD16  R3, ps_done
    JMP.Z   R3, R1
    RCALL   uart_putc
    LOAD16  R3, ps_loop
    JMP     R3
ps_done:
    RRET

; R1 = 16-bit value -> prints 4 uppercase hex digits
print_hex4:
    RPUSH   R0
    LOAD16  R0, VAR_HEX_VAL
    LD      (R0), R1
    LOAD16  R0, VAR_HEX_CNT
    LOAD16  R1, 4
    LD      (R0), R1
ph_loop:
    LOAD16  R0, VAR_HEX_VAL
    LD      R1, (R0)
    ROT.L   R1
    ROT.L   R1
    ROT.L   R1
    ROT.L   R1
    LD      (R0), R1
    LOAD16  R2, 0x000F
    AND     R1, R2
    LOAD16  R0, 9
    SUB     R0, R1
    LOAD16  R3, ph_af
    JMP.M   R3, R0
    LOAD16  R0, 48
    ADD     R1, R0
    LOAD16  R3, ph_emit
    JMP     R3
ph_af:
    LOAD16  R0, 55
    ADD     R1, R0
ph_emit:
    RCALL   uart_putc
    LOAD16  R0, VAR_HEX_CNT
    LD      R2, (R0)
    DEC     R2
    LD      (R0), R2
    LOAD16  R3, ph_done
    JMP.Z   R3, R2
    LOAD16  R3, ph_loop
    JMP     R3
ph_done:
    RRET

str_banner:
    .asciz "\r\n=== MR4 Track A.3 HW Verify (SPI microSD + 1-DSP Math) ===\r\n"
str_ver:
    .asciz "CPU_VER: 0x"
str_caps:
    .asciz "  CPU_CAPS: 0x"
str_math_hdr:
    .asciz "Testing 1-DSP MathAccelerator (0x0010-0x0016)... "
str_math_pass:
    .asciz "PASS (12/12)\r\n"
str_fail:
    .asciz "FAIL errs=0x"
str_sd_hdr:
    .asciz "Testing microSD SPI (0x0018-0x001A)...\r\n"
str_cmd0:
    .asciz "  CMD0 R1=0x"
str_cmd8:
    .asciz "  CMD8 R1=0x"
str_sd_nocard:
    .asciz "  SD: No card or idle failed (expected R1=0x0001)\r\n"
str_sd_timeout:
    .asciz "  SD: ACMD41 timeout\r\n"
str_sd_init_ok:
    .asciz "  SD: SDHC init OK (switched to 12 MHz), reading Sector 0...\r\n"
str_sd_rd_fail:
    .asciz "  SD: CMD17 read failed\r\n"
str_mbr:
    .asciz "  MBR[0..1]=0x"
str_sig:
    .asciz "  SIG(expect AA55)=0x"

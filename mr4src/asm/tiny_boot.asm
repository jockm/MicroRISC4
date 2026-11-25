; ==============================================================================
; FILE: mr4src/asm/tiny_boot.asm
; Architecture: MicroRISC4 Tiny Tapeout Boot ROM (0x0100 - 0x01FF, <= 256 words)
; Target: `tt_um_mr4` (16-word local scratchpad + 256-word Boot ROM + QSPI PSRAM/Flash)
;
; Memory Map:
;   0x0000 - 0x0003 : SAVEALL / LOADALL scratchpad (on-chip 16-word flop RAM)
;   0x0004          : RSP (initialized to 0xFEFF in external QSPI PSRAM)
;   0x0005          : ASP (initialized to 0xFAFF in external QSPI PSRAM)
;   0x0006 - 0x0007 : Boot ROM scratch (return addr & low-byte staging)
;   0x000E - 0x000F : UART RX / TX MMIO
;   0x0100 - 0x01FF : Synthesizable AsicBootRom (this file)
;   0x0200 - 0xFFFF : External QSPI PSRAM (CS1) or XIP Flash (CS0 when ui_in[1]=1)
;
; Boot Sequence:
;   1. Initialize RSP = 0xFEFF and ASP = 0xFAFF in external QSPI PSRAM.
;   2. Auto-boot check: if word [0x0400] == 0x4D34 ("M4"), jump immediately to 0x0401
;      (supports instant XIP execution from QSPI Flash when ui_in[1]=1 or preloaded PSRAM).
;   3. Print banner "MR4 TT\r\n" over UART TX.
;   4. Enter compact binary UART loader / monitor loop:
;        '?' (0x3F)                        -> replies '!' (0x21)
;        'L' (0x4C) addr_lo hi len_lo hi   -> receives `len` LE 16-bit words into QSPI PSRAM, replies 'K'
;        'G' (0x47) addr_lo hi             -> replies 'G', then JMP addr
;        'P' (0x50) addr_lo hi             -> reads word [addr], replies lo_byte, hi_byte
; ==============================================================================

.include "common.inc"

.define TINY_RSP_INIT   0xFEFF
.define TINY_ASP_INIT   0xFAFF
.define SCRATCH_RET     6
.define SCRATCH_LO      7
.define AUTOBOOT_ADDR   0x0400
.define AUTOBOOT_MAGIC  0x4D34      ; "M4"

; ==============================================================================
; Reset Entry & Compact Bootloader (0x0100 - 0x01EF)
; Note: enableCrossTraps=false on tt_um_mr4, so only Trap 0 (0x0100) and
; Trap 15 (0x01F0) can fire, giving 240 contiguous words for the Boot ROM.
; ==============================================================================
.org 0x0100
_trap0_reset:
    ; 1. Initialize Return Stack Pointer (0x0004) & Argument Stack Pointer (0x0005)
    LOAD16  R1, TINY_RSP_INIT
    LD      R0, 4
    LD      (R0), R1
    LOAD16  R1, TINY_ASP_INIT
    INC     R0
    LD      (R0), R1

    ; 2. Auto-boot check: if [0x0400] == 0x4D34 ("M4"), execute [0x0401]
    LOAD16  R0, AUTOBOOT_ADDR
    LD      R1, (R0)
    LOAD16  R2, AUTOBOOT_MAGIC
    SUB     R1, R2
    LOAD16  R2, _autoboot
    JMP.Z   R2, R1
    LOAD16  R2, _banner
    JMP     R2
_autoboot:
    INC     R0
    JMP     R0

    ; 3. Emit boot banner "MR4 TT\r\n" over UART
_banner:
    LOAD16  R2, _str_banner
_banner_loop:
    LD      R3, (R2++)
    BYTE_GET_LO R1, R3
    LOAD16  R0, _cmd_loop
    JMP.Z   R0, R1
    LOAD16  R0, _putc
    LINK    R0, R0
    BYTE_GET_HI R1, R3
    LOAD16  R0, _cmd_loop
    JMP.Z   R0, R1
    LOAD16  R0, _putc
    LINK    R0, R0
    LOAD16  R0, _banner_loop
    JMP     R0

    ; 4. Compact Binary UART Loader Command Dispatch Loop
_cmd_loop:
    LOAD16  R0, _getc
    LINK    R0, R0

    ; '?' (0x3F) -> ping reply '!'
    LOAD16  R0, 0x003F
    SUB     R0, R1
    LOAD16  R2, _do_ping
    JMP.Z   R2, R0

    ; 'L' (0x4C) -> Load `len` 16-bit LE words into [addr..]
    LOAD16  R0, 0x004C
    SUB     R0, R1
    LOAD16  R2, _do_load
    JMP.Z   R2, R0

    ; 'G' (0x47) -> Go / Jump to 16-bit address
    LOAD16  R0, 0x0047
    SUB     R0, R1
    LOAD16  R2, _do_go
    JMP.Z   R2, R0

    ; 'P' (0x50) -> Peek 16-bit word at [addr], reply lo then hi
    LOAD16  R0, 0x0050
    SUB     R0, R1
    LOAD16  R2, _do_peek
    JMP.Z   R2, R0

    LOAD16  R0, _cmd_loop
    JMP     R0

_do_ping:
    LOAD16  R1, 0x0021              ; '!'
    LOAD16  R0, _putc
    LINK    R0, R0
    LOAD16  R0, _cmd_loop
    JMP     R0

_do_load:
    LOAD16  R0, _get16
    LINK    R0, R0
    LD      R2, R1                  ; R2 = target word address
    LOAD16  R0, _get16
    LINK    R0, R0
    LD      R3, R1                  ; R3 = word count
_load_loop:
    LOAD16  R0, _load_done
    JMP.Z   R0, R3
    LOAD16  R0, _get16
    LINK    R0, R0
    LD      (R2), R1
    INC     R2
    DEC     R3
    LOAD16  R0, _load_loop
    JMP     R0
_load_done:
    LOAD16  R1, 0x004B              ; 'K'
    LOAD16  R0, _putc
    LINK    R0, R0
    LOAD16  R0, _cmd_loop
    JMP     R0

_do_go:
    LOAD16  R0, _get16
    LINK    R0, R0
    LD      R2, R1                  ; R2 = jump target
    LOAD16  R1, 0x0047              ; 'G' ack
    LOAD16  R0, _putc
    LINK    R0, R0
    JMP     R2

_do_peek:
    LOAD16  R0, _get16
    LINK    R0, R0
    LD      R2, R1
    LD      R3, (R2)
    LD      R1, R3                  ; Low byte
    LOAD16  R0, _putc
    LINK    R0, R0
    BYTE_GET_HI R1, R3              ; High byte
    LOAD16  R0, _putc
    LINK    R0, R0
    LOAD16  R0, _cmd_loop
    JMP     R0

; ==============================================================================
; Leaf Subroutines (Zero PSRAM stack traffic; preserves R2 & R3)
; ==============================================================================

; _putc: Transmit low byte of R1 over UART TX (0x000F). Preserves R1, R2, R3.
_putc:
    XCHG    R0                      ; Shadow R0 holds return address
    XCHG    R2
    XCHG    R3
    LD      R0, 15                  ; UART_TX_ADDR = 0x000F
_putc_wait:
    LD      R2, (R0)
    LOAD16  R3, _putc_send
    JMP.Z   R3, R2
    LOAD16  R3, _putc_wait
    JMP     R3
_putc_send:
    LD      (R0), R1
    XCHG    R3
    XCHG    R2
    XCHG    R0
    JMP     R0

; _getc: Receive one byte into R1 (0x00..0xFF) from UART RX (0x000E). Preserves R2, R3.
_getc:
    XCHG    R0                      ; Shadow R0 holds return address
    XCHG    R2
    LD      R0, 14                  ; UART_RX_ADDR = 0x000E
_getc_wait:
    LD      R1, (R0)
    LOAD16  R2, _getc_ok
    JMP.M   R2, R1
    LOAD16  R2, _getc_wait
    JMP     R2
_getc_ok:
    LOAD16  R2, 0x00FF
    AND     R1, R2
    XCHG    R2
    XCHG    R0
    JMP     R0

; _get16: Receive 16-bit little-endian word into R1. Preserves R2, R3.
; Uses local on-chip scratchpad [0x0006] (ret) and [0x0007] (lo byte).
_get16:
    XCHG    R3
    LD      R3, R0                  ; Save return addr via shadow R3
    LD      R0, SCRATCH_RET
    LD      (R0), R3
    XCHG    R3
    LOAD16  R0, _getc
    LINK    R0, R0
    LD      R0, SCRATCH_LO
    LD      (R0), R1                ; Save low byte
    LOAD16  R0, _getc
    LINK    R0, R0
    PUSH8   R1, 0x00                ; R1 = hi << 8
    LD      R0, SCRATCH_LO
    LD      R0, (R0)
    OR      R1, R0                  ; R1 = (hi << 8) | lo
    LD      R0, SCRATCH_RET
    LD      R0, (R0)
    JMP     R0

_str_banner:
    .asciz "MR4 TT\r\n"

; ==============================================================================
; Trap 15: Alignment / Fault Halt Vector (0x01F0)
; ==============================================================================
.org 0x01F0
_trap15_fault:
    LOAD16  R0, _trap15_halt
_trap15_halt:
    JMP     R0

; ==============================================================================
; Compiled by ACT4 MiniRISC4 Compiler (act4c)
; Target: MiniRISC4 16-bit Architecture
; ==============================================================================
.include "common.inc"
.include "M4R_LIB.asm"


.org 0x0100

; --- Entry Point ---
_start:
    START_PROGRAM
_halt:
    LOAD16  R0, _halt
    JMP     R0

; --- Function: putc ---
_putc:
    RPUSH   R0
_while_start_1:
    LOAD16  R0, 0x000F
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SUB     R1, R2
    LOAD16  R0, _while_exit_2
    JMP.Z   R0, R1
; // Wait until UART TX status indicates idle (0x0000)
    LOAD16  R0, _while_start_1
    JMP     R0
_while_exit_2:
    LOAD16  R0, _putc_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, 0x000F
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    RRET

_putc_ch: .word 0

; --- Function: getc ---
_getc:
    RPUSH   R0
_while_start_3:
    LOAD16  R0, _getc_val
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x8000
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    AND     R1, R2
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SUB     R1, R2
    LOAD16  R0, _eq_skip_5
    JMP.Z   R0, R1
    LOAD16  R0, _while_exit_4
    JMP     R0
_eq_skip_5:
    LOAD16  R0, 0x000E
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _getc_val
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
; // Bit 15 indicates data ready
    LOAD16  R0, _while_start_3
    JMP     R0
_while_exit_4:
    LOAD16  R0, _getc_val
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x00FF
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    AND     R1, R2
    RRET
    RRET

_getc_val: .word 0

; --- Function: puts ---
_puts:
    RPUSH   R0
    LOAD16  R0, _puts_str
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      R2, (R0)
    LD0     R0
    INC     R0
    AND     R2, R0
    LOAD16  R0, _get_hi_6
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_7
    JMP     R0
_get_hi_6:
    BYTE_GET_LO R1, R1
_get_done_7:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _puts_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
_while_start_8:
    LOAD16  R0, _puts_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SUB     R1, R2
    LOAD16  R0, _while_exit_9
    JMP.Z   R0, R1
    LOAD16  R0, _puts_ch
    LD      R1, (R0)
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
    LOAD16  R0, _puts_i
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R0, _puts_str
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _puts_i
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      R2, (R0)
    LD0     R0
    INC     R0
    AND     R2, R0
    LOAD16  R0, _get_hi_10
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_11
    JMP     R0
_get_hi_10:
    BYTE_GET_LO R1, R1
_get_done_11:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _puts_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _while_start_8
    JMP     R0
_while_exit_9:
    RRET

_puts_i: .word 0
_puts_ch: .word 0
_puts_str: .word 0

; --- Function: print_nibble ---
_print_nibble:
    RPUSH   R0
    LOAD16  R0, _print_nibble_n
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x000F
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    AND     R1, R2
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _print_nibble_v
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _print_nibble_v
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x000A
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    RCALL   _CMP_GE
    LOAD16  R2, _else_12
    JMP.Z   R2, R0
    LOAD16  R0, _print_nibble_v
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0030
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    ADD     R1, R2
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
; // '0'..'9'
    LOAD16  R0, _endif_13
    JMP     R0
_else_12:
    LOAD16  R0, _print_nibble_v
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0037
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    ADD     R1, R2
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
; // 'A'..'F'
_endif_13:
    RRET

_print_nibble_v: .word 0
_print_nibble_n: .word 0

; --- Function: print_hex16 ---
_print_hex16:
    RPUSH   R0
    LOAD16  R0, _print_hex16_val
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x000C
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    LOAD16  R0, _print_nibble_n
    LD      (R0), R1
    RCALL   _print_nibble
    LOAD16  R0, _print_hex16_val
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0008
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    LOAD16  R0, _print_nibble_n
    LD      (R0), R1
    RCALL   _print_nibble
    LOAD16  R0, _print_hex16_val
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0004
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    LOAD16  R0, _print_nibble_n
    LD      (R0), R1
    RCALL   _print_nibble
    LOAD16  R0, _print_hex16_val
    LD      R1, (R0)
    LOAD16  R0, _print_nibble_n
    LD      (R0), R1
    RCALL   _print_nibble
    RRET

_print_hex16_val: .word 0

; --- Function: print_space ---
_print_space:
    RPUSH   R0
    LOAD16  R1, 0x0020
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
; // ' '
    RRET


; --- Function: print_newline ---
_print_newline:
    RPUSH   R0
    LOAD16  R1, 0x000D
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
; // '\r'
    LOAD16  R1, 0x000A
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
; // '\n'
    RRET


; --- Function: read_line ---
_read_line:
    RPUSH   R0
_while_start_14:
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0027
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    RCALL   _CMP_GE
    LOAD16  R2, _while_exit_15
    JMP.Z   R2, R0
    RCALL   _getc
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x000D
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x000A
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _else_16
    JMP.Z   R0, R1
    LOAD16  R0, _line_buf
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LOAD16  R0, _act4_t2
    LD      (R0), R1
    LOAD16  R0, _act4_t1
    LD      R1, (R0)
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LOAD16  R0, _act4_t3
    LD      (R0), R1
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t2
    LD      R2, (R0)
    LOAD16  R0, _act4_t1
    LD      R3, (R0)
    LD0     R0
    INC     R0
    AND     R3, R0
    LOAD16  R0, _set_hi_18
    JMP.Z   R0, R3
    BYTE_SET_HI R1, R2
    LOAD16  R0, _set_done_19
    JMP     R0
_set_hi_18:
    BYTE_SET_LO R1, R2
_set_done_19:
    LOAD16  R0, _act4_t3
    LD      R0, (R0)
    LD      (R0), R1
    RCALL   _print_newline
    RRET
    LOAD16  R0, _endif_17
    JMP     R0
_else_16:
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0008
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x007F
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _else_20
    JMP.Z   R0, R1
; // Backspace
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    RCALL   _CMP_LE
    LOAD16  R2, _endif_23
    JMP.Z   R2, R0
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R1, 0x0008
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
    LOAD16  R1, 0x0020
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
    LOAD16  R1, 0x0008
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
_endif_23:
    LOAD16  R0, _endif_21
    JMP     R0
_else_20:
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0020
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x007E
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _endif_25
    JMP.Z   R0, R1
    LOAD16  R0, _line_buf
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t2
    LD      (R0), R1
    LOAD16  R0, _act4_t1
    LD      R1, (R0)
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LOAD16  R0, _act4_t3
    LD      (R0), R1
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t2
    LD      R2, (R0)
    LOAD16  R0, _act4_t1
    LD      R3, (R0)
    LD0     R0
    INC     R0
    AND     R3, R0
    LOAD16  R0, _set_hi_26
    JMP.Z   R0, R3
    BYTE_SET_HI R1, R2
    LOAD16  R0, _set_done_27
    JMP     R0
_set_hi_26:
    BYTE_SET_LO R1, R2
_set_done_27:
    LOAD16  R0, _act4_t3
    LD      R0, (R0)
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    LOAD16  R0, _putc_ch
    LD      (R0), R1
    RCALL   _putc
; // Echo
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
_endif_25:
_endif_21:
_endif_17:
    LOAD16  R0, _while_start_14
    JMP     R0
_while_exit_15:
    LOAD16  R0, _line_buf
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LOAD16  R0, _act4_t2
    LD      (R0), R1
    LOAD16  R0, _act4_t1
    LD      R1, (R0)
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LOAD16  R0, _act4_t3
    LD      (R0), R1
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t2
    LD      R2, (R0)
    LOAD16  R0, _act4_t1
    LD      R3, (R0)
    LD0     R0
    INC     R0
    AND     R3, R0
    LOAD16  R0, _set_hi_28
    JMP.Z   R0, R3
    BYTE_SET_HI R1, R2
    LOAD16  R0, _set_done_29
    JMP     R0
_set_hi_28:
    BYTE_SET_LO R1, R2
_set_done_29:
    LOAD16  R0, _act4_t3
    LD      R0, (R0)
    LD      (R0), R1
    RCALL   _print_newline
    RRET

_read_line_idx: .word 0
_read_line_ch: .word 0

; --- Function: skip_spaces ---
_skip_spaces:
    RPUSH   R0
    LOAD16  R0, _line_buf
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      R2, (R0)
    LD0     R0
    INC     R0
    AND     R2, R0
    LOAD16  R0, _get_hi_30
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_31
    JMP     R0
_get_hi_30:
    BYTE_GET_LO R1, R1
_get_done_31:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _skip_spaces_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
_while_start_32:
    LOAD16  R0, _skip_spaces_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0020
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _skip_spaces_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0009
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _while_exit_33
    JMP.Z   R0, R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R0, _line_buf
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      R2, (R0)
    LD0     R0
    INC     R0
    AND     R2, R0
    LOAD16  R0, _get_hi_34
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_35
    JMP     R0
_get_hi_34:
    BYTE_GET_LO R1, R1
_get_done_35:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _skip_spaces_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _while_start_32
    JMP     R0
_while_exit_33:
    RRET

_skip_spaces_ch: .word 0

; --- Function: parse_hex ---
_parse_hex:
    RPUSH   R0
    RCALL   _skip_spaces
    LOAD16  R0, _line_buf
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      R2, (R0)
    LD0     R0
    INC     R0
    AND     R2, R0
    LOAD16  R0, _get_hi_36
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_37
    JMP     R0
_get_hi_36:
    BYTE_GET_LO R1, R1
_get_done_37:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
_while_start_38:
    LOAD16  R1, 0x0001
    LOAD16  R0, _while_exit_39
    JMP.Z   R0, R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0030
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0039
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _else_40
    JMP.Z   R0, R1
; // '0'..'9'
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0004
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0030
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SUB     R1, R2
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    OR      R1, R2
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_res
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R0, _endif_41
    JMP     R0
_else_40:
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0041
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0046
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _else_42
    JMP.Z   R0, R1
; // 'A'..'F'
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0004
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0037
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SUB     R1, R2
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    OR      R1, R2
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_res
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R0, _endif_43
    JMP     R0
_else_42:
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0061
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0066
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _else_44
    JMP.Z   R0, R1
; // 'a'..'f'
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0004
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0057
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SUB     R1, R2
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    OR      R1, R2
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_res
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R0, _endif_45
    JMP     R0
_else_44:
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    RRET
_endif_45:
_endif_43:
_endif_41:
    LOAD16  R0, _line_buf
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      R2, (R0)
    LD0     R0
    INC     R0
    AND     R2, R0
    LOAD16  R0, _get_hi_46
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_47
    JMP     R0
_get_hi_46:
    BYTE_GET_LO R1, R1
_get_done_47:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _while_start_38
    JMP     R0
_while_exit_39:
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    RRET
    RRET

_parse_hex_res: .word 0
_parse_hex_ch: .word 0

; --- Function: do_examine ---
_do_examine:
    RPUSH   R0
    RCALL   _parse_hex
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_examine_addr
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _do_examine_addr
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_examine_ptr
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _do_examine_addr
    LD      R1, (R0)
    LOAD16  R0, _print_hex16_val
    LD      (R0), R1
    RCALL   _print_hex16
    LOAD16  R1, _str_lit_0
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
_while_start_48:
    LOAD16  R0, _do_examine_i
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0008
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    RCALL   _CMP_GE
    LOAD16  R2, _while_exit_49
    JMP.Z   R2, R0
    LOAD16  R0, _do_examine_ptr
    LD      R1, (R0)
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _print_hex16_val
    LD      (R0), R1
    RCALL   _print_hex16
    RCALL   _print_space
    LOAD16  R0, _do_examine_ptr
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R0, _do_examine_i
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R0, _while_start_48
    JMP     R0
_while_exit_49:
    RCALL   _print_newline
    RRET

_do_examine_addr: .word 0
_do_examine_i: .word 0
_do_examine_ptr: .word 0

; --- Function: do_change ---
_do_change:
    RPUSH   R0
    RCALL   _parse_hex
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_change_addr
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    RCALL   _parse_hex
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_change_val
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _do_change_addr
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_change_ptr
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _do_change_val
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_change_ptr
    LD      R1, (R0)
    LD      R0, R1
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R1, _str_lit_1
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R0, _do_change_val
    LD      R1, (R0)
    LOAD16  R0, _print_hex16_val
    LD      (R0), R1
    RCALL   _print_hex16
    LOAD16  R1, _str_lit_2
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R0, _do_change_addr
    LD      R1, (R0)
    LOAD16  R0, _print_hex16_val
    LD      (R0), R1
    RCALL   _print_hex16
    LOAD16  R1, _str_lit_3
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    RCALL   _print_newline
    RRET

_do_change_addr: .word 0
_do_change_val: .word 0
_do_change_ptr: .word 0

; --- Function: do_go ---
_do_go:
    RPUSH   R0
    RCALL   _parse_hex
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_go_addr
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _do_go_addr
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_go_target
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R1, _str_lit_4
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R0, _do_go_addr
    LD      R1, (R0)
    LOAD16  R0, _print_hex16_val
    LD      (R0), R1
    RCALL   _print_hex16
    LOAD16  R1, _str_lit_5
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R0, _do_go_target
    LD      R1, (R0)
    LD      R2, R1
    LINK    R2, R0
    RRET

_do_go_addr: .word 0
_do_go_target: .word 0

; --- Function: main ---
_main:
    RPUSH   R0
    LOAD16  R1, _str_lit_6
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R1, _str_lit_7
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R1, _str_lit_8
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R1, _str_lit_9
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R1, _str_lit_10
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R1, _str_lit_11
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    LOAD16  R1, _str_lit_12
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
_while_start_50:
    LOAD16  R1, 0x0001
    LOAD16  R0, _while_exit_51
    JMP.Z   R0, R1
    LOAD16  R1, _str_lit_13
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    RCALL   _read_line
    LOAD16  R1, 0x0000
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    RCALL   _skip_spaces
    LOAD16  R0, _line_buf
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      (R0), R1
    SHIFT.R R1
    LOAD16  R0, _act4_t0
    LD      R2, (R0)
    ADD     R1, R2
    LD      R0, R1
    LD      R1, (R0)
    LOAD16  R0, _act4_t1
    LD      R2, (R0)
    LD0     R0
    INC     R0
    AND     R2, R0
    LOAD16  R0, _get_hi_52
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_53
    JMP     R0
_get_hi_52:
    BYTE_GET_LO R1, R1
_get_done_53:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _main_cmd
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0065
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0045
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _else_54
    JMP.Z   R0, R1
; // 'e' or 'E'
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    RCALL   _do_examine
    LOAD16  R0, _endif_55
    JMP     R0
_else_54:
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0063
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0043
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _else_56
    JMP.Z   R0, R1
; // 'c' or 'C'
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    RCALL   _do_change
    LOAD16  R0, _endif_57
    JMP     R0
_else_56:
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0067
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0047
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    LOAD16  R0, _else_58
    JMP.Z   R0, R1
; // 'g' or 'G'
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    RCALL   _do_go
    LOAD16  R0, _endif_59
    JMP     R0
_else_58:
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    LOAD16  R0, _act4_t0
    LD      R1, (R0)
    SUB     R1, R2
    LOAD16  R0, _endif_61
    JMP.Z   R0, R1
    LOAD16  R1, _str_lit_14
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
_endif_61:
_endif_59:
_endif_57:
_endif_55:
    LOAD16  R0, _while_start_50
    JMP     R0
_while_exit_51:
    RRET

_main_cmd: .word 0

; ==============================================================================
; Global Data & Static Storage
; ==============================================================================
_act4_arg0: .word 0
_act4_arg1: .word 0
_act4_arg2: .word 0
_act4_arg3: .word 0
_act4_arg4: .word 0
_act4_arg5: .word 0
_act4_arg6: .word 0
_act4_arg7: .word 0
_act4_t0: .word 0
_act4_t1: .word 0
_act4_t2: .word 0
_act4_t3: .word 0
_act4_t4: .word 0
_act4_t5: .word 0
_act4_t6: .word 0
_act4_t7: .word 0
_line_buf: .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
_parse_idx: .word 0x0000

; --- String Literals ---
_str_lit_0: .asciz ": "
_str_lit_1: .asciz "Wrote "
_str_lit_2: .asciz " to ["
_str_lit_3: .asciz "]"
_str_lit_4: .asciz "Running at ["
_str_lit_5: .asciz "]...\r\n"
_str_lit_6: .asciz "\r\n============================\r\n"
_str_lit_7: .asciz "  MiniRISC4 ACT4 Monitor    \r\n"
_str_lit_8: .asciz "  Commands:                 \r\n"
_str_lit_9: .asciz "    e <addr>      (Examine) \r\n"
_str_lit_10: .asciz "    c <addr> <val>(Change)  \r\n"
_str_lit_11: .asciz "    g <addr>      (Go / Run)\r\n"
_str_lit_12: .asciz "============================\r\n"
_str_lit_13: .asciz "> "
_str_lit_14: .asciz "Unknown command. Use 'e <addr>', 'c <addr> <val>', or 'g <addr>'\r\n"

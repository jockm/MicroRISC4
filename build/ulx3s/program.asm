; ==============================================================================
; Compiled by ACT4 MiniRISC4 Compiler (act4c)
; Target: MiniRISC4 16-bit Architecture
; ==============================================================================
.include "common.inc"


; ==============================================================================
; Hardware Direct Stride Vector Table (0x0100 - 0x01FF)
; Fixed 16-word (32-byte) stride per vector slot
; ==============================================================================
.org 0x0100
_reset_slot:
    START_PROGRAM

.org 0x0110
_trap_1_slot:
    JMP     R0

.org 0x0120
_trap_2_slot:
    JMP     R0

.org 0x0130
_trap_3_slot:
    JMP     R0

.org 0x0140
_trap_4_slot:
    JMP     R0

.org 0x0150
_trap_5_slot:
    JMP     R0

.org 0x0160
_trap_6_slot:
    JMP     R0

.org 0x0170
_trap_7_slot:
    JMP     R0

.org 0x0180
_trap_8_slot:
    JMP     R0

.org 0x0190
_trap_9_slot:
    JMP     R0

.org 0x01A0
_trap_10_slot:
    JMP     R0

.org 0x01B0
_trap_11_slot:
    JMP     R0

.org 0x01C0
_trap_12_slot:
    JMP     R0

.org 0x01D0
_trap_13_slot:
    JMP     R0

.org 0x01E0
_trap_14_slot:
    JMP     R0

.org 0x01F0
_trap_15_slot:
    JMP     R0

; ==============================================================================
; Application Code & Global Storage (Origin 0x0200)
; ==============================================================================
.org 0x0200

; --- Function: putc ---
_putc:
    RPUSH   R0
_while_start_1:
    LOAD16  R0, 0x000F
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    APOP    R1
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
    LOAD16  R1, 0x0000
    LOAD16  R0, _getc_val
    LD      (R0), R1
_while_start_3:
    LOAD16  R0, _getc_val
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x8000
    LD      R2, R1
    APOP    R1
    AND     R1, R2
    APUSH   R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    APOP    R1
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
    APUSH   R1
    LOAD16  R1, 0x00FF
    LD      R2, R1
    APOP    R1
    AND     R1, R2
    RRET
    RRET

_getc_val: .word 0

; --- Function: puts ---
_puts:
    RPUSH   R0
    LOAD16  R1, 0x0000
    LOAD16  R0, _puts_i
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LOAD16  R0, _puts_ch
    LD      (R0), R1
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
    APUSH   R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    APOP    R1
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
    LOAD16  R1, 0x0000
    LOAD16  R0, _print_nibble_v
    LD      (R0), R1
    LOAD16  R0, _print_nibble_n
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x000F
    LD      R2, R1
    APOP    R1
    AND     R1, R2
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _print_nibble_v
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _print_nibble_v
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x000A
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_GE
    LOAD16  R2, _else_12
    DEC     R1
    JMP.Z   R2, R1
    LOAD16  R0, _print_nibble_v
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0030
    LD      R2, R1
    APOP    R1
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
    APUSH   R1
    LOAD16  R1, 0x0037
    LD      R2, R1
    APOP    R1
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
    APUSH   R1
    LOAD16  R1, 0x000C
    LD      R2, R1
    APOP    R1
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
    APUSH   R1
    LOAD16  R1, 0x0008
    LD      R2, R1
    APOP    R1
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
    APUSH   R1
    LOAD16  R1, 0x0004
    LD      R2, R1
    APOP    R1
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
    LOAD16  R1, 0x0000
    LOAD16  R0, _read_line_idx
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LOAD16  R0, _read_line_ch
    LD      (R0), R1
_while_start_14:
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0027
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_GE
    LOAD16  R2, _while_exit_15
    DEC     R1
    JMP.Z   R2, R1
    RCALL   _getc
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x000D
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _or_true_18
    JMP.Z   R0, R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x000A
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _eq_skip_19
    JMP.Z   R0, R1
    LOAD16  R0, _else_16
    JMP     R0
_eq_skip_19:
_or_true_18:
    LOAD16  R1, _line_buf
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
    LOAD16  R0, _set_hi_20
    JMP.Z   R0, R3
    BYTE_SET_HI R1, R2
    LOAD16  R0, _set_done_21
    JMP     R0
_set_hi_20:
    BYTE_SET_LO R1, R2
_set_done_21:
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
    APUSH   R1
    LOAD16  R1, 0x0008
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _or_true_24
    JMP.Z   R0, R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x007F
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _eq_skip_25
    JMP.Z   R0, R1
    LOAD16  R0, _else_22
    JMP     R0
_eq_skip_25:
_or_true_24:
; // Backspace
    LOAD16  R0, _read_line_idx
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_LE
    LOAD16  R2, _endif_27
    DEC     R1
    JMP.Z   R2, R1
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
_endif_27:
    LOAD16  R0, _endif_23
    JMP     R0
_else_22:
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0020
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_LT
    LOAD16  R2, _endif_29
    DEC     R1
    JMP.Z   R2, R1
    LOAD16  R0, _read_line_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x007E
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_GT
    LOAD16  R2, _endif_29
    DEC     R1
    JMP.Z   R2, R1
    LOAD16  R1, _line_buf
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
    LOAD16  R0, _set_hi_30
    JMP.Z   R0, R3
    BYTE_SET_HI R1, R2
    LOAD16  R0, _set_done_31
    JMP     R0
_set_hi_30:
    BYTE_SET_LO R1, R2
_set_done_31:
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
_endif_29:
_endif_23:
_endif_17:
    LOAD16  R0, _while_start_14
    JMP     R0
_while_exit_15:
    LOAD16  R1, _line_buf
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
    LOAD16  R0, _set_hi_32
    JMP.Z   R0, R3
    BYTE_SET_HI R1, R2
    LOAD16  R0, _set_done_33
    JMP     R0
_set_hi_32:
    BYTE_SET_LO R1, R2
_set_done_33:
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
    LOAD16  R1, 0x0000
    LOAD16  R0, _skip_spaces_ch
    LD      (R0), R1
    LOAD16  R1, _line_buf
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
_while_start_36:
    LOAD16  R0, _skip_spaces_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0020
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _or_true_38
    JMP.Z   R0, R1
    LOAD16  R0, _skip_spaces_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0009
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _eq_skip_39
    JMP.Z   R0, R1
    LOAD16  R0, _while_exit_37
    JMP     R0
_eq_skip_39:
_or_true_38:
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R1, _line_buf
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
    LOAD16  R0, _get_hi_40
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_41
    JMP     R0
_get_hi_40:
    BYTE_GET_LO R1, R1
_get_done_41:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _skip_spaces_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _while_start_36
    JMP     R0
_while_exit_37:
    RRET

_skip_spaces_ch: .word 0

; --- Function: parse_hex ---
_parse_hex:
    RPUSH   R0
    LOAD16  R1, 0x0000
    LOAD16  R0, _parse_hex_res
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LOAD16  R0, _parse_hex_ch
    LD      (R0), R1
    RCALL   _skip_spaces
    LOAD16  R1, _line_buf
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
    LOAD16  R0, _get_hi_42
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_43
    JMP     R0
_get_hi_42:
    BYTE_GET_LO R1, R1
_get_done_43:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _parse_hex_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
_while_start_44:
    LOAD16  R1, 0x0001
    LOAD16  R0, _while_exit_45
    JMP.Z   R0, R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0030
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_LT
    LOAD16  R2, _else_46
    DEC     R1
    JMP.Z   R2, R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0039
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_GT
    LOAD16  R2, _else_46
    DEC     R1
    JMP.Z   R2, R1
; // '0'..'9'
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0004
    LD      R2, R1
    APOP    R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    APUSH   R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0030
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LD      R2, R1
    APOP    R1
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
    LOAD16  R0, _endif_47
    JMP     R0
_else_46:
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0041
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_LT
    LOAD16  R2, _else_48
    DEC     R1
    JMP.Z   R2, R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0046
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_GT
    LOAD16  R2, _else_48
    DEC     R1
    JMP.Z   R2, R1
; // 'A'..'F'
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0004
    LD      R2, R1
    APOP    R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    APUSH   R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0037
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LD      R2, R1
    APOP    R1
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
    LOAD16  R0, _endif_49
    JMP     R0
_else_48:
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0061
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_LT
    LOAD16  R2, _else_50
    DEC     R1
    JMP.Z   R2, R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0066
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_GT
    LOAD16  R2, _else_50
    DEC     R1
    JMP.Z   R2, R1
; // 'a'..'f'
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0004
    LD      R2, R1
    APOP    R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    APUSH   R1
    LOAD16  R0, _parse_hex_ch
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0057
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LD      R2, R1
    APOP    R1
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
    LOAD16  R0, _endif_51
    JMP     R0
_else_50:
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    RRET
_endif_51:
_endif_49:
_endif_47:
    LOAD16  R1, _line_buf
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
    LOAD16  R0, _parse_hex_ch
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _while_start_44
    JMP     R0
_while_exit_45:
    LOAD16  R0, _parse_hex_res
    LD      R1, (R0)
    RRET
    RRET

_parse_hex_res: .word 0
_parse_hex_ch: .word 0

; --- Function: do_examine ---
_do_examine:
    RPUSH   R0
    LOAD16  R1, 0x0000
    LOAD16  R0, _do_examine_addr
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LOAD16  R0, _do_examine_i
    LD      (R0), R1
    RCALL   _skip_spaces
; // If no argument was provided (end of string), continue from dump_ptr
    LOAD16  R1, _line_buf
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
    LOAD16  R0, _get_hi_56
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_57
    JMP     R0
_get_hi_56:
    BYTE_GET_LO R1, R1
_get_done_57:
    APUSH   R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _eq_skip_58
    JMP.Z   R0, R1
    LOAD16  R0, _else_54
    JMP     R0
_eq_skip_58:
    LOAD16  R0, _dump_ptr
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_examine_addr
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _endif_55
    JMP     R0
_else_54:
    RCALL   _parse_hex
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _do_examine_addr
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
_endif_55:
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
_while_start_59:
    LOAD16  R0, _do_examine_i
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0008
    LD      R2, R1
    APOP    R1
    RCALL   _CMP_GE
    LOAD16  R2, _while_exit_60
    DEC     R1
    JMP.Z   R2, R1
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
    LOAD16  R0, _while_start_59
    JMP     R0
_while_exit_60:
    RCALL   _print_newline
; // Advance dump_ptr for subsequent consecutive 'e' commands
    LOAD16  R0, _do_examine_ptr
    LD      R1, (R0)
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _dump_ptr
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    RRET

_do_examine_addr: .word 0
_do_examine_i: .word 0
_do_examine_ptr: .word 0

; --- Function: do_change ---
_do_change:
    RPUSH   R0
    LOAD16  R1, 0x0000
    LOAD16  R0, _do_change_addr
    LD      (R0), R1
    LOAD16  R1, 0x0000
    LOAD16  R0, _do_change_val
    LD      (R0), R1
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
    LOAD16  R1, 0x0000
    LOAD16  R0, _do_go_addr
    LD      (R0), R1
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
    LOAD16  R1, _str_lit_6
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
    RRET

_do_go_addr: .word 0
_do_go_target: .word 0

; --- Function: main ---
_main:
    RPUSH   R0
    LOAD16  R1, 0x0000
    LOAD16  R0, _main_cmd
    LD      (R0), R1
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
    LOAD16  R1, _str_lit_13
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
_while_start_61:
    LOAD16  R1, 0x0001
    LOAD16  R0, _while_exit_62
    JMP.Z   R0, R1
    LOAD16  R1, _str_lit_14
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
    LOAD16  R1, _line_buf
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
    LOAD16  R0, _get_hi_63
    JMP.Z   R0, R2
    BYTE_GET_HI R1, R1
    LOAD16  R0, _get_done_64
    JMP     R0
_get_hi_63:
    BYTE_GET_LO R1, R1
_get_done_64:
    LOAD16  R0, _act4_t0
    LD      (R0), R1
    LOAD16  R0, _main_cmd
    LOAD16  R2, _act4_t0
    LD      R1, (R2)
    LD      (R0), R1
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0065
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _or_true_67
    JMP.Z   R0, R1
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0045
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _eq_skip_68
    JMP.Z   R0, R1
    LOAD16  R0, _else_65
    JMP     R0
_eq_skip_68:
_or_true_67:
; // 'e' or 'E'
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    RCALL   _do_examine
    LOAD16  R0, _endif_66
    JMP     R0
_else_65:
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0063
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _or_true_71
    JMP.Z   R0, R1
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0043
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _eq_skip_72
    JMP.Z   R0, R1
    LOAD16  R0, _else_69
    JMP     R0
_eq_skip_72:
_or_true_71:
; // 'c' or 'C'
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    RCALL   _do_change
    LOAD16  R0, _endif_70
    JMP     R0
_else_69:
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0067
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _or_true_75
    JMP.Z   R0, R1
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0047
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _eq_skip_76
    JMP.Z   R0, R1
    LOAD16  R0, _else_73
    JMP     R0
_eq_skip_76:
_or_true_75:
; // 'g' or 'G'
    LOAD16  R0, _parse_idx
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    RCALL   _do_go
    LOAD16  R0, _endif_74
    JMP     R0
_else_73:
    LOAD16  R0, _main_cmd
    LD      R1, (R0)
    APUSH   R1
    LOAD16  R1, 0x0000
    LD      R2, R1
    APOP    R1
    SUB     R1, R2
    LOAD16  R0, _endif_78
    JMP.Z   R0, R1
    LOAD16  R1, _str_lit_15
    LOAD16  R0, _puts_str
    LD      (R0), R1
    RCALL   _puts
_endif_78:
_endif_74:
_endif_70:
_endif_66:
    LOAD16  R0, _while_start_61
    JMP     R0
_while_exit_62:
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
_dump_ptr: .word 0x0000

; --- String Literals ---
_str_lit_0: .asciz ": "
_str_lit_1: .asciz "Wrote "
_str_lit_2: .asciz " to ["
_str_lit_3: .asciz "]"
_str_lit_4: .asciz "Running at ["
_str_lit_5: .asciz "]...\r\n"
_str_lit_6: .asciz "\r\n[Program returned to monitor]\r\n"
_str_lit_7: .asciz "\r\n============================\r\n"
_str_lit_8: .asciz "  MiniRISC4 ACT4 Monitor    \r\n"
_str_lit_9: .asciz "  Commands:                 \r\n"
_str_lit_10: .asciz "    e [<addr>]    (Examine) \r\n"
_str_lit_11: .asciz "    c <addr> <val>(Change)  \r\n"
_str_lit_12: .asciz "    g <addr>      (Go / Run)\r\n"
_str_lit_13: .asciz "============================\r\n"
_str_lit_14: .asciz "> "
_str_lit_15: .asciz "Unknown command. Use 'e [<addr>]', 'c <addr> <val>', or 'g <addr>'\r\n"

; ==============================================================================
; Standard Runtime Library (placed after application code & data)
; ==============================================================================
.include "M4R_LIB.asm"

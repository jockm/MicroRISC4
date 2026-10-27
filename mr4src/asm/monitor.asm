; ==============================================================================
; FILE: mr4src/asm/monitor.asm
; Architecture: MiniRISC4 16-Bit Word-Addressed Processor
; Target Hardware: Lattice ECP5 FPGA (ULX3S) / Verilog Core
; Description:
;   Interactive Serial Memory Monitor for the MiniRISC4 Architecture.
;
; Commands:
;   e [<addr>]       - Examine 8 words starting at <addr> (or next 8 words if omitted)
;   c <addr> <val>   - Change word at <addr> to <val>
;   g <addr>         - Go / Execute code at <addr>
;
; Table of Contents:
;   1. Program Entry & Stack Setup (_start)
;   2. Main Command Dispatch Loop (monitor_loop)
;   3. Command Implementations (cmd_go, cmd_examine, cmd_change)
;   4. String & Formatting Subroutines (puts, print_newline, print_hex16, print_nibble)
;   5. Terminal Line Input & Space Skipping (read_line, skip_spaces)
;   6. Hexadecimal Parsing Subroutine (parse_hex)
;   7. Static Banners, Prompts, Messages & Buffers
; ==============================================================================

.include "common.inc"

.org 0x0100

.equ TRAP_BASE, 0xFFF0

; ==============================================================================
; SECTION 1: Program Entry & Stack Initialization
; ==============================================================================
_start:
    START_PROGRAM

_main:
    ; 3. Print startup banner
    LOAD16  R1, msg_banner
    RCALL   puts

; ==============================================================================
; SECTION 2: Main Command Dispatch Loop
; ==============================================================================
monitor_loop:
    ; Display prompt: "> "
    LOAD16  R1, msg_prompt
    RCALL   puts

    ; Read interactive command line into line_buffer
    LOAD16  R1, line_buffer
    RCALL   read_line

    ; Skip leading spaces
    LOAD16  R3, line_buffer
    RCALL   skip_spaces

    ; Read command character from (R3++)
    LD      R1, (R3++)
    BYTE_GET_LO R1, R1

    ; Empty line check: if char == 0, loop
    XOR     R0, R0
    SUB     R0, R1
    LOAD16  R2, monitor_loop
    JMP.Z   R2, R0

    ; Check 'e' / 'E' (Examine)
    LOAD16  R0, 101             ; 'e'
    SUB     R0, R1
    LOAD16  R2, cmd_examine
    JMP.Z   R2, R0
    LOAD16  R0, 69              ; 'E'
    SUB     R0, R1
    LOAD16  R2, cmd_examine
    JMP.Z   R2, R0

    ; Check 'c' / 'C' (Change)
    LOAD16  R0, 99              ; 'c'
    SUB     R0, R1
    LOAD16  R2, cmd_change
    JMP.Z   R2, R0
    LOAD16  R0, 67              ; 'C'
    SUB     R0, R1
    LOAD16  R2, cmd_change
    JMP.Z   R2, R0

    ; Check 'g' / 'G' (Go / Run)
    LOAD16  R0, 103             ; 'g'
    SUB     R0, R1
    LOAD16  R2, cmd_go
    JMP.Z   R2, R0
    LOAD16  R0, 71              ; 'G'
    SUB     R0, R1
    LOAD16  R2, cmd_go
    JMP.Z   R2, R0

    ; Unknown command error
    LOAD16  R1, msg_unknown
    RCALL   puts
    LOAD16  R2, monitor_loop
    JMP     R2

; ==============================================================================
; SECTION 3: Command Implementations
; ==============================================================================

; ------------------------------------------------------------------------------
; COMMAND: 'g <addr>' (Go / Execute at target address)
; ------------------------------------------------------------------------------
cmd_go:
    RCALL   skip_spaces
    RCALL   parse_hex           ; Returns target address in R1
    LD      R2, R1              ; R2 = target execution address

    LOAD16  R1, msg_running
    RCALL   puts

    LD      R1, R2
    RCALL   print_hex16

    LOAD16  R1, msg_run_tail
    RCALL   puts

    LOAD16  R0, .go_return
    RPUSH   R0                  ; Save return link on Return Stack
    LINK    R2, R0              ; Call target

.go_return:
    LOAD16  R1, msg_returned
    RCALL   puts
    LOAD16  R2, monitor_loop
    JMP     R2


; ------------------------------------------------------------------------------
; COMMAND: 'e [<addr>]' (Examine 8 Words)
; ------------------------------------------------------------------------------
cmd_examine:
    RCALL   skip_spaces

    ; Peek at next character in buffer at R3
    LD      R1, (R3)
    BYTE_GET_LO R1, R1

    ; Check if empty (null terminator == 0) -> continue from last address
    XOR     R0, R0
    SUB     R0, R1
    LOAD16  R2, .use_prev_addr
    JMP.Z   R2, R0

    ; Address was typed -> parse it into R1
    RCALL   parse_hex
    LOAD16  R2, .start_dump
    JMP     R2

.use_prev_addr:
    LOAD16  R2, dump_ptr
    LD      R1, (R2)            ; Continue from where previous examine finished

.start_dump:
    ; Store current dump pointer to memory
    LOAD16  R2, dump_ptr
    LD      (R2), R1

    ; Print address header ("0000: ")
    RCALL   print_hex16
    LOAD16  R1, msg_colon
    RCALL   puts

    ; Initialize loop counter = 8 in memory
    LOAD16  R0, 8
    LOAD16  R2, dump_cnt
    LD      (R2), R0

.examine_loop:
    ; 1. Fetch current pointer from memory and read the word
    LOAD16  R0, dump_ptr
    LD      R2, (R0)            ; R2 = current memory address
    LD      R1, (R2++)          ; R1 = word at address; R2 is incremented

    ; 2. Immediately save advanced pointer back to memory
    LD      (R0), R2

    ; 3. Print the word followed by a space
    RCALL   print_hex16
    LOAD16  R1, 32              ; ' '
    PUTC    R1

    ; 4. Decrement loop counter in memory
    LOAD16  R0, dump_cnt
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1

    ; 5. Check if counter == 0
    XOR     R0, R0
    SUB     R0, R1
    LOAD16  R2, .examine_done
    JMP.Z   R2, R0

    LOAD16  R2, .examine_loop
    JMP     R2

.examine_done:
    RCALL   print_newline
    LOAD16  R2, monitor_loop
    JMP     R2

; ------------------------------------------------------------------------------
; COMMAND: 'c <addr> <val>' (Change Word)
; ------------------------------------------------------------------------------
cmd_change:
    RCALL   skip_spaces
    RCALL   parse_hex           ; R1 = target address
    LD      R2, R1              ; R2 = Address

    RCALL   skip_spaces
    XCHG    R2                  ; shadow_r[2] = Address
    RCALL   parse_hex           ; R1 = Value
    XCHG    R2                  ; R2 = Address restored, shadow_r[2] = Value

    LD      (R2), R1            ; [Address] = Value

    LOAD16  R1, msg_wrote
    RCALL   puts

    XCHG    R2                  ; R2 = Value, shadow_r[2] = Address
    LD      R1, R2
    RCALL   print_hex16         ; Print value

    LOAD16  R1, msg_to
    RCALL   puts

    XCHG    R2                  ; R2 = Address, shadow_r[2] = Value
    LD      R1, R2
    RCALL   print_hex16         ; Print address

    LOAD16  R1, msg_bracket_nl
    RCALL   puts

    LOAD16  R2, monitor_loop
    JMP     R2

; ==============================================================================
; SECTION 4: String & Formatting Subroutines
; ==============================================================================

; ------------------------------------------------------------------------------
; SUBROUTINE: puts
; Inputs: R1 = Pointer to null-terminated .asciz string
; ------------------------------------------------------------------------------
puts:
    RPUSH   R0
    LD      R2, R1

.puts_word_loop:
    LD      R3, (R2++)

    ; Slot 0 (Low Byte)
    BYTE_GET_LO R1, R3
    XOR     R0, R0
    SUB     R0, R1
    LOAD16  R0, .puts_done
    JMP.Z   R0, R1
    PUTC    R1

    ; Slot 1 (High Byte)
    BYTE_GET_HI R1, R3
    XOR     R0, R0
    SUB     R0, R1
    LOAD16  R0, .puts_done
    JMP.Z   R0, R1
    PUTC    R1

    LOAD16  R0, .puts_word_loop
    JMP     R0

.puts_done:
    RRET

; ------------------------------------------------------------------------------
; SUBROUTINE: print_newline
; ------------------------------------------------------------------------------
print_newline:
    RPUSH   R0
    LOAD16  R1, 13
    PUTC    R1
    LOAD16  R1, 10
    PUTC    R1
    RRET

; ------------------------------------------------------------------------------
; SUBROUTINE: print_hex16
; Inputs: R1 = 16-bit word to print
; ------------------------------------------------------------------------------
print_hex16:
    RPUSH   R0
    XCHG    R2                  ; Preserve caller R2 in shadow register
    LD      R2, R1              ; R2 = 16-bit word

    ; Nibble 3 [15:12]
    BYTE_GET_HI R1, R2
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    RCALL   print_nibble

    ; Nibble 2 [11:8]
    BYTE_GET_HI R1, R2
    LOAD16  R0, 0x000F
    AND     R1, R0
    RCALL   print_nibble

    ; Nibble 1 [7:4]
    BYTE_GET_LO R1, R2
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    RCALL   print_nibble

    ; Nibble 0 [3:0]
    BYTE_GET_LO R1, R2
    LOAD16  R0, 0x000F
    AND     R1, R0
    RCALL   print_nibble

    XCHG    R2                  ; Restore caller R2
    RRET

; ------------------------------------------------------------------------------
; SUBROUTINE: print_nibble
; Inputs: R1 = Nibble value (0-15)
; ------------------------------------------------------------------------------
print_nibble:
    RPUSH   R0

    ; R0 = 9 - R1 (negative if R1 >= 10, i.e. 'A'-'F')
    LOAD16  R0, 9
    SUB     R0, R1
    LOAD16  R3, .hex_letter
    JMP.M   R3, R0              ; Jump directly on negative result

    ; Digit '0'-'9': ASCII = R1 + 48
    LOAD16  R0, 48
    ADD     R1, R0
    PUTC    R1
    RRET

.hex_letter:
    ; Digit 'A'-'F': ASCII = R1 + 55
    LOAD16  R0, 55
    ADD     R1, R0
    PUTC    R1
    RRET

; ==============================================================================
; SECTION 5: Terminal Line Input & Space Skipping
; ==============================================================================

; ------------------------------------------------------------------------------
; SUBROUTINE: read_line
; Inputs: R1 = Buffer pointer
; ------------------------------------------------------------------------------
read_line:
    RPUSH   R0
    LD      R2, R1              ; R2 = Buffer write pointer
    LOAD16  R3, 0               ; R3 = Character count

.read_char:
    GETC    R1                  ; Character arrives in R1

    ; Check Carriage Return (13)
    LOAD16  R0, 13
    SUB     R0, R1              ; R0 = 13 - R1
    XCHG    R1                  ; shadow_r[1] = char, R1 is free for target
    LOAD16  R1, .line_done
    JMP.Z   R1, R0
    XCHG    R1                  ; R1 = char restored

    ; Check Line Feed (10)
    LOAD16  R0, 10
    SUB     R0, R1              ; R0 = 10 - R1
    XCHG    R1                  ; shadow_r[1] = char
    LOAD16  R1, .line_done
    JMP.Z   R1, R0
    XCHG    R1                  ; R1 = char restored

    ; Check Backspace (8)
    LOAD16  R0, 8
    SUB     R0, R1
    XCHG    R1
    LOAD16  R1, .handle_bs
    JMP.Z   R1, R0
    XCHG    R1

    ; Check Backspace / DEL (127)
    LOAD16  R0, 127
    SUB     R0, R1
    XCHG    R1
    LOAD16  R1, .handle_bs
    JMP.Z   R1, R0
    XCHG    R1

    ; Regular character: store and echo
    LD      (R2), R1
    INC     R2
    PUTC    R1
    INC     R3
    LOAD16  R0, .read_char
    JMP     R0

.handle_bs:
    XCHG    R1                  ; Restore R1 (char)
    XOR     R0, R0
    SUB     R0, R3
    XCHG    R1                  ; shadow_r[1] = char, R1 = target
    LOAD16  R1, .read_char
    JMP.Z   R1, R0              ; If count == 0, ignore backspace
    XCHG    R1                  ; Restore R1
    DEC     R2
    DEC     R3

    ; Erase on terminal: BS, Space, BS
    LOAD16  R1, 8
    PUTC    R1
    LOAD16  R1, 32
    PUTC    R1
    LOAD16  R1, 8
    PUTC    R1
    LOAD16  R0, .read_char
    JMP     R0

.line_done:
    XCHG    R1                  ; Restore R1
    XOR     R0, R0
    LD      (R2), R0            ; Null-terminate string in buffer
    RCALL   print_newline
    RRET

; ------------------------------------------------------------------------------
; SUBROUTINE: skip_spaces
; Inputs/Outputs: R3 = pointer into buffer
; ------------------------------------------------------------------------------
skip_spaces:
    RPUSH   R0

.skip_loop:
    LD      R1, (R3)
    BYTE_GET_LO R1, R1

    ; Test space (32)
    LOAD16  R0, 32
    SUB     R0, R1
    LOAD16  R2, .is_space
    JMP.Z   R2, R0

    ; Test tab (9)
    LOAD16  R0, 9
    SUB     R0, R1
    LOAD16  R2, .is_space
    JMP.Z   R2, R0

    RRET

.is_space:
    INC     R3
    LOAD16  R0, .skip_loop
    JMP     R0

; ==============================================================================
; SECTION 6: Hexadecimal Parsing Subroutine
; Inputs:  R3 = pointer to hex string
; Outputs: R1 = parsed 16-bit number
;          R3 = advanced past parsed hex digits
; ------------------------------------------------------------------------------
parse_hex:
    RPUSH   R0
    XOR     R1, R1              ; R1 = accumulator = 0

.parse_digit:
    LD      R2, (R3)
    BYTE_GET_LO R2, R2

    ; Check if char < '0' (48)
    LOAD16  R0, 48
    SUB     R2, R0              ; R2 = char - 48
    LOAD16  R0, .parse_done
    JMP.M   R0, R2              ; If R2 < 0, done

    ; Check if char <= '9' (i.e. R2 <= 9)
    LOAD16  R0, 9
    SUB     R0, R2              ; R0 = 9 - R2
    XCHG    R1                  ; shadow_r[1] = acc, R1 is free for target
    LOAD16  R1, .check_upper
    JMP.M   R1, R0              ; If 9 - R2 < 0, jump to .check_upper
    XCHG    R1                  ; Restore R1 = acc

.is_num:
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    ADD     R1, R2
    INC     R3                  ; Advance string pointer (R3 preserved)
    LOAD16  R0, .parse_digit
    JMP     R0

.check_upper:
    XCHG    R1                  ; Restore R1 = acc
    ; 'A' is 65 - 48 = 17
    LOAD16  R0, 17
    SUB     R2, R0              ; R2 = char - 'A'
    LOAD16  R0, .parse_done
    JMP.M   R0, R2              ; If char < 'A', done

    ; 'F' is 5. Check if R2 <= 5
    LOAD16  R0, 5
    SUB     R0, R2              ; R0 = 5 - R2
    XCHG    R1                  ; shadow_r[1] = acc
    LOAD16  R1, .check_lower
    JMP.M   R1, R0              ; If 5 - R2 < 0, jump to .check_lower
    XCHG    R1                  ; Restore R1 = acc

.is_upper:
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    LOAD16  R0, 10
    ADD     R2, R0              ; R2 = digit value (10..15)
    ADD     R1, R2
    INC     R3                  ; Advance string pointer (R3 preserved)
    LOAD16  R0, .parse_digit
    JMP     R0

.check_lower:
    XCHG    R1                  ; Restore R1 = acc
    ; 'a' is 97 - 65 = 32
    LOAD16  R0, 32
    SUB     R2, R0              ; R2 = char - 'a'
    LOAD16  R0, .parse_done
    JMP.M   R0, R2              ; If char < 'a', done

    ; 'f' is 5. Check if R2 <= 5
    LOAD16  R0, 5
    SUB     R0, R2              ; R0 = 5 - R2
    XCHG    R1
    LOAD16  R1, .parse_done
    JMP.M   R1, R0              ; If 5 - R2 < 0, invalid hex char -> done
    XCHG    R1                  ; Restore R1 = acc

.is_lower:
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    LOAD16  R0, 10
    ADD     R2, R0
    ADD     R1, R2
    INC     R3                  ; Advance string pointer (R3 preserved)
    LOAD16  R0, .parse_digit
    JMP     R0

.parse_done:
    RRET

; ==============================================================================
; SECTION 7: Static Messages & Buffers
; ==============================================================================
.align                          ; Guarantees word boundary for Slot 0 packing

msg_banner:
    .asciz "\r\n============================\r\n  MiniRISC4 ASM Monitor\r\n  Commands:\r\n    e <addr>      (Examine)\r\n    c <addr> <val>(Change)\r\n    g <addr>      (Go / Run)\r\n============================\r\n"

msg_prompt:
    .asciz "> "

msg_colon:
    .asciz ": "

msg_unknown:
    .asciz "Unknown command. Use 'e <addr>', 'c <addr> <val>', or 'g <addr>'\r\n"

msg_wrote:
    .asciz "Wrote "

msg_to:
    .asciz " to ["

msg_bracket_nl:
    .asciz "]\r\n"

msg_running:
    .asciz "Running at ["

msg_run_tail:
    .asciz "]...\r\n"

msg_returned:
    .asciz "\r\n[Program returned to monitor]\r\n"

next_examine_addr:
    .word 0x0000

dump_ptr:
    .word 0x0000

dump_cnt:
    .word 0x0000

line_buffer:
    .word 0, 0, 0, 0, 0, 0, 0, 0
    .word 0, 0, 0, 0, 0, 0, 0, 0
    .word 0, 0, 0, 0, 0, 0, 0, 0
    .word 0, 0, 0, 0, 0, 0, 0, 0

; ==============================================================================
; Runtime Library Inclusion at the Bottom
; ==============================================================================
.include "M4R_LIB.asm"

; ==============================================================================
; Trap Vectors
; ==============================================================================
.org TRAP_BASE
    .word _start            ; Trap 0 / Reset Vector
    .word 0000              ; Trap 1
    .word 0000              ; Trap 2
    .word 0000              ; Trap 3
    .word 0000              ; Trap 4
    .word 0000              ; Trap 5
    .word 0000              ; Trap 6
    .word 0000              ; Trap 7
    .word 0000              ; Trap 8
    .word 0000              ; Trap 9
    .word 0000              ; Trap 10
    .word 0000              ; Trap 11
    .word 0000              ; Trap 12
    .word 0000              ; Trap 13
    .word 0000              ; Trap 14
    .word _start            ; Trap 15 Illegal instructions and Slot 1 alignment violations

path = "mr4src/asm/monitor.asm"

content = """\
; ==============================================================================
; FILE: mr4src/asm/monitor.asm
; Architecture: MiniRISC4 16-Bit Word-Addressed Processor
; Target Hardware: Lattice ECP5 FPGA (ULX3S) / Verilog Core
; Description:
;   Interactive Serial Memory Monitor for the MiniRISC4 Architecture.
;
; Commands:
;   e <addr>         - Examine 8 words starting at 16-bit word address <addr>
;   c <addr> <val>   - Change word at <addr> to <val>
;   g <addr>         - Go / Execute code at <addr>
; ==============================================================================

.include "common.inc"

.org 0x0100

; ==============================================================================
; SECTION 1: Program Entry & Stack Initialization
; ==============================================================================
_start:
    ; 1. Initialize Return Stack Pointer (RSP @ 0x0004 = 0xFEFF)
    LOAD16  R1, 0xFEFF
    LD      R0, 4
    LD      (R0), R1

    ; 2. Initialize Argument Stack Pointer (ASP @ 0x0005 = 0xFAFF)
    LOAD16  R1, 0xFAFF
    INC     R0
    LD      (R0), R1

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
; COMMAND: 'e <addr>' (Examine 8 Words)
; ------------------------------------------------------------------------------
cmd_examine:
    RCALL   skip_spaces
    RCALL   parse_hex           ; R1 = target word address
    LD      R2, R1              ; R2 = dump pointer

    RCALL   print_hex16
    LOAD16  R1, msg_colon
    RCALL   puts

    LOAD16  R3, 8               ; Loop counter = 8 words

.examine_loop:
    LD      R1, (R2++)          ; Fetch memory word, advance pointer
    XCHG    R2                  ; shadow_r[2] = dump pointer
    XCHG    R3                  ; shadow_r[3] = loop counter
    RCALL   print_hex16

    LOAD16  R1, 32              ; Print space
    PUTC    R1

    XCHG    R3                  ; R3 = loop counter restored
    XCHG    R2                  ; R2 = dump pointer restored
    DEC     R3                  ; counter--

    XOR     R0, R0
    SUB     R0, R3
    LOAD16  R1, .examine_done
    JMP.Z   R1, R0

    LOAD16  R1, .examine_loop
    JMP     R1

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
; ------------------------------------------------------------------------------
print_hex16:
    RPUSH   R0
    XCHG    R2                  ; shadow_r[2] = caller R2
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
; ------------------------------------------------------------------------------
print_nibble:
    RPUSH   R0
    XCHG    R0
    LOAD16  R0, 10
    SUB     R0, R1
    LOAD16  R3, .hex_letter
    XCHG    R0
    JMP.M   R3, R0
    XCHG    R0

    ; 0-9
    LOAD16  R0, 48
    ADD     R1, R0
    PUTC    R1
    RRET

.hex_letter:
    XCHG    R0
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
    XCHG    R1                  ; shadow_r[1] = char, R1 is free for branch target
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
    LOAD16  R0, .check_upper
    XCHG    R0                  ; R0 = (9 - R2), shadow_r[0] = .check_upper
    XCHG    R2                  ; shadow_r[2] = R2 (digit), R2 = .check_upper
    XCHG    R0                  ; R0 = .check_upper target, R2 = target
    JMP.M   R0, R2              ; Wait, cleaner below!
    ; Let us do clean registers:
"""

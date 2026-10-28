; ==============================================================================
; Architectural Control & MMIO Port Addresses (Low Memory 0x0000 - 0x000F)
; ==============================================================================
.define FIFO_IN_ADDR    0x000A      ; Inter-core inbound stream FIFO (RO pop)
.define FIFO_OUT_ADDR   0x000B      ; Inter-core outbound stream FIFO (WO push)
.define MAILBOX_ADDR    0x000C      ; Cross-core trap trigger register (WO)
.define CPUID_ADDR      0x000D      ; Hardware CPUID register (RO)
.define UART_RX_ADDR    0x000E      ; Physical UART RX register
.define UART_TX_ADDR    0x000F      ; Physical UART TX register

.ifndef TRAP_BASE
    .define TRAP_BASE   0x0100      ; Direct Stride Vector Table Base
.endif
.define TRAP_STRIDE     16          ; 16 words (32 bytes) per direct vector slot

; ------------------------------------------------------------------------------
; Multi-Core & Hardware Control Macros
; ------------------------------------------------------------------------------
.macro GET_CPUID dest_reg
    LD      R0, 13                  ; Slot 0: R0 = 0x000D (Opcode 0x1)
    LD      %dest_reg, (R0)         ; Slot 1: Read CPUID
.endmacro

.macro FIFO_POP dest_reg
    LD      R0, 10                  ; Slot 0: R0 = 0x000A (Opcode 0x1)
    LD      %dest_reg, (R0)         ; Slot 1: Pop inbound FIFO
.endmacro

.macro FIFO_PUSH src_reg
    LD      R0, 11                  ; Slot 0: R0 = 0x000B (Opcode 0x1)
    LD      (R0), %src_reg          ; Slot 1: Push outbound FIFO
.endmacro

.macro TRIGGER_TRAP target_core, trap_num
    LOAD16  R0, ((%target_core << 8) | (%trap_num & 0x0F))
    LD      R1, 12                  ; Slot 0: R1 = 0x000C (Opcode 0x1)
    LD      (R1), R0                ; Slot 1: Write to MAILBOX_ADDR
.endmacro

; ==============================================================================
; Architectural MMIO Addresses (Optional / Parameterized)
; ==============================================================================
.define CPUID_ADDR      0x000D      ; Hardware CPUID register (RO)
.define UART_RX_ADDR    0x000E      ; Hardware UART RX register
.define UART_TX_ADDR    0x000F      ; Hardware UART TX register

; ------------------------------------------------------------------------------
; MACRO: GET_CPUID dest_reg
; Reads the hardware core ID into dest_reg in 2 single-byte instructions (1 word).
; ------------------------------------------------------------------------------
.macro GET_CPUID dest_reg
    LD      R0, 13                  ; Slot 0: R0 = 0x000D (Opcode 0x1)
    LD      %dest_reg, (R0)         ; Slot 1: Read CPUID
.endmacro

; ==============================================================================
; Configurable Physical Memory Capacity
; Default: 64K words (0x10000). Override before including or via assembler CLI.
; ==============================================================================
.ifndef MEM_WORDS
    .define MEM_WORDS   0x10000
.endif
.define MEM_TOP         (MEM_WORDS - 1)
.define RSP_INIT        (MEM_WORDS - 0x0101)    ; Return Stack top
.define ASP_INIT        (MEM_WORDS - 0x0501)    ; Argument Stack top

; ==============================================================================
; Architectural Traps and Vectors Configuration
; ==============================================================================
; TRAP_BASE is defined by the assembler (defaults to 0x0010)
.define TRAP_RESET_ADDR (TRAP_BASE + 0)
.define TRAP_FAULT_ADDR (TRAP_BASE + 15)

; ==============================================================================
; FILE: lib/common.inc
; Architecture: MiniRISC4 16-Bit Word-Addressed Processor
; Target Hardware: Lattice ECP5 FPGA (ULX3S) / Verilog Core
; Description:
;   Standard Architectural Macro Definitions and System Abstractions.
;
; Table of Contents:
;   1. Program Entry & Stack Initialization (START_PROGRAM)
;   2. Core Register Manipulation & Arithmetic Macros (SWAP, LOAD16, LD0, NOT, NEG, XCHGALL)
;   3. System Scratchpad & Register Spilling (SAVEALL, LOADALL via 0x0000-0x0003)
;   4. Hardware Stack Engine (Full Descending: STPUSH, STPOP, RPUSH, RPOP, APUSH, APOP)
;   5. Register Spilling via Argument Stack (PUSHALL, POPALL via 0x0005)
;   6. Subroutine Linkage & Return (RCALL, RRET)
;   7. Byte Extraction and Modification (BYTE_GET_LO, BYTE_GET_HI, BYTE_SET_LO, BYTE_SET_HI)
;   8. Polled Serial UART Terminal I/O (PUTC, GETC via MMIO 0x000E / 0x000F)
; ==============================================================================

; ==============================================================================
; ==============================================================================
; MACRO: START_PROGRAM
; Description:
;   Standard program initialization macro executed at Trap 0 (Reset) entry (0x0100).
;   Initializes RSP, ASP, and jumps to _main.
;
; CRITICAL ARCHITECTURAL CONSTRAINT:
;   Under Direct Stride Vectoring (stride = 16 words), Trap 0 code occupies
;   addresses 0x0100 - 0x010F. Therefore, START_PROGRAM MUST NOT EXCEED
;   16 WORDS (32 bytes / 32 single-byte instruction slots). Any additional startup
;   logic must be placed after 0x0200 or inside _main.
; ==============================================================================
; Description:
;   Initializes the Return Stack Pointer (RSP at 0x0004) to 0xFEFF and the
;   Argument Stack Pointer (ASP at 0x0005) to 0xFAFF, then jumps directly
;   to the program entry point label _main via register-indirect branching.
; Inputs:
;   None (fixed entry target: _main).
; Outputs:
;   [0x0004] = 0xFEFF (Return stack initialized)
;   [0x0005] = 0xFAFF (Argument stack initialized)
; Side Effects:
;   Overwrites registers R0 and R1, then transfers control to _main.
; ==============================================================================
.macro START_PROGRAM
    ; 1. Initialize Return Stack Pointer (RSP) at [0x0004] = 0xFEFF
    LOAD16  R1, RSP_INIT          ; Default Return Stack top
    LD      R0, 4               ; R0 = 0x0004 (RSP scratchpad address)
    LD      (R0), R1            ; [0x0004] = 0xFEFF

    ; 2. Initialize Argument Stack Pointer (ASP) at [0x0005] = 0xFAFF
    LOAD16  R1, ASP_INIT          ; Default Argument Stack top
    INC     R0                  ; R0 = 0x0005 (ASP scratchpad address)
    LD      (R0), R1            ; [0x0005] = 0xFAFF

    ; 3. Jump to the main function
    LOAD16  R0, _main           ; Load address of _main
    JMP     R0                  ; Unconditional register-indirect jump to _main
.endmacro


; ==============================================================================
; MACRO: SWAP
; Description:
;   Swaps the contents of two registers in-place using the three-step XOR algorithm.
; Inputs:
;   regA - First register (R0-R3)
;   regB - Second register (R0-R3)
; Outputs:
;   regA holds original regB; regB holds original regA.
; ==============================================================================
.macro SWAP regA, regB
    XOR     %regA, %regB
    XOR     %regB, %regA
    XOR     %regA, %regB
.endmacro


; ==============================================================================
; MACRO: LOAD16
; Description:
;   Loads a 16-bit constant or address label into a register using two sequential
;   PUSH8 operations (high byte followed by low byte).
; Inputs:
;   reg   - Destination register (R0-R3)
;   value - 16-bit literal, symbol, or label address
; Outputs:
;   reg = value
; ==============================================================================
.macro LOAD16 reg, value
    PUSH8   %reg, >(%value)
    PUSH8   %reg, <(%value)
.endmacro


; ==============================================================================
; MACRO: LD0
; Description:
;   Clears the specified register to 0x0000 in-place using XOR. Single-cycle execution.
; Inputs:
;   reg - Destination register (R0-R3)
; Outputs:
;   reg = 0x0000
; ==============================================================================
.macro LD0 reg
    XOR     %reg, %reg
.endmacro


; ==============================================================================
; MACRO: NOT
; Description:
;   Performs bitwise NOT (one's complement) on a register in-place:
;     reg = ~reg (computed as reg ^ 0xFFFF).
; Inputs:
;   reg - Register to invert (R0-R3)
; Outputs:
;   reg inverted bitwise.
; ==============================================================================
.macro NOT reg
    XCHG    R0
    LD0     R0
    DEC     R0                  ; R0 = 0xFFFF
    XOR     %reg, R0
    XCHG    R0
.endmacro


; ==============================================================================
; MACRO: NEG
; Description:
;   Negates a register using two's complement arithmetic:
;     reg = -reg (computed as ~reg + 1).
; Inputs:
;   reg - Register to negate (R0-R3)
; Outputs:
;   reg = -reg
; ==============================================================================
.macro NEG reg
    NOT     %reg
    INC     %reg
.endmacro


; ==============================================================================
; MACRO: XCHGALL
; Description:
;   Exchanges all four primary registers (R0-R3) with their corresponding
;   hardware shadow counterparts (shadow_r[0]-shadow_r[3]).
; Inputs:
;   None
; Outputs:
;   R0-R3 hold previous shadow values; shadow registers hold previous R0-R3 values.
; ==============================================================================
.macro XCHGALL
    XCHG    R0
    XCHG    R1
    XCHG    R2
    XCHG    R3
.endmacro


; ==============================================================================
; MACRO: SAVEALL
; Description:
;   Saves R0-R3 to low scratchpad RAM addresses 0x0000-0x0003 in natural order:
;     [0x0000] = R0, [0x0001] = R1, [0x0002] = R2, [0x0003] = R3
; Inputs:
;   None (operates on current register file R0-R3)
; Outputs:
;   Memory locations 0x0000-0x0003 populated with register snapshots.
; ==============================================================================
.macro SAVEALL
    XCHG    R0
    LD      R0, 4
    LD      (--R0), R3
    LD      (--R0), R2
    XCHG    R2
    LD      R2, R0
    XCHG    R0
    LD      (--R2), R1
    LD      (--R2), R0
    XCHG    R2
.endmacro


; ==============================================================================
; MACRO: LOADALL
; Description:
;   Restores all four registers (R0-R3) from low scratchpad RAM addresses
;   0x0000-0x0003 via post-increment sequential loading.
; Inputs:
;   Memory locations 0x0000-0x0003 must contain valid saved register data.
; Outputs:
;   R0-R3 restored to the values read from memory.
; ==============================================================================
.macro LOADALL
    LD      R0, 0
    LD      R3, R0
    LD      R0, (R3++)
    LD      R1, (R3++)
    LD      R2, (R3++)
    LD      R3, (R3)
.endmacro


; ==============================================================================
; HARDWARE STACK ENGINE MACROS (Full Descending)
; ==============================================================================
.macro STPUSH ptr_addr, reg
    XCHG    R2
    XCHG    R3
    XCHG    R0
    LD      R0, %ptr_addr
    LD      R2, R0
    XCHG    R0
    LD      R3, (R2)
    LD      (--R3), %reg
    LD      (R2), R3
    XCHG    R3
    XCHG    R2
.endmacro

.macro STPOP ptr_addr, reg
    XCHG    R2
    XCHG    R3
    XCHG    R0
    LD      R0, %ptr_addr
    LD      R2, R0
    XCHG    R0
    LD      R3, (R2)
    LD      %reg, (R3++)
    LD      (R2), R3
    XCHG    R3
    XCHG    R2
.endmacro

.macro RPUSH reg
    STPUSH  4, %reg
.endmacro

.macro RPOP reg
    STPOP   4, %reg
.endmacro

.macro APUSH reg
    STPUSH  5, %reg
.endmacro

.macro APOP reg
    STPOP   5, %reg
.endmacro


; ==============================================================================
; MACRO: PUSHALL / POPALL
; Description:
;   Spills and restores all four general-purpose registers to/from the Argument Stack.
; ==============================================================================
.macro PUSHALL
    APUSH   R0
    APUSH   R1
    APUSH   R2
    APUSH   R3
.endmacro

.macro POPALL
    APOP    R3
    APOP    R2
    APOP    R1
    APOP    R0
.endmacro


; ==============================================================================
; SUBROUTINE LINKAGE MACROS (RCALL / RRET)
; ==============================================================================
.macro RCALL target
    LOAD16  R0, %target
    LINK    R0, R0
.endmacro

.macro RRET
    RPOP    R0
    JMP     R0
.endmacro


; ==============================================================================
; BYTE EXTRACTION & MODIFICATION MACROS (Using Native AND)
; ==============================================================================
.macro BYTE_GET_LO dest, src
    LD      %dest, %src
    XCHG    R0
    LOAD16  R0, 0x00FF
    AND     %dest, R0
    XCHG    R0
.endmacro

.macro BYTE_GET_HI dest, src
    LD      %dest, %src
    SHIFT.R %dest
    SHIFT.R %dest
    SHIFT.R %dest
    SHIFT.R %dest
    SHIFT.R %dest
    SHIFT.R %dest
    SHIFT.R %dest
    SHIFT.R %dest
.endmacro

.macro BYTE_SET_LO dest, src_byte
    XCHG    R0
    LOAD16  R0, 0xFF00
    AND     %dest, R0
    XCHG    R0
    XCHG    R2
    BYTE_GET_LO R2, %src_byte
    OR      %dest, R2
    XCHG    R2
.endmacro

.macro BYTE_SET_HI dest, src_byte
    XCHG    R0
    LOAD16  R0, 0x00FF
    AND     %dest, R0
    LD      R0, %src_byte
    PUSH8   R0, 0x00
    OR      %dest, R0
    XCHG    R0
.endmacro


; ==============================================================================
; POLLED SERIAL UART TERMINAL I/O MACROS
; ==============================================================================
.macro PUTC reg
    XCHG    R0
    XCHG    R2
    XCHG    R3
    LD      R0, 15              ; UART TX MMIO (0x000F)

._PUTC_WAIT_%:
    LD      R2, (R0)
    LOAD16  R3, ._PUTC_SEND_%
    JMP.Z   R3, R2
    LOAD16  R3, ._PUTC_WAIT_%
    JMP     R3

._PUTC_SEND_%:
    LD      (R0), %reg
    XCHG    R3
    XCHG    R2
    XCHG    R0
.endmacro

.macro GETC dest_reg
    XCHG    R0
    XCHG    R2
    LD      R0, 14              ; UART RX MMIO (0x000E)

._GETC_WAIT_%:
    LD      %dest_reg, (R0)
    LOAD16  R2, ._GETC_DONE_%
    JMP.M   R2, %dest_reg
    LOAD16  R2, ._GETC_WAIT_%
    JMP     R2

._GETC_DONE_%:
    BYTE_GET_LO %dest_reg, %dest_reg
    XCHG    R2
    XCHG    R0
.endmacro
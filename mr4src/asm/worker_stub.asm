; ==============================================================================
; FILE: mr4src/asm/worker_stub.asm
; Architecture: MiniRISC4 Worker Core Resident Stub (0x0100 - 0x03FF)
;
; Memory Map:
;   0x0004 / 0x0005 : Hardware RSP / ASP stack pointers
;   0x0006 - 0x0009 : Reserved for ACT4 scratchpad temporaries
;   0x000A / 0x000B : FIFO_IN (pop) / FIFO_OUT (push)
;   0x000C / 0x000D : MAILBOX (strobe) / CPUID (read-only core ID)
;   0x0010 - 0x0017 : Worker Stub private state variables
;   0x0100 - 0x01FF : Direct Stride Vector Table (16 words per vector)
;   0x0200 - 0x03FF : Resident Loader & Trap 1 Syscall Bridge
;   0x0400+         : Loaded User Application Space
; ==============================================================================

.include "common.inc"

; ------------------------------------------------------------------------------
; Stub Private Scratchpad (0x0010 - 0x0017)
; ------------------------------------------------------------------------------
.define STUB_ARG1           0x0010  ; Saved R1 (val / buf_ptr)
.define STUB_ARG2           0x0011  ; Saved R2 (val / word_len)
.define STUB_ARG3           0x0012  ; Saved R3 (fd / mode / index)
.define STUB_RET_PC         0x0013  ; Saved R0 (app return PC)
.define STUB_SYS_ID         0x0014  ; Extracted syscall_id byte
.define STUB_ENTRY_ADDR     0x0015  ; Loaded app entry point

; Protocol Constants
.define CMD_LOAD_MAGIC      0x4C44  ; "LD" packet header from Core 0
.define SYS_EXIT_ID         0x01    ; Scalar exit syscall ID
.define ERR_ALIGN_FAULT     0xFF0F  ; Exit code reported on Trap 15
.define OS_CORE_TRAP1       0x0001  ; Mailbox word: Core 0, Trap 1

; Default Stack Tops (adjust per worker BRAM size, e.g. 64K defaults)
.define WORKER_RSP_INIT     0xFEFF
.define WORKER_ASP_INIT     0xFAFF

; ==============================================================================
; DIRECT STRIDE VECTOR TABLE (0x0100 - 0x01FF)
; Strict 16-word stride per slot
; ==============================================================================
.org 0x0100
_trap0_reset:
    LOAD16  R0, _stub_reset_idle
    JMP     R0
    .align

.org 0x0110
_trap1_syscall:
    XCHG    R0                      ; 1 cycle: save app return PC in shadow_r[0]
    LOAD16  R0, _sys_dispatch
    JMP     R0
    .align

.org 0x01E0
_trap14_kill:
    ; Remote KILL from Core 0: discard app state, reset stacks, return to idle
    LOAD16  R0, _stub_reset_idle
    JMP     R0
    .align

.org 0x01F0
_trap15_align_fault:
    ; Hardware Slot 1 violation: notify Core 0 and return to idle
    LOAD16  R0, _fault_report
    JMP     R0
    .align

; ==============================================================================
; WORKER STUB RUNTIME (0x0200 - 0x03FF)
; ==============================================================================
.org 0x0200

; ------------------------------------------------------------------------------
; Stack Reset & Idle Program Loader
; Polls FIFO_IN (0x000A) for CMD_LOAD_MAGIC.
; Packet: [0x4C44, load_addr, word_count, entry_addr, w0, w1, ..., wN-1]
; ------------------------------------------------------------------------------
_stub_reset_idle:
    LOAD16  R1, WORKER_RSP_INIT
    LD      R0, 4                   ; 0x0004 = RSP
    LD      (R0), R1
    LOAD16  R1, WORKER_ASP_INIT
    INC     R0                      ; 0x0005 = ASP
    LD      (R0), R1

_loader_idle:
    LD      R0, 10                  ; 0x000A = FIFO_IN
    LD      R1, (R0)                ; Poll inbound FIFO (0 = empty)
    LOAD16  R2, CMD_LOAD_MAGIC
    SUB     R1, R2
    LOAD16  R3, _loader_idle
    JMP.Z   _loader_start_rx, R1    ; Magic matched -> begin load
    JMP     R3

_loader_start_rx:
    ; Pop load header: [load_addr, word_count, entry_addr]
    LD      R0, 10                  ; FIFO_IN
    LD      R2, (R0)                ; R2 = load_addr (e.g. 0x0400)
    LD      R3, (R0)                ; R3 = word_count
    LD      R1, (R0)                ; R1 = entry_addr
    LOAD16  R0, STUB_ENTRY_ADDR
    LD      (R0), R1

_loader_copy_loop:
    LOAD16  R0, _loader_launch
    JMP.Z   R0, R3                  ; Done when word_count == 0
    LD      R0, 10                  ; FIFO_IN
    LD      R1, (R0)                ; Read next program word
    LD      (R2), R1                ; Write to worker RAM
    INC     R2                      ; load_addr++
    DEC     R3                      ; word_count--
    LOAD16  R0, _loader_copy_loop
    JMP     R0

_loader_launch:
    LOAD16  R0, STUB_ENTRY_ADDR
    LD      R0, (R0)                ; R0 = entry_addr
    LINK    R0, R0                  ; Call user app; R0 = return address here

    ; If user app returns normally via RRET, report SYS_EXIT(R1) to Core 0
    LOAD16  R0, STUB_ARG1
    LD      (R0), R1                ; Exit code = app's R1 return value
    LOAD16  R0, _send_exit_and_idle
    JMP     R0

; ------------------------------------------------------------------------------
; Trap 15 Alignment Fault Reporter
; ------------------------------------------------------------------------------
_fault_report:
    LOAD16  R1, ERR_ALIGN_FAULT
    LOAD16  R0, STUB_ARG1
    LD      (R0), R1
    ; Fall through to _send_exit_and_idle

_send_exit_and_idle:
    LOAD16  R1, SYS_EXIT_ID
    LOAD16  R0, STUB_SYS_ID
    LD      (R0), R1
    LOAD16  R0, _push_hdr_helper
    LINK    R0, R0                  ; Push [(CPUID << 8) | SYS_EXIT_ID]
    LD      R0, 11                  ; FIFO_OUT
    LD      R1, 1                   ; Payload len = 1
    LD      (R0), R1
    LOAD16  R2, STUB_ARG1
    LD      R1, (R2)                ; Exit code
    LD      (R0), R1
    ; Notify Core 0
    LOAD16  R1, OS_CORE_TRAP1
    LD      R0, 12                  ; 0x000C = MAILBOX
    LD      (R0), R1
    LOAD16  R0, _stub_reset_idle
    JMP     R0

; ==============================================================================
; TRAP 1 SYSCALL BRIDGE
; Entry: shadow_r[0] = app return PC; R1..R3 = app arguments
; Exit:  R1 = status, R2 = secondary result, returns to app return PC
; ==============================================================================
_sys_dispatch:
    ; 1. Save R1..R3 to stub scratchpad
    LOAD16  R0, STUB_ARG1
    LD      (R0), R1
    INC     R0                      ; STUB_ARG2
    LD      (R0), R2
    INC     R0                      ; STUB_ARG3
    LD      (R0), R3

    ; 2. Retrieve app return PC from shadow_r[0] and save it
    XCHG    R0                      ; R0 = app return PC
    LOAD16  R1, STUB_RET_PC
    LD      (R1), R0

    ; 3. Extract syscall_id from upper byte of TRAP instruction at mem[R0 - 1]
    DEC     R0                      ; Point to TRAP word
    LD      R1, (R0)                ; R1 = [syscall_id : trap_opcode]
    BYTE_GET_HI R1, R1              ; R1 = syscall_id (0x00..0xFF)
    LOAD16  R0, STUB_SYS_ID
    LD      (R0), R1

    ; 4. Check for SYS_EXIT (0x01) -> no reply expected
    LOAD16  R2, SYS_EXIT_ID
    SUB     R2, R1
    LOAD16  R0, _send_exit_and_idle
    JMP.Z   R0, R2

    ; 5. Push Wire Header: Word 0 = (CPUID << 8) | syscall_id
    LOAD16  R0, _push_hdr_helper
    LINK    R0, R0

    ; 6. Route by syscall class (bits [7:4] of syscall_id)
    LOAD16  R0, STUB_SYS_ID
    LD      R1, (R0)
    LOAD16  R2, 0x00F0
    AND     R1, R2                  ; R1 = class nibble (0x00, 0x10, 0x20)

    LOAD16  R0, _sys_class_scalar
    JMP.Z   R0, R1                  ; 0x00..0x0F -> Scalar

    LOAD16  R2, 0x0010
    SUB     R1, R2
    LOAD16  R0, _sys_class_buf_out
    JMP.Z   R0, R1                  ; 0x10..0x1F -> Buffer Out

    ; Otherwise 0x20..0x2F -> Buffer In
    LOAD16  R0, _sys_class_buf_in
    JMP     R0

; --- Class A: Scalar (0x00..0x0F) --------------------------------------------
; Sends: [len=2, ARG1, ARG2]  |  Receives: [status -> R1, result -> R2]
_sys_class_scalar:
    LD      R0, 11                  ; FIFO_OUT
    LD      R1, 2                   ; payload_len = 2
    LD      (R0), R1
    LOAD16  R2, STUB_ARG1
    LD      R1, (R2)
    LD      (R0), R1                ; ARG1
    INC     R2
    LD      R1, (R2)
    LD      (R0), R1                ; ARG2
    LOAD16  R0, _sys_wait_scalar_reply
    JMP     R0

; --- Class B: Buffer Out (0x10..0x1F) ----------------------------------------
; App: R1=src_ptr, R2=word_len, R3=extra (fd/mode)
; Sends: [len=(word_len+2), extra, word_len, w0..wN-1]
_sys_class_buf_out:
    LOAD16  R0, STUB_ARG2
    LD      R3, (R0)                ; R3 = word_len
    LD      R1, R3
    INC     R1
    INC     R1                      ; R1 = word_len + 2
    LD      R0, 11                  ; FIFO_OUT
    LD      (R0), R1                ; Push payload_len

    LOAD16  R2, STUB_ARG3
    LD      R1, (R2)
    LD      (R0), R1                ; Push extra (fd/mode)
    LD      (R0), R3                ; Push word_len

    LOAD16  R2, STUB_ARG1
    LD      R2, (R2)                ; R2 = src_ptr
_buf_out_loop:
    LOAD16  R0, _sys_wait_scalar_reply
    JMP.Z   R0, R3                  ; Done streaming when count == 0
    LD      R1, (R2)                ; Load word from app RAM
    LD      R0, 11                  ; FIFO_OUT
    LD      (R0), R1                ; Push word
    INC     R2
    DEC     R3
    LOAD16  R0, _buf_out_loop
    JMP     R0

; --- Class C: Buffer In (0x20..0x2F) -----------------------------------------
; App: R1=dst_ptr, R2=max_words, R3=extra (fd/index)
; Sends: [len=2, extra, max_words]
; Receives: [status -> R1, words_read -> R2, w0..wN-1 -> mem[dst_ptr++]]
_sys_class_buf_in:
    LD      R0, 11                  ; FIFO_OUT
    LD      R1, 2                   ; payload_len = 2
    LD      (R0), R1
    LOAD16  R2, STUB_ARG3
    LD      R1, (R2)
    LD      (R0), R1                ; Push extra (fd/index)
    LOAD16  R2, STUB_ARG2
    LD      R1, (R2)
    LD      (R0), R1                ; Push max_words

    ; Strobe Core 0 Trap 1
    LOAD16  R1, OS_CORE_TRAP1
    LD      R0, 12                  ; MAILBOX
    LD      (R0), R1

    ; Read reply header: [status, words_read]
    LD      R0, 10                  ; FIFO_IN
    LD      R1, (R0)                ; R1 = status
    LD      R3, (R0)                ; R3 = words_read (loop counter)
    LOAD16  R0, STUB_ARG3
    LD      (R0), R3                ; Save words_read for return in R2

    LOAD16  R2, STUB_ARG1
    LD      R2, (R2)                ; R2 = dst_ptr
_buf_in_loop:
    LOAD16  R0, _buf_in_done
    JMP.Z   R0, R3
    LD      R0, 10                  ; FIFO_IN
    LD      R0, (R0)                ; Pop data word
    LD      (R2), R0                ; Store to app RAM
    INC     R2
    DEC     R3
    LOAD16  R0, _buf_in_loop
    JMP     R0

_buf_in_done:
    LOAD16  R0, STUB_ARG3
    LD      R2, (R0)                ; R2 = words_read (R1 still holds status)
    LOAD16  R0, STUB_RET_PC
    LD      R0, (R0)
    JMP     R0                      ; Return to app

; --- Common Notify & Scalar Reply Path ---------------------------------------
_sys_wait_scalar_reply:
    LOAD16  R1, OS_CORE_TRAP1
    LD      R0, 12                  ; 0x000C = MAILBOX
    LD      (R0), R1                ; Pulse Core 0 Trap 1

    LD      R0, 10                  ; 0x000A = FIFO_IN
    LD      R1, (R0)                ; R1 = status
    LD      R2, (R0)                ; R2 = secondary result

    LOAD16  R0, STUB_RET_PC
    LD      R0, (R0)
    JMP     R0                      ; Return to app

; ------------------------------------------------------------------------------
; Helper: Push Word 0 = (CPUID << 8) | STUB_SYS_ID to FIFO_OUT
; (Isolates the transport header so migrating to the networked FIFO fabric
;  later only requires updating this helper and the MAILBOX strobe.)
; ------------------------------------------------------------------------------
_push_hdr_helper:
    LD      R1, 13                  ; 0x000D = CPUID (RO)
    LD      R1, (R1)                ; R1 = core_id
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1                      ; R1 = core_id << 8
    LOAD16  R2, STUB_SYS_ID
    LD      R2, (R2)
    OR      R1, R2                  ; R1 = (core_id << 8) | syscall_id
    LD      R2, 11                  ; 0x000B = FIFO_OUT
    LD      (R2), R1
    JMP     R0                      ; Return to caller

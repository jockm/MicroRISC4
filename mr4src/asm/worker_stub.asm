; ==============================================================================
; FILE: mr4src/asm/worker_stub.asm
; Architecture: MicroRISC4 Worker Core Resident Stub (0x0100 - 0x03FF)
; Transport   : Unified Hardware Lean Ring NoC (MMIO 0x0020 - 0x002A) + Trap 14
;
; Memory Map:
;   0x0004 / 0x0005 : Hardware RSP / ASP stack pointers
;   0x0006 - 0x0009 : Reserved for ACT4 scratchpad temporaries
;   0x000D          : CPUID (read-only hardware core ID)
;   0x0010 - 0x0016 : Optional Hardware Math Accelerator (untouched by stub!)
;   0x0020 - 0x002A : Hardware Lean Ring NoC MMIO (TX/DST/RX/STAT/MBOX/INFO)
;   0x0100 - 0x01FF : Direct Stride Vector Table (16 words per vector)
;   0x0200 - 0x03EF : Resident Loader & Trap 1 Syscall Bridge
;   0x03F0 - 0x03F7 : Worker Stub private state variables (local BRAM)
;   0x0400+         : Loaded User Application Space (BRAM + SDRAM via Cache)
; ==============================================================================

.include "common.inc"

; ------------------------------------------------------------------------------
; Hardware Lean Ring NoC MMIO Registers (matches hdl/mr4/lib/noc_router.dart)
; ------------------------------------------------------------------------------
.define NOC_TX_DATA         0x0020  ; W: push payload word to NOC_DST_CORE
.define NOC_DST_CORE        0x0021  ; R/W: direct destination core ID
.define NOC_RX_DATA         0x0022  ; R: pop word from shared 16-word RX FIFO
.define NOC_STAT            0x0023  ; R: b0=rx_ne, b1=rx_full, b2=tx_rdy, b4=mbox_v
.define NOC_MBOX_SEND       0x0025  ; W: send priority doorbell/MBOX to NOC_DST_CORE
.define NOC_MBOX_DATA       0x0026  ; R: pop incoming MBOX payload (clears Trap 14)

; ------------------------------------------------------------------------------
; Stub Private Scratchpad (0x03F0 - 0x03F5, inside local BRAM, clear of 0x0010!)
; ------------------------------------------------------------------------------
.define STUB_ARG1           0x03F0  ; Saved R1 (val / buf_ptr)
.define STUB_ARG2           0x03F1  ; Saved R2 (val / word_len / reply status)
.define STUB_ARG3           0x03F2  ; Saved R3 (fd / mode / index / words_read)
.define STUB_RET_PC         0x03F3  ; Saved R0 (app return PC)
.define STUB_SYS_ID         0x03F4  ; Extracted syscall_id byte
.define STUB_ENTRY_ADDR     0x03F5  ; Loaded app entry point

; Protocol Constants
.define CMD_LOAD_MAGIC      0x4C44  ; "LD" packet header from Core 0
.define CMD_SYS_GRANT       0x474F  ; "GO" grant token from Core 0
.define MBOX_SYS_REQ_HI     0x5300  ; "S\0" | syscall_id doorbell to Core 0
.define SYS_EXIT_ID         0x01    ; Scalar exit syscall ID

; Default Stack Tops (64K virtual space; BRAM or SDRAM-cached on hardware)
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

.org 0x0120
_trap2_unhandled:
    LD      R0, 2
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x0130
_trap3_unhandled:
    LD      R0, 3
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x0140
_trap4_unhandled:
    LD      R0, 4
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x0150
_trap5_unhandled:
    LD      R0, 5
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x0160
_trap6_unhandled:
    LD      R0, 6
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x0170
_trap7_unhandled:
    LD      R0, 7
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x0180
_trap8_unhandled:
    LD      R0, 8
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x0190
_trap9_unhandled:
    LD      R0, 9
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x01A0
_trap10_unhandled:
    LD      R0, 10
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x01B0
_trap11_unhandled:
    LD      R0, 11
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x01C0
_trap12_unhandled:
    LD      R0, 12
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x01D0
_trap13_unhandled:
    LD      R0, 13
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

.org 0x01E0
_trap14_kill:
    ; Hardware async Doorbell/MBOX KILL from Core 0:
    ; Discard app state, clear MBOX, drain stale RX FIFO, reset stacks, go idle.
    LOAD16  R0, _stub_reset_idle
    JMP     R0
    .align

.org 0x01F0
_trap15_align_fault:
    ; Hardware Slot 1 violation: notify Core 0 (0xFF0F) and return to idle
    LD      R0, 15
    LD      R1, R0
    LOAD16  R0, _trap_fault_report
    JMP     R0
    .align

; ==============================================================================
; WORKER STUB RUNTIME (0x0200 - 0x03EF)
; ==============================================================================
.org 0x0200

; ------------------------------------------------------------------------------
; Stack Reset, Doorbell/FIFO Drain & Idle Program Loader
; Polls NOC_RX_DATA for CMD_LOAD_MAGIC (0x4C44).
; Packet: [0x4C44, load_addr, word_count, entry_addr, w0, w1, ..., wN-1]
; ------------------------------------------------------------------------------
_stub_reset_idle:
    LOAD16  R1, WORKER_RSP_INIT
    LD      R0, 4                   ; 0x0004 = RSP
    LD      (R0), R1
    LOAD16  R1, WORKER_ASP_INIT
    INC     R0                      ; 0x0005 = ASP
    LD      (R0), R1

    ; Clear any latched MBOX doorbell so Ulx3sTop Trap 14 gate re-arms cleanly
    LOAD16  R0, NOC_MBOX_DATA
    LD      R1, (R0)

    ; Drain any stale words left in our RX FIFO after a remote KILL
_drain_rx_loop:
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LD      R0, 1
    AND     R1, R0
    LOAD16  R0, _loader_idle
    JMP.Z   R0, R1
    LOAD16  R0, NOC_RX_DATA
    LD      R1, (R0)
    LOAD16  R0, _drain_rx_loop
    JMP     R0

_loader_idle:
    ; Poll inline (zero RSP depth while idle so RSP stays exactly 0xFEFF)
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LD      R0, 1
    AND     R1, R0
    LOAD16  R0, _loader_idle
    JMP.Z   R0, R1
    LOAD16  R0, NOC_RX_DATA
    LD      R1, (R0)
    LOAD16  R2, CMD_LOAD_MAGIC
    SUB     R1, R2
    LOAD16  R0, _loader_start_rx
    JMP.Z   R0, R1                  ; Magic matched -> begin load
    LOAD16  R0, _loader_idle
    JMP     R0

_loader_start_rx:
    ; Pop load header: [load_addr, word_count, entry_addr]
    RCALL   _noc_rx_word
    LD      R2, R1                  ; R2 = load_addr (e.g. 0x0400)
    RCALL   _noc_rx_word
    LD      R3, R1                  ; R3 = word_count
    RCALL   _noc_rx_word            ; R1 = entry_addr
    LOAD16  R0, STUB_ENTRY_ADDR
    LD      (R0), R1

_loader_copy_loop:
    LOAD16  R0, _loader_launch
    JMP.Z   R0, R3                  ; Done when word_count == 0
    RCALL   _noc_rx_word            ; R1 = next program word (preserves R2, R3)
    LD      (R2), R1                ; Write to worker RAM / SDRAM cache
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
; Trap Fault Reporter (Traps 2..13 & Trap 15)
; Entry: R1 = trap vector number (2..13 or 15) -> sends SYS_EXIT(0xFF00 | vec)
; ------------------------------------------------------------------------------
_trap_fault_report:
    LOAD16  R2, 0xFF00
    OR      R1, R2
    LOAD16  R0, STUB_ARG1
    LD      (R0), R1
    ; Fall through to _send_exit_and_idle

_send_exit_and_idle:
    LOAD16  R1, SYS_EXIT_ID
    LOAD16  R0, STUB_SYS_ID
    LD      (R0), R1
    RCALL   _noc_request_grant      ; Ring Core 0 MBOX & wait for "GO" grant
    RCALL   _push_hdr_helper        ; Push [(CPUID << 8) | SYS_EXIT_ID]
    LD0     R1
    INC     R1                      ; Payload len = 1
    RCALL   _noc_tx_word
    LOAD16  R2, STUB_ARG1
    LD      R1, (R2)                ; Exit code
    RCALL   _noc_tx_word
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

    ; 5. Acquire exclusive syscall transmit grant from Core 0 via Lean Ring MBOX
    RCALL   _noc_request_grant

    ; 6. Push Wire Header: Word 0 = (CPUID << 8) | syscall_id
    RCALL   _push_hdr_helper

    ; 7. Route by syscall class (bits [7:4] of syscall_id)
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
    LD      R0, 2
    LD      R1, R0                  ; payload_len = 2
    RCALL   _noc_tx_word
    LOAD16  R2, STUB_ARG1
    LD      R1, (R2)                ; ARG1
    RCALL   _noc_tx_word
    INC     R2
    LD      R1, (R2)                ; ARG2
    RCALL   _noc_tx_word
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
    RCALL   _noc_tx_word            ; Push payload_len

    LOAD16  R2, STUB_ARG3
    LD      R1, (R2)                ; Push extra (fd/mode)
    RCALL   _noc_tx_word
    LD      R1, R3                  ; Push word_len
    RCALL   _noc_tx_word

    LOAD16  R2, STUB_ARG1
    LD      R2, (R2)                ; R2 = src_ptr
_buf_out_loop:
    LOAD16  R0, _sys_wait_scalar_reply
    JMP.Z   R0, R3                  ; Done streaming when count == 0
    LD      R1, (R2)                ; Load word from app RAM
    RCALL   _noc_tx_word            ; Push word (preserves R2, R3)
    INC     R2
    DEC     R3
    LOAD16  R0, _buf_out_loop
    JMP     R0

; --- Class C: Buffer In (0x20..0x2F) -----------------------------------------
; App: R1=dst_ptr, R2=max_words, R3=extra (fd/index)
; Sends: [len=2, extra, max_words]
; Receives: [status -> R1, words_read -> R2, w0..wN-1 -> mem[dst_ptr++]]
_sys_class_buf_in:
    LD      R0, 2
    LD      R1, R0                  ; payload_len = 2
    RCALL   _noc_tx_word
    LOAD16  R2, STUB_ARG3
    LD      R1, (R2)                ; Push extra (fd/index)
    RCALL   _noc_tx_word
    LOAD16  R2, STUB_ARG2
    LD      R1, (R2)                ; Push max_words
    RCALL   _noc_tx_word

    ; Read reply header: [status, words_read]
    RCALL   _noc_rx_word            ; R1 = status
    LOAD16  R0, STUB_ARG2
    LD      (R0), R1                ; Save status
    RCALL   _noc_rx_word            ; R1 = words_read
    LD      R3, R1                  ; R3 = loop counter
    LOAD16  R0, STUB_ARG3
    LD      (R0), R3                ; Save words_read for return in R2

    LOAD16  R2, STUB_ARG1
    LD      R2, (R2)                ; R2 = dst_ptr
_buf_in_loop:
    LOAD16  R0, _buf_in_done
    JMP.Z   R0, R3
    RCALL   _noc_rx_word            ; R1 = data word (preserves R2, R3)
    LD      (R2), R1                ; Store to app RAM
    INC     R2
    DEC     R3
    LOAD16  R0, _buf_in_loop
    JMP     R0

_buf_in_done:
    LOAD16  R0, STUB_ARG2
    LD      R1, (R0)                ; R1 = status
    INC     R0                      ; STUB_ARG3
    LD      R2, (R0)                ; R2 = words_read
    LOAD16  R0, STUB_RET_PC
    LD      R0, (R0)
    JMP     R0                      ; Return to app

; --- Common Scalar Reply Path ------------------------------------------------
_sys_wait_scalar_reply:
    RCALL   _noc_rx_word            ; R1 = status
    LD      R3, R1                  ; Preserve status across next RX poll
    RCALL   _noc_rx_word            ; R1 = secondary result
    LD      R2, R1                  ; R2 = secondary result
    LD      R1, R3                  ; R1 = status

    LOAD16  R0, STUB_RET_PC
    LD      R0, (R0)
    JMP     R0                      ; Return to app

; ==============================================================================
; LEAN RING TRANSPORT HELPERS
; ==============================================================================

; Blocking RX pop: polls NOC_STAT[0] (rx_not_empty), returns NOC_RX_DATA in R1.
; Preserves R2 and R3.
_noc_rx_word:
    RPUSH   R0
_noc_rx_poll:
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LD      R0, 1
    AND     R1, R0
    LOAD16  R0, _noc_rx_poll
    JMP.Z   R0, R1
    LOAD16  R0, NOC_RX_DATA
    LD      R1, (R0)
    RRET

; Blocking TX push: polls NOC_STAT[2] (tx_ready), writes R1 to NOC_TX_DATA.
; Preserves R1, R2, and R3.
_noc_tx_word:
    RPUSH   R0
    RPUSH   R1
_noc_tx_poll:
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LD      R0, 4
    AND     R1, R0
    LOAD16  R0, _noc_tx_poll
    JMP.Z   R0, R1
    RPOP    R1
    LOAD16  R0, NOC_TX_DATA
    LD      (R0), R1
    RRET

; Ring Core 0's priority MBOX doorbell and wait for exclusive CMD_SYS_GRANT ("GO").
; Prevents multi-worker packet interleaving on Core 0's shared 16-word RX FIFO.
_noc_request_grant:
    RPUSH   R0
    LOAD16  R0, NOC_DST_CORE
    LD0     R1
    LD      (R0), R1                ; Target = Core 0
_noc_mbox_poll:
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LD      R0, 4
    AND     R1, R0
    LOAD16  R0, _noc_mbox_poll
    JMP.Z   R0, R1
    LOAD16  R0, STUB_SYS_ID
    LD      R1, (R0)
    LOAD16  R2, MBOX_SYS_REQ_HI
    OR      R1, R2                  ; 0x5300 | syscall_id
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1                ; Ring Core 0 doorbell
_noc_wait_grant:
    RCALL   _noc_rx_word            ; Wait for Core 0 "GO" token (0x474F)
    LOAD16  R2, CMD_SYS_GRANT
    SUB     R1, R2
    LOAD16  R0, _noc_wait_grant_ok
    JMP.Z   R0, R1
    LOAD16  R0, _noc_wait_grant
    JMP     R0
_noc_wait_grant_ok:
    LOAD16  R0, NOC_DST_CORE
    LD0     R1
    LD      (R0), R1                ; Ensure target = Core 0 for packet stream
    RRET

; Push Word 0 = (CPUID << 8) | STUB_SYS_ID to NOC_TX_DATA (NOC_DST_CORE == 0).
_push_hdr_helper:
    RPUSH   R0
    LD      R0, 13                  ; 0x000D = CPUID (RO)
    LD      R1, (R0)                ; R1 = core_id
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
    RCALL   _noc_tx_word
    RRET

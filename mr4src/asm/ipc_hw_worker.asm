; ==============================================================================
; FILE: mr4src/asm/ipc_hw_worker.asm
; ULX3S-85F 4-Core Hardware IPC + Trap 14 Cross-Trap Worker Firmware (Cores 1..3)
;
; Runs out of 2K local BRAM (stacks at 0x07FF / 0x07BF) with private SDRAM at
; 0x0800..0xFFFF ({coreId[7:0], addr[15:0]}).
;
; Trap 14 Doorbell Protocol (from Core 0 or upstream ring neighbor):
;   0xA100 | W : T2 Ping + private SDRAM 0x4000 round-trip -> reply MBOX to Core 0
;                with ((W << 12) | 0x0500 | (val & 0x00FF)) if SDRAM & src==0 OK,
;                else 0xEEEE.
;   0xB008     : T3 Pop 8 words from NOC_RX_DATA, XOR each with 0x00FF, push all 8
;                back to Core 0's RX FIFO, and send Trap 14 MBOX with XOR checksum.
;   0xC0xx     : T4 4-Core Ring Relay! Write (W * 0x1111) to private SDRAM 0x4000,
;                evict via 0x8000, verify readback, add (W * 0x0011) to token, and
;                relay MBOX Trap 14 to next core ((W + 1) & 3 -> wraps 3 -> 0!).
; ==============================================================================

.include "common.inc"

.define NOC_TX_DATA     0x0020
.define NOC_DST_CORE    0x0021
.define NOC_RX_DATA     0x0022
.define NOC_STAT        0x0023
.define NOC_MBOX_SEND   0x0025
.define NOC_MBOX_DATA   0x0026
.define NOC_MBOX_SRC    0x0027

.org 0x0100
_reset_vector:
    LOAD16  R1, 0x07FF          ; RSP in local BRAM
    LD      R0, 4
    LD      (R0), R1
    LOAD16  R1, 0x07BF          ; ASP in local BRAM
    LD      R0, 5
    LD      (R0), R1
    LOAD16  R0, _main
    JMP     R0

; --- Trap 14: Hardware NoC Doorbell/MBOX ISR (<= 16 words) ---
.org 0x01E0
_trap14_vector:
    XCHG    R0                  ; Save user's LIVE R0 in shadow_r0 (PC is in hardware EPC)
    LOAD16  R0, _trap14_isr
    JMP     R0

.org 0x01F0
_trap15_vector:
    LOAD16  R0, _trap15_halt
_trap15_halt:
    JMP     R0

; ==============================================================================
; Worker Main & ISR (0x0200)
; ==============================================================================
.org 0x0200

_trap14_isr:
    XCHG    R1
    XCHG    R2
    XCHG    R3

    ; Read MBOX payload & source core (reading 0x0026 clears mboxValidQ)
    LOAD16  R0, NOC_MBOX_SRC
    LD      R1, (R0)
    LOAD16  R2, var_mbox_src
    LD      (R2), R1

    LOAD16  R0, NOC_MBOX_DATA
    LD      R1, (R0)
    LOAD16  R2, var_mbox_val
    LD      (R2), R1

    ; Increment trap counter & set pending flag
    LOAD16  R2, var_trap_cnt
    LD      R1, (R2)
    INC     R1
    LD      (R2), R1

    LOAD16  R1, 1
    LOAD16  R2, var_mbox_flag
    LD      (R2), R1

    XCHG    R3
    XCHG    R2
    XCHG    R1
    XCHG    R0
    ERET

_main:
    ; Clear mailbox state in local BRAM
    LD0     R1
    LOAD16  R2, var_mbox_flag
    LD      (R2), R1
    LOAD16  R2, var_trap_cnt
    LD      (R2), R1

    ; Cache own hardware CPUID (1, 2, or 3)
    GET_CPUID R1
    LOAD16  R2, var_my_id
    LD      (R2), R1

; Idle loop: ZERO XCHG and NEVER hold live values in R0 (R0 is the hardware trap link reg!)
_worker_idle:
    LOAD16  R2, var_mbox_flag
    LD      R1, (R2)
    LOAD16  R3, _worker_idle
    JMP.Z   R3, R1

    ; Consume flag
    LD0     R1
    LD      (R2), R1

    ; Dispatch by top nibble of var_mbox_val (0xA..., 0xB..., 0xC...)
    LOAD16  R2, var_mbox_val
    LD      R1, (R2)
    LOAD16  R0, 0xF000
    AND     R1, R0

    LOAD16  R0, 0xA000
    SUB     R0, R1
    LOAD16  R3, _cmd_ping
    JMP.Z   R3, R0

    LOAD16  R0, 0xB000
    SUB     R0, R1
    LOAD16  R3, _cmd_fifo_echo
    JMP.Z   R3, R0

    LOAD16  R0, 0xC000
    SUB     R0, R1
    LOAD16  R3, _cmd_ring_relay
    JMP.Z   R3, R0

    LOAD16  R0, _worker_idle
    JMP     R0

; ------------------------------------------------------------------------------
; Command 0xA10x: Ping + private SDRAM 0x4000 round-trip -> MBOX reply to Core 0
; ------------------------------------------------------------------------------
_cmd_ping:
    ; Compute unique pattern = var_mbox_val ^ (my_id << 12)
    LOAD16  R2, var_my_id
    LD      R1, (R2)
    RCALL   shift_l12           ; R1 = my_id << 12
    LOAD16  R2, var_tmp
    LD      (R2), R1            ; var_tmp = my_id << 12

    LOAD16  R2, var_mbox_val
    LD      R3, (R2)
    XOR     R1, R3              ; R1 = pattern
    LOAD16  R2, var_pat
    LD      (R2), R1

    ; Write pattern to private SDRAM 0x4000, evict via 0x8000, refill 0x4000
    LOAD16  R2, 0x4000
    LD      (R2), R1
    LOAD16  R2, 0x8000
    LD      R0, (R2)            ; Evicts 0x4000 line to SDRAM
    LOAD16  R2, 0x4000
    LD      R1, (R2)            ; Refills 0x4000 from SDRAM

    ; Verify readback == var_pat AND var_mbox_src == 0
    LOAD16  R2, var_pat
    LD      R0, (R2)
    SUB     R0, R1
    LOAD16  R3, .ping_ok1
    JMP.Z   R3, R0
    LOAD16  R1, 0xEEEE
    LOAD16  R3, .ping_send
    JMP     R3

.ping_ok1:
    LOAD16  R2, var_mbox_src
    LD      R0, (R2)
    LOAD16  R3, .ping_ok2
    JMP.Z   R3, R0
    LOAD16  R1, 0xEE01
    LOAD16  R3, .ping_send
    JMP     R3

.ping_ok2:
    ; Reply = (my_id << 12) | 0x0500 | (var_mbox_val & 0x00FF)
    LOAD16  R2, var_mbox_val
    LD      R1, (R2)
    LOAD16  R0, 0x00FF
    AND     R1, R0
    LOAD16  R0, 0x0500
    OR      R1, R0
    LOAD16  R2, var_tmp
    LD      R0, (R2)
    OR      R1, R0

.ping_send:
    LD0     R2                  ; Target Core 0
    LOAD16  R0, noc_send_mbox_and_idle
    JMP     R0

; ------------------------------------------------------------------------------
; Command 0xB008: Pop 8 words from RX FIFO, transform (^ 0x00FF), stream back to
; Core 0 RX FIFO, and ring Core 0 Trap 14 with 16-bit XOR checksum.
; ------------------------------------------------------------------------------
_cmd_fifo_echo:
    ; Select target Core 0 for outbound TX
    LOAD16  R0, NOC_DST_CORE
    LD0     R1
    LD      (R0), R1

    LD0     R1
    LOAD16  R2, var_chk
    LD      (R2), R1
    LOAD16  R1, 8
    LOAD16  R2, var_cnt
    LD      (R2), R1

.fe_loop:
    ; Wait for RX not_empty (NOC_STAT bit 0)
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LOAD16  R2, 1
    AND     R1, R2
    LOAD16  R3, .fe_loop
    JMP.Z   R3, R1

    ; Pop word from RX FIFO
    LOAD16  R0, NOC_RX_DATA
    LD      R1, (R0)

    ; Transform: word ^ 0x00FF
    LOAD16  R0, 0x00FF
    XOR     R1, R0
    LOAD16  R2, var_tmp
    LD      (R2), R1

    ; Update ADD checksum
    LOAD16  R2, var_chk
    LD      R0, (R2)
    ADD     R0, R1
    LD      (R2), R0

    ; Wait for TX ready (NOC_STAT bit 2) and send transformed word to Core 0
.fe_tx_wait:
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LOAD16  R2, 4
    AND     R1, R2
    LOAD16  R3, .fe_tx_wait
    JMP.Z   R3, R1

    LOAD16  R2, var_tmp
    LD      R1, (R2)
    LOAD16  R0, NOC_TX_DATA
    LD      (R0), R1

    ; Decrement loop counter
    LOAD16  R2, var_cnt
    LD      R1, (R2)
    DEC     R1
    LD      (R2), R1
    LOAD16  R3, .fe_done
    JMP.Z   R3, R1
    LOAD16  R3, .fe_loop
    JMP     R3

.fe_done:
    ; Send Trap 14 MBOX to Core 0 carrying checksum, then jump straight to _worker_idle (zero XCHG after send!)
    LOAD16  R2, var_chk
    LD      R1, (R2)
    LD0     R2                  ; Target Core 0
    LOAD16  R0, noc_send_mbox_and_idle
    JMP     R0

; ------------------------------------------------------------------------------
; Command 0xC0xx: 4-Core Ring Relay + Private SDRAM Isolation Write
;   Writes (my_id * 0x1111) to private SDRAM 0x4000, evicts & verifies readback,
;   adds (my_id * 0x0011) to token, and sends Trap 14 MBOX to (my_id + 1) & 3.
; ------------------------------------------------------------------------------
_cmd_ring_relay:
    ; Build pat = my_id * 0x1111 (my_id is 1, 2, or 3 -> loop add 0x1111)
    LOAD16  R2, var_my_id
    LD      R3, (R2)
    LD0     R1
    LOAD16  R0, 0x1111
.rr_mul1:
    ADD     R1, R0
    DEC     R3
    LOAD16  R2, .rr_mul1_done
    JMP.Z   R2, R3
    LOAD16  R2, .rr_mul1
    JMP     R2
.rr_mul1_done:
    LOAD16  R2, var_pat
    LD      (R2), R1

    ; Write pat to private SDRAM 0x4000, evict via 0x8000, read back & verify
    LOAD16  R2, 0x4000
    LD      (R2), R1
    LOAD16  R2, 0x8000
    LD      R0, (R2)
    LOAD16  R2, 0x4000
    LD      R1, (R2)

    LOAD16  R2, var_pat
    LD      R0, (R2)
    SUB     R0, R1
    LOAD16  R3, .rr_sdram_ok
    JMP.Z   R3, R0
    LOAD16  R1, 0xEE04          ; Private SDRAM mismatch!
    LD0     R2
    LOAD16  R0, noc_send_mbox_and_idle
    JMP     R0

.rr_sdram_ok:
    ; token += my_id * 0x0011
    LOAD16  R2, var_my_id
    LD      R3, (R2)
    LOAD16  R2, var_mbox_val
    LD      R1, (R2)
    LOAD16  R0, 0x0011
.rr_add:
    ADD     R1, R0
    DEC     R3
    LOAD16  R2, .rr_add_done
    JMP.Z   R2, R3
    LOAD16  R2, .rr_add
    JMP     R2
.rr_add_done:
    ; Next core = (my_id + 1) & 3 (1->2, 2->3, 3->0)
    LOAD16  R2, var_my_id
    LD      R2, (R2)
    INC     R2
    LOAD16  R0, 3
    AND     R2, R0
    LOAD16  R0, noc_send_mbox_and_idle
    JMP     R0

; ------------------------------------------------------------------------------
; Helpers
; ------------------------------------------------------------------------------
; shift_l12: R1 = R1 << 12
shift_l12:
    RPUSH   R0
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    RRET

; noc_send_mbox_and_idle: R2 = dst_core, R1 = payload -> sends MBOX and jumps
; directly to _worker_idle with ZERO XCHG instructions after NOC_MBOX_SEND.
noc_send_mbox_and_idle:
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R2
.nsm_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LOAD16  R0, 4
    AND     R3, R0
    LOAD16  R0, .nsm_wait
    JMP.Z   R0, R3
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1
    LOAD16  R0, _worker_idle
    JMP     R0

; Local BRAM Variables (0x0710..0x072F)
.org 0x0710
var_mbox_val:  .word 0
var_mbox_src:  .word 0
var_trap_cnt:  .word 0
var_mbox_flag: .word 0
var_my_id:     .word 0
var_tmp:       .word 0
var_pat:       .word 0
var_chk:       .word 0
var_cnt:       .word 0

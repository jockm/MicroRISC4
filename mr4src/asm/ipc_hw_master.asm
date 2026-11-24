; ==============================================================================
; FILE: mr4src/asm/ipc_hw_master.asm
; ULX3S-85F 4-Core Hardware IPC + Trap 14 Cross-Trap Master Suite (Core 0)
;
; Paired with ipc_hw_worker.asm on Workers 1..3 (ULX3S_NOC_CORES=4,
; ULX3S_SDRAM_CACHE=1). Runs 100% out of 2K local BRAM (stacks at 0x07FF/0x07BF)
; and prints a complete verification report over 3 Mbaud UART.
; ==============================================================================

.include "common.inc"

.define NOC_TX_DATA     0x0020
.define NOC_DST_CORE    0x0021
.define NOC_RX_DATA     0x0022
.define NOC_STAT        0x0023
.define NOC_MBOX_SEND   0x0025
.define NOC_MBOX_DATA   0x0026
.define NOC_MBOX_SRC    0x0027
.define NOC_INFO        0x002A

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
    XCHG    R0                  ; Save interrupted return PC in shadow_r0
    LOAD16  R0, _trap14_isr
    JMP     R0

.org 0x01F0
_trap15_vector:
    LOAD16  R1, 33              ; '!'
    PUTC    R1
    LOAD16  R1, 84              ; 'T'
    PUTC    R1
    LOAD16  R1, 49              ; '1'
    PUTC    R1
    LOAD16  R1, 53              ; '5'
    PUTC    R1
    LOAD16  R0, _t15_halt
_t15_halt:
    JMP     R0

; ==============================================================================
; Master Main & Trap 14 ISR (0x0200)
; ==============================================================================
.org 0x0200

_trap14_isr:
    XCHG    R1
    XCHG    R2
    XCHG    R3

    LOAD16  R0, NOC_MBOX_SRC
    LD      R1, (R0)
    LOAD16  R2, var_mbox_src
    LD      (R2), R1

    LOAD16  R0, NOC_MBOX_DATA
    LD      R1, (R0)
    LOAD16  R2, var_mbox_val
    LD      (R2), R1

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
    JMP     R0

_main:
run_suite:
    ; Reset local BRAM stacks & suite counters
    LOAD16  R1, 0x07FF
    LD      R0, 4
    LD      (R0), R1
    LOAD16  R1, 0x07BF
    LD      R0, 5
    LD      (R0), R1

    LD0     R1
    LOAD16  R2, var_mbox_flag
    LD      (R2), R1
    LOAD16  R2, var_trap_cnt
    LD      (R2), R1
    LOAD16  R2, var_errs
    LD      (R2), R1

    ; Short startup delay so Workers 1..3 finish reset & enter _worker_idle
    LOAD16  R0, 2000
.boot_delay:
    DEC     R0
    LOAD16  R1, .boot_delay_done
    JMP.Z   R1, R0
    LOAD16  R1, .boot_delay
    JMP     R1
.boot_delay_done:

    LOAD16  R1, msg_banner
    RCALL   puts

    ; ------------------------------------------------------------------
    ; T1: Hardware Topology Discovery (CPUID + NOC_INFO)
    ; ------------------------------------------------------------------
    LOAD16  R1, msg_t1
    RCALL   puts
    GET_CPUID R1
    RCALL   print_hex16
    RCALL   print_space
    LOAD16  R0, NOC_INFO
    LD      R1, (R0)
    LOAD16  R2, var_tmp
    LD      (R2), R1
    RCALL   print_hex16
    RCALL   print_nl
    ; Expect NOC_INFO == 0x1004
    LOAD16  R2, var_tmp
    LD      R1, (R2)
    LOAD16  R0, 0x1004
    SUB     R0, R1
    LOAD16  R3, .t1_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.t1_ok:

    ; ------------------------------------------------------------------
    ; T2: Per-Worker Hardware Trap 14 Doorbell Ping + Worker SDRAM Test
    ; ------------------------------------------------------------------
    LOAD16  R1, msg_t2
    RCALL   puts

    LOAD16  R1, 1
    LOAD16  R2, 0xA101
    LOAD16  R3, 0x1501
    RCALL   test_worker_ping

    LOAD16  R1, 2
    LOAD16  R2, 0xA102
    LOAD16  R3, 0x2502
    RCALL   test_worker_ping

    LOAD16  R1, 3
    LOAD16  R2, 0xA103
    LOAD16  R3, 0x3503
    RCALL   test_worker_ping
    RCALL   print_nl

    ; ------------------------------------------------------------------
    ; T3: 8-Word Multi-Hop RX FIFO Burst Echo + Trap 14 Checksum (W1..W3)
    ; ------------------------------------------------------------------
    LOAD16  R1, msg_t3
    RCALL   puts

    LOAD16  R1, 1
    LOAD16  R2, 0x1100
    RCALL   test_worker_fifo

    LOAD16  R1, 2
    LOAD16  R2, 0x2200
    RCALL   test_worker_fifo

    LOAD16  R1, 3
    LOAD16  R2, 0x3300
    RCALL   test_worker_fifo
    RCALL   print_nl

    ; ------------------------------------------------------------------
    ; T4 & T5: 4-Core Ring Relay (0->1->2->3->0) + Concurrent SDRAM Isolation
    ; ------------------------------------------------------------------
    ; Write 0xCAFE to Core 0's private SDRAM 0x4000 and evict via 0x8000
    LOAD16  R2, 0x4000
    LOAD16  R1, 0xCAFE
    LD      (R2), R1
    LOAD16  R2, 0x8000
    LD      R0, (R2)

    ; Send Trap 14 relay token 0xC000 to Core 1 (1->2->3->0 => 0xC066!)
    LOAD16  R2, 1
    LOAD16  R1, 0xC000
    RCALL   noc_send_mbox_wait

    LOAD16  R1, msg_t4
    RCALL   puts
    LOAD16  R2, var_mbox_src
    LD      R1, (R2)
    RCALL   print_hex16
    RCALL   print_space
    LOAD16  R2, var_mbox_val
    LD      R1, (R2)
    RCALL   print_hex16
    RCALL   print_nl

    ; Verify src == 3 and val == 0xC066
    LOAD16  R2, var_mbox_src
    LD      R1, (R2)
    LOAD16  R0, 3
    SUB     R0, R1
    LOAD16  R3, .t4_src_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.t4_src_ok:
    LOAD16  R2, var_mbox_val
    LD      R1, (R2)
    LOAD16  R0, 0xC066
    SUB     R0, R1
    LOAD16  R3, .t4_val_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.t4_val_ok:

    ; T5: Verify Core 0's private SDRAM 0x4000 is STILL 0xCAFE after W1..W3 wrote theirs!
    LOAD16  R1, msg_t5
    RCALL   puts
    LOAD16  R2, 0x4000
    LD      R1, (R2)
    LOAD16  R2, var_tmp
    LD      (R2), R1
    RCALL   print_hex16
    RCALL   print_nl
    LOAD16  R2, var_tmp
    LD      R1, (R2)
    LOAD16  R0, 0xCAFE
    SUB     R0, R1
    LOAD16  R3, .t5_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.t5_ok:

    ; ------------------------------------------------------------------
    ; Summary: Trap 14 count (expect 0007) & PASS/FAIL
    ; ------------------------------------------------------------------
    LOAD16  R1, msg_sum
    RCALL   puts
    LOAD16  R2, var_trap_cnt
    LD      R1, (R2)
    RCALL   print_hex16
    RCALL   print_space

    LOAD16  R2, var_trap_cnt
    LD      R1, (R2)
    LOAD16  R0, 7
    SUB     R0, R1
    LOAD16  R3, .cnt_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.cnt_ok:

    LOAD16  R2, var_errs
    LD      R1, (R2)
    LOAD16  R3, .all_pass
    JMP.Z   R3, R1
    LOAD16  R1, msg_fail
    RCALL   puts
    LOAD16  R2, var_errs
    LD      R1, (R2)
    RCALL   print_hex16
    RCALL   print_nl
    LOAD16  R3, .wait_key
    JMP     R3
.all_pass:
    LOAD16  R1, msg_pass
    RCALL   puts

.wait_key:
    LOAD16  R1, msg_prompt
    RCALL   puts
    GETC    R1
    LOAD16  R0, run_suite
    JMP     R0

; ==============================================================================
; Test Helpers
; ==============================================================================

; test_worker_ping: R1 = worker_id, R2 = tx_val, R3 = exp_val
test_worker_ping:
    RPUSH   R0
    LOAD16  R0, var_wid
    LD      (R0), R1
    LOAD16  R0, var_exp
    LD      (R0), R3

    ; Send MBOX(tx_val) to worker_id and wait cleanly for Trap 14 reply
    LD      R1, R2              ; payload = tx_val
    LOAD16  R0, var_wid
    LD      R2, (R0)            ; dst_core = worker_id
    RCALL   noc_send_mbox_wait

    ; Print "SSSS:VVVV "
    LOAD16  R0, var_mbox_src
    LD      R1, (R0)
    RCALL   print_hex16
    LOAD16  R1, 58              ; ':'
    PUTC    R1
    LOAD16  R0, var_mbox_val
    LD      R1, (R0)
    RCALL   print_hex16
    RCALL   print_space

    ; Check src == worker_id and val == exp_val
    LOAD16  R0, var_mbox_src
    LD      R1, (R0)
    LOAD16  R0, var_wid
    LD      R2, (R0)
    SUB     R1, R2
    LOAD16  R3, .twp_s_ok
    JMP.Z   R3, R1
    RCALL   inc_err
.twp_s_ok:
    LOAD16  R0, var_mbox_val
    LD      R1, (R0)
    LOAD16  R0, var_exp
    LD      R2, (R0)
    SUB     R1, R2
    LOAD16  R3, .twp_v_ok
    JMP.Z   R3, R1
    RCALL   inc_err
.twp_v_ok:
    RRET

; test_worker_fifo: R1 = worker_id, R2 = base_val (streams base+0..base+7)
test_worker_fifo:
    RPUSH   R0
    LOAD16  R0, var_wid
    LD      (R0), R1
    LOAD16  R0, var_base
    LD      (R0), R2

    ; Select target worker_id
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R1

    ; Push 8 words (base+0 .. base+7) into worker's RX FIFO
    LOAD16  R1, 8
    LOAD16  R0, var_cnt
    LD      (R0), R1
    LOAD16  R0, var_cur
    LD      (R0), R2

.twf_tx:
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LOAD16  R2, 4
    AND     R1, R2
    LOAD16  R3, .twf_tx
    JMP.Z   R3, R1

    LOAD16  R0, var_cur
    LD      R1, (R0)
    LOAD16  R2, NOC_TX_DATA
    LD      (R2), R1
    INC     R1
    LD      (R0), R1

    LOAD16  R0, var_cnt
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R3, .twf_tx_done
    JMP.Z   R3, R1
    LOAD16  R3, .twf_tx
    JMP     R3

.twf_tx_done:
    ; Ring worker Trap 14 with 0xB008 (echo 8 words) and wait cleanly for Trap 14 reply
    LOAD16  R0, var_wid
    LD      R2, (R0)
    LOAD16  R1, 0xB008
    RCALL   noc_send_mbox_wait

    ; Verify all 8 echoed words == (base+i) ^ 0x00FF and XOR checksum == var_mbox_val
    LD0     R1
    LOAD16  R0, var_chk
    LD      (R0), R1
    LOAD16  R0, var_bad
    LD      (R0), R1
    LOAD16  R1, 8
    LOAD16  R0, var_cnt
    LD      (R0), R1
    LOAD16  R0, var_base
    LD      R1, (R0)
    LOAD16  R0, var_cur
    LD      (R0), R1

.twf_rx:
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LOAD16  R2, 1
    AND     R1, R2
    LOAD16  R3, .twf_rx
    JMP.Z   R3, R1

    LOAD16  R0, NOC_RX_DATA
    LD      R1, (R0)            ; got word

    ; Update ADD checksum
    LOAD16  R0, var_chk
    LD      R2, (R0)
    ADD     R2, R1
    LD      (R0), R2

    ; Compare against (var_cur ^ 0x00FF)
    LOAD16  R0, var_cur
    LD      R2, (R0)
    LOAD16  R3, 0x00FF
    XOR     R2, R3
    SUB     R1, R2
    LOAD16  R3, .twf_w_ok
    JMP.Z   R3, R1
    LOAD16  R0, var_bad
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
.twf_w_ok:
    LOAD16  R0, var_cur
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1

    LOAD16  R0, var_cnt
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R3, .twf_rx_done
    JMP.Z   R3, R1
    LOAD16  R3, .twf_rx
    JMP     R3

.twf_rx_done:
    ; Check checksum == var_mbox_val AND var_bad == 0
    LOAD16  R0, var_chk
    LD      R1, (R0)
    LOAD16  R0, var_mbox_val
    LD      R2, (R0)
    SUB     R1, R2
    LOAD16  R3, .twf_chk_ok
    JMP.Z   R3, R1
    LOAD16  R0, var_bad
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
.twf_chk_ok:
    ; Print "CHK:BAD " (expect XXXX:0000)
    LOAD16  R0, var_chk
    LD      R1, (R0)
    RCALL   print_hex16
    LOAD16  R1, 58
    PUTC    R1
    LOAD16  R0, var_bad
    LD      R1, (R0)
    RCALL   print_hex16
    RCALL   print_space

    LOAD16  R0, var_bad
    LD      R1, (R0)
    LOAD16  R3, .twf_end
    JMP.Z   R3, R1
    RCALL   inc_err
.twf_end:
    RRET

; noc_send_mbox_wait: R2 = dst_core, R1 = payload
; Sends NOC_MBOX_SEND and immediately spins on var_mbox_flag with ZERO XCHG
; instructions between send and Trap 14 arrival (100% shadow-reg race-free!).
noc_send_mbox_wait:
    RPUSH   R0
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R2
.m_nsm_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LOAD16  R0, 4
    AND     R3, R0
    LOAD16  R0, .m_nsm_wait
    JMP.Z   R0, R3
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1
.wmt_spin:
    LOAD16  R2, var_mbox_flag
    LD      R1, (R2)
    LOAD16  R3, .wmt_spin
    JMP.Z   R3, R1
    LD0     R1
    LD      (R2), R1
    RRET

inc_err:
    RPUSH   R0
    LOAD16  R2, var_errs
    LD      R1, (R2)
    INC     R1
    LD      (R2), R1
    RRET

; ==============================================================================
; UART Formatting Helpers
; ==============================================================================
puts:
    RPUSH   R0
    LD      R2, R1
.puts_loop:
    LD      R3, (R2++)
    BYTE_GET_LO R1, R3
    LOAD16  R0, .puts_done
    JMP.Z   R0, R1
    PUTC    R1
    BYTE_GET_HI R1, R3
    LOAD16  R0, .puts_done
    JMP.Z   R0, R1
    PUTC    R1
    LOAD16  R0, .puts_loop
    JMP     R0
.puts_done:
    RRET

print_space:
    RPUSH   R0
    LOAD16  R1, 32
    PUTC    R1
    RRET

print_nl:
    RPUSH   R0
    LOAD16  R1, 13
    PUTC    R1
    LOAD16  R1, 10
    PUTC    R1
    RRET

print_hex16:
    RPUSH   R0
    APUSH   R2
    LD      R2, R1
    BYTE_GET_HI R1, R2
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    RCALL   print_nib
    BYTE_GET_HI R1, R2
    LOAD16  R0, 0x000F
    AND     R1, R0
    RCALL   print_nib
    BYTE_GET_LO R1, R2
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    RCALL   print_nib
    BYTE_GET_LO R1, R2
    LOAD16  R0, 0x000F
    AND     R1, R0
    RCALL   print_nib
    APOP    R2
    RRET

print_nib:
    RPUSH   R0
    LOAD16  R0, 9
    SUB     R0, R1
    LOAD16  R3, .nib_af
    JMP.M   R3, R0
    LOAD16  R0, 48
    ADD     R1, R0
    PUTC    R1
    RRET
.nib_af:
    LOAD16  R0, 55
    ADD     R1, R0
    PUTC    R1
    RRET

; ==============================================================================
; Strings
; ==============================================================================
msg_banner:
    .asciz "\r\n=== MR4 4-Core IPC & Trap 14 Hardware Test [Build #2] ===\r\n"
msg_t1:
    .asciz "T1 TOPO  (0000 1004):           "
msg_t2:
    .asciz "T2 MBOX  (1:1501 2:2502 3:3503): "
msg_t3:
    .asciz "T3 FIFO8 (CHK:0000 x3):         "
msg_t4:
    .asciz "T4 RING  (0003 C066):           "
msg_t5:
    .asciz "T5 ISOL  (C0@4000=CAFE):        "
msg_sum:
    .asciz "TRAPS14  (exp 0007):            "
msg_pass:
    .asciz "PASS!\r\n"
msg_fail:
    .asciz "FAIL errs="
msg_prompt:
    .asciz "Press any key to re-run...\r\n"

; Local BRAM Variables (0x0710..0x073F)
.org 0x0710
var_mbox_val:  .word 0
var_mbox_src:  .word 0
var_trap_cnt:  .word 0
var_mbox_flag: .word 0
var_errs:      .word 0
var_tmp:       .word 0
var_wid:       .word 0
var_exp:       .word 0
var_base:      .word 0
var_cur:       .word 0
var_cnt:       .word 0
var_chk:       .word 0
var_bad:       .word 0

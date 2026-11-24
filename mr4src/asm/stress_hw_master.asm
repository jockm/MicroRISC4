; ==============================================================================
; FILE: mr4src/asm/stress_hw_master.asm
; ULX3S-85F 4-Core Long-Duration Hardware Stress Master (Core 0)
;
; Paired with stress_hw_worker.asm on Workers 1..3 (ULX3S_NOC_CORES=4,
; ULX3S_SDRAM_CACHE=1). Runs continuously forever, hammering all 4 cores with:
;   - 16-bit Galois LFSR pseudo-random patterns every round
;   - Concurrent 4-core SDRAM 4-row cache eviction + refill sweeps (128 words/rnd)
;   - Concurrent 3-worker RX FIFO completion bursts into Core 0's 16-word FIFO
;   - Full 4-core hardware Trap 14 ring relays (Core 0 -> 1 -> 2 -> 3 -> 0)
; Prints a live heartbeat on Round 1 and every 64 rounds (0x0040) over 3 Mbaud UART.
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
    LOAD16  R1, 0x07FF
    LD      R0, 4
    LD      (R0), R1
    LOAD16  R1, 0x07BF
    LD      R0, 5
    LD      (R0), R1
    LOAD16  R0, _main
    JMP     R0

; --- Trap 14: Hardware NoC Doorbell/MBOX ISR (<= 16 words) ---
.org 0x01E0
_trap14_vector:
    XCHG    R0
    LOAD16  R0, _trap14_isr
    JMP     R0

.org 0x01F0
_trap15_vector:
    LOAD16  R1, 33
    PUTC    R1
    LOAD16  R1, 84
    PUTC    R1
    LOAD16  R1, 49
    PUTC    R1
    LOAD16  R1, 53
    PUTC    R1
    LOAD16  R0, _t15_halt
_t15_halt:
    JMP     R0

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
    ; Initialize counters & LFSR seed = 0xACE1
    LD0     R1
    LOAD16  R2, var_mbox_flag
    LD      (R2), R1
    LOAD16  R2, var_trap_cnt
    LD      (R2), R1
    LOAD16  R2, var_round
    LD      (R2), R1
    LOAD16  R2, var_errs
    LD      (R2), R1
    LOAD16  R2, var_kb
    LD      (R2), R1
    LOAD16  R1, 0xACE1
    LOAD16  R2, var_lfsr
    LD      (R2), R1

    ; Short startup delay so Workers 1..3 finish reset & enter _worker_idle
    LOAD16  R0, 2000
.boot_wait:
    DEC     R0
    LOAD16  R1, .boot_done
    JMP.Z   R1, R0
    LOAD16  R1, .boot_wait
    JMP     R1
.boot_done:

    LOAD16  R1, msg_banner
    RCALL   puts

    ; Print hardware topology (expect 0000 1004)
    LOAD16  R1, msg_topo
    RCALL   puts
    GET_CPUID R1
    RCALL   print_hex16
    RCALL   print_space
    LOAD16  R0, NOC_INFO
    LD      R1, (R0)
    RCALL   print_hex16
    RCALL   print_nl

; ==============================================================================
; Continuous Soak Loop (runs indefinitely!)
; ==============================================================================
_soak_loop:
    ; Increment round counter
    LOAD16  R2, var_round
    LD      R1, (R2)
    INC     R1
    LD      (R2), R1

    ; Step 16-bit Galois LFSR (poly 0xB400), mask bit 15 -> 15-bit Phase A seed
    RCALL   lfsr_next           ; updates var_lfsr, returns 15-bit seed in R1
    LOAD16  R2, var_seed
    LD      (R2), R1

    ; ------------------------------------------------------------------
    ; Phase A: Launch Workers 1, 2, 3 simultaneously via Trap 14 (bit 15 == 0)
    ; ------------------------------------------------------------------
    LOAD16  R2, 1
    RCALL   noc_send_mbox_nowait
    LOAD16  R2, var_seed
    LD      R1, (R2)
    LOAD16  R2, 2
    RCALL   noc_send_mbox_nowait
    LOAD16  R2, var_seed
    LD      R1, (R2)
    LOAD16  R2, 3
    RCALL   noc_send_mbox_nowait

    ; Core 0 concurrently thrashes its own 4 SDRAM rows (32 words)!
    LOAD16  R2, 0x2000
    LOAD16  R3, 0x1000
    RCALL   write_line8
    LOAD16  R2, 0x4000
    LOAD16  R3, 0x2000
    RCALL   write_line8
    LOAD16  R2, 0x8000
    LOAD16  R3, 0x4000
    RCALL   write_line8
    LOAD16  R2, 0xC000
    LOAD16  R3, 0x8000
    RCALL   write_line8

    LOAD16  R2, 0x2000
    LOAD16  R3, 0x1000
    RCALL   verify_line8
    LOAD16  R2, 0x4000
    LOAD16  R3, 0x2000
    RCALL   verify_line8
    LOAD16  R2, 0x8000
    LOAD16  R3, 0x4000
    RCALL   verify_line8
    LOAD16  R2, 0xC000
    LOAD16  R3, 0x8000
    RCALL   verify_line8

    ; Collect 3 workers' atomic 1-word completion flits from RX FIFO:
    ;   [15:12] = wid (1..3), [11:4] = ((seed ^ (wid*0x1111)) & 0xFF), [3:0] = err_flag
    LD0     R1
    LOAD16  R2, var_wmask
    LD      (R2), R1
    LOAD16  R1, 3
    LOAD16  R2, var_wrem
    LD      (R2), R1

.collect_workers:
    RCALL   fifo_pop_blocking   ; R1 = atomic completion word
    LOAD16  R2, var_w0
    LD      (R2), R1

    ; Check low nibble err_flag == 0
    LOAD16  R0, 0x000F
    AND     R1, R0
    LOAD16  R3, .cw_err_ok
    JMP.Z   R3, R1
    RCALL   inc_err
.cw_err_ok:
    ; Extract wid = w0 >> 12 (1, 2, or 3)
    LOAD16  R2, var_w0
    LD      R1, (R2)
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
    SHIFT.R R1                  ; R1 = wid (1, 2, or 3)
    LOAD16  R2, var_wid
    LD      (R2), R1

    ; Accumulate wid sum (1 + 2 + 3 == 6)
    LOAD16  R2, var_wmask
    LD      R0, (R2)
    ADD     R0, R1
    LD      (R2), R0

    ; Compute expected [11:4] = ((seed ^ (wid * 0x1111)) & 0xFF) << 4
    LD      R3, R1
    LD0     R1
    LOAD16  R0, 0x1111
.cw_mul:
    ADD     R1, R0
    DEC     R3
    LOAD16  R2, .cw_mul_done
    JMP.Z   R2, R3
    LOAD16  R2, .cw_mul
    JMP     R2
.cw_mul_done:
    LOAD16  R2, var_seed
    LD      R0, (R2)
    XOR     R1, R0
    LOAD16  R0, 0x00FF
    AND     R1, R0
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1                  ; expected [11:4]
    LOAD16  R2, var_w0
    LD      R0, (R2)
    LOAD16  R3, 0x0FF0
    AND     R0, R3
    SUB     R0, R1
    LOAD16  R3, .cw_w1_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.cw_w1_ok:
    LOAD16  R2, var_wrem
    LD      R1, (R2)
    DEC     R1
    LD      (R2), R1
    LOAD16  R3, .cw_all_done
    JMP.Z   R3, R1
    LOAD16  R3, .collect_workers
    JMP     R3
.cw_all_done:
    ; Verify wmask == 6 (Workers 1 + 2 + 3 all reported!)
    LOAD16  R2, var_wmask
    LD      R1, (R2)
    LOAD16  R0, 6
    SUB     R0, R1
    LOAD16  R3, .cw_mask_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.cw_mask_ok:

    ; ------------------------------------------------------------------
    ; Phase B: 4-Core Trap 14 Ring Relay (Core 0 -> 1 -> 2 -> 3 -> 0)
    ;   Send 0xC000 | (seed & 0x00FF) -> W1(+0x100)->W2(+0x200)->W3(+0x300)
    ;   Expect Core 3 reply == 0xC600 | (seed & 0x00FF) with src == 3!
    ; ------------------------------------------------------------------
    LOAD16  R2, var_seed
    LD      R1, (R2)
    LOAD16  R0, 0x00FF
    AND     R1, R0
    LOAD16  R0, 0xC000
    OR      R1, R0
    LOAD16  R2, 1
    RCALL   noc_send_mbox_wait

    ; Verify src == 3
    LOAD16  R2, var_mbox_src
    LD      R1, (R2)
    LOAD16  R0, 3
    SUB     R0, R1
    LOAD16  R3, .pb_src_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.pb_src_ok:
    ; Verify val == 0xC600 | (seed & 0x00FF)
    LOAD16  R2, var_seed
    LD      R1, (R2)
    LOAD16  R0, 0x00FF
    AND     R1, R0
    LOAD16  R0, 0xC600
    OR      R1, R0
    LOAD16  R2, var_mbox_val
    LD      R0, (R2)
    SUB     R0, R1
    LOAD16  R3, .pb_val_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.pb_val_ok:

    ; Print live heartbeat on Round 1 and every 64 rounds ((round & 0x3F) == 0)
    LOAD16  R2, var_round
    LD      R1, (R2)
    LOAD16  R0, 1
    SUB     R0, R1
    LOAD16  R3, .do_print
    JMP.Z   R3, R0

    LOAD16  R0, 0x003F
    AND     R1, R0
    LOAD16  R3, .no_print
    LOAD16  R2, .do_print_64
    JMP.Z   R2, R1
    JMP     R3

.do_print_64:
    ; Add 32 KB (64 rounds * 512 bytes/round) to var_kb
    LOAD16  R2, var_kb
    LD      R1, (R2)
    LOAD16  R0, 32
    ADD     R1, R0
    LD      (R2), R1

.do_print:
    LOAD16  R1, msg_rnd
    RCALL   puts
    LOAD16  R2, var_round
    LD      R1, (R2)
    RCALL   print_hex16

    LOAD16  R1, msg_seed
    RCALL   puts
    LOAD16  R2, var_seed
    LD      R1, (R2)
    RCALL   print_hex16

    LOAD16  R1, msg_traps
    RCALL   puts
    LOAD16  R2, var_trap_cnt
    LD      R1, (R2)
    RCALL   print_hex16

    LOAD16  R1, msg_kb
    RCALL   puts
    LOAD16  R2, var_kb
    LD      R1, (R2)
    RCALL   print_hex16

    LOAD16  R1, msg_errs
    RCALL   puts
    LOAD16  R2, var_errs
    LD      R1, (R2)
    RCALL   print_hex16

    LOAD16  R2, var_errs
    LD      R1, (R2)
    LOAD16  R3, .hb_ok
    JMP.Z   R3, R1
    LOAD16  R1, msg_bad
    RCALL   puts
    LOAD16  R3, .no_print
    JMP     R3
.hb_ok:
    LOAD16  R1, msg_ok
    RCALL   puts

.no_print:
    LOAD16  R3, _soak_loop
    JMP     R3

; ==============================================================================
; Helpers
; ==============================================================================
; lfsr_next: Galois 16-bit LFSR (poly 0xB400), returns 15-bit seed in R1
lfsr_next:
    RPUSH   R0
    LOAD16  R2, var_lfsr
    LD      R1, (R2)
    LOAD16  R0, 1
    AND     R0, R1              ; lsb = lfsr & 1
    SHIFT.R R1                  ; lfsr >>= 1
    LOAD16  R3, .lfsr_noxor
    JMP.Z   R3, R0
    LOAD16  R0, 0xB400
    XOR     R1, R0
.lfsr_noxor:
    LD      (R2), R1
    LOAD16  R0, 0x7FFF
    AND     R1, R0              ; bit 15 = 0 for Phase A command
    RRET

write_line8:
    RPUSH   R0
    LOAD16  R0, var_seed
    LD      R1, (R0)
    XOR     R1, R3              ; Core 0 has id_sh12 == 0
    LOAD16  R0, 8
.c0_wl8:
    LD      (R2), R1
    INC     R2
    INC     R1
    DEC     R0
    LOAD16  R3, .c0_wl8_done
    JMP.Z   R3, R0
    LOAD16  R3, .c0_wl8
    JMP     R3
.c0_wl8_done:
    RRET

verify_line8:
    RPUSH   R0
    LOAD16  R0, var_seed
    LD      R1, (R0)
    XOR     R1, R3
    LOAD16  R0, var_exp
    LD      (R0), R1
    LOAD16  R0, var_addr
    LD      (R0), R2
    LOAD16  R1, 8
    LOAD16  R0, var_cnt
    LD      (R0), R1
.c0_vl8:
    LOAD16  R0, var_addr
    LD      R2, (R0)
    LD      R1, (R2++)
    LD      (R0), R2
    LOAD16  R0, var_exp
    LD      R3, (R0)
    SUB     R1, R3
    LOAD16  R2, .c0_vl8_ok
    JMP.Z   R2, R1
    RCALL   inc_err
.c0_vl8_ok:
    LOAD16  R0, var_exp
    LD      R3, (R0)
    INC     R3
    LD      (R0), R3
    LOAD16  R0, var_cnt
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R2, .c0_vl8_done
    JMP.Z   R2, R1
    LOAD16  R2, .c0_vl8
    JMP     R2
.c0_vl8_done:
    RRET

fifo_pop_blocking:
    RPUSH   R0
.fpb_wait:
    LOAD16  R0, NOC_STAT
    LD      R1, (R0)
    LOAD16  R2, 1
    AND     R1, R2
    LOAD16  R3, .fpb_wait
    JMP.Z   R3, R1
    LOAD16  R0, NOC_RX_DATA
    LD      R1, (R0)
    RRET

noc_send_mbox_nowait:
    RPUSH   R0
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R2
.nsmn_w:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LOAD16  R0, 4
    AND     R3, R0
    LOAD16  R0, .nsmn_w
    JMP.Z   R0, R3
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1
    RRET

; Trap-safe send + spin: ZERO XCHG and ZERO live R0 while waiting for Trap 14!
noc_send_mbox_wait:
    RPUSH   R0
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R2
.nsmw_w:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LOAD16  R0, 4
    AND     R3, R0
    LOAD16  R0, .nsmw_w
    JMP.Z   R0, R3
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1
.nsmw_spin:
    LOAD16  R2, var_mbox_flag
    LD      R1, (R2)
    LOAD16  R3, .nsmw_spin
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

; UART Formatting Helpers
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

; Strings
msg_banner:
    .asciz "\r\n=== MR4 4-Core Continuous Hardware Stress [Build #1] ===\r\n"
msg_topo:
    .asciz "TOPO (0000 1004): "
msg_rnd:
    .asciz "RND "
msg_seed:
    .asciz " | SEED "
msg_traps:
    .asciz " | TRAPS "
msg_kb:
    .asciz " | SDR_KB "
msg_errs:
    .asciz " | ERRS "
msg_ok:
    .asciz " OK\r\n"
msg_bad:
    .asciz " !FAIL!\r\n"

; Local BRAM Variables (0x0710..0x074F)
.org 0x0710
var_mbox_val:  .word 0
var_mbox_src:  .word 0
var_mbox_flag: .word 0
var_trap_cnt:  .word 0
var_round:     .word 0
var_errs:      .word 0
var_kb:        .word 0
var_lfsr:      .word 0
var_seed:      .word 0
var_wmask:     .word 0
var_wrem:      .word 0
var_w0:        .word 0
var_w1:        .word 0
var_wid:       .word 0
var_exp:       .word 0
var_addr:      .word 0
var_cnt:       .word 0

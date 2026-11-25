; ==============================================================================
; FILE: mr4src/asm/stress_manycore_master.asm
; Dynamic N-Core ULX3S-85F Hardware Stress Master (Core 0, supports 2..64 cores)
;
; Paired with stress_manycore_worker.asm on Workers 1..N-1.
; Discovers N = (NOC_INFO & 0xFF) dynamically at boot and runs indefinitely:
;   - Phase A: Broadcasts 15-bit LFSR seed via Trap 14 MBOX to all N-1 workers
;              simultaneously; every worker verifies a 32-word BRAM pattern and
;              fires an atomic completion flit back into Core 0's 16-word RX
;              FIFO (stressing real Lean Ring backpressure when N > 16!).
;              Core 0 checks err_flag==0, exact signature, and ID sum N*(N-1)/2.
;   - Phase B: Full N-core Hardware Trap 14 ring relay:
;              Core 0 -> 1 -> 2 -> ... -> N-1 -> 0, verifying src == N-1 and
;              accumulated sum == (seed & 0xFF) + N*(N-1)/2.
; Prints live heartbeat on Round 1 and every 64 rounds (0x0040) over 3 Mbaud UART.
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
    ERET

_main:
    LD0     R1
    LOAD16  R2, var_mbox_flag
    LD      (R2), R1
    LOAD16  R2, var_trap_cnt
    LD      (R2), R1
    LOAD16  R2, var_round
    LD      (R2), R1
    LOAD16  R2, var_errs
    LD      (R2), R1
    LOAD16  R1, 0xACE1
    LOAD16  R2, var_lfsr
    LD      (R2), R1

    ; Discover N = NOC_INFO & 0xFF and precompute expected ID sum = 1+2+..+(N-1)
    LOAD16  R0, NOC_INFO
    LD      R1, (R0)
    LOAD16  R2, var_noc_info
    LD      (R2), R1
    LOAD16  R0, 0x00FF
    AND     R1, R0
    LOAD16  R2, var_n
    LD      (R2), R1

    DEC     R1                      ; R1 = N - 1
    LOAD16  R2, var_n_minus1
    LD      (R2), R1

    LD0     R2                      ; sum = 0
.sum_loop:
    ADD     R2, R1
    DEC     R1
    LOAD16  R0, .sum_done
    JMP.Z   R0, R1
    LOAD16  R0, .sum_loop
    JMP     R0
.sum_done:
    LOAD16  R0, var_exp_sum
    LD      (R0), R2

    ; Brief startup settle so all N-1 workers enter _worker_idle
    LOAD16  R0, 500
.boot_wait:
    DEC     R0
    LOAD16  R1, .boot_done
    JMP.Z   R1, R0
    LOAD16  R1, .boot_wait
    JMP     R1
.boot_done:

    LOAD16  R2, msg_banner
    RCALL   rom_puts
    LOAD16  R1, var_n
    LD      R1, (R1)
    RCALL   print_hex16
    LOAD16  R2, msg_info
    RCALL   rom_puts
    LOAD16  R1, var_noc_info
    LD      R1, (R1)
    RCALL   print_hex16
    RCALL   print_nl

; ==============================================================================
; Continuous Many-Core Soak Loop
; ==============================================================================
_soak_loop:
    LOAD16  R2, var_round
    LD      R1, (R2)
    INC     R1
    LD      (R2), R1

    RCALL   lfsr_next               ; R1 = 15-bit seed (0x0000..0x7FFF)
    LOAD16  R2, var_seed
    LD      (R2), R1

    ; ------------------------------------------------------------------
    ; Phase A: Broadcast seed via Trap 14 MBOX to Workers k = 1 .. N-1
    ; ------------------------------------------------------------------
    LOAD16  R1, 1
    LOAD16  R2, var_k
    LD      (R2), R1
.launch_loop:
    LOAD16  R2, var_k
    LD      R2, (R2)
    LOAD16  R0, var_seed
    LD      R1, (R0)
    RCALL   noc_send_mbox           ; send R1 to core R2

    LOAD16  R2, var_k
    LD      R1, (R2)
    INC     R1
    LD      (R2), R1
    LOAD16  R0, var_n
    LD      R0, (R0)
    SUB     R0, R1
    LOAD16  R3, .launch_done
    JMP.Z   R3, R0
    LOAD16  R3, .launch_loop
    JMP     R3
.launch_done:

    ; Core 0 concurrently runs its own 32-word local BRAM write/verify sweep
    RCALL   core0_bram_sweep

    ; Collect N-1 completion flits from Core 0's RX FIFO (backpressured ring!)
    ; Format: [15]=err_flag, [14:8]=wid (1..N-1), [7:0]=(seed ^ (wid*0x13)) & 0xFF
    LD0     R1
    LOAD16  R2, var_id_sum
    LD      (R2), R1
    LOAD16  R0, var_n_minus1
    LD      R1, (R0)
    LOAD16  R2, var_rem
    LD      (R2), R1

.collect_loop:
    RCALL   fifo_pop_blocking       ; R1 = completion word
    LOAD16  R2, var_word
    LD      (R2), R1

    ; Check bit 15 == 0 (no worker error)
    LOAD16  R3, .cw_err
    JMP.M   R3, R1
    LOAD16  R3, .cw_no_err
    JMP     R3
.cw_err:
    RCALL   inc_err
.cw_no_err:

    ; wid = (word >> 8) & 0x7F
    LOAD16  R2, var_word
    LD      R1, (R2)
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    SHIFT.R R1
    LOAD16  R0, 0x007F
    AND     R1, R0
    LOAD16  R2, var_wid
    LD      (R2), R1

    ; Accumulate wid into var_id_sum
    LOAD16  R2, var_id_sum
    LD      R0, (R2)
    ADD     R0, R1
    LD      (R2), R0

    ; Expected sig = (seed ^ (wid * 0x13)) & 0xFF
    ; wid * 0x13 = (wid << 4) + (wid << 1) + wid
    LD      R2, R1                  ; R2 = wid
    LD      R3, R1
    SHIFT.L R3                      ; R3 = wid << 1
    ADD     R2, R3                  ; R2 = wid * 3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3                      ; R3 = wid << 4
    ADD     R2, R3                  ; R2 = wid * 19 (0x13)

    LOAD16  R0, var_seed
    LD      R0, (R0)
    XOR     R2, R0
    LOAD16  R0, 0x00FF
    AND     R2, R0                  ; R2 = expected sig

    LOAD16  R1, var_word
    LD      R1, (R1)
    AND     R1, R0                  ; R1 = actual sig
    SUB     R1, R2
    LOAD16  R3, .cw_sig_ok
    JMP.Z   R3, R1
    RCALL   inc_err
.cw_sig_ok:

    LOAD16  R2, var_rem
    LD      R1, (R2)
    DEC     R1
    LD      (R2), R1
    LOAD16  R3, .collect_done
    JMP.Z   R3, R1
    LOAD16  R3, .collect_loop
    JMP     R3
.collect_done:

    ; Verify sum of all worker IDs == N*(N-1)/2
    LOAD16  R0, var_id_sum
    LD      R1, (R0)
    LOAD16  R0, var_exp_sum
    LD      R2, (R0)
    SUB     R1, R2
    LOAD16  R3, .sum_ok
    JMP.Z   R3, R1
    RCALL   inc_err
.sum_ok:

    ; ------------------------------------------------------------------
    ; Phase B: Full N-Core Trap 14 Ring Relay (0 -> 1 -> 2 -> ... -> N-1 -> 0)
    ; ------------------------------------------------------------------
    LD0     R1
    LOAD16  R2, var_mbox_flag
    LD      (R2), R1

    LOAD16  R0, var_seed
    LD      R1, (R0)
    LOAD16  R0, 0x00FF
    AND     R1, R0
    LOAD16  R0, 0x8000
    OR      R1, R0                  ; payload = 0x8000 | (seed & 0xFF)
    LOAD16  R2, 1
    RCALL   noc_send_mbox

.wait_relay:
    LOAD16  R2, var_mbox_flag
    LD      R1, (R2)
    LOAD16  R3, .wait_relay
    JMP.Z   R3, R1
    LD0     R1
    LD      (R2), R1

    ; Expect src == N - 1
    LOAD16  R0, var_mbox_src
    LD      R1, (R0)
    LOAD16  R0, var_n_minus1
    LD      R2, (R0)
    SUB     R1, R2
    LOAD16  R3, .relay_src_ok
    JMP.Z   R3, R1
    RCALL   inc_err
.relay_src_ok:

    ; Expect val == 0x8000 | (((seed & 0xFF) + exp_sum) & 0x7FFF)
    LOAD16  R0, var_seed
    LD      R1, (R0)
    LOAD16  R0, 0x00FF
    AND     R1, R0
    LOAD16  R0, var_exp_sum
    LD      R2, (R0)
    ADD     R1, R2
    LOAD16  R0, 0x7FFF
    AND     R1, R0
    LOAD16  R0, 0x8000
    OR      R1, R0                  ; R1 = expected relay val
    LOAD16  R0, var_mbox_val
    LD      R2, (R0)
    SUB     R2, R1
    LOAD16  R3, .relay_val_ok
    JMP.Z   R3, R2
    RCALL   inc_err
.relay_val_ok:

    ; Print heartbeat on Round 1 or every 64 rounds (round & 0x3F == 0)
    LOAD16  R0, var_round
    LD      R1, (R0)
    DEC     R1
    LOAD16  R3, .do_print
    JMP.Z   R3, R1
    INC     R1
    LOAD16  R0, 0x003F
    AND     R1, R0
    LOAD16  R3, .do_print
    JMP.Z   R3, R1
    LOAD16  R3, _soak_loop
    JMP     R3

.do_print:
    LOAD16  R2, msg_rnd
    RCALL   rom_puts
    LOAD16  R0, var_round
    LD      R1, (R0)
    RCALL   print_hex16
    LOAD16  R2, msg_traps
    RCALL   rom_puts
    LOAD16  R0, var_trap_cnt
    LD      R1, (R0)
    RCALL   print_hex16
    LOAD16  R2, msg_err
    RCALL   rom_puts
    LOAD16  R0, var_errs
    LD      R1, (R0)
    RCALL   print_hex16
    RCALL   print_nl

    LOAD16  R3, _soak_loop
    JMP     R3

; ==============================================================================
; Helpers
; ==============================================================================

; Local 32-word BRAM write + verify sweep on Core 0 (0x0680..0x069F)
core0_bram_sweep:
    RPUSH   R0
    LOAD16  R0, var_seed
    LD      R1, (R0)
    LOAD16  R2, 0x0680
    LOAD16  R3, 32
.c0_wr:
    LD      (R2), R1
    INC     R2
    LOAD16  R0, 0x0101
    ADD     R1, R0
    DEC     R3
    LOAD16  R0, .c0_rd_init
    JMP.Z   R0, R3
    LOAD16  R0, .c0_wr
    JMP     R0
.c0_rd_init:
    LOAD16  R0, var_seed
    LD      R1, (R0)
    LOAD16  R2, 0x0680
    LOAD16  R3, 32
.c0_rd:
    LD      R0, (R2++)
    SUB     R0, R1
    APUSH   R3
    LOAD16  R3, .c0_ok
    JMP.Z   R3, R0
    RCALL   inc_err
.c0_ok:
    APOP    R3
    LOAD16  R0, 0x0101
    ADD     R1, R0
    DEC     R3
    LOAD16  R0, .c0_done
    JMP.Z   R0, R3
    LOAD16  R0, .c0_rd
    JMP     R0
.c0_done:
    RRET

; Galois LFSR (poly 0xB400), returns 15-bit seed in R1
lfsr_next:
    RPUSH   R0
    LOAD16  R2, var_lfsr
    LD      R1, (R2)
    LD      R3, R1
    LOAD16  R0, 1
    AND     R3, R0
    SHIFT.R R1
    LOAD16  R0, .lfsr_noxor
    JMP.Z   R0, R3
    LOAD16  R0, 0xB400
    XOR     R1, R0
.lfsr_noxor:
    LD      (R2), R1
    LOAD16  R0, 0x7FFF
    AND     R1, R0
    RRET

; Send MBOX payload R1 to destination core R2
noc_send_mbox:
    RPUSH   R0
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R2
.nsm_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LD      R0, 4
    AND     R3, R0
    LOAD16  R0, .nsm_wait
    JMP.Z   R0, R3
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1
    RRET

; Blocking RX FIFO pop -> R1
fifo_pop_blocking:
    RPUSH   R0
.fp_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LD      R0, 1
    AND     R3, R0
    LOAD16  R0, .fp_wait
    JMP.Z   R0, R3
    LOAD16  R0, NOC_RX_DATA
    LD      R1, (R0)
    RRET

inc_err:
    RPUSH   R0
    LOAD16  R0, var_errs
    LD      R3, (R0)
    INC     R3
    LD      (R0), R3
    RRET

rom_puts:
    RPUSH   R0
.rp_loop:
    LD      R3, (R2++)
    BYTE_GET_LO R1, R3
    LOAD16  R0, .rp_done
    JMP.Z   R0, R1
    RCALL   putc_r1
    BYTE_GET_HI R1, R3
    LOAD16  R0, .rp_done
    JMP.Z   R0, R1
    RCALL   putc_r1
    LOAD16  R0, .rp_loop
    JMP     R0
.rp_done:
    RRET

putc_r1:
    RPUSH   R0
    PUTC    R1
    RRET

print_nl:
    RPUSH   R0
    LOAD16  R1, 13
    RCALL   putc_r1
    LOAD16  R1, 10
    RCALL   putc_r1
    RRET

; Print 16-bit value in R1 as 4 uppercase hex chars
print_hex16:
    RPUSH   R0
    APUSH   R1
    LOAD16  R3, 4
    APUSH   R3
.ph_loop:
    APOP    R3
    APOP    R1
    ; Extract top nibble (bits 15:12)
    LD      R2, R1
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    SHIFT.R R2
    ; Shift R1 left by 4 for next nibble
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    APUSH   R1
    DEC     R3
    APUSH   R3
    ; Convert nibble R2 (0..15) -> ASCII
    LOAD16  R0, 10
    LD      R1, R2
    SUB     R1, R0
    LOAD16  R0, .ph_digit
    JMP.M   R0, R1
    LOAD16  R0, 55                  ; 'A' - 10
    ADD     R2, R0
    LOAD16  R0, .ph_emit
    JMP     R0
.ph_digit:
    LOAD16  R0, 48                  ; '0'
    ADD     R2, R0
.ph_emit:
    LD      R1, R2
    RCALL   putc_r1
    APOP    R3
    APUSH   R3
    LOAD16  R0, .ph_done
    JMP.Z   R0, R3
    LOAD16  R0, .ph_loop
    JMP     R0
.ph_done:
    APOP    R3
    APOP    R1
    RRET

msg_banner: .asciz "MR4 MANYCORE STRESS N="
msg_info:   .asciz " INFO="
msg_rnd:    .asciz "R="
msg_traps:  .asciz " T="
msg_err:    .asciz " E="

.org 0x0600
var_n:         .word 0
var_n_minus1:  .word 0
var_noc_info:  .word 0
var_exp_sum:   .word 0
var_lfsr:      .word 0
var_seed:      .word 0
var_round:     .word 0
var_errs:      .word 0
var_trap_cnt:  .word 0
var_mbox_flag: .word 0
var_mbox_src:  .word 0
var_mbox_val:  .word 0
var_k:         .word 0
var_rem:       .word 0
var_word:      .word 0
var_wid:       .word 0
var_id_sum:    .word 0

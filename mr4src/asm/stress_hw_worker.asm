; ==============================================================================
; FILE: mr4src/asm/stress_hw_worker.asm
; ULX3S-85F 4-Core Long-Duration Hardware Stress Worker (Cores 1..3)
;
; Runs 100% out of 2K local BRAM (stacks 0x07FF / 0x07BF) while continuously
; thrashing its private 64K-word SDRAM partition ({coreId[7:0], addr[15:0]})
; concurrently with Core 0 and the other 2 workers.
;
; Trap 14 Doorbell Protocol:
;   Bit 15 == 0 (0x0000..0x7FFF): Phase A — Concurrent SDRAM 4-Row Cache Thrash!
;     seed = payload (15-bit LFSR seed). Writes & evicts 4 conflicting cache
;     lines (0x2000, 0x4000, 0x8000, 0xC000 = 32 words) in private SDRAM, reads
;     all 32 words back from SDRAM, verifies every bit, and pushes a 2-word
;     completion record [ (my_id << 12) | errs, seed ^ (my_id * 0x1111) ] into
;     Core 0's 16-word RX FIFO.
;   Bit 15 == 1 (0x8000..0xFFFF): Phase B — 4-Core Trap 14 Ring Relay!
;     Adds (my_id << 8) to payload and forwards Trap 14 MBOX to (my_id + 1) & 3
;     (1 -> 2 -> 3 -> 0).
; ==============================================================================

.include "common.inc"

.define NOC_TX_DATA     0x0020
.define NOC_DST_CORE    0x0021
.define NOC_STAT        0x0023
.define NOC_MBOX_SEND   0x0025
.define NOC_MBOX_DATA   0x0026
.define NOC_MBOX_SRC    0x0027

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

    ; Precompute my_id, my_id_sh12 (W<<12), my_id_sh8 (W<<8), my_id_1111 (W*0x1111)
    GET_CPUID R1
    LOAD16  R2, var_my_id
    LD      (R2), R1

    ; my_id_sh8 = my_id << 8
    LD      R3, R1
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    LOAD16  R2, var_id_sh8
    LD      (R2), R3

    ; my_id_sh12 = my_id_sh8 << 4
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    LOAD16  R2, var_id_sh12
    LD      (R2), R3

    ; my_id_1111 = my_id * 0x1111
    LOAD16  R2, var_my_id
    LD      R3, (R2)
    LD0     R1
    LOAD16  R0, 0x1111
.init_mul:
    ADD     R1, R0
    DEC     R3
    LOAD16  R2, .init_mul_done
    JMP.Z   R2, R3
    LOAD16  R2, .init_mul
    JMP     R2
.init_mul_done:
    LOAD16  R2, var_id_1111
    LD      (R2), R1

; Trap-safe idle loop: ZERO XCHG and NEVER hold live value in R0!
_worker_idle:
    LOAD16  R2, var_mbox_flag
    LD      R1, (R2)
    LOAD16  R3, _worker_idle
    JMP.Z   R3, R1

    LD0     R1
    LD      (R2), R1

    ; Branch on bit 15 of var_mbox_val: negative (bit 15 == 1) -> Phase B relay
    LOAD16  R2, var_mbox_val
    LD      R1, (R2)
    LOAD16  R3, _phase_b_relay
    JMP.M   R3, R1

; ------------------------------------------------------------------------------
; Phase A (bit 15 == 0): Concurrent 4-Row SDRAM Cache-Eviction Thrash (32 words)
; ------------------------------------------------------------------------------
_phase_a_sdram:
    LOAD16  R2, var_seed
    LD      (R2), R1
    LD0     R0
    LOAD16  R2, var_errs
    LD      (R2), R0

    ; Write 4 conflicting cache lines (all D-cache index 0 -> forced writebacks!)
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

    ; Read & verify all 4 lines back from SDRAM (forces 4 refills + 4 evictions!)
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

    ; Push atomic 1-word completion flit to Core 0's RX FIFO (order-independent!):
    ;   [15:12] = my_id (1..3)
    ;   [11:4]  = ((var_seed ^ var_id_1111) & 0x00FF) << 4
    ;   [3:0]   = (var_errs == 0) ? 0 : 0xF
    LOAD16  R2, var_seed
    LD      R1, (R2)
    LOAD16  R2, var_id_1111
    LD      R0, (R2)
    XOR     R1, R0
    LOAD16  R0, 0x00FF
    AND     R1, R0
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1
    SHIFT.L R1                  ; R1 = ((seed ^ id_1111) & 0xFF) << 4
    LOAD16  R2, var_id_sh12
    LD      R0, (R2)
    OR      R1, R0              ; [15:12] = my_id

    LOAD16  R2, var_errs
    LD      R0, (R2)
    LOAD16  R3, .pa_no_err
    JMP.Z   R3, R0
    LOAD16  R0, 0x000F
    OR      R1, R0
.pa_no_err:
    ; Send atomic completion flit and jump straight to _worker_idle (ZERO XCHG after send!)
    LOAD16  R0, NOC_DST_CORE
    LD0     R2
    LD      (R0), R2
.pa_txw:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LOAD16  R0, 4
    AND     R3, R0
    LOAD16  R0, .pa_txw
    JMP.Z   R0, R3
    LOAD16  R0, NOC_TX_DATA
    LD      (R0), R1
    LOAD16  R3, _worker_idle
    JMP     R3

; ------------------------------------------------------------------------------
; Phase B (bit 15 == 1): 4-Core Trap 14 Ring Relay (1 -> 2 -> 3 -> 0)
; ------------------------------------------------------------------------------
_phase_b_relay:
    ; payload += (my_id << 8)
    LOAD16  R2, var_id_sh8
    LD      R0, (R2)
    ADD     R1, R0

    ; dst_core = (my_id + 1) & 3
    LOAD16  R2, var_my_id
    LD      R2, (R2)
    INC     R2
    LOAD16  R0, 3
    AND     R2, R0

    ; Send MBOX and jump straight to _worker_idle (ZERO XCHG after send!)
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R2
.pb_txw:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LOAD16  R0, 4
    AND     R3, R0
    LOAD16  R0, .pb_txw
    JMP.Z   R0, R3
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1
    LOAD16  R3, _worker_idle
    JMP     R3

; ------------------------------------------------------------------------------
; SDRAM 8-Word Line Write & Verify Helpers
;   R2 = base SDRAM addr (8-word aligned), R3 = row salt
;   Pattern for word i (0..7) = (var_seed ^ var_id_sh12 ^ salt) + i
; ------------------------------------------------------------------------------
write_line8:
    RPUSH   R0
    LOAD16  R0, var_seed
    LD      R1, (R0)
    LOAD16  R0, var_id_sh12
    LD      R0, (R0)
    XOR     R1, R0
    XOR     R1, R3              ; R1 = base pattern
    LOAD16  R0, 8
.wl8_loop:
    LD      (R2), R1
    INC     R2
    INC     R1
    DEC     R0
    LOAD16  R3, .wl8_done
    JMP.Z   R3, R0
    LOAD16  R3, .wl8_loop
    JMP     R3
.wl8_done:
    RRET

verify_line8:
    RPUSH   R0
    LOAD16  R0, var_seed
    LD      R1, (R0)
    LOAD16  R0, var_id_sh12
    LD      R0, (R0)
    XOR     R1, R0
    XOR     R1, R3              ; R1 = expected base pattern
    LOAD16  R0, var_exp
    LD      (R0), R1
    LOAD16  R0, var_addr
    LD      (R0), R2
    LOAD16  R1, 8
    LOAD16  R0, var_cnt
    LD      (R0), R1
.vl8_loop:
    LOAD16  R0, var_addr
    LD      R2, (R0)
    LD      R1, (R2++)
    LD      (R0), R2
    LOAD16  R0, var_exp
    LD      R3, (R0)
    SUB     R1, R3
    LOAD16  R2, .vl8_ok
    JMP.Z   R2, R1
    LOAD16  R2, var_errs
    LD      R1, (R2)
    INC     R1
    LD      (R2), R1
.vl8_ok:
    INC     R3
    LD      (R0), R3
    LOAD16  R0, var_cnt
    LD      R1, (R0)
    DEC     R1
    LD      (R0), R1
    LOAD16  R2, .vl8_done
    JMP.Z   R2, R1
    LOAD16  R2, .vl8_loop
    JMP     R2
.vl8_done:
    RRET

fifo_send_c0:
    RPUSH   R0
    LOAD16  R0, NOC_DST_CORE
    LD0     R2
    LD      (R0), R2
.fsc_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LOAD16  R0, 4
    AND     R3, R0
    LOAD16  R0, .fsc_wait
    JMP.Z   R0, R3
    LOAD16  R0, NOC_TX_DATA
    LD      (R0), R1
    RRET

; Local BRAM Variables (0x0710..0x073F)
.org 0x0710
var_mbox_val:  .word 0
var_mbox_src:  .word 0
var_mbox_flag: .word 0
var_my_id:     .word 0
var_id_sh8:    .word 0
var_id_sh12:   .word 0
var_id_1111:   .word 0
var_seed:      .word 0
var_errs:      .word 0
var_exp:       .word 0
var_addr:      .word 0
var_cnt:       .word 0

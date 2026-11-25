; ==============================================================================
; FILE: mr4src/asm/stress_manycore_worker.asm
; Dynamic N-Core ULX3S-85F Hardware Stress Worker (Cores 1..N-1, 2K local BRAM)
;
; Discovers its own ID (`CPUID @ 0x000D`) and cluster size (`N = NOC_INFO & 0xFF`)
; dynamically at boot. Services two Trap 14 MBOX phases forever:
;   - Phase A (bit 15 == 0): 32-word local BRAM write/verify sweep at 0x0680..0x069F
;     using (seed + i*0x0101) ^ (my_id * 0x0111), then pushes atomic completion
;     word `(err << 15) | (my_id << 8) | ((seed ^ (my_id * 0x13)) & 0xFF)` to
;     Core 0's RX FIFO.
;   - Phase B (bit 15 == 1): Adds `my_id` to lower 15 bits and forwards Trap 14
;     MBOX to `(my_id + 1) % N` (rippling 1 -> 2 -> ... -> N-1 -> 0).
; ==============================================================================

.include "common.inc"

.define NOC_TX_DATA     0x0020
.define NOC_DST_CORE    0x0021
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

    ; Discover my_id and N
    GET_CPUID R1
    LOAD16  R2, var_my_id
    LD      (R2), R1

    LOAD16  R0, NOC_INFO
    LD      R2, (R0)
    LOAD16  R0, 0x00FF
    AND     R2, R0                  ; R2 = N

    ; next_core = (my_id + 1 == N) ? 0 : (my_id + 1)
    LD      R3, R1
    INC     R3
    SUB     R2, R3
    LOAD16  R0, .wrap_zero
    JMP.Z   R0, R2
    LOAD16  R0, .store_next
    JMP     R0
.wrap_zero:
    LD0     R3
.store_next:
    LOAD16  R2, var_next_core
    LD      (R2), R3

    ; Precompute my_id_sh8 = my_id << 8
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

    ; Precompute id_mul13 = my_id * 0x13 = (my_id << 4) + (my_id << 1) + my_id
    LD      R2, R1
    LD      R3, R1
    SHIFT.L R3
    ADD     R2, R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    ADD     R2, R3
    LOAD16  R0, var_id_mul13
    LD      (R0), R2

    ; Precompute id_mask = my_id * 0x0111 = (my_id << 8) + (my_id << 4) + my_id
    LD      R2, R1
    LD      R3, R1
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    SHIFT.L R3
    ADD     R2, R3
    LOAD16  R0, var_id_sh8
    LD      R0, (R0)
    ADD     R2, R0
    LOAD16  R0, var_id_mask
    LD      (R0), R2

_worker_idle:
    LOAD16  R2, var_mbox_flag
    LD      R1, (R2)
    LOAD16  R3, _worker_idle
    JMP.Z   R3, R1

    LD0     R1
    LD      (R2), R1

    LOAD16  R2, var_mbox_val
    LD      R1, (R2)
    LOAD16  R3, _phase_b_relay
    JMP.M   R3, R1

; ------------------------------------------------------------------------------
; Phase A: 32-word local BRAM write + verify sweep, reply atomic completion word
; ------------------------------------------------------------------------------
_phase_a_compute:
    LOAD16  R2, var_seed
    LD      (R2), R1
    LD0     R0
    LOAD16  R2, var_err
    LD      (R2), R0

    ; Write 32 words to 0x0680..0x069F: val = (seed + i*0x0101) ^ id_mask
    LOAD16  R2, 0x0680
    LOAD16  R3, 32
.pa_wr:
    LOAD16  R0, var_id_mask
    LD      R0, (R0)
    XOR     R0, R1
    LD      (R2), R0
    INC     R2
    LOAD16  R0, 0x0101
    ADD     R1, R0
    DEC     R3
    LOAD16  R0, .pa_rd_init
    JMP.Z   R0, R3
    LOAD16  R0, .pa_wr
    JMP     R0

.pa_rd_init:
    LOAD16  R0, var_seed
    LD      R1, (R0)
    LOAD16  R2, 0x0680
    LOAD16  R3, 32
.pa_rd:
    LOAD16  R0, var_id_mask
    LD      R0, (R0)
    XOR     R0, R1                  ; R0 = expected
    APUSH   R3
    LD      R3, (R2++)              ; R3 = actual
    SUB     R3, R0
    LOAD16  R0, .pa_ok
    JMP.Z   R0, R3
    LOAD16  R0, var_err
    LOAD16  R3, 0x8000
    LD      (R0), R3
.pa_ok:
    APOP    R3
    LOAD16  R0, 0x0101
    ADD     R1, R0
    DEC     R3
    LOAD16  R0, .pa_reply
    JMP.Z   R0, R3
    LOAD16  R0, .pa_rd
    JMP     R0

.pa_reply:
    ; word = err_bit15 | id_sh8 | ((seed ^ id_mul13) & 0xFF)
    LOAD16  R0, var_seed
    LD      R1, (R0)
    LOAD16  R0, var_id_mul13
    LD      R2, (R0)
    XOR     R1, R2
    LOAD16  R0, 0x00FF
    AND     R1, R0
    LOAD16  R0, var_id_sh8
    LD      R2, (R0)
    OR      R1, R2
    LOAD16  R0, var_err
    LD      R2, (R0)
    OR      R1, R2

    ; Send to Core 0 RX FIFO
    LOAD16  R0, NOC_DST_CORE
    LD0     R2
    LD      (R0), R2
.pa_tx_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LD      R0, 4
    AND     R3, R0
    LOAD16  R0, .pa_tx_wait
    JMP.Z   R0, R3
    LOAD16  R0, NOC_TX_DATA
    LD      (R0), R1

    LOAD16  R3, _worker_idle
    JMP     R3

; ------------------------------------------------------------------------------
; Phase B: N-Core Trap 14 Ring Relay (add my_id, forward to next_core)
; ------------------------------------------------------------------------------
_phase_b_relay:
    LOAD16  R0, var_my_id
    LD      R2, (R0)
    ADD     R1, R2
    LOAD16  R0, 0x7FFF
    AND     R1, R0
    LOAD16  R0, 0x8000
    OR      R1, R0

    LOAD16  R0, var_next_core
    LD      R2, (R0)
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R2
.pb_tx_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LD      R0, 4
    AND     R3, R0
    LOAD16  R0, .pb_tx_wait
    JMP.Z   R0, R3
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1

    LOAD16  R3, _worker_idle
    JMP     R3

.org 0x0600
var_my_id:     .word 0
var_next_core: .word 0
var_id_sh8:    .word 0
var_id_mul13:  .word 0
var_id_mask:   .word 0
var_mbox_flag: .word 0
var_mbox_src:  .word 0
var_mbox_val:  .word 0
var_seed:      .word 0
var_err:       .word 0

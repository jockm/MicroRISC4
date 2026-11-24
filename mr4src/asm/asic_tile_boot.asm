; ==============================================================================
; FILE: mr4src/asm/asic_tile_boot.asm
; Architecture: Unified Multi-Tile ASIC Cold-Start Boot ROM (0x0100 - 0x02FF)
;
; Identical ROM image baked into every hardened `mr4_tile` macro.
; Each tile discovers its role at runtime via strapped `CPUID` (0x0001):
;   - Tile 0 (Master):
;       1. Prints "MR4 TILE0 OK\r\n" on UART.
;       2. Reads `NOC_INFO` (0x002A) for total ring tile count N.
;       3. For each worker k = 1 .. N-1:
;            - Sends MBOX doorbell (0x1000 + k) to Tile k (triggers Trap 14!)
;            - Receives RX FIFO reply from Tile k and verifies == (0x2000 + k)
;       4. Writes 0x600D to [0x0303], prints "RING PASS\r\n", enters UART echo.
;   - Tiles 1..N-1 (Workers):
;       1. Hardware Trap 14 ISR switches to shadow registers, pops MBOX_SRC +
;          MBOX_DATA (clearing mbox_valid / deasserting Trap 14), sets flag, and
;          returns cleanly via ERET.
;       2. Worker main loop sends reply = data + 0x1000 via NOC_TX_DATA to src,
;          marks [0x0303] = 0x600D, and loops for further jobs.
; ==============================================================================

.include "common.inc"

.define TILE_RSP_INIT     0x03FF
.define TILE_ASP_INIT     0x03BF
.define SCRATCH_N         0x0300
.define SCRATCH_K         0x0301
.define SCRATCH_EXP       0x0302
.define SCRATCH_OK        0x0303
.define SCRATCH_MBOX_FLAG 0x0304
.define SCRATCH_MBOX_SRC  0x0305
.define SCRATCH_MBOX_DATA 0x0306

.define NOC_TX_DATA       0x0020
.define NOC_DST_CORE      0x0021
.define NOC_RX_DATA       0x0022
.define NOC_STAT          0x0023
.define NOC_MBOX_SEND     0x0025
.define NOC_MBOX_DATA     0x0026
.define NOC_MBOX_SRC      0x0027
.define NOC_INFO          0x002A

; ==============================================================================
; Direct Stride Vector Table (0x0100 - 0x01FF)
; ==============================================================================
.org 0x0100
_trap0_reset:
    LOAD16  R1, TILE_RSP_INIT
    LD      R0, 4                   ; RSP @ 0x0004
    LD      (R0), R1
    LOAD16  R1, TILE_ASP_INIT
    INC     R0                      ; ASP @ 0x0005
    LD      (R0), R1
    LOAD16  R0, _tile_boot_main
    JMP     R0

.org 0x0180
_msg_tile0:
    .asciz  "MR4 TILE0 OK\r\n"
_msg_pass:
    .asciz  "RING PASS\r\n"
_msg_fail:
    .asciz  "RING FAIL\r\n"

.org 0x01E0
_trap14_async:
    ; Non-destructive Trap 14 ISR using shadow bank + ERET
    XCHG    R0
    LOAD16  R0, _trap14_body
    JMP     R0

.org 0x01F0
_trap15_fault:
    LOAD16  R0, _trap15_halt
_trap15_halt:
    JMP     R0

; ==============================================================================
; Unified Tile Boot Entry (0x0200 - 0x02FF)
; ==============================================================================
.org 0x0200
_tile_boot_main:
    ; Clear MBOX software flag in uninitialized cold-start RAM
    LOAD16  R0, SCRATCH_MBOX_FLAG
    LD0     R1
    LD      (R0), R1

    ; Read strapped CPUID (0x000D = 13): Tile 0 -> Master, Tiles 1..N-1 -> Worker
    LD      R0, 13
    LD      R1, (R0)
    LOAD16  R0, _master_main
    JMP.Z   R0, R1

; ------------------------------------------------------------------------------
; Worker Tile Loop (CPUID != 0): service MBOX doorbells captured by Trap 14 ISR
; ------------------------------------------------------------------------------
_worker_loop:
    LOAD16  R0, SCRATCH_MBOX_FLAG
    LD      R1, (R0)
    LOAD16  R0, _worker_loop
    JMP.Z   R0, R1

    ; Clear software flag
    LOAD16  R0, SCRATCH_MBOX_FLAG
    LD0     R1
    LD      (R0), R1

    ; Set destination core to sender
    LOAD16  R0, SCRATCH_MBOX_SRC
    LD      R2, (R0)
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R2

    ; Wait for TX ready (NOC_STAT bit 2)
_worker_tx_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LD      R0, 4
    AND     R3, R0
    LOAD16  R0, _worker_tx_wait
    JMP.Z   R0, R3

    ; Reply with payload + 0x1000
    LOAD16  R0, SCRATCH_MBOX_DATA
    LD      R1, (R0)
    LOAD16  R2, 0x1000
    ADD     R1, R2
    LOAD16  R0, NOC_TX_DATA
    LD      (R0), R1

    ; Mark worker healthy sentinel
    LOAD16  R0, SCRATCH_OK
    LOAD16  R1, 0x600D
    LD      (R0), R1

    LOAD16  R0, _worker_loop
    JMP     R0

; ------------------------------------------------------------------------------
; Hardware Trap 14 ISR Body (pops MBOX_SRC + MBOX_DATA to deassert Trap 14)
; ------------------------------------------------------------------------------
_trap14_body:
    XCHG    R1
    XCHG    R2
    LOAD16  R0, NOC_MBOX_SRC
    LD      R2, (R0)
    LOAD16  R0, NOC_MBOX_DATA
    LD      R1, (R0)                ; pops mbox_valid -> clears Trap 14
    LOAD16  R0, SCRATCH_MBOX_SRC
    LD      (R0), R2
    LOAD16  R0, SCRATCH_MBOX_DATA
    LD      (R0), R1
    LOAD16  R0, SCRATCH_MBOX_FLAG
    LOAD16  R1, 1
    LD      (R0), R1
    XCHG    R2
    XCHG    R1
    XCHG    R0
    ERET

; ------------------------------------------------------------------------------
; Master Tile 0: Banner + Ring Round-Trip Verification across Tiles 1..N-1
; ------------------------------------------------------------------------------
_master_main:
    LOAD16  R2, _msg_tile0
    RCALL   _rom_puts

    ; Discover N = NOC_INFO & 0xFF
    LOAD16  R0, NOC_INFO
    LD      R1, (R0)
    LOAD16  R2, 0x00FF
    AND     R1, R2
    LOAD16  R0, SCRATCH_N
    LD      (R0), R1

    ; k = 1
    LOAD16  R1, 1
    LOAD16  R0, SCRATCH_K
    LD      (R0), R1

_master_ping_loop:
    ; Check if k >= N (k - N == 0 -> done)
    LOAD16  R0, SCRATCH_K
    LD      R1, (R0)
    LOAD16  R0, SCRATCH_N
    LD      R2, (R0)
    SUB     R2, R1
    LOAD16  R0, _master_ring_pass
    JMP.Z   R0, R2

    ; Select destination core k
    LOAD16  R0, NOC_DST_CORE
    LD      (R0), R1

    ; Wait for TX ready
_master_tx_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LD      R0, 4
    AND     R3, R0
    LOAD16  R0, _master_tx_wait
    JMP.Z   R0, R3

    ; Send MBOX doorbell (0x1000 + k)
    LOAD16  R2, 0x1000
    ADD     R1, R2
    LOAD16  R0, NOC_MBOX_SEND
    LD      (R0), R1

    ; Save expected reply (0x2000 + k)
    ADD     R1, R2
    LOAD16  R0, SCRATCH_EXP
    LD      (R0), R1

    ; Wait for RX FIFO non-empty (NOC_STAT bit 0)
_master_rx_wait:
    LOAD16  R0, NOC_STAT
    LD      R3, (R0)
    LD      R0, 1
    AND     R3, R0
    LOAD16  R0, _master_rx_wait
    JMP.Z   R0, R3

    ; Pop reply and compare with expected
    LOAD16  R0, NOC_RX_DATA
    LD      R1, (R0)
    LOAD16  R0, SCRATCH_EXP
    LD      R2, (R0)
    SUB     R1, R2
    LOAD16  R0, _master_next_k
    JMP.Z   R0, R1

    ; Mismatch -> print FAIL and halt
    LOAD16  R2, _msg_fail
    RCALL   _rom_puts
_master_halt:
    LOAD16  R0, _master_halt
    JMP     R0

_master_next_k:
    LOAD16  R0, SCRATCH_K
    LD      R1, (R0)
    INC     R1
    LD      (R0), R1
    LOAD16  R0, _master_ping_loop
    JMP     R0

_master_ring_pass:
    LOAD16  R0, SCRATCH_OK
    LOAD16  R1, 0x600D
    LD      (R0), R1
    LOAD16  R2, _msg_pass
    RCALL   _rom_puts

_echo_loop:
    GETC    R1
    RCALL   _putc_r1
    LOAD16  R0, _echo_loop
    JMP     R0

; ------------------------------------------------------------------------------
; Print packed NUL-terminated string pointed to by R2 (compact for 512w ROM)
; ------------------------------------------------------------------------------
_rom_puts:
    RPUSH   R0
_rom_puts_loop:
    LD      R3, (R2++)
    BYTE_GET_LO R1, R3
    LOAD16  R0, _rom_puts_done
    JMP.Z   R0, R1
    RCALL   _putc_r1
    BYTE_GET_HI R1, R3
    LOAD16  R0, _rom_puts_done
    JMP.Z   R0, R1
    RCALL   _putc_r1
    LOAD16  R0, _rom_puts_loop
    JMP     R0
_rom_puts_done:
    RRET

_putc_r1:
    RPUSH   R0
    PUTC    R1
    RRET

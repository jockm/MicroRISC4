; HELLO.ASM - a minimal MR4OS console-output example.
; From /WORK, assemble and run it with:
;   ! ASM.PRG HELLO.ASM HELLO.PRG
;   ! HELLO.PRG
; Console output uses the OS syscall interface rather than polling UART MMIO.

.include "common.inc"           ; Supplies the LOAD16 and LD0 macros.

.org 0x0400                     ; MR4OS loads application programs here.
_main:
    LOAD16  R1, hello_message
    LOAD16  R2, 10              ; String is 20 bytes including NUL: 10 words.
    LD0     R3                  ; SYS_WRITE_CON's extra argument is unused.
    LD0     R0
    INC     R0                  ; R0=1 selects the worker's syscall trap vector.
    TRAP    R0, 0x10             ; SYS_WRITE_CON: R1=buffer, R2=word count.
    LD0     R1                  ; SYS_EXIT returns the application status in R1.
    LD0     R2                  ; The second scalar syscall argument is unused.
    LD0     R0
    INC     R0
    TRAP    R0, 0x01             ; SYS_EXIT(0); this syscall does not return.

hello_message:
    .asciz  "Hello from Mr4OS!\r\n" ; Two bytes per word; ASCIZ appends NUL.

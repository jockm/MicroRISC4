# MiniRISC4 Standard Libraries

- `common.inc`: Core macro library (stacks, UART, bitwise, register save/restore).
- `M4R_LIB.asm`: 16-bit runtime arithmetic and comparisons (MULT, DIV, MOD, _CMP_*).
- `M4R_LIB32.asm`: 32-bit runtime arithmetic, logic, shifts, and comparisons (ADD32, SUB32, MULT32, DIV32, MOD32, AND32, OR32, XOR32, NOT32, NEG32, SHL32, SHR32, ASR32, ROTL32, ROTR32, CMP32_*).

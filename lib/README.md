# MicroRISC4 Standard Libraries

- `common.inc`: Core macro library (stacks, UART, bitwise, register save/restore).
- `M4R_LIB.asm`: 16-bit runtime arithmetic and comparisons (MULT, DIV, MOD, _CMP_*).
- `M4R_LIB32.asm`: 32-bit runtime arithmetic, logic, shifts, and comparisons (ADD32, SUB32, MULT32, DIV32, MOD32, AND32, OR32, XOR32, NOT32, NEG32, SHL32, SHR32, ASR32, ROTL32, ROTR32, CMP32_*).

## How LLMs Are Used in This Project.
The project makes use of LLM's in a Spec -> Revise -> Generate -> Test loop.  Normally for specific features or goals.  Each step is reviewed by a human, as is the output.

In addition human hands have revised code and documents directly and created original code.

Decisions and the direction of development are always made by a human, all research and references are always checked.

Multiple LLMs have been used:
- Google Gemini
- Antropic Claude
- Microsoft Copilot
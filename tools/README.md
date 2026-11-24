# MicroRISC4 Software Toolchain

This directory contains the assembler, simulator, and high-level language compiler for the MicroRISC4 architecture.

---

### 1. Two-Pass Macro Assembler (`mr4asm.py`)
```bash
python3 tools/mr4asm.py lib/common.inc lib/M4R_LIB.asm app.asm --hex -o hdl/verilog/system_image.hex -l app.lst
```

### 2. Instruction-Level Simulator (`mr4sim.py`)
```bash
python3 tools/mr4sim.py app.bin --startaddr 0x0100
```

### 3. ACT4 Language Compiler (`act4c.py`)
```bash
python3 tools/act4c.py tools/monitor.a4 -o tools/monitor.asm
```
## How LLMs Are Used in This Project.
The project makes use of LLM's in a Spec -> Revise -> Generate -> Test loop.  Normally for specific features or goals.  Each step is reviewed by a human, as is the output.

In addition human hands have revised code and documents directly and created original code.

Decisions and the direction of development are always made by a human, all research and references are always checked.

Multiple LLMs have been used:
- Google Gemini
- Antropic Claude
- Microsoft Copilot
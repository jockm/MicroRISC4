# MiniRISC4 Software Toolchain

This directory contains the assembler, simulator, and high-level language compiler for the MiniRISC4 architecture.

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

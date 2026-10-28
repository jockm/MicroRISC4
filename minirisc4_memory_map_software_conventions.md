# MiniRISC4 Memory Map & Software Conventions

---

## 1. Unified 64K Memory Map

MiniRISC4 features a completely unified 64K-word (128 KB) read/write RAM space. There is no write-protected ROM region.

| Address Range | Size | Description |
| :---: | :---: | :--- |
| `0x0000` – `0x0003` | 4 words | Scratchpad RAM for register save/restore (`SAVEALL` / `LOADALL`). |
| `0x0004` | 1 word | **Return Stack Pointer (RSP)**. Default base: `0xFEFF`, grows down. |
| `0x0005` | 1 word | **Argument Stack Pointer (ASP)**. Default base: `0xFAFF`, grows down. |
| `0x0006` – `0x000C` | 7 words | General scratchpad workspace cells. |
| `0x000D` | 1 word | **Hardware CPUID Register (RO)**: Returns core ID (acts as RAM if CPUID disabled). |
| `0x000E` | 1 word | **MMIO UART RX**: Read bit 15 = valid; bits [7:0] = byte; read pops FIFO. |
| `0x000F` | 1 word | **MMIO UART TX**: Read 0 = idle; write bits [7:0] transmits byte. |
| `0x0010` – `0x001F` | 16 words | **Hardware Vectors** | Exception and Trap Vector Table (`0x0010` = Reset Vector, `0x001F` = Trap 15 Alignment Fault). |
| `0x0020` – `0x001F` | 65,504 words | RAM | General unified RAM for code (`_start` at `0x0100`), heap, and descending stacks. |

---

## 2. Register Roles & Conventions

| Register | Name | Role & Software Convention |
| :---: | :---: | :--- |
| `R0` | Link / Scratch | Subroutine return address link (`LINK Rr, R0`), 4-bit immediate destination (`LD R0, imm4`), trap vector scratch. |
| `R1` | Accumulator | Primary expression evaluation and function return value. |
| `R2` | Operand / Pointer | Secondary operand register, pointer scratch. |
| `R3` | Index / Scratch | Memory address indexing, stack pointer manipulation. |
| `shadow_r[0..3]` | Shadow Bank | Hardware shadow registers toggled in 1 cycle via `XCHG Rr`. |

---

## 3. Stack Conventions (Full Descending)

Both the Return Stack (`0x0004`) and Argument Stack (`0x0005`) operate using the **Full Descending (FD)** convention:
- **Push**: `LD (--Rr), Rl` (Opcode `0x5`) pre-decrements the stack pointer, then stores the word.
- **Pop**: `LD Rr, (Rl++)` (Opcode `0x4`) loads the word, then post-increments the stack pointer.

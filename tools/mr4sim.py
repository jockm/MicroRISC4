#!/usr/bin/env python3
"""
tools/mr4sim.py - Instruction-level simulator for the MiniRISC4 architecture.

Features:
  - 16-bit word-addressed memory space (64K words: 0x0000 - 0xFFFF).
  - Little-endian binary file loading (Slot 0 in byte 0, Slot 1 in byte 1).
  - Dual-slot instruction packing per word.
  - Native AND (Opcode 0xA).
  - Dedicated hardware shadow registers and exchange (XCHG Rr, Opcode 0xB, sub 0x3).
  - Full Descending stack:
      * LD Rr, (Rl++) -> Post-increment load (Pop, Opcode 0x4)
      * LD (--Rr), Rl -> Pre-decrement store (Push, Opcode 0x5)
  - Word-aligned instructions: PUSH8, LINK, TRAP (Slot 1 violation faulting).
  - Non-blocking MMIO UART at 0x000E (RX) and 0x000F (TX).
  - Interactive (m4db) debugger with symbol mapping, breakpoints, watchpoints,
    load, save, and arbitrary jump execution.
"""

import sys
import os
import argparse
import select
from collections import deque

try:
    import readline
except ImportError:
    pass

IS_WINDOWS = sys.platform.startswith("win")
if IS_WINDOWS:
    import msvcrt
else:
    import tty
    import termios

MEM_WORDS       = 65536
WORD_MASK       = 0xFFFF
ADDR_MASK       = 0xFFFF
BYTE_MASK       = 0xFF

ADDR_UART_RX    = 0x000E
ADDR_UART_TX    = 0x000F
ADDR_RESET_VEC  = 0x0010
TRAP_BASE       = 0x0010

# MiniRISC4 Primary Opcodes (Bits [7:4] / [15:12])
OP_LD_REG       = 0x0
OP_LD_IMM4      = 0x1
OP_LD_PEEK      = 0x2
OP_LD_POKE      = 0x3
OP_LD_POP       = 0x4  # LD Rr, (Rl++)
OP_LD_PUSH      = 0x5  # LD (--Rr), Rl
OP_ADD          = 0x6
OP_SUB          = 0x7
OP_OR           = 0x8
OP_XOR          = 0x9
OP_AND          = 0xA  # Native single-cycle AND
OP_SHIFT        = 0xB
OP_ROT_INC_DEC  = 0xC
OP_JMP_Z        = 0xD
OP_JMP_M        = 0xE
OP_JMP_SPECIAL  = 0xF

# Sub-Opcodes for OP_SHIFT (0xB)
SUB_SHIFT_L     = 0x0
SUB_SHIFT_R     = 0x1
SUB_SHIFT_AR    = 0x2
SUB_SHIFT_XCHG  = 0x3

# Sub-Opcodes for OP_ROT_INC_DEC (0xC)
SUB_ROT_L       = 0x0
SUB_ROT_R       = 0x1
SUB_INC         = 0x2
SUB_DEC         = 0x3

# Sub-Opcodes for OP_JMP_SPECIAL (0xF)
SUB_JMP         = 0x0
SUB_LINK        = 0x1
SUB_PUSH8       = 0x2
SUB_TRAP        = 0x3


class RawTerminal:
    """Context manager for raw terminal I/O on POSIX platforms."""
    def __enter__(self):
        if not IS_WINDOWS and sys.stdin.isatty():
            self.old_settings = termios.tcgetattr(sys.stdin)
            tty.setcbreak(sys.stdin.fileno())
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if not IS_WINDOWS and sys.stdin.isatty():
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self.old_settings)


class MiniRISC4Sim:
    def __init__(self, trace: bool = False):
        self.mem_words = 65536
        self.mem = [0] * MEM_WORDS
        self.r = [0] * 4
        self.shadow_r = [0] * 4
        self.pc = 0
        self.trap_base = 0x0100
        self.core_id = 0
        self.enable_cpuid = True
        self.enable_uart = True
        self.slot = 0          # 0 = Slot 0 [7:0], 1 = Slot 1 [15:8]
        self.trace = trace
        self.running = True
        self.halted = False
        self.rx_queue = deque()
        self.cycles = 0

        # Debugger state
        self.breakpoints = set()
        self.watchpoints = set()
        self.sym_to_addr = {}
        self.addr_to_sym = {}

    def load_binary(self, filename: str, offset: int = 0):
        """Loads a binary file into 16-bit word memory (little-endian: Slot 0 low, Slot 1 high)."""
        with open(filename, "rb") as f:
            data = f.read()
        if len(data) % 2 != 0:
            data += b"\x00"
        words = len(data) // 2
        for i in range(words):
            slot0 = data[i * 2]
            slot1 = data[i * 2 + 1]
            addr = (offset + i) & ADDR_MASK
            self.mem[addr] = (slot1 << 8) | slot0

    def load_symbols(self, lst_filename: str):
        """Parses an assembler listing file (.lst) to resolve symbolic labels."""
        if not os.path.exists(lst_filename):
            return
        with open(lst_filename, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        addr = int(parts[0], 16)
                        token = parts[1]
                        if token.endswith(":"):
                            label = token[:-1]
                            self.sym_to_addr[label] = addr
                            self.addr_to_sym[addr] = label
                    except ValueError:
                        continue

    def parse_addr_or_symbol(self, token: str):
        """Resolves a hex address, decimal address, or symbol string to a 16-bit address."""
        if token in self.sym_to_addr:
            return self.sym_to_addr[token]
        try:
            return int(token, 0) & ADDR_MASK
        except ValueError:
            return None

    def read_mem(self, addr: int) -> int:
        addr &= ADDR_MASK
        if addr == ADDR_UART_RX:
            self._poll_stdin()
            if self.rx_queue:
                ch = self.rx_queue.popleft()
                return 0x8000 | (ch & BYTE_MASK)
            return 0x0000
        elif addr == ADDR_UART_TX:
            return 0x0000  # UART TX status: 0x0000 = idle / ready
        if addr == 0x000D and getattr(self, 'enable_cpuid', True):
            return getattr(self, 'core_id', 0) & 0xFFFF
        return self.mem[addr]

    def write_mem(self, addr: int, val: int):
        addr &= ADDR_MASK
        val &= WORD_MASK
        if addr in self.watchpoints:
            print(f"\n[WATCHPOINT] Write to 0x{addr:04X}: Old=0x{self.mem[addr]:04X}, New=0x{val:04X}")
            self.interactive_cli()

        if addr == ADDR_UART_TX:
            char = chr(val & BYTE_MASK)
            sys.stdout.write(char)
            sys.stdout.flush()
        else:
            self.mem[addr] = val

    def _poll_stdin(self):
        """Polls host terminal for incoming characters."""
        if IS_WINDOWS:
            while msvcrt.kbhit():
                ch = msvcrt.getch()
                self.rx_queue.append(ord(ch))
        else:
            r, _, _ = select.select([sys.stdin], [], [], 0)
            if r:
                data = os.read(sys.stdin.fileno(), 1024)
                for b in data:
                    self.rx_queue.append(b)

    def _branch_to(self, target_word_addr: int):
        self.pc = target_word_addr & ADDR_MASK
        self.slot = 0

    def step(self):
        """Executes a single instruction slot."""
        if self.halted:
            return

        current_pc = self.pc
        current_slot = self.slot
        word = self.mem[current_pc]

        if current_slot == 0:
            instr = word & BYTE_MASK
        else:
            instr = (word >> 8) & BYTE_MASK

        opcode = (instr >> 4) & 0x0F
        arg = instr & 0x0F
        rr = (arg >> 2) & 0x03
        rl = arg & 0x03

        if self.trace and current_slot == 0:
            sym = f" <{self.addr_to_sym[current_pc]}>" if current_pc in self.addr_to_sym else ""
            print(f"\nPC:0x{current_pc:04X}{sym} [0x{word:04X}] | R0:{self.r[0]:04X} R1:{self.r[1]:04X} R2:{self.r[2]:04X} R3:{self.r[3]:04X}")

        # Advance slot / PC tracking default
        next_pc = current_pc
        next_slot = current_slot + 1
        if next_slot > 1:
            next_slot = 0
            next_pc = (current_pc + 1) & ADDR_MASK

        self.pc = next_pc
        self.slot = next_slot
        self.cycles += 1

        # ----------------------------------------------------------------------
        # Opcode Decoding
        # ----------------------------------------------------------------------
        if opcode == OP_LD_REG:
            self.r[rr] = self.r[rl]

        elif opcode == OP_LD_IMM4:
            self.r[rr] = rl

        elif opcode == OP_LD_PEEK:
            self.r[rr] = self.read_mem(self.r[rl])

        elif opcode == OP_LD_POKE:
            self.write_mem(self.r[rr], self.r[rl])

        elif opcode == OP_LD_POP:
            # LD Rr, (Rl++)
            ptr = self.r[rl]
            self.r[rr] = self.read_mem(ptr)
            self.r[rl] = (ptr + 1) & ADDR_MASK

        elif opcode == OP_LD_PUSH:
            # LD (--Rr), Rl
            ptr = (self.r[rr] - 1) & ADDR_MASK
            val_to_write = self.r[rl]
            self.r[rr] = ptr
            self.write_mem(ptr, val_to_write)

        elif opcode == OP_ADD:
            res = (self.r[rr] + self.r[rl]) & WORD_MASK
            self.r[rr] = res

        elif opcode == OP_SUB:
            res = (self.r[rr] - self.r[rl]) & WORD_MASK
            self.r[rr] = res

        elif opcode == OP_OR:
            self.r[rr] = (self.r[rr] | self.r[rl]) & WORD_MASK

        elif opcode == OP_XOR:
            self.r[rr] = (self.r[rr] ^ self.r[rl]) & WORD_MASK

        elif opcode == OP_AND:
            # Native single-cycle AND
            self.r[rr] = (self.r[rr] & self.r[rl]) & WORD_MASK

        elif opcode == OP_SHIFT:
            if rl == SUB_SHIFT_L:
                self.r[rr] = (self.r[rr] << 1) & WORD_MASK
            elif rl == SUB_SHIFT_R:
                self.r[rr] = (self.r[rr] >> 1) & WORD_MASK
            elif rl == SUB_SHIFT_AR:
                sign = self.r[rr] & 0x8000
                self.r[rr] = (self.r[rr] >> 1) | sign
            elif rl == SUB_SHIFT_XCHG:
                tmp = self.r[rr]
                self.r[rr] = self.shadow_r[rr]
                self.shadow_r[rr] = tmp

        elif opcode == OP_ROT_INC_DEC:
            if rl == SUB_ROT_L:
                msb = (self.r[rr] >> 15) & 1
                self.r[rr] = ((self.r[rr] << 1) | msb) & WORD_MASK
            elif rl == SUB_ROT_R:
                lsb = self.r[rr] & 1
                self.r[rr] = ((self.r[rr] >> 1) | (lsb << 15)) & WORD_MASK
            elif rl == SUB_INC:
                self.r[rr] = (self.r[rr] + 1) & WORD_MASK
            elif rl == SUB_DEC:
                self.r[rr] = (self.r[rr] - 1) & WORD_MASK

        elif opcode == OP_JMP_Z:
            # JMP.Z Rr, Rl -> Branch to Rr if Rl == 0
            if self.r[rl] == 0:
                self._branch_to(self.r[rr])

        elif opcode == OP_JMP_M:
            # JMP.M Rr, Rl -> Branch to Rr if Rl is negative (bit 15 set)
            if (self.r[rl] & 0x8000) != 0:
                self._branch_to(self.r[rr])

        elif opcode == OP_JMP_SPECIAL:
            if current_slot != 0:
                # Word-alignment fault for PUSH8, LINK, TRAP
                print(f"\n[FAULT] Slot 1 alignment violation at PC:0x{current_pc:04X}")
                self.pc = self.read_mem(0xFFFF)
                self.slot = 0
                return

            if rr == SUB_JMP:
                self._branch_to(self.r[rl])

            elif rr == SUB_LINK:
                target = self.r[rl]
                self.r[0] = (current_pc + 1) & ADDR_MASK
                self._branch_to(target)

            elif rr == SUB_PUSH8:
                imm8 = (word >> 8) & BYTE_MASK
                self.r[rl] = ((self.r[rl] << 8) | imm8) & WORD_MASK
                self.pc = (current_pc + 1) & ADDR_MASK
                self.slot = 0

            elif rr == SUB_TRAP:
                trap_vector = TRAP_BASE + (self.r[rl] & 0x0F)
                self.r[0] = (current_pc + 1) & ADDR_MASK
                self._branch_to(self.read_mem(trap_vector))

    def interactive_cli(self):
        """Interactive debugger command loop ((m4db))."""
        print(f"\n--- MiniRISC4 Debugger (m4db) ---")
        print(f"PC: 0x{self.pc:04X} (Slot {self.slot}), Cycles: {self.cycles}")

        while True:
            try:
                cmd_line = input("(m4db) ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                return

            if not cmd_line:
                continue

            parts = cmd_line.split()
            cmd = parts[0].lower()
            args = parts[1:]

            if cmd in ("h", "help", "?"):
                self.print_help()

            elif cmd in ("c", "cont", "continue"):
                print("Continuing execution (Press Ctrl+C to halt into debugger)...")
                return

            elif cmd in ("s", "step"):
                self.step()
                sym = f" <{self.addr_to_sym[self.pc]}>" if self.pc in self.addr_to_sym else ""
                print(f"Step -> PC: 0x{self.pc:04X}{sym} Slot:{self.slot}")

            elif cmd in ("stepw", "next", "n"):
                start_pc = self.pc
                while self.pc == start_pc and not self.halted:
                    self.step()
                sym = f" <{self.addr_to_sym[self.pc]}>" if self.pc in self.addr_to_sym else ""
                print(f"Step Word -> PC: 0x{self.pc:04X}{sym}")

            elif cmd in ("r", "regs"):
                print(f"R0: 0x{self.r[0]:04X}  R1: 0x{self.r[1]:04X}  R2: 0x{self.r[2]:04X}  R3: 0x{self.r[3]:04X}")
                print(f"s0: 0x{self.shadow_r[0]:04X}  s1: 0x{self.shadow_r[1]:04X}  s2: 0x{self.shadow_r[2]:04X}  s3: 0x{self.shadow_r[3]:04X}")
                print(f"PC: 0x{self.pc:04X}  Slot: {self.slot}  RSP: 0x{self.mem[4]:04X}  ASP: 0x{self.mem[5]:04X}")

            elif cmd in ("m", "mem", "dump"):
                if not args:
                    print("Usage: m <addr/label> [count]")
                    continue
                start = self.parse_addr_or_symbol(args[0])
                if start is None:
                    print(f"Invalid address: {args[0]}")
                    continue
                cnt = int(args[1], 0) if len(args) > 1 else 8
                for i in range(cnt):
                    addr = (start + i) & ADDR_MASK
                    val = self.mem[addr]
                    lo = val & 0xFF
                    hi = (val >> 8) & 0xFF
                    c_lo = chr(lo) if 32 <= lo <= 126 else "."
                    c_hi = chr(hi) if 32 <= hi <= 126 else "."
                    sym = f" <{self.addr_to_sym[addr]}>" if addr in self.addr_to_sym else ""
                    print(f"  0x{addr:04X}{sym:20s}: 0x{val:04X}  [{lo:02X} {hi:02X}]  '{c_lo}{c_hi}'")

            elif cmd in ("b", "break"):
                if not args:
                    print("Usage: b <addr/label>")
                    continue
                addr = self.parse_addr_or_symbol(args[0])
                if addr is None:
                    print(f"Invalid address: {args[0]}")
                    continue
                self.breakpoints.add(addr)
                print(f"Breakpoint set at 0x{addr:04X}")

            elif cmd in ("blist",):
                print(f"Active breakpoints: {[f'0x{a:04X}' for a in sorted(self.breakpoints)]}")

            elif cmd in ("bdel",):
                if not args:
                    print("Usage: bdel <addr/label>")
                    continue
                addr = self.parse_addr_or_symbol(args[0])
                if addr in self.breakpoints:
                    self.breakpoints.remove(addr)
                    print(f"Removed breakpoint at 0x{addr:04X}")

            elif cmd in ("watch",):
                if not args:
                    print("Usage: watch <addr/label>")
                    continue
                addr = self.parse_addr_or_symbol(args[0])
                if addr is not None:
                    self.watchpoints.add(addr)
                    print(f"Watchpoint set for writes to 0x{addr:04X}")

            elif cmd in ("g", "jump", "goto"):
                if not args:
                    print("Usage: g <addr/label>  or  jump <addr/label>")
                    continue
                target = self.parse_addr_or_symbol(args[0])
                if target is None:
                    print(f"Invalid target address or symbol: {args[0]}")
                    continue
                self.pc = target & ADDR_MASK
                self.slot = 0
                sym_info = f" <{self.addr_to_sym[self.pc]}>" if self.pc in self.addr_to_sym else ""
                print(f"Jumping to 0x{self.pc:04X}{sym_info} and continuing execution...")
                return

            elif cmd == "load":
                if len(args) < 2:
                    print("Usage: load <filename> <addr/label>")
                    continue

                filename = args[0]
                target_addr = self.parse_addr_or_symbol(args[1])

                if target_addr is None:
                    print(f"Error: Invalid load address or symbol '{args[1]}'")
                    continue

                if not os.path.exists(filename):
                    print(f"Error: File '{filename}' not found")
                    continue

                try:
                    with open(filename, "rb") as f:
                        raw_data = f.read()

                    # Pad to even number of bytes for 16-bit word alignment
                    if len(raw_data) % 2 != 0:
                        raw_data += b"\x00"

                    words_count = len(raw_data) // 2
                    for i in range(words_count):
                        slot0 = raw_data[i * 2]
                        slot1 = raw_data[i * 2 + 1]
                        dest_addr = (target_addr + i) & ADDR_MASK
                        self.mem[dest_addr] = (slot1 << 8) | slot0

                    end_addr = (target_addr + words_count - 1) & ADDR_MASK
                    print(f"Loaded {words_count} words ({len(raw_data)} bytes) from '{filename}' into [0x{target_addr:04X}..0x{end_addr:04X}]")

                except Exception as e:
                    print(f"Error loading file: {e}")

            elif cmd == "save":
                if len(args) < 3:
                    print("Usage: save <addr/label> <length> <filename>")
                    continue

                start_addr = self.parse_addr_or_symbol(args[0])
                if start_addr is None:
                    print(f"Error: Invalid start address or symbol '{args[0]}'")
                    continue

                try:
                    length = int(args[1], 0)
                except ValueError:
                    print(f"Error: Invalid length '{args[1]}'")
                    continue

                filename = args[2]

                try:
                    out_bytes = bytearray()
                    for i in range(length):
                        src_addr = (start_addr + i) & ADDR_MASK
                        word_val = self.mem[src_addr]
                        slot0 = word_val & BYTE_MASK
                        slot1 = (word_val >> 8) & BYTE_MASK
                        out_bytes.append(slot0)
                        out_bytes.append(slot1)

                    with open(filename, "wb") as f:
                        f.write(out_bytes)

                    end_addr = (start_addr + length - 1) & ADDR_MASK
                    print(f"Saved {length} words ({len(out_bytes)} bytes) from [0x{start_addr:04X}..0x{end_addr:04X}] to '{filename}'")

                except Exception as e:
                    print(f"Error saving file: {e}")

            elif cmd in ("q", "quit", "exit"):
                print("Exiting simulator.")
                self.running = False
                sys.exit(0)

            else:
                print(f"Unknown command: '{cmd}'. Type 'help' for debugger commands.")

    def print_help(self):
        print("""
Execution & Stepping:
  s, step                        Step 1 instruction slot
  n, next, stepw                 Step 1 full 16-bit word
  c, cont                        Continue execution until breakpoint or Ctrl+C
  g, jump <addr/label>           Set PC to arbitrary address/label and continue

Breakpoints & Watchpoints:
  b, break <addr/label>          Set breakpoint at word address
  blist                          List all breakpoints
  bdel <addr/label>              Delete breakpoint
  watch <addr/label>             Set watchpoint on memory writes

Inspection & Memory:
  r, regs                        Display all general and shadow registers
  m, mem <addr/label> [count]    Dump memory words in hex and ASCII

File Operations:
  load <filename> <addr/label>         Load binary file into memory at address
  save <addr/label> <length> <filename> Save length words from memory to binary file

Control:
  q, quit                        Exit simulator
""")


def main():
    parser = argparse.ArgumentParser(description="MiniRISC4 Instruction-Level Python Simulator (mr4sim)")
    parser.add_argument("binary", help="Path to binary file (.bin)")
    parser.add_argument("--memwords", type=lambda x: int(x, 0), default=65536, help="Physical memory capacity in words (default: 65536)")
    parser.add_argument("--core-id", type=lambda x: int(x, 0), default=0, help="Hardware Core ID (default: 0)")
    parser.add_argument("--disable-cpuid", action="store_true", help="Disable CPUID at 0x000D (treat as RAM)")
    parser.add_argument("--disable-uart", action="store_true", help="Disable UART MMIO at 0x000E/0x000F (treat as RAM)")
    parser.add_argument("--trapbase", type=lambda x: int(x, 0), default=0x0100, help="Vector table base address (default: 0x0010)")
    parser.add_argument("--startaddr", type=lambda x: int(x, 0), default=None,
                        help="Starting word address (hex e.g. 0x0100). Default: reset vector at mem[0xFFF0]")
    parser.add_argument("--loadaddr", type=lambda x: int(x, 0), default=0,
                        help="Word offset at which to load the binary into memory (default: 0x0000)")
    parser.add_argument("--debug", action="store_true", help="Halt into debugger immediately before execution")
    parser.add_argument("--trace", action="store_true", help="Print PC and register state on every cycle")
    parser.add_argument("--sym", default=None, help="Assembler listing file (.lst) for symbol resolution")
    args = parser.parse_args()

    if not os.path.exists(args.binary):
        print(f"Error: Binary file '{args.binary}' not found.", file=sys.stderr)
        sys.exit(1)

    sim = MiniRISC4Sim(trace=args.trace)
    sim.load_binary(args.binary, offset=args.loadaddr)

    if args.sym:
        sim.load_symbols(args.sym)

    if args.startaddr is not None:
        sim.pc = args.startaddr & ADDR_MASK
    else:
        sim.pc = sim.read_mem(ADDR_RESET_VEC)

    if args.debug:
        sim.interactive_cli()

    old_settings = termios.tcgetattr(sys.stdin) if not IS_WINDOWS and sys.stdin.isatty() else None
    try:
        while sim.running:
            try:
                if not IS_WINDOWS and sys.stdin.isatty():
                    tty.setcbreak(sys.stdin.fileno())

                while sim.running:
                    # Check breakpoints
                    if sim.slot == 0 and sim.pc in sim.breakpoints:
                        if old_settings:
                            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                        print(f"\n[BREAKPOINT] Reached breakpoint at 0x{sim.pc:04X}")
                        sim.interactive_cli()
                        if not IS_WINDOWS and sys.stdin.isatty():
                            tty.setcbreak(sys.stdin.fileno())

                    sim.step()

            except KeyboardInterrupt:
                if old_settings:
                    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                print("\n[INTERRUPT] Pausing execution into debugger.")
                sim.interactive_cli()

    finally:
        if old_settings:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)


if __name__ == "__main__":
    main()
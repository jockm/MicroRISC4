#!/usr/bin/env python3
"""
================================================================================
FILE: tools/mr4asm.py
Architecture: MiniRISC4 16-Bit Word-Addressed Processor
Target Hardware: Lattice ECP5 FPGA (ULX3S) / Verilog Core
Description:
  Two-pass macro assembler for the MiniRISC4 architecture.

Features:
  - 16-Bit Word Addressing: Memory space 0x0000 to 0xFFFF (64K words / 128 KB).
  - Dual-Instruction Word Packing: Two 8-bit instruction slots packed per 16-bit word:
      * Slot 0: Low byte (bits [7:0])
      * Slot 1: High byte (bits [15:8])
  - Native Hardware AND: Single-cycle bitwise AND Rr, Rl (Opcode 0xA).
  - Single-Cycle Shadow Register Swap: XCHG Rr (Opcode 0xB, sub-opcode 0x3).
  - Full Descending Hardware Stack:
      * Pop:  LD Rr, (Rl++) -> Post-increment load (Opcode 0x4)
      * Push: LD (--Rr), Rl -> Pre-decrement store (Opcode 0x5)
  - Automatic Word Alignment:
      * LINK Rr, R0 (Opcode 0xF, sub 0x1) padded with NOP in Slot 1.
      * PUSH8 Rr, const8 (Opcode 0xF, sub 0x2) spans Slot 0 and Slot 1.
      * TRAP Rr, val8 (Opcode 0xF, sub 0x3) spans Slot 0 and Slot 1.
      * If encountered while current position is Slot 1, automatically precedes
        with a NOP (0x00) in Slot 1 of the prior word to force Slot 0 alignment.
  - Multi-Pass Macro Preprocessor:
      * Directive syntax: .macro NAME param1, param2 ... .endmacro
      * Parameter substitution with %param prefix.
      * Unique label generation using ._% suffix expansion.
      * Nested macro support with maximum recursion limit of 20 levels.
  - File Inclusion:
      * .include "filename.asm" (nested, checked relative to file then via -I).
      * Supports multiple input assembly files directly on the CLI (nargs="+").
  - Rich Expression Evaluation:
      * Full arithmetic and bitwise expressions: +, -, *, /, %, &, |, ^, ~, <<, >>.
      * Byte extraction operators: <LABEL (low byte [7:0]), >LABEL (high byte [15:8]).
      * Literal radices: 0x... / $... / ...h (hex), 0b... / %... (bin), decimal, 'char'.
  - Output Formats:
      * Raw binary: --bin (first to last defined address), --fullbin (full 64K words),
        or --sparsebin.
      * Verilog hex format (--hex): 65,536 lines for $readmemh initialization.
      * Assembly listing file (-l <file.lst>): Displays addresses in hex, source lines,
        and assembled byte slot comments (; [HEX]).
================================================================================
"""

import sys
import os
import re
import argparse
from typing import List, Dict, Tuple, Optional, Any

# ==============================================================================
# Architectural Dimensions & Manifest Constants
# ==============================================================================
MEM_WORD_SIZE       = 65536          # Total memory capacity in 16-bit words (64K)
MEM_BYTE_SIZE       = MEM_WORD_SIZE * 2
WORD_MASK           = 0xFFFF
BYTE_MASK           = 0xFF
NIBBLE_MASK         = 0x0F

SLOT_0              = 0              # Low byte: bits [7:0]
SLOT_1              = 1              # High byte: bits [15:8]
NOP_BYTE            = 0x00           # LD R0, R0 acts as canonical 1-byte NOP
MAX_MACRO_RECURSION = 20             # Maximum allowed nested macro depth

# Primary Opcode Nibbles (Bits [7:4])
OP_LD_REG           = 0x0            # LD Rr, Rl (0000rrll)
OP_LD_IMM4          = 0x1            # LD R0, imm4 (0001iiii)
OP_LD_PEEK          = 0x2            # LD Rr, (Rl) (0010rrll)
OP_LD_POKE          = 0x3            # LD (Rr), Rl (0011rrll)
OP_LD_POSTINC       = 0x4            # LD Rr, (Rl++) -> Pop (0100rrll)
OP_LD_PREDEC        = 0x5            # LD (--Rr), Rl -> Push (0101rrll)
OP_ADD              = 0x6            # ADD Rr, Rl (0110rrll)
OP_SUB              = 0x7            # SUB Rr, Rl (0111rrll)
OP_OR               = 0x8            # OR Rr, Rl (1000rrll)
OP_XOR              = 0x9            # XOR Rr, Rl (1001rrll)
OP_AND              = 0xA            # AND Rr, Rl (1010rrll) - Native Hardware AND
OP_SHIFT            = 0xB            # Shift & XCHG Group (1011ssrr)
OP_ROT_INC_DEC      = 0xC            # Rotate, INC, DEC Group (1100ssrr)
OP_JMP_Z            = 0xD            # JMP.Z Rr, Rl (1101rrll)
OP_JMP_M            = 0xE            # JMP.M Rr, Rl (1110rrll)
OP_JMP_SPECIAL      = 0xF            # JMP, LINK, PUSH8, TRAP (1111ssrr)

# Sub-Opcodes for OP_SHIFT (Nibble 0xB, Bits [3:2])
SUB_SHIFT_L         = 0x0            # SHIFT.L: Logical shift left by 1 bit
SUB_SHIFT_R         = 0x1            # SHIFT.R: Logical shift right by 1 bit
SUB_SHIFT_AR        = 0x2            # SHIFT.AR: Arithmetic shift right by 1 bit
SUB_SHIFT_XCHG      = 0x3            # XCHG: Single-cycle shadow register swap

# Sub-Opcodes for OP_ROT_INC_DEC (Nibble 0xC, Bits [3:2])
SUB_ROT_L           = 0x0            # ROT.L: Circular rotate left by 1 bit
SUB_ROT_R           = 0x1            # ROT.R: Circular rotate right by 1 bit
SUB_INC             = 0x2            # INC: Increment register by 1
SUB_DEC             = 0x3            # DEC: Decrement register by 1

# Sub-Opcodes for OP_JMP_SPECIAL (Nibble 0xF, Bits [3:2])
SUB_JMP             = 0x0            # JMP: Unconditional register-indirect branch
SUB_LINK            = 0x1            # LINK: Subroutine call with link (R0 <= PC + 1)
SUB_PUSH8           = 0x2            # PUSH8: Shift left 8 and insert immediate byte
SUB_TRAP            = 0x3            # TRAP: Word-aligned software trap vector lookup

# Register Mapping Table (Case-Insensitive)
REG_NAMES = {
    "R0": 0, "R1": 1, "R2": 2, "R3": 3,
    "r0": 0, "r1": 1, "r2": 2, "r3": 3
}

# ==============================================================================
# Helper Classes for Preprocessing and Errors
# ==============================================================================

class SourceLine:
    """Represents a physical source code line with origin tracking for diagnostics."""
    def __init__(self, text: str, filename: str, line_no: int):
        self.text = text
        self.filename = filename
        self.line_no = line_no

class MacroDef:
    """Holds a parsed macro definition with parameter names and template source lines."""
    def __init__(self, name: str, params: List[str], lines: List[SourceLine]):
        self.name = name.upper()
        self.params = [p.upper() for p in params]
        self.lines = lines

class AssemblerError(Exception):
    """Exception raised for assembler syntax or expression evaluation failures."""
    def __init__(self, msg: str, line: Optional[SourceLine] = None):
        if line:
            super().__init__(f"{line.filename}:{line.line_no}: Error: {msg}")
        else:
            super().__init__(f"Error: {msg}")

# ==============================================================================
# Expression Evaluator & Literal Parser
# ==============================================================================

def strip_comment(text: str) -> str:
    """Strips assembly comments starting with ';' while respecting string literals."""
    in_str = False
    quote_char = ''
    escaped = False
    for i, ch in enumerate(text):
        if in_str:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == quote_char:
                in_str = False
        else:
            if ch in ('"', "'"):
                in_str = True
                quote_char = ch
            elif ch == ';':
                return text[:i]
    return text

def parse_string_literal(literal: str) -> bytes:
    """Parses an escaped string or character literal into bytes."""
    inner = literal[1:-1]
    res = bytearray()
    i = 0
    while i < len(inner):
        if inner[i] == '\\' and i + 1 < len(inner):
            nxt = inner[i + 1]
            if nxt == 'n':   res.append(0x0A)
            elif nxt == 'r': res.append(0x0D)
            elif nxt == 't': res.append(0x09)
            elif nxt == '0': res.append(0x00)
            elif nxt == '\\':res.append(0x5C)
            elif nxt == '"': res.append(0x22)
            elif nxt == "'": res.append(0x27)
            elif nxt == 'x' and i + 3 < len(inner):
                val = int(inner[i + 2:i + 4], 16)
                res.append(val)
                i += 2
            else:
                res.append(ord(nxt))
            i += 2
        else:
            res.append(ord(inner[i]))
            i += 1
    return bytes(res)

def evaluate_expression(expr_str: str, symbols: Dict[str, int], line: SourceLine, pass_num: int = 2) -> int:
    expr_str = expr_str.strip()
    if not expr_str:
        raise AssemblerError("Empty expression", line)

    def sub_numeric(match: re.Match) -> str:
        tok = match.group(0)
        u_tok = tok.upper()
        if tok.startswith("'") and tok.endswith("'"):
            content = parse_string_literal(tok)
            if len(content) != 1:
                raise AssemblerError(f"Invalid character literal: {tok}", line)
            return str(content[0])
        if tok.startswith("$"):
            return str(int(tok[1:], 16))
        if tok.startswith("%"):
            return str(int(tok[1:], 2))
        if tok.startswith("0x") or tok.startswith("0X"):
            return str(int(tok[2:], 16))
        if tok.startswith("0b") or tok.startswith("0B"):
            return str(int(tok[2:], 2))
        if u_tok.endswith("H") and re.match(r"^[0-9A-F]+H$", u_tok):
            return str(int(u_tok[:-1], 16))
        if tok.isdigit():
            return str(int(tok, 10))
        return tok

    num_pattern = re.compile(r"'(?:\\.|[^'\\\\])'|\$[0-9a-fA-F]+|%[01]+|0[xX][0-9a-fA-F]+|0[bB][01]+|\\b[0-9][0-9a-fA-F]*[hH]\\b|\b\d+\b")
    transformed = num_pattern.sub(sub_numeric, expr_str)

    def sub_high(match: re.Match) -> str:
        inner = match.group(1).strip()
        val = evaluate_expression(inner, symbols, line, pass_num)
        return str((val >> 8) & BYTE_MASK)

    def sub_low(match: re.Match) -> str:
        inner = match.group(1).strip()
        val = evaluate_expression(inner, symbols, line, pass_num)
        return str(val & BYTE_MASK)

    transformed = re.sub(r">\s*([A-Za-z0-9_.]+|\([^)]+\))", sub_high, transformed)
    transformed = re.sub(r"<\s*([A-Za-z0-9_.]+|\([^)]+\))", sub_low, transformed)

    for sym in sorted(symbols.keys(), key=len, reverse=True):
        val = symbols[sym]
        pattern = rf"(?<![A-Za-z0-9_.])" + re.escape(sym) + rf"(?![A-Za-z0-9_.])"
        transformed = re.sub(pattern, str(val), transformed, flags=re.IGNORECASE)

    allowed = re.compile(r"^[0-9+\-*/%&|^~()<>\s]+$")
    if not allowed.match(transformed):
        if pass_num == 1:
            return 0
        raise AssemblerError(f"Undefined symbol or invalid expression: '{expr_str}'", line)

    try:
        result = eval(transformed, {"__builtins__": None}, {})
        return int(result)
    except Exception as e:
        if pass_num == 1:
            return 0
        raise AssemblerError(f"Failed to evaluate expression '{expr_str}': {e}", line)

# ==============================================================================
# Macro Preprocessor & File Includer
# ==============================================================================

class Preprocessor:
    def __init__(self, include_dirs: List[str]):
        self.include_dirs = include_dirs
        self.macros: Dict[str, MacroDef] = {}
        self.unique_id = 0

    def resolve_file(self, filename: str, current_file: str) -> str:
        cur_dir = os.path.dirname(os.path.abspath(current_file))
        candidate = os.path.join(cur_dir, filename)
        if os.path.exists(candidate):
            return candidate
        for d in self.include_dirs:
            candidate = os.path.join(d, filename)
            if os.path.exists(candidate):
                return candidate
        raise AssemblerError(f"Included file not found: '{filename}'")

    def run(self, filename: str) -> List[SourceLine]:
        loaded_lines = self._load_file(filename)
        return self._expand_macros(loaded_lines, depth=0)

    def _load_file(self, filename: str) -> List[SourceLine]:
        abs_path = os.path.abspath(filename)
        if not os.path.exists(abs_path):
            raise AssemblerError(f"Source file not found: '{filename}'")

        with open(abs_path, 'r', encoding='utf-8', errors='replace') as f:
            raw_lines = f.readlines()

        source_lines: List[SourceLine] = []
        for line_no, raw_text in enumerate(raw_lines, start=1):
            source_lines.append(SourceLine(raw_text.rstrip('\r\n'), abs_path, line_no))
        return source_lines

    def _expand_macros(self, lines: List[SourceLine], depth: int) -> List[SourceLine]:
        if depth > MAX_MACRO_RECURSION:
            raise AssemblerError(f"Exceeded maximum macro recursion depth of {MAX_MACRO_RECURSION}")

        expanded: List[SourceLine] = []
        i = 0
        while i < len(lines):
            line = lines[i]
            code = strip_comment(line.text).strip()
            if not code:
                expanded.append(line)
                i += 1
                continue

            # Check for file inclusion (.include "file.asm")
            inc_match = re.match(r'^\.INCLUDE\s+["\']([^"\']+)["\']', code, re.IGNORECASE)
            if inc_match:
                inc_filename = inc_match.group(1)
                resolved = self.resolve_file(inc_filename, line.filename)
                inc_lines = self._load_file(resolved)
                expanded_inc = self._expand_macros(inc_lines, depth + 1)
                expanded.extend(expanded_inc)
                i += 1
                continue

            # Check for macro definition (.macro NAME arg1, arg2 ...)
            macro_start_match = re.match(r'^\.MACRO\s+([A-Za-z_][A-Za-z0-9_]*)(.*)$', code, re.IGNORECASE)
            if macro_start_match:
                macro_name = macro_start_match.group(1).upper()
                params_str = macro_start_match.group(2).strip()
                params = [p.strip() for p in params_str.split(',') if p.strip()] if params_str else []

                macro_body: List[SourceLine] = []
                i += 1
                found_end = False
                while i < len(lines):
                    body_line = lines[i]
                    body_code = strip_comment(body_line.text).strip()
                    if body_code.upper() == ".ENDMACRO":
                        found_end = True
                        break
                    macro_body.append(body_line)
                    i += 1

                if not found_end:
                    raise AssemblerError(f"Unterminated macro definition for '{macro_name}'", line)

                self.macros[macro_name] = MacroDef(macro_name, params, macro_body)
                i += 1
                continue

            # Check for macro invocation
            parts = code.split(None, 1)
            first_tok = parts[0].upper()
            if first_tok in self.macros:
                macro = self.macros[first_tok]
                arg_str = parts[1] if len(parts) > 1 else ""
                args = [a.strip() for a in arg_str.split(',')] if arg_str else []

                if len(args) != len(macro.params):
                    raise AssemblerError(
                        f"Macro '{macro.name}' expects {len(macro.params)} arguments, got {len(args)}",
                        line
                    )

                self.unique_id += 1
                unique_tag = f"_M{self.unique_id}"

                instantiated_lines: List[SourceLine] = []
                for template_line in macro.lines:
                    t = template_line.text
                    # Strict parameter substitution: must have leading % and end on word boundary
                    for p, a in zip(macro.params, args):
                        t = re.sub(r"%" + re.escape(p) + r"\b", str(a), t, flags=re.IGNORECASE)
                    # Replace macro-local label suffix % with unique ID
                    t = re.sub(r"%", unique_tag, t)
                    instantiated_lines.append(SourceLine(t, line.filename, line.line_no))
                
                expanded_sub = self._expand_macros(instantiated_lines, depth + 1)
                expanded.extend(expanded_sub)
                i += 1
                continue

            expanded.append(line)
            i += 1

        return expanded

# ==============================================================================
# Assembler Core: Pass 1 & Pass 2
# ==============================================================================

class AssembledItem:
    """Represents a single assembled byte or word emitted into the output image."""
    def __init__(self, line: SourceLine, word_addr: int, slot: int, byte_val: int):
        self.line = line
        self.word_addr = word_addr
        self.slot = slot
        self.byte_val = byte_val

class Assembler:
    def __init__(self, source_lines: List[SourceLine]):
        self.lines = source_lines
        self.symbols: Dict[str, int] = {}
        self.mem_words = 65536
        self.symbols['MEM_WORDS'] = self.mem_words
        self.symbols['MEM_TOP'] = self.mem_words - 1
        self.trap_base = 0x0010
        self.symbols['TRAP_BASE'] = self.trap_base
        self.symbols['CPUID_ADDR'] = 0x000D
        self.symbols['CPUID'] = 0x000D
        self.assembled_items: List[AssembledItem] = []
        self.memory: Dict[int, int] = {}

    def assemble(self):
        # Pass 1: Parse symbols, define constants, determine instruction addresses
        self._run_pass(pass_num=1)
        # Pass 2: Generate exact byte encodings and populate memory map
        self._run_pass(pass_num=2)

    def _run_pass(self, pass_num: int):
        cur_word_addr = 0x0000
        cur_slot = SLOT_0

        def emit_byte(val: int, line: SourceLine):
            nonlocal cur_word_addr, cur_slot
            val &= BYTE_MASK
            if pass_num == 2:
                self.assembled_items.append(AssembledItem(line, cur_word_addr, cur_slot, val))
                existing = self.memory.get(cur_word_addr, 0x0000)
                if cur_slot == SLOT_0:
                    self.memory[cur_word_addr] = (existing & 0xFF00) | val
                else:
                    self.memory[cur_word_addr] = (existing & 0x00FF) | (val << 8)

            if cur_slot == SLOT_0:
                cur_slot = SLOT_1
            else:
                cur_word_addr = (cur_word_addr + 1) & WORD_MASK
                cur_slot = SLOT_0

        def align_to_word(line: SourceLine, pad_with_nop: bool = False):
            """Pads Slot 1 with NOP (0x00) if currently occupying Slot 1."""
            nonlocal cur_slot
            if cur_slot == SLOT_1:
                emit_byte(NOP_BYTE if pad_with_nop else 0x00, line)

        for line in self.lines:
            code = strip_comment(line.text).strip()
            if not code:
                continue

            # Process labels (trailing colon format, e.g. "MY_LABEL:")
            while True:
                label_match = re.match(r'^([A-Za-z_.][A-Za-z0-9_.]*)\s*:(.*)$', code)
                if not label_match:
                    break
                lbl = label_match.group(1).upper()
                code = label_match.group(2).strip()
                # Auto-align label: If currently in Slot 1, pad with NOP
                # so the label address is strictly word-aligned (Slot 0).
                align_to_word(line, pad_with_nop=True)

                if pass_num == 1:
                    if lbl in self.symbols:
                        raise AssemblerError(f"Duplicate symbol definition: '" + lbl + "'", line)
                    self.symbols[lbl] = cur_word_addr
                if not code:
                    break

            if not code:
                continue

            # Tokenize mnemonic and operand tail
            parts = code.split(None, 1)
            mnemonic = parts[0].upper()

            if mnemonic in ("PUSH8", "LINK", "TRAP"):

                if hasattr(self, "slot") and self.slot == 1:

                    self._emit_byte(0x00, line)


                    self._emit_byte(0x00, line)
            operands = parts[1].strip() if len(parts) > 1 else ""

            # ------------------------------------------------------------------
            # Assembler Directives
            # ------------------------------------------------------------------

            if mnemonic == ".ORG":
                val = evaluate_expression(operands, self.symbols, line, pass_num)
                if val < 0 or val >= MEM_WORD_SIZE:
                    raise AssemblerError(f".ORG address out of 16-bit range: {val}", line)
                align_to_word(line, pad_with_nop=False)
                cur_word_addr = val & WORD_MASK
                cur_slot = SLOT_0
                continue

            if mnemonic == ".DEFINE":
                def_parts = operands.split(None, 1)
                if len(def_parts) != 2:
                    raise AssemblerError("Syntax error in .DEFINE directive. Expected: .DEFINE NAME value", line)
                name = def_parts[0].upper()
                val = evaluate_expression(def_parts[1], self.symbols, line, pass_num)
                if pass_num == 1:
                    self.symbols[name] = val
                continue

            if mnemonic == ".ALIGN":
                align_to_word(line, pad_with_nop=True)
                continue

            if mnemonic in (".WORD", ".HEXW"):
                align_to_word(line, pad_with_nop=False)
                words = [w.strip() for w in operands.split(',') if w.strip()]
                for w_expr in words:
                    val = evaluate_expression(w_expr, self.symbols, line, pass_num) & WORD_MASK
                    emit_byte(val & BYTE_MASK, line)
                    emit_byte((val >> 8) & BYTE_MASK, line)
                continue

            if mnemonic == ".BYTE":
                bytes_list = [b.strip() for b in operands.split(',') if b.strip()]
                for b_expr in bytes_list:
                    val = evaluate_expression(b_expr, self.symbols, line, pass_num)
                    if val < 0 or val > 255:
                        raise AssemblerError(f"Byte constant out of range (0-255): {val}", line)
                    emit_byte(val, line)
                continue

            if mnemonic == ".ASCIZ":
                str_match = re.search(r'"([^"\\]|\\.)*"', operands)
                if not str_match:
                    raise AssemblerError('.ASCIZ directive expects string literal enclosed in quotes', line)
                parsed_bytes = parse_string_literal(str_match.group(0))
                for b in parsed_bytes:
                    emit_byte(b, line)
                emit_byte(0x00, line)  # Null terminator
                continue

            if mnemonic == ".HEX":
                hex_tokens = operands.split()
                for tok in hex_tokens:
                    clean_tok = tok.strip()
                    if len(clean_tok) % 2 != 0:
                        clean_tok = "0" + clean_tok
                    for k in range(0, len(clean_tok), 2):
                        emit_byte(int(clean_tok[k:k+2], 16), line)
                continue

            # ------------------------------------------------------------------
            # Instruction Encodings
            # ------------------------------------------------------------------
            ops = [o.strip() for o in operands.split(',') if o.strip()]

            if mnemonic == "NOP":
                emit_byte(NOP_BYTE, line)
                continue

            # LD Instruction Group (Opcodes 0x0 through 0x5)
            if mnemonic == "LD":
                if len(ops) != 2:
                    raise AssemblerError("LD instruction expects 2 operands", line)
                dst, src = ops[0], ops[1]

                # Pre-decrement store: LD (--Rr), Rl (Opcode 0x5, Push)
                predec_match = re.match(r'^\(--([A-Za-z0-9_]+)\)$', dst)
                if predec_match:
                    rr = self._parse_reg(predec_match.group(1), line)
                    rl = self._parse_reg(src, line)
                    emit_byte((OP_LD_PREDEC << 4) | (rr << 2) | rl, line)
                    continue

                # Post-increment load: LD Rr, (Rl++) (Opcode 0x4, Pop)
                postinc_match = re.match(r'^\(([A-Za-z0-9_]+)\+\+\)$', src)
                if postinc_match:
                    rr = self._parse_reg(dst, line)
                    rl = self._parse_reg(postinc_match.group(1), line)
                    emit_byte((OP_LD_POSTINC << 4) | (rr << 2) | rl, line)
                    continue

                # Indirect memory read: LD Rr, (Rl) (Opcode 0x2, Peek)
                peek_match = re.match(r'^\(([A-Za-z0-9_]+)\)$', src)
                if peek_match:
                    rr = self._parse_reg(dst, line)
                    rl = self._parse_reg(peek_match.group(1), line)
                    emit_byte((OP_LD_PEEK << 4) | (rr << 2) | rl, line)
                    continue

                # Indirect memory write: LD (Rr), Rl (Opcode 0x3, Poke)
                poke_match = re.match(r'^\(([A-Za-z0-9_]+)\)$', dst)
                if poke_match:
                    rr = self._parse_reg(poke_match.group(1), line)
                    rl = self._parse_reg(src, line)
                    emit_byte((OP_LD_POKE << 4) | (rr << 2) | rl, line)
                    continue

                # Register-to-register copy: LD Rr, Rl (Opcode 0x0)
                if dst.upper() in REG_NAMES and src.upper() in REG_NAMES:
                    rr = self._parse_reg(dst, line)
                    rl = self._parse_reg(src, line)
                    emit_byte((OP_LD_REG << 4) | (rr << 2) | rl, line)
                    continue

                # Immediate 4-bit load: LD R0, imm4 (Opcode 0x1)
                if dst.upper() == "R0":
                    val = evaluate_expression(src, self.symbols, line, pass_num)
                    if val < 0 or val > 15:
                        raise AssemblerError(f"LD R0 immediate out of range (0-15): {val}", line)
                    emit_byte((OP_LD_IMM4 << 4) | (val & 0x0F), line)
                    continue

                raise AssemblerError(f"Invalid operand combination for LD: '{operands}'", line)

            # ALU Binary Operations (ADD, SUB, OR, XOR, AND)
            alu_map = {
                "ADD": OP_ADD, "SUB": OP_SUB, "OR": OP_OR,
                "XOR": OP_XOR, "AND": OP_AND
            }
            if mnemonic in alu_map:
                if len(ops) != 2:
                    raise AssemblerError(f"{mnemonic} expects 2 register operands", line)
                rr = self._parse_reg(ops[0], line)
                rl = self._parse_reg(ops[1], line)
                emit_byte((alu_map[mnemonic] << 4) | (rr << 2) | rl, line)
                continue

            # Shift & Register Swap Operations (Nibble 0xB)
            if mnemonic == "SHIFT.L":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_SHIFT << 4) | (SUB_SHIFT_L << 2) | rr, line)
                continue

            if mnemonic == "SHIFT.R":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_SHIFT << 4) | (SUB_SHIFT_R << 2) | rr, line)
                continue

            if mnemonic == "SHIFT.AR":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_SHIFT << 4) | (SUB_SHIFT_AR << 2) | rr, line)
                continue

            if mnemonic == "XCHG":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_SHIFT << 4) | (SUB_SHIFT_XCHG << 2) | rr, line)
                continue

            # Rotate & Step Operations (Nibble 0xC)
            if mnemonic == "ROT.L":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_ROT_INC_DEC << 4) | (SUB_ROT_L << 2) | rr, line)
                continue

            if mnemonic == "ROT.R":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_ROT_INC_DEC << 4) | (SUB_ROT_R << 2) | rr, line)
                continue

            if mnemonic == "INC":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_ROT_INC_DEC << 4) | (SUB_INC << 2) | rr, line)
                continue

            if mnemonic == "DEC":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_ROT_INC_DEC << 4) | (SUB_DEC << 2) | rr, line)
                continue

            # Conditional Indirect Branches (Nibbles 0xD and 0xE)
            if mnemonic == "JMP.Z":
                if len(ops) != 2:
                    raise AssemblerError("JMP.Z expects 2 register operands: JMP.Z Rr, Rl", line)
                rr = self._parse_reg(ops[0], line)
                rl = self._parse_reg(ops[1], line)
                emit_byte((OP_JMP_Z << 4) | (rr << 2) | rl, line)
                continue

            if mnemonic == "JMP.M":
                if len(ops) != 2:
                    raise AssemblerError("JMP.M expects 2 register operands: JMP.M Rr, Rl", line)
                rr = self._parse_reg(ops[0], line)
                rl = self._parse_reg(ops[1], line)
                emit_byte((OP_JMP_M << 4) | (rr << 2) | rl, line)
                continue

            # Unconditional Jump (Nibble 0xF, Sub 0x0)
            if mnemonic == "JMP":
                rr = self._parse_reg(self._single_op(ops, line, mnemonic), line)
                emit_byte((OP_JMP_SPECIAL << 4) | (SUB_JMP << 2) | rr, line)
                continue

            # Word-Aligned Call with Link: LINK Rr, R0 (Nibble 0xF, Sub 0x1)
            if mnemonic == "LINK":
                if len(ops) == 2:
                    if ops[1].upper() != "R0":
                        raise AssemblerError("LINK destination register must strictly be R0", line)
                    rr = self._parse_reg(ops[0], line)
                elif len(ops) == 1:
                    rr = self._parse_reg(ops[0], line)
                else:
                    raise AssemblerError("LINK expects: LINK Rr, R0 or LINK Rr", line)

                align_to_word(line, pad_with_nop=True)
                emit_byte((OP_JMP_SPECIAL << 4) | (SUB_LINK << 2) | rr, line)
                emit_byte(NOP_BYTE, line)  # Automatic NOP padding in Slot 1
                continue

            # Word-Aligned Immediate Byte Shift: PUSH8 Rr, const8 (Nibble 0xF, Sub 0x2)
            if mnemonic == "PUSH8":
                if len(ops) != 2:
                    raise AssemblerError("PUSH8 expects: PUSH8 Rr, const8", line)
                rr = self._parse_reg(ops[0], line)
                val8 = evaluate_expression(ops[1], self.symbols, line, pass_num)
                if val8 < 0 or val8 > 255:
                    raise AssemblerError(f"PUSH8 immediate value out of range (0-255): {val8}", line)

                align_to_word(line, pad_with_nop=True)
                emit_byte((OP_JMP_SPECIAL << 4) | (SUB_PUSH8 << 2) | rr, line)
                emit_byte(val8 & BYTE_MASK, line)
                continue

            # Word-Aligned Software Trap: TRAP Rr, val8 (Nibble 0xF, Sub 0x3)
            if mnemonic == "TRAP":
                if len(ops) == 2:
                    rr = self._parse_reg(ops[0], line)
                    val8 = evaluate_expression(ops[1], self.symbols, line, pass_num)
                    if val8 < 0 or val8 > 255:
                        raise AssemblerError(f"TRAP payload byte out of range (0-255): {val8}", line)
                elif len(ops) == 1:
                    rr = self._parse_reg(ops[0], line)
                    val8 = 0x00
                elif len(ops) == 0:
                    rr = 0
                    val8 = 0x00
                else:
                    raise AssemblerError("TRAP expects: TRAP Rr, val8 or TRAP Rr", line)

                align_to_word(line, pad_with_nop=True)
                emit_byte((OP_JMP_SPECIAL << 4) | (SUB_TRAP << 2) | rr, line)
                emit_byte(val8 & BYTE_MASK, line)
                continue

            raise AssemblerError(f"Unrecognized mnemonic or directive: '{mnemonic}'", line)

        # Pad remaining slot at EOF with NOP
        align_to_word(SourceLine("", "", 0), pad_with_nop=True)

    def _parse_reg(self, reg_str: str, line: SourceLine) -> int:
        u = reg_str.upper()
        if u not in REG_NAMES:
            raise AssemblerError(f"Invalid register name: '{reg_str}'. Expected R0, R1, R2, or R3", line)
        return REG_NAMES[u]

    def _single_op(self, ops: List[str], line: SourceLine, mnem: str) -> str:
        if len(ops) != 1:
            raise AssemblerError(f"{mnem} expects exactly 1 register operand", line)
        return ops[0]

# ==============================================================================
# Output Format Generators (.hex, .bin, .lst)
# ==============================================================================

def write_listing(filename: str, assembler: Assembler):
    """Generates an assembly listing mapping addresses, source lines, and hex byte slots."""
    items_by_line: Dict[Tuple[str, int], List[AssembledItem]] = {}
    for item in assembler.assembled_items:
        key = (item.line.filename, item.line.line_no)
        items_by_line.setdefault(key, []).append(item)

    lines_output = []
    lines_output.append("; =============================================================================")
    lines_output.append("; MiniRISC4 Assembler Listing")
    lines_output.append("; ADDR    SOURCE LINE                                ; [HEX]")
    lines_output.append("; =============================================================================")

    for line in assembler.lines:
        code_clean = strip_comment(line.text).strip()
        key = (line.filename, line.line_no)
        items = items_by_line.get(key, [])

        if items:
            w_addr = items[0].word_addr
            hex_bytes = " ".join(f"{it.byte_val:02X}" for it in items)
            lines_output.append(f"{w_addr:04X}    {line.text:<42} ; [{hex_bytes}]")
        else:
            if code_clean:
                lines_output.append(f"        {line.text}")
            else:
                lines_output.append(line.text)

    with open(filename, 'w', encoding='utf-8') as f:
        f.write("\n".join(lines_output) + "\n")

def write_hex(filename: str, memory: Dict[int, int]):
    """Outputs a complete 65,536-line Verilog $readmemh hex initialization file."""
    with open(filename, 'w', encoding='utf-8') as f:
        for addr in range(MEM_WORD_SIZE):
            val = memory.get(addr, 0x0000)
            f.write(f"{val:04X}\n")

def write_binary(filename: str, memory: Dict[int, int], mode: str):
    """
    Outputs binary images to disk low-byte first (Slot 0, then Slot 1):
      - 'bin': from 0x0000 up to highest written address.
      - 'fullbin': entire 64K-word (128 KB) memory space.
      - 'sparsebin': from lowest defined address up to highest written address.
    """
    if not memory:
        min_addr = 0
        max_addr = 0
    else:
        min_addr = min(memory.keys())
        max_addr = max(memory.keys())

    if mode == "fullbin":
        start_addr = 0
        end_addr = MEM_WORD_SIZE - 1
    elif mode == "sparsebin":
        start_addr = min_addr
        end_addr = max_addr
    else:  # mode == "bin"
        start_addr = 0
        end_addr = max_addr

    out_bytes = bytearray()
    for addr in range(start_addr, end_addr + 1):
        w = memory.get(addr, 0x0000)
        out_bytes.append(w & BYTE_MASK)         # Slot 0 (low byte)
        out_bytes.append((w >> 8) & BYTE_MASK)  # Slot 1 (high byte)

    with open(filename, 'wb') as f:
        f.write(out_bytes)

# ==============================================================================
# CLI Entry Point
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="MiniRISC4 Macro Assembler (tools/mr4asm.py)",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("inputs", nargs="+", help="Source assembly file(s) (.asm, .inc)")
    parser.add_argument("-o", "--output", default=None, help="Output filename")
    parser.add_argument("--mem-words", dest="mem_words", default="65536", help="Configured memory capacity in 16-bit words (default: 65536)")
    parser.add_argument("--trap-base", dest="trap_base", default="0x0010", help="Vector table base address (default: 0x0010)")
    parser.add_argument("-l", "--listing", default=None, help="Generate assembly listing file (.lst)")
    parser.add_argument("-I", "--include", action="append", default=["."], help="Add search directory for .include")
    parser.add_argument("--hex", action="store_true", help="Output 64K Verilog $readmemh hex file (.hex)")
    parser.add_argument("--bin", action="store_true", help="Output raw binary from 0 up to highest address")
    parser.add_argument("--fullbin", action="store_true", help="Output complete 64K-word (128 KB) binary")
    parser.add_argument("--sparsebin", action="store_true", help="Output binary from lowest to highest address")

    args = parser.parse_args()

    # Preprocessing: Expand includes and macros across all CLI input files
    prep = Preprocessor(include_dirs=args.include)
    all_source_lines: List[SourceLine] = []

    for fn in args.inputs:
        try:
            expanded = prep.run(fn)
            all_source_lines.extend(expanded)
        except AssemblerError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)

    # Assemble: Run 2-pass assembly
    assembler = Assembler(all_source_lines)
    try:
        assembler.assemble()
    except AssemblerError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Determine default output file and mode
    if args.hex:
        out_file = args.output or "system_image.hex"
        write_hex(out_file, assembler.memory)
    else:
        out_file = args.output
        if not out_file:
            base, _ = os.path.splitext(args.inputs[0])
            out_file = base + ".bin"

        mode = "bin"
        if args.fullbin:
            mode = "fullbin"
        elif args.sparsebin:
            mode = "sparsebin"

        write_binary(out_file, assembler.memory, mode)

    # Generate listing file if requested
    if args.listing:
        write_listing(args.listing, assembler)

    print(f"Assembly completed successfully. Output written to '{out_file}'.")

if __name__ == "__main__":
    main()
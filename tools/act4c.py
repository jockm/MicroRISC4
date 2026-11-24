#!/usr/bin/env python3
"""
act4c.py - Self-contained compiler for the ACT4 systems programming language
targeting the MiniRISC4 16-bit word-addressed processor architecture.
"""

import sys
import os
import re
import argparse
from typing import List, Dict, Optional, Any, Union, Tuple

# ==============================================================================
# Lexer Token Specification
# ==============================================================================

TOKEN_TYPES = [
    ("COMMENT",    r"//[^\n\r]*"),
    ("WHITESPACE", r"[ \t\n\r]+"),
    ("HEX_LIT",    r"0[xX][0-9a-fA-F]+"),
    ("BIN_LIT",    r"0[bB][01]+"),
    ("DEC_LIT",    r"[0-9]+"),
    ("STR_LIT",    r'"([^"\\]|\\.)*"'),
    ("CHAR_LIT",   r"'([^'\\]|\\.)*'"),
    ("ARROW",      r"->"),
    ("LE",         r"<="),
    ("GE",         r">="),
    ("EQ",         r"=="),
    ("NE",         r"!="),
    ("SHL_ASSIGN", r"<<="),
    ("SHR_ASSIGN", r">>="),
    ("SHL",        r"<<"),
    ("SHR",        r">>"),
    ("LOG_AND",    r"&&"),
    ("LOG_OR",     r"\|\|"),
    ("INC",        r"\+\+"),
    ("DEC",        r"--"),
    ("ADD_ASSIGN", r"\+="),
    ("SUB_ASSIGN", r"-="),
    ("MUL_ASSIGN", r"\*="),
    ("DIV_ASSIGN", r"/="),
    ("MOD_ASSIGN", r"%="),
    ("AND_ASSIGN", r"&="),
    ("OR_ASSIGN",  r"\|="),
    ("XOR_ASSIGN", r"\^="),
    ("ASSIGN",     r"="),
    ("LT",         r"<"),
    ("GT",         r">"),
    ("PLUS",       r"\+"),
    ("MINUS",      r"-"),
    ("STAR",       r"\*"),
    ("SLASH",      r"/"),
    ("PERCENT",    r"%"),
    ("AMP",        r"&"),
    ("PIPE",       r"\|"),
    ("CARET",      r"\^"),
    ("TILDE",      r"~"),
    ("BANG",       r"!"),
    ("AT",         r"@"),
    ("DOT",        r"\."),
    ("LPAREN",     r"\("),
    ("RPAREN",     r"\)"),
    ("LBRACE",     r"\{"),
    ("RBRACE",     r"\}"),
    ("LBRACKET",   r"\["),
    ("RBRACKET",   r"\]"),
    ("COMMA",      r","),
    ("COLON",      r":"),
    ("SEMI",       r";"),
    ("IDENT",      r"[A-Za-z_][A-Za-z0-9_]*"),
]

KEYWORDS = {
    "u16", "void", "type", "func", "const", "if", "else", "while",
    "return", "break", "continue", "asm", "trap", "sizeof", "import",
    "getbyte", "setbyte", "true", "false"
}

class Token:
    def __init__(self, typ: str, val: str, line: int, col: int, filename: str):
        self.type = typ
        self.value = val
        self.line = line
        self.col = col
        self.filename = filename

    def __repr__(self):
        return f"Token({self.type}, {repr(self.value)}, L{self.line}:C{self.col})"

class CompilerError(Exception):
    def __init__(self, msg: str, tok: Optional[Token] = None, filename: str = "", line: int = 0):
        if tok:
            super().__init__(f"{tok.filename}:{tok.line}:{tok.col}: error: {msg}")
        elif filename and line:
            super().__init__(f"{filename}:{line}: error: {msg}")
        else:
            super().__init__(f"error: {msg}")

def tokenize(code: str, filename: str) -> List[Token]:
    tokens = []
    line_num = 1
    line_start = 0
    token_regex = "|".join(f"(?P<{pair[0]}>{pair[1]})" for pair in TOKEN_TYPES)
    compiled_re = re.compile(token_regex)

    for mo in compiled_re.finditer(code):
        typ = mo.lastgroup
        val = mo.group(typ)
        start = mo.start()
        col = start - line_start + 1
        num_newlines = val.count('\n')
        if num_newlines > 0:
            line_num += num_newlines
            line_start = mo.end() - (len(val) - val.rfind('\n') - 1)

        if typ == "WHITESPACE":
            continue
        elif typ == "COMMENT":
            tokens.append(Token("COMMENT", val, line_num - num_newlines, col, filename))
        elif typ == "IDENT":
            if val in KEYWORDS:
                tokens.append(Token(val.upper(), val, line_num - num_newlines, col, filename))
            else:
                tokens.append(Token("IDENT", val, line_num - num_newlines, col, filename))
        else:
            tokens.append(Token(typ, val, line_num - num_newlines, col, filename))

    tokens.append(Token("EOF", "", line_num, 1, filename))
    return tokens

# ==============================================================================
# AST Definitions
# ==============================================================================

class ASTNode:
    pass

class TypeDesc:
    def __init__(self, base_type: str, is_pointer: bool = False, array_size: Optional[int] = None,
                 is_func_ptr: bool = False, func_params: List['TypeDesc'] = None, func_ret: Optional['TypeDesc'] = None):
        self.base_type = base_type
        self.is_pointer = is_pointer
        self.array_size = array_size
        self.is_func_ptr = is_func_ptr
        self.func_params = func_params or []
        self.func_ret = func_ret

    def word_size(self, structs: Dict[str, 'StructDef']) -> int:
        if self.is_pointer or self.is_func_ptr:
            sz = 1
        elif self.base_type == 'u16':
            sz = 1
        elif self.base_type == 'void':
            sz = 0
        elif self.base_type in structs:
            sz = structs[self.base_type].word_size
        else:
            sz = 1
        if self.array_size is not None:
            return sz * self.array_size
        return sz

    def __repr__(self):
        s = self.base_type
        if self.is_pointer:
            s += "*"
        if self.array_size is not None:
            s += f"[{self.array_size}]"
        return s

class StructDef:
    def __init__(self, name: str, fields: List[Tuple[str, TypeDesc, int]], structs: Optional[Dict[str, 'StructDef']] = None):
        self.name = name
        self.fields = fields
        self.word_size = sum(f[1].word_size(structs or {}) for f in fields)

class VarDecl(ASTNode):
    def __init__(self, name: str, typ: TypeDesc, init_expr: Optional[Any] = None,
                 address: Optional[int] = None, is_const: bool = False,
                 array_inits: Optional[List[Any]] = None):
        self.name = name
        self.typ = typ
        self.init_expr = init_expr
        self.address = address
        self.is_const = is_const
        self.array_inits = array_inits

class FunctionDef(ASTNode):
    def __init__(self, name: str, ret_type: TypeDesc, params: List[Tuple[str, TypeDesc]],
                 locals_decls: List[VarDecl], body: List[ASTNode], trap_vector: Optional[int] = None):
        self.name = name
        self.ret_type = ret_type
        self.params = params
        self.locals_decls = locals_decls
        self.body = body
        self.trap_vector = trap_vector  # 0..15 if bound via @ trap(N)

class AsmBlock(ASTNode):
    def __init__(self, asm_text: str):
        self.asm_text = asm_text

class TrapStmt(ASTNode):
    def __init__(self, vector_expr: Any, data_byte: int):
        self.vector_expr = vector_expr
        self.data_byte = data_byte

class IfStmt(ASTNode):
    def __init__(self, cond: Any, then_block: List[ASTNode], else_block: Optional[List[ASTNode]] = None):
        self.cond = cond
        self.then_block = then_block
        self.else_block = else_block

class WhileStmt(ASTNode):
    def __init__(self, cond: Any, body: List[ASTNode]):
        self.cond = cond
        self.body = body

class ReturnStmt(ASTNode):
    def __init__(self, expr: Optional[Any] = None):
        self.expr = expr

class BreakStmt(ASTNode):
    pass

class ContinueStmt(ASTNode):
    pass

class AssignStmt(ASTNode):
    def __init__(self, target: Any, op: str, value: Any):
        self.target = target
        self.op = op
        self.value = value

class SetByteStmt(ASTNode):
    def __init__(self, base_expr: Any, index_expr: Any, val_expr: Any):
        self.base_expr = base_expr
        self.index_expr = index_expr
        self.val_expr = val_expr

class CallStmt(ASTNode):
    def __init__(self, call_expr: Any):
        self.call_expr = call_expr

class CommentNode(ASTNode):
    def __init__(self, text: str):
        self.text = text

class IncDecStmt(ASTNode):
    def __init__(self, target: Any, op: str, is_postfix: bool):
        self.target = target
        self.op = op
        self.is_postfix = is_postfix

# --- Expression Nodes ---

class Expr(ASTNode):
    pass

class IntLit(Expr):
    def __init__(self, val: int):
        self.val = val & 0xFFFF

class StrLit(Expr):
    def __init__(self, text: str, label: str = ""):
        self.text = text
        self.label = label

class VarRef(Expr):
    def __init__(self, name: str):
        self.name = name

class UnaryOp(Expr):
    def __init__(self, op: str, operand: Expr):
        self.op = op
        self.operand = operand

class BinaryOp(Expr):
    def __init__(self, op: str, lhs: Expr, rhs: Expr):
        self.op = op
        self.lhs = lhs
        self.rhs = rhs

class MemberAccess(Expr):
    def __init__(self, target: Expr, member: str, is_arrow: bool = False):
        self.target = target
        self.member = member
        self.is_arrow = is_arrow

class IndexAccess(Expr):
    def __init__(self, target: Expr, index: Expr):
        self.target = target
        self.index = index

class CallExpr(Expr):
    def __init__(self, callee: Expr, args: List[Expr]):
        self.callee = callee
        self.args = args

class GetByteExpr(Expr):
    def __init__(self, base_expr: Expr, index_expr: Expr):
        self.base_expr = base_expr
        self.index_expr = index_expr

# ==============================================================================
# Recursive Descent Parser
# ==============================================================================

class Parser:
    def __init__(self, tokens: List[Token], structs: Dict[str, StructDef], constants: Dict[str, int],
                 str_dedup: Optional[Dict[str, str]] = None):
        self.tokens = tokens
        self.pos = 0
        self.structs = structs
        self.constants = constants
        self.string_literals: List[Tuple[str, str]] = []
        self.str_dedup: Dict[str, str] = str_dedup if str_dedup is not None else {}
        self.str_count = 0

    def cur(self) -> Token:
        return self.tokens[self.pos]

    def peek(self, offset: int = 1) -> Token:
        idx = self.pos + offset
        if idx < len(self.tokens):
            return self.tokens[idx]
        return self.tokens[-1]

    def match(self, *expected_types: str) -> bool:
        return self.cur().type in expected_types

    def consume(self, expected_type: str, msg: str = "") -> Token:
        tok = self.cur()
        if tok.type != expected_type:
            raise CompilerError(msg or f"Expected {expected_type}, got {tok.type} ('{tok.value}')", tok)
        self.pos += 1
        return tok

    def parse_program(self) -> List[ASTNode]:
        nodes = []
        while not self.match("EOF"):
            if self.match("COMMENT"):
                nodes.append(CommentNode(self.consume("COMMENT").value))
            elif self.match("TYPE"):
                self.parse_type_def()
            elif self.match("CONST"):
                nodes.append(self.parse_const_decl())
            elif self.match("U16", "VOID") or (self.match("IDENT") and (self.cur().value in self.structs or self.peek(1).type in ("IDENT", "STAR"))) or self.match("FUNC"):
                node = self.parse_top_level_decl()
                if node:
                    nodes.append(node)
            elif self.match("IMPORT"):
                self.consume("IMPORT")
                self.consume("STR_LIT")
                self.consume("SEMI")
            else:
                raise CompilerError(f"Unexpected token at top level: {self.cur().value}", self.cur())
        return nodes

    def parse_type_def(self):
        self.consume("TYPE")
        name_tok = self.consume("IDENT", "Expected struct name after 'type'")
        self.consume("LBRACE")
        fields = []
        offset = 0
        while not self.match("RBRACE"):
            if self.match("COMMENT"):
                self.consume("COMMENT")
                continue
            ftype = self.parse_type()
            fname_tok = self.consume("IDENT")
            if self.match("LBRACKET"):
                self.consume("LBRACKET")
                size_expr = self.parse_expr()
                self.consume("RBRACKET")
                sz = self.eval_const(size_expr)
                ftype.array_size = sz
            self.consume("SEMI")
            fields.append((fname_tok.value, ftype, offset))
            offset += ftype.word_size(self.structs)
        self.consume("RBRACE")
        self.consume("SEMI")
        self.structs[name_tok.value] = StructDef(name_tok.value, fields, self.structs)

    def parse_const_decl(self) -> VarDecl:
        self.consume("CONST")
        typ = self.parse_type()
        name_tok = self.consume("IDENT")
        self.consume("ASSIGN")
        init_expr = self.parse_expr()
        self.consume("SEMI")
        val = self.eval_const(init_expr)
        self.constants[name_tok.value] = val
        return VarDecl(name_tok.value, typ, IntLit(val), is_const=True)

    def parse_type(self) -> TypeDesc:
        if self.match("FUNC"):
            self.consume("FUNC")
            self.consume("LPAREN")
            param_types = []
            if not self.match("RPAREN"):
                if self.match("VOID") and self.peek(1).type == "RPAREN":
                    self.consume("VOID")
                else:
                    while True:
                        param_types.append(self.parse_type())
                        if self.match("COMMA"):
                            self.consume("COMMA")
                        else:
                            break
            self.consume("RPAREN")
            self.consume("COLON")
            ret_type = self.parse_type()
            return TypeDesc("func", is_func_ptr=True, func_params=param_types, func_ret=ret_type)

        base = "u16"
        if self.match("U16"):
            self.consume("U16")
            base = "u16"
        elif self.match("VOID"):
            self.consume("VOID")
            base = "void"
        elif self.match("IDENT") and (self.cur().value in self.structs or self.peek(1).type in ("IDENT", "STAR")):
            base = self.consume("IDENT").value
        else:
            raise CompilerError(f"Expected type specifier, got {self.cur().value}", self.cur())

        is_ptr = False
        if self.match("STAR"):
            self.consume("STAR")
            is_ptr = True
        return TypeDesc(base, is_pointer=is_ptr)

    def parse_top_level_decl(self) -> Optional[ASTNode]:
        typ = self.parse_type()

        if typ.is_func_ptr:
            if self.match("STAR"):
                self.consume("STAR")
            name_tok = self.consume("IDENT")
            init_expr = None
            if self.match("ASSIGN"):
                self.consume("ASSIGN")
                init_expr = self.parse_expr()
            self.consume("SEMI")
            return VarDecl(name_tok.value, typ, init_expr)

        name_tok = self.consume("IDENT")

        if self.match("LPAREN"):
            return self.parse_function(typ, name_tok.value)

        return self.parse_var_decl_tail(typ, name_tok.value)

    def parse_var_decl_tail(self, typ: TypeDesc, name: str) -> VarDecl:
        arr_size = None
        array_inits = None
        addr = None
        init_expr = None

        if self.match("LBRACKET"):
            self.consume("LBRACKET")
            if not self.match("RBRACKET"):
                sz_expr = self.parse_expr()
                arr_size = self.eval_const(sz_expr)
            self.consume("RBRACKET")
            typ.array_size = arr_size

        if self.match("AT"):
            self.consume("AT")
            addr_expr = self.parse_expr()
            addr = self.eval_const(addr_expr)

        if self.match("ASSIGN"):
            self.consume("ASSIGN")
            if self.match("LBRACE"):
                self.consume("LBRACE")
                array_inits = []
                while not self.match("RBRACE"):
                    array_inits.append(self.parse_expr())
                    if self.match("COMMA"):
                        self.consume("COMMA")
                    else:
                        break
                self.consume("RBRACE")
                if typ.array_size is None:
                    typ.array_size = len(array_inits)
            else:
                init_expr = self.parse_expr()

        self.consume("SEMI")
        return VarDecl(name, typ, init_expr=init_expr, address=addr, array_inits=array_inits)

    def parse_function(self, ret_type: TypeDesc, name: str) -> FunctionDef:
        self.consume("LPAREN")
        params = []
        if self.match("VOID") and self.peek(1).type == "RPAREN":
            self.consume("VOID")
        elif not self.match("RPAREN"):
            while True:
                ptyp = self.parse_type()
                pname_tok = self.consume("IDENT")
                if self.match("LBRACKET"):
                    self.consume("LBRACKET")
                    self.consume("RBRACKET")
                    ptyp.is_pointer = True
                params.append((pname_tok.value, ptyp))
                if self.match("COMMA"):
                    self.consume("COMMA")
                else:
                    break
        self.consume("RPAREN")

        trap_vec = None
        if self.match("AT"):
            self.consume("AT")
            self.consume("TRAP", "Expected 'trap' after '@' in function attribute")
            self.consume("LPAREN")
            vec_expr = self.parse_expr()
            self.consume("RPAREN")
            trap_vec = self.eval_const(vec_expr)
            if trap_vec < 0 or trap_vec > 15:
                raise CompilerError(f"Trap vector must be between 0 and 15, got {trap_vec}", self.cur())
            if params:
                raise CompilerError(f"Trap routine '{name}' cannot take parameters", self.cur())
            if ret_type.base_type != "void" or ret_type.is_pointer:
                raise CompilerError(f"Trap routine '{name}' must return void", self.cur())

        self.consume("LBRACE")

        locals_decls = []
        body = []

        while not self.match("RBRACE"):
            if self.match("COMMENT"):
                body.append(CommentNode(self.consume("COMMENT").value))
                continue
            if self.is_decl_start():
                dtyp = self.parse_type()
                if dtyp.is_func_ptr:
                    if self.match("STAR"):
                        self.consume("STAR")
                    dname_tok = self.consume("IDENT")
                    init_expr = None
                    if self.match("ASSIGN"):
                        self.consume("ASSIGN")
                        init_expr = self.parse_expr()
                    self.consume("SEMI")
                    decl = VarDecl(dname_tok.value, dtyp, init_expr)
                else:
                    dname_tok = self.consume("IDENT")
                    decl = self.parse_var_decl_tail(dtyp, dname_tok.value)
                locals_decls.append(decl)
            else:
                body.append(self.parse_stmt())

        self.consume("RBRACE")
        return FunctionDef(name, ret_type, params, locals_decls, body, trap_vector=trap_vec)

    def is_decl_start(self) -> bool:
        if self.match("U16", "VOID", "FUNC"):
            return True
        if self.match("IDENT") and (self.cur().value in self.structs or self.peek(1).type in ("IDENT", "STAR")):
            return True
        return False

    def parse_stmt(self) -> ASTNode:
        if self.match("COMMENT"):
            return CommentNode(self.consume("COMMENT").value)
        if self.match("IF"):
            return self.parse_if()
        if self.match("WHILE"):
            return self.parse_while()
        if self.match("RETURN"):
            return self.parse_return()
        if self.match("BREAK"):
            self.consume("BREAK")
            self.consume("SEMI")
            return BreakStmt()
        if self.match("CONTINUE"):
            self.consume("CONTINUE")
            self.consume("SEMI")
            return ContinueStmt()
        if self.match("ASM"):
            return self.parse_asm()
        if self.match("TRAP"):
            return self.parse_trap()
        if self.match("SETBYTE"):
            return self.parse_setbyte()

        if self.match("INC", "DEC"):
            op_tok = self.consume(self.cur().type)
            target = self.parse_unary_or_postfix()
            self.consume("SEMI")
            return IncDecStmt(target, op_tok.value, is_postfix=False)

        expr = self.parse_unary_or_postfix()

        if self.match("INC", "DEC"):
            op_tok = self.consume(self.cur().type)
            self.consume("SEMI")
            return IncDecStmt(expr, op_tok.value, is_postfix=True)

        assign_ops = ["ASSIGN", "ADD_ASSIGN", "SUB_ASSIGN", "MUL_ASSIGN", "DIV_ASSIGN",
                      "MOD_ASSIGN", "AND_ASSIGN", "OR_ASSIGN", "XOR_ASSIGN", "SHL_ASSIGN", "SHR_ASSIGN"]
        if self.match(*assign_ops):
            op_tok = self.consume(self.cur().type)
            val_expr = self.parse_expr()
            self.consume("SEMI")
            return AssignStmt(expr, op_tok.value, val_expr)

        if isinstance(expr, CallExpr):
            self.consume("SEMI")
            return CallStmt(expr)

        raise CompilerError(f"Invalid statement expression: {expr}", self.cur())

    def parse_if(self) -> IfStmt:
        self.consume("IF")
        self.consume("LPAREN")
        cond = self.parse_expr()
        self.consume("RPAREN")
        self.consume("LBRACE")
        then_block = []
        while not self.match("RBRACE"):
            then_block.append(self.parse_stmt())
        self.consume("RBRACE")

        else_block = None
        if self.match("ELSE"):
            self.consume("ELSE")
            if self.match("IF"):
                else_block = [self.parse_if()]
            else:
                self.consume("LBRACE")
                else_block = []
                while not self.match("RBRACE"):
                    else_block.append(self.parse_stmt())
                self.consume("RBRACE")
        return IfStmt(cond, then_block, else_block)

    def parse_while(self) -> WhileStmt:
        self.consume("WHILE")
        self.consume("LPAREN")
        cond = self.parse_expr()
        self.consume("RPAREN")
        self.consume("LBRACE")
        body = []
        while not self.match("RBRACE"):
            body.append(self.parse_stmt())
        self.consume("RBRACE")
        return WhileStmt(cond, body)

    def parse_return(self) -> ReturnStmt:
        self.consume("RETURN")
        expr = None
        if not self.match("SEMI"):
            expr = self.parse_expr()
        self.consume("SEMI")
        return ReturnStmt(expr)

    def parse_asm(self) -> AsmBlock:
        self.consume("ASM")
        self.consume("LBRACE")
        stmts = []
        cur_parts = []
        line_starters = {
            "NOP", "LD", "ADD", "SUB", "OR", "XOR", "AND",
            "SHIFT.L", "SHIFT.R", "SHIFT.AR", "XCHG", "XCHGALL",
            "ROT.L", "ROT.R", "INC", "DEC",
            "JMP.Z", "JMP.M", "JMP", "LINK", "PUSH8", "TRAP",
            "APUSH", "APOP", "RPUSH", "RPOP", "RCALL", "RRET",
            "PUSHALL", "POPALL", "SWAP", "LD0", "NOT", "NEG",
            "BYTE_GET_LO", "BYTE_GET_HI", "PUTC", "GETC",
            "START_PROGRAM", "LOAD16",
            ".ORG", ".DEFINE", ".WORD", ".BYTE", ".ASCIZ", ".ALIGN"
        }
        while not self.match("RBRACE"):
            tok = self.tokens[self.pos]
            self.pos += 1
            if tok.type == "COMMENT":
                continue
            u = tok.value.upper()
            if u in line_starters and cur_parts:
                stmts.append(" ".join(cur_parts).replace("( ", "(").replace(" )", ")"))
                cur_parts = [tok.value]
            elif tok.type == "COMMA" and cur_parts:
                cur_parts[-1] = cur_parts[-1] + ","
            else:
                cur_parts.append(tok.value)
        if cur_parts:
            stmts.append(" ".join(cur_parts).replace("( ", "(").replace(" )", ")"))
        self.consume("RBRACE")
        return AsmBlock("\n".join(stmts))
    def parse_trap(self) -> TrapStmt:
        self.consume("TRAP")
        self.consume("LPAREN")
        vec_expr = self.parse_expr()
        self.consume("COMMA")
        data_expr = self.parse_expr()
        self.consume("RPAREN")
        self.consume("SEMI")
        data_byte = self.eval_const(data_expr) & 0xFF
        return TrapStmt(vec_expr, data_byte)

    def parse_setbyte(self) -> SetByteStmt:
        self.consume("SETBYTE")
        self.consume("LPAREN")
        base = self.parse_expr()
        self.consume("COMMA")
        idx = self.parse_expr()
        self.consume("COMMA")
        val = self.parse_expr()
        self.consume("RPAREN")
        self.consume("SEMI")
        return SetByteStmt(base, idx, val)

    def parse_expr(self) -> Expr:
        return self.parse_logical_or()

    def parse_logical_or(self) -> Expr:
        lhs = self.parse_logical_and()
        while self.match("LOG_OR"):
            op = self.consume("LOG_OR").value
            rhs = self.parse_logical_and()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_logical_and(self) -> Expr:
        lhs = self.parse_bitwise_or()
        while self.match("LOG_AND"):
            op = self.consume("LOG_AND").value
            rhs = self.parse_bitwise_or()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_bitwise_or(self) -> Expr:
        lhs = self.parse_bitwise_xor()
        while self.match("PIPE"):
            op = self.consume("PIPE").value
            rhs = self.parse_bitwise_xor()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_bitwise_xor(self) -> Expr:
        lhs = self.parse_bitwise_and()
        while self.match("CARET"):
            op = self.consume("CARET").value
            rhs = self.parse_bitwise_and()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_bitwise_and(self) -> Expr:
        lhs = self.parse_equality()
        while self.match("AMP"):
            op = self.consume("AMP").value
            rhs = self.parse_equality()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_equality(self) -> Expr:
        lhs = self.parse_relational()
        while self.match("EQ", "NE"):
            op = self.consume(self.cur().type).value
            rhs = self.parse_relational()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_relational(self) -> Expr:
        lhs = self.parse_shift()
        while self.match("LT", "GT", "LE", "GE"):
            op = self.consume(self.cur().type).value
            rhs = self.parse_shift()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_shift(self) -> Expr:
        lhs = self.parse_additive()
        while self.match("SHL", "SHR"):
            op = self.consume(self.cur().type).value
            rhs = self.parse_additive()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_additive(self) -> Expr:
        lhs = self.parse_multiplicative()
        while self.match("PLUS", "MINUS"):
            op = self.consume(self.cur().type).value
            rhs = self.parse_multiplicative()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_multiplicative(self) -> Expr:
        lhs = self.parse_unary_or_postfix()
        while self.match("STAR", "SLASH", "PERCENT"):
            op = self.consume(self.cur().type).value
            rhs = self.parse_unary_or_postfix()
            lhs = BinaryOp(op, lhs, rhs)
        return lhs

    def parse_unary_or_postfix(self) -> Expr:
        if self.match("MINUS", "TILDE", "BANG", "STAR", "AMP"):
            op_tok = self.consume(self.cur().type)
            operand = self.parse_unary_or_postfix()
            return UnaryOp(op_tok.value, operand)

        expr = self.parse_primary()
        while True:
            if self.match("LBRACKET"):
                self.consume("LBRACKET")
                idx = self.parse_expr()
                self.consume("RBRACKET")
                expr = IndexAccess(expr, idx)
            elif self.match("DOT"):
                self.consume("DOT")
                mem_tok = self.consume("IDENT")
                expr = MemberAccess(expr, mem_tok.value, is_arrow=False)
            elif self.match("ARROW"):
                self.consume("ARROW")
                mem_tok = self.consume("IDENT")
                expr = MemberAccess(expr, mem_tok.value, is_arrow=True)
            elif self.match("LPAREN"):
                self.consume("LPAREN")
                args = []
                if not self.match("RPAREN"):
                    while True:
                        args.append(self.parse_expr())
                        if self.match("COMMA"):
                            self.consume("COMMA")
                        else:
                            break
                self.consume("RPAREN")
                expr = CallExpr(expr, args)
            else:
                break
        return expr

    def parse_primary(self) -> Expr:
        if self.match("GETBYTE"):
            self.consume("GETBYTE")
            self.consume("LPAREN")
            b_expr = self.parse_expr()
            self.consume("COMMA")
            i_expr = self.parse_expr()
            self.consume("RPAREN")
            return GetByteExpr(b_expr, i_expr)

        if self.match("SIZEOF"):
            self.consume("SIZEOF")
            self.consume("LPAREN")
            typ = self.parse_type()
            self.consume("RPAREN")
            return IntLit(typ.word_size(self.structs))

        if self.match("TRUE"):
            self.consume("TRUE")
            return IntLit(1)
        if self.match("FALSE"):
            self.consume("FALSE")
            return IntLit(0)

        if self.match("DEC_LIT"):
            v = int(self.consume("DEC_LIT").value, 10)
            return IntLit(v)
        if self.match("HEX_LIT"):
            v = int(self.consume("HEX_LIT").value, 16)
            return IntLit(v)
        if self.match("BIN_LIT"):
            v = int(self.consume("BIN_LIT").value, 2)
            return IntLit(v)
        if self.match("CHAR_LIT"):
            s = self.consume("CHAR_LIT").value[1:-1]
            return IntLit(ord(s.encode().decode('unicode_escape')[0]))
        if self.match("STR_LIT"):
            s = self.consume("STR_LIT").value[1:-1]
            if s in self.str_dedup:
                return StrLit(s, label=self.str_dedup[s])
            lbl = f"_str_lit_{self.str_count}"
            self.str_count += 1
            self.str_dedup[s] = lbl
            self.string_literals.append((lbl, s))
            return StrLit(s, label=lbl)

        if self.match("IDENT"):
            name = self.consume("IDENT").value
            if name in self.constants:
                return IntLit(self.constants[name])
            return VarRef(name)

        if self.match("LPAREN"):
            self.consume("LPAREN")
            e = self.parse_expr()
            self.consume("RPAREN")
            return e

        raise CompilerError(f"Unexpected token in expression: {self.cur().value}", self.cur())

    def eval_const(self, node: Any) -> int:
        if isinstance(node, IntLit):
            return node.val
        if isinstance(node, VarRef) and node.name in self.constants:
            return self.constants[node.name]
        if isinstance(node, UnaryOp):
            val = self.eval_const(node.operand)
            if node.op == '-': return (-val) & 0xFFFF
            if node.op == '~': return (~val) & 0xFFFF
            if node.op == '!': return 1 if val == 0 else 0
        if isinstance(node, BinaryOp):
            l = self.eval_const(node.lhs)
            r = self.eval_const(node.rhs)
            if node.op == '+': return (l + r) & 0xFFFF
            if node.op == '-': return (l - r) & 0xFFFF
            if node.op == '*': return (l * r) & 0xFFFF
            if node.op == '/': return (l // r) & 0xFFFF if r != 0 else 0xFFFF
            if node.op == '%': return (l % r) & 0xFFFF if r != 0 else 0
            if node.op == '&': return (l & r) & 0xFFFF
            if node.op == '|': return (l | r) & 0xFFFF
            if node.op == '^': return (l ^ r) & 0xFFFF
            if node.op == '<<': return (l << r) & 0xFFFF
            if node.op == '>>': return (l >> r) & 0xFFFF
        raise CompilerError(f"Expression is not a constant: {node}")

# ==============================================================================
# Assembly Code Generator
# ==============================================================================

class CodeGen:
    def __init__(self, ast: List[ASTNode], structs: Dict[str, StructDef], constants: Dict[str, int],
                 string_literals: List[Tuple[str, str]], org: int = 0x0200, no_preamble: bool = False,
                 hw_math: bool = False):
        self.ast = ast
        self.structs = structs
        self.constants = constants
        self.string_literals = string_literals
        self.org = org
        self.no_preamble = no_preamble
        self.hw_math = hw_math
        self.asm: List[str] = []
        self.label_counter = 0

        self.global_vars: Dict[str, VarDecl] = {}
        self.functions: Dict[str, FunctionDef] = {}
        self.current_func: Optional[FunctionDef] = None
        self.loop_stack: List[Tuple[str, str]] = []
        self.trap_bindings: Dict[int, str] = {}
        self.bss_entries: List[Tuple[str, int]] = []

    def new_label(self, prefix: str = "L") -> str:
        self.label_counter += 1
        return f"_{prefix}_{self.label_counter}"

    def emit(self, instruction: str):
        self.asm.append(f"    {instruction}")

    def emit_raw(self, line: str):
        self.asm.append(line)

    def generate(self) -> str:
        for node in self.ast:
            if isinstance(node, VarDecl):
                self.global_vars[node.name] = node
            elif isinstance(node, FunctionDef):
                self.functions[node.name] = node
                if node.trap_vector is not None:
                    if node.trap_vector in self.trap_bindings:
                        raise CompilerError(f"Trap vector {node.trap_vector} bound multiple times")
                    self.trap_bindings[node.trap_vector] = node.name

        self.emit_raw("; ==============================================================================")
        self.emit_raw("; Compiled by ACT4 MiniRISC4 Compiler (act4c)")
        self.emit_raw("; Target: MiniRISC4 16-bit Architecture")
        self.emit_raw("; ==============================================================================")
        self.emit_raw('.include "common.inc"')
        self.emit_raw("")

        for name, val in self.constants.items():
            self.emit_raw(f".define {name} 0x{val:04X}")
        self.emit_raw("")

        # Direct Stride Vector Table (0x0100 - 0x01FF)
        if not self.no_preamble:
            self.emit_raw("; ==============================================================================")
            self.emit_raw("; Hardware Direct Stride Vector Table (0x0100 - 0x01FF)")
            self.emit_raw("; Fixed 16-word (32-byte) stride per vector slot")
            self.emit_raw("; ==============================================================================")
            self.emit_raw(".org 0x0100")
            self.emit_raw("_reset_slot:")
            self.emit("START_PROGRAM")

            for vec in range(1, 16):
                slot_addr = 0x0100 + (vec * 16)
                self.emit_raw(f"\n.org 0x{slot_addr:04X}")
                self.emit_raw(f"_trap_{vec}_slot:")
                if vec in self.trap_bindings:
                    fn_name = self.trap_bindings[vec]
                    self.emit("RPUSH   R0")
                    self.emit(f"LOAD16  R0, _{fn_name}")
                    self.emit("JMP     R0")
                else:
                    self.emit("JMP     R0")
            self.emit_raw("")

        # Application Code & Global Data (0x0200 or user --org)
        self.emit_raw("; ==============================================================================")
        self.emit_raw(f"; Application Code & Global Storage (Origin 0x{self.org:04X})")
        self.emit_raw("; ==============================================================================")
        self.emit_raw(f".org 0x{self.org:04X}")
        self.emit_raw("")

        if self.no_preamble and "main" in self.functions:
            # Place a 3-word entry trampoline at --org so external loaders
            # (e.g. worker_stub.asm LINK to APP_LOAD_ADDR) enter _main while
            # preserving caller return address in R0.
            self.emit_raw("_entry:")
            self.emit("LOAD16  R1, _main")
            self.emit("JMP     R1")
            self.emit_raw("")

        # Dead-function elimination: when `main` exists, only emit functions
        # reachable from `main`, bound `@ trap(N)` ISRs, or global initializers.
        reachable = self.compute_reachable_functions()

        # Generate Functions
        for node in self.ast:
            if isinstance(node, FunctionDef):
                if reachable is None or node.name in reachable:
                    self.gen_function(node)

        # Self-contained runtime .bss zero-fill helper (called once at _main entry)
        if "main" in self.functions:
            self.emit_raw("; --- Runtime BSS Zero-Init Helper ---")
            self.emit_raw("_act4_zero_bss:")
            self.emit("RPUSH   R0")
            self.emit("LOAD16  R2, _act4_bss_start")
            self.emit("LOAD16  R3, _act4_bss_end")
            self.emit("SUB     R3, R2")
            self.emit("LOAD16  R0, _act4_zero_bss_done")
            self.emit("JMP.Z   R0, R3")
            self.emit("LD0     R1")
            self.emit_raw("_act4_zero_bss_loop:")
            self.emit("LD      (R2), R1")
            self.emit("INC     R2")
            self.emit("DEC     R3")
            self.emit("LOAD16  R0, _act4_zero_bss_done")
            self.emit("JMP.Z   R0, R3")
            self.emit("LOAD16  R0, _act4_zero_bss_loop")
            self.emit("JMP     R0")
            self.emit_raw("_act4_zero_bss_done:")
            self.emit("RRET")
            self.emit_raw("")

        # Optional Hardware Math Accelerator runtime helpers & CPU_CAPS guard (--hw-math)
        if self.hw_math:
            self.emit_raw("; --- Hardware Math Accelerator Runtime (--hw-math, MMIO 0x0010-0x0016) ---")
            if "main" in self.functions:
                self.emit_raw("_act4_require_hw_math:")
                self.emit("RPUSH   R0")
                self.emit("LOAD16  R0, 0x001C")       # CPU_CAPS
                self.emit("LD      R1, (R0)")
                self.emit("LD      R0, 8")            # CAP_MATH_ACCEL = 0x0008 (bit 3)
                self.emit("AND     R1, R0")
                self.emit("LOAD16  R0, _act4_hw_math_missing")
                self.emit("JMP.Z   R0, R1")
                self.emit("RRET")
                self.emit_raw("_act4_hw_math_missing:")
                use_sys_con = (
                    self.no_preamble
                    and "sys_puts" in self.functions
                    and (reachable is None or "sys_puts" in reachable)
                    and len(self.functions["sys_puts"].params) == 1
                )
                if use_sys_con:
                    fn_wc = self.functions["sys_puts"]
                    self.emit("LOAD16  R1, _act4_hw_math_err_msg")
                    self.emit(f"LOAD16  R0, _sys_puts_{fn_wc.params[0][0]}")
                    self.emit("LD      (R0), R1")
                    self.emit("RCALL   _sys_puts")
                else:
                    self.emit("LOAD16  R0, 0x001C")       # Check CAP_UART (bit 2) before direct UART print
                    self.emit("LD      R1, (R0)")
                    self.emit("LD      R0, 4")
                    self.emit("AND     R1, R0")
                    self.emit("LOAD16  R0, _act4_hw_math_exit")
                    self.emit("JMP.Z   R0, R1")
                    self.emit("LOAD16  R2, _act4_hw_math_err_msg")
                    self.emit_raw("_act4_hw_math_puts:")
                    self.emit("LD      R3, (R2++)")
                    self.emit("BYTE_GET_LO R1, R3")
                    self.emit("LOAD16  R0, _act4_hw_math_exit")
                    self.emit("JMP.Z   R0, R1")
                    self.emit("PUTC    R1")
                    self.emit("BYTE_GET_HI R1, R3")
                    self.emit("LOAD16  R0, _act4_hw_math_exit")
                    self.emit("JMP.Z   R0, R1")
                    self.emit("PUTC    R1")
                    self.emit("LOAD16  R0, _act4_hw_math_puts")
                    self.emit("JMP     R0")
                self.emit_raw("_act4_hw_math_exit:")
                if self.no_preamble:
                    # MR4OS worker app: pop guard return link and return R1=1 from _main -> SYS_EXIT(1)
                    self.emit("RPOP    R0")
                    self.emit("LD      R0, 1")
                    self.emit("LD      R1, R0")
                    self.emit("LOAD16  R0, _ACT4_RET")
                    self.emit("JMP     R0")
                else:
                    # Standalone binary: leave error code R1=1 and halt cleanly
                    self.emit("LD      R0, 1")
                    self.emit("LD      R1, R0")
                    self.emit_raw("_act4_hw_math_halt:")
                    self.emit("LOAD16  R0, _act4_hw_math_halt")
                    self.emit("JMP     R0")
                self.emit_raw("")

            # Register-direct 16-bit HW Math wrappers (R1=A, R2=B -> R1=result; zero APUSH/APOP!)
            self.emit_raw("_ACT4_HW_MUL:")
            self.emit("RPUSH   R0")
            self.emit("LD0     R3")                   # CMD_MUL = 0
            self.emit("LOAD16  R0, _ACT4_HW_EXEC")
            self.emit("JMP     R0")
            self.emit_raw("_ACT4_HW_DIV:")
            self.emit("RPUSH   R0")
            self.emit("LD      R0, 4")                # CMD_DIVU = 4
            self.emit("LD      R3, R0")
            self.emit("LOAD16  R0, _ACT4_HW_EXEC")
            self.emit("JMP     R0")
            self.emit_raw("_ACT4_HW_MOD:")
            self.emit("RPUSH   R0")
            self.emit("LD      R0, 5")                # CMD_REMU = 5
            self.emit("LD      R3, R0")
            self.emit("LOAD16  R0, _ACT4_HW_EXEC")
            self.emit("JMP     R0")
            self.emit_raw("_ACT4_HW_SHL:")
            self.emit("RPUSH   R0")
            self.emit("LOAD16  R0, 0xFFF0")
            self.emit("AND     R0, R2")
            self.emit("LOAD16  R3, _ACT4_HW_SHL_GO")
            self.emit("JMP.Z   R3, R0")
            self.emit("LD0     R1")
            self.emit("RRET")
            self.emit_raw("_ACT4_HW_SHL_GO:")
            self.emit("LD      R0, 8")                # CMD_SLL = 8
            self.emit("LD      R3, R0")
            self.emit("LOAD16  R0, _ACT4_HW_EXEC")
            self.emit("JMP     R0")
            self.emit_raw("_ACT4_HW_SHR:")
            self.emit("RPUSH   R0")
            self.emit("LOAD16  R0, 0xFFF0")
            self.emit("AND     R0, R2")
            self.emit("LOAD16  R3, _ACT4_HW_SHR_GO")
            self.emit("JMP.Z   R3, R0")
            self.emit("LD0     R1")
            self.emit("RRET")
            self.emit_raw("_ACT4_HW_SHR_GO:")
            self.emit("LD      R0, 9")                # CMD_SRL = 9
            self.emit("LD      R3, R0")
            self.emit_raw("_ACT4_HW_EXEC:")
            self.emit("LOAD16  R0, 0x0010")           # MATH_A_LO
            self.emit("LD      (R0), R1")
            self.emit("INC     R0")                   # 0x0011 MATH_A_HI = 0
            self.emit("LD0     R1")
            self.emit("LD      (R0), R1")
            self.emit("INC     R0")                   # 0x0012 MATH_B_LO
            self.emit("LD      (R0), R2")
            self.emit("INC     R0")                   # 0x0013 MATH_B_HI = 0
            self.emit("LD      (R0), R1")
            self.emit("INC     R0")                   # 0x0014 MATH_CMD = R3
            self.emit("LD      (R0), R3")
            self.emit("LD0     R2")
            self.emit("INC     R2")                   # R2 = 1 (busy bit mask; R0 remains 0x0014)
            self.emit_raw("_ACT4_HW_WAIT:")
            self.emit("LD      R1, (R0)")             # Poll MATH_CMD_STAT[0]
            self.emit("AND     R1, R2")
            self.emit("LOAD16  R3, _ACT4_HW_DONE")
            self.emit("JMP.Z   R3, R1")
            self.emit("LOAD16  R3, _ACT4_HW_WAIT")
            self.emit("JMP     R3")
            self.emit_raw("_ACT4_HW_DONE:")
            self.emit("INC     R0")                   # 0x0015 MATH_RES_LO
            self.emit("LD      R1, (R0)")
            self.emit("RRET")
            self.emit_raw("")

        self.emit_raw("; ==============================================================================")
        self.emit_raw("; Standard Runtime Library (placed before .bss so trailing zeros trim cleanly)")
        self.emit_raw("; ==============================================================================")
        self.emit_raw('.include "M4R_LIB.asm"')
        self.emit_raw("")

        # Initialized Non-Zero Global Data (.data) + String Literals (.rodata)
        self.emit_raw("; ==============================================================================")
        self.emit_raw("; Initialized Data (.data) & String Literals (.rodata)")
        self.emit_raw("; ==============================================================================")

        bss_globals: List[Tuple[str, int]] = []
        for i in range(8):
            bss_globals.append((f"_act4_arg{i}", 1))
        for i in range(8):
            bss_globals.append((f"_act4_t{i}", 1))

        for name, decl in self.global_vars.items():
            if decl.is_const or decl.address is not None:
                continue
            lbl = f"_{name}"
            if decl.array_inits is not None:
                vals = [self.eval_const_init(e) & 0xFFFF for e in decl.array_inits]
                if any(v != 0 for v in vals):
                    inits = [f"0x{v:04X}" for v in vals]
                    self.emit_raw(f"{lbl}: .word " + ", ".join(inits))
                else:
                    bss_globals.append((lbl, len(vals)))
            elif decl.typ.array_size is not None:
                sz = decl.typ.word_size(self.structs)
                bss_globals.append((lbl, sz))
            elif decl.init_expr is not None:
                v = self.eval_const_init(decl.init_expr) & 0xFFFF
                if v != 0:
                    self.emit_raw(f"{lbl}: .word 0x{v:04X}")
                else:
                    bss_globals.append((lbl, 1))
            else:
                sz = decl.typ.word_size(self.structs)
                bss_globals.append((lbl, sz))

        if self.string_literals or (self.hw_math and "main" in self.functions):
            self.emit_raw("")
            self.emit_raw("; --- String Literals ---")
            for lbl, s in self.string_literals:
                clean_s = s.replace('"', '\\"')
                self.emit_raw(f'{lbl}: .asciz "{clean_s}"')
            if self.hw_math and "main" in self.functions:
                self.emit_raw('_act4_hw_math_err_msg: .asciz "\\r\\nERR: CPU lacks HW Math Accelerator (CPU_CAPS.b3=0)\\r\\n"')

        # Trailing Zero-Initialized Storage (.bss) via .resw (trimmed from binary on disk!)
        self.emit_raw("")
        self.emit_raw("; ==============================================================================")
        self.emit_raw("; Uninitialized / Zero-Initialized Storage (.bss - trimmed from disk image)")
        self.emit_raw("; ==============================================================================")
        self.emit(".align")
        self.emit_raw("_act4_bss_start:")
        for lbl, sz in bss_globals:
            self.emit_raw(f"{lbl}: .resw {sz}")
        for lbl, sz in self.bss_entries:
            self.emit_raw(f"{lbl}: .resw {sz}")
        self.emit_raw("_act4_bss_end:")
        return "\n".join(self.asm) + "\n"

    def compute_reachable_functions(self) -> Optional[set]:
        if "main" not in self.functions:
            return None
        reachable = {"main"}
        reachable.update(self.trap_bindings.values())
        if self.hw_math and self.no_preamble and "sys_puts" in self.functions:
            reachable.add("sys_puts")
        worklist = list(reachable)

        def collect_refs(node: Any):
            if node is None:
                return
            if isinstance(node, list):
                for item in node:
                    collect_refs(item)
                return
            if isinstance(node, VarRef):
                if node.name in self.functions and node.name not in reachable:
                    reachable.add(node.name)
                    worklist.append(node.name)
                return
            if isinstance(node, AsmBlock):
                for fname in self.functions:
                    if fname not in reachable and f"_{fname}" in node.asm_text:
                        reachable.add(fname)
                        worklist.append(fname)
                return
            if isinstance(node, ASTNode):
                for val in vars(node).values():
                    if isinstance(val, (ASTNode, list)):
                        collect_refs(val)

        for decl in self.global_vars.values():
            collect_refs(decl.init_expr)
            collect_refs(decl.array_inits)

        while worklist:
            fn_name = worklist.pop()
            fn = self.functions[fn_name]
            for decl in fn.locals_decls:
                collect_refs(decl.init_expr)
                collect_refs(decl.array_inits)
            collect_refs(fn.body)

        return reachable

    def eval_const_init(self, expr: Any) -> int:
        if isinstance(expr, IntLit):
            return expr.val
        if isinstance(expr, VarRef) and expr.name in self.constants:
            return self.constants[expr.name]
        return 0

    def emit_load_const(self, reg: str, val: int):
        val &= 0xFFFF
        if val == 0:
            self.emit(f"LD0     {reg}")
        elif val == 1:
            self.emit(f"LD0     {reg}")
            self.emit(f"INC     {reg}")
        elif val == 0xFFFF:
            self.emit(f"LD0     {reg}")
            self.emit(f"DEC     {reg}")
        elif reg == "R0" and val <= 15:
            self.emit(f"LD      R0, {val}")
        else:
            self.emit(f"LOAD16  {reg}, 0x{val:04X}")

    def get_const_val(self, expr: Expr) -> Optional[int]:
        if isinstance(expr, IntLit):
            return expr.val & 0xFFFF
        if isinstance(expr, VarRef) and not self.is_local_var(expr.name) and expr.name in self.constants:
            return self.constants[expr.name] & 0xFFFF
        return None

    def is_local_var(self, name: str) -> bool:
        if self.current_func:
            for pname, _ in self.current_func.params:
                if pname == name:
                    return True
            for decl in self.current_func.locals_decls:
                if decl.name == name:
                    return True
        return False

    def is_simple_expr(self, expr: Expr) -> bool:
        return isinstance(expr, (IntLit, StrLit, VarRef))

    def expr_contains_call(self, node: Any) -> bool:
        if node is None:
            return False
        if isinstance(node, CallExpr):
            return True
        if isinstance(node, list):
            return any(self.expr_contains_call(x) for x in node)
        if isinstance(node, ASTNode):
            return any(
                self.expr_contains_call(v)
                for v in vars(node).values()
                if isinstance(v, (ASTNode, list))
            )
        return False

    def gen_simple_into_reg(self, expr: Expr, reg: str):
        """Evaluate a simple expression into `reg` (R1/R2/R3), touching only R0 and `reg`."""
        cval = self.get_const_val(expr)
        if cval is not None:
            self.emit_load_const(reg, cval)
            return
        if isinstance(expr, StrLit):
            self.emit(f"LOAD16  {reg}, {expr.label}")
            return
        if isinstance(expr, VarRef):
            if not self.is_local_var(expr.name) and expr.name not in self.global_vars and expr.name in self.functions:
                self.emit(f"LOAD16  {reg}, _{expr.name}")
                return
            lbl = self.resolve_var_label(expr.name)
            is_array = self.is_array_expr(expr)
            addr = self.resolve_fixed_address(expr.name)
            if addr is not None:
                if is_array:
                    self.emit_load_const(reg, addr)
                else:
                    self.emit_load_const("R0", addr)
                    self.emit(f"LD      {reg}, (R0)")
            elif is_array:
                self.emit(f"LOAD16  {reg}, {lbl}")
            else:
                self.emit(f"LOAD16  R0, {lbl}")
                self.emit(f"LD      {reg}, (R0)")
            return
        raise CompilerError(f"gen_simple_into_reg called on non-simple expr: {expr}")

    def emit_ret(self):
        self.emit("LOAD16  R0, _ACT4_RET")
        self.emit("JMP     R0")

    def gen_function(self, fn: FunctionDef):
        self.current_func = fn
        self.emit_raw(f"; --- Function: {fn.name} ---")
        if fn.trap_vector is not None:
            self.emit_raw(f"; Bound to hardware Trap Vector {fn.trap_vector} (0x{0x0100 + fn.trap_vector * 16:04X})")
        self.emit_raw(f"_{fn.name}:")
        if fn.trap_vector is not None:
            # Return PC was already pushed onto RSP by _trap_N_slot
            self.emit("RPUSH   R1")
            self.emit("RPUSH   R2")
            self.emit("RPUSH   R3")
        else:
            self.emit("RPUSH   R0")
            if fn.name == "main":
                self.emit("LOAD16  R0, _act4_zero_bss")
                self.emit("LINK    R0, R0")
                if self.hw_math:
                    self.emit("LOAD16  R0, _act4_require_hw_math")
                    self.emit("LINK    R0, R0")

        for decl in fn.locals_decls:
            if decl.init_expr is not None and not decl.typ.array_size:
                self.gen_expr(decl.init_expr)
                self.emit(f"LOAD16  R0, _{fn.name}_{decl.name}")
                self.emit("LD      (R0), R1")

        for stmt in fn.body:
            self.gen_stmt(stmt)

        if fn.trap_vector is not None:
            self.emit_raw(f"_{fn.name}_iret:")
            self.emit("RPOP    R3")
            self.emit("RPOP    R2")
            self.emit("RPOP    R1")
            self.emit("RRET")
        else:
            self.emit_ret()
        self.emit_raw("")

        for decl in fn.locals_decls:
            if decl.address is not None:
                continue
            lbl = f"_{fn.name}_{decl.name}"
            sz = decl.typ.word_size(self.structs)
            self.bss_entries.append((lbl, sz))

        for pname, ptype in fn.params:
            self.bss_entries.append((f"_{fn.name}_{pname}", 1))
        self.emit_raw("")

        self.current_func = None

    def gen_stmt(self, stmt: ASTNode):
        if isinstance(stmt, CommentNode):
            text = stmt.text
            if text.startswith("//"):
                text = text[2:].strip()
            self.emit_raw(f"; // {text}")

        elif isinstance(stmt, AsmBlock):
            self.emit_raw(f"    ; --- Inline Assembly ---")
            for line in stmt.asm_text.splitlines():
                self.emit_raw(f"    {line.strip()}")

        elif isinstance(stmt, ReturnStmt):
            if stmt.expr is not None:
                self.gen_expr(stmt.expr)
            if self.current_func and self.current_func.trap_vector is not None:
                self.emit(f"LOAD16  R0, _{self.current_func.name}_iret")
                self.emit("JMP     R0")
            else:
                self.emit_ret()

        elif isinstance(stmt, BreakStmt):
            if not self.loop_stack:
                raise CompilerError("break statement outside of loop")
            lbl_break, _ = self.loop_stack[-1]
            self.emit(f"LOAD16  R0, {lbl_break}")
            self.emit(f"JMP     R0")

        elif isinstance(stmt, ContinueStmt):
            if not self.loop_stack:
                raise CompilerError("continue statement outside of loop")
            _, lbl_cont = self.loop_stack[-1]
            self.emit(f"LOAD16  R0, {lbl_cont}")
            self.emit(f"JMP     R0")

        elif isinstance(stmt, IfStmt):
            lbl_else = self.new_label("else")
            lbl_end = self.new_label("endif")
            self.gen_cond_branch(stmt.cond, invert=True, target_label=lbl_else if stmt.else_block else lbl_end)
            for s in stmt.then_block:
                self.gen_stmt(s)
            if stmt.else_block:
                self.emit(f"LOAD16  R0, {lbl_end}")
                self.emit(f"JMP     R0")
                self.emit_raw(f"{lbl_else}:")
                for s in stmt.else_block:
                    self.gen_stmt(s)
                self.emit_raw(f"{lbl_end}:")
            else:
                self.emit_raw(f"{lbl_end}:")

        elif isinstance(stmt, WhileStmt):
            lbl_loop = self.new_label("while_start")
            lbl_exit = self.new_label("while_exit")
            self.loop_stack.append((lbl_exit, lbl_loop))
            self.emit_raw(f"{lbl_loop}:")
            self.gen_cond_branch(stmt.cond, invert=True, target_label=lbl_exit)
            for s in stmt.body:
                self.gen_stmt(s)
            self.emit(f"LOAD16  R0, {lbl_loop}")
            self.emit(f"JMP     R0")
            self.emit_raw(f"{lbl_exit}:")
            self.loop_stack.pop()

        elif isinstance(stmt, IncDecStmt):
            self.gen_inc_dec(stmt)

        elif isinstance(stmt, AssignStmt):
            self.gen_assign(stmt)

        elif isinstance(stmt, CallStmt):
            self.gen_expr(stmt.call_expr)

        elif isinstance(stmt, SetByteStmt):
            self.gen_setbyte(stmt)

        elif isinstance(stmt, TrapStmt):
            self.gen_trap_stmt(stmt)

    def gen_trap_stmt(self, stmt: TrapStmt):
        self.gen_expr(stmt.vector_expr)
        self.emit(f"TRAP    R1, 0x{stmt.data_byte:02X}")

    def gen_inc_dec(self, stmt: IncDecStmt):
        self.gen_lvalue_addr(stmt.target)
        self.emit("LD      R1, (R0)")
        if stmt.op == "++":
            self.emit("INC     R1")
        else:
            self.emit("DEC     R1")
        self.emit("LD      (R0), R1")

    def gen_assign(self, stmt: AssignStmt):
        if stmt.op == "=":
            if isinstance(stmt.target, VarRef):
                self.gen_expr(stmt.value)
                self.gen_lvalue_addr(stmt.target)
                self.emit("LD      (R0), R1")
            elif self.get_const_val(stmt.value) is not None or isinstance(stmt.value, StrLit):
                self.gen_lvalue_addr(stmt.target)
                self.gen_simple_into_reg(stmt.value, "R1")
                self.emit("LD      (R0), R1")
            elif self.is_simple_expr(stmt.value):
                self.gen_lvalue_addr(stmt.target)
                self.emit("LD      R2, R0")
                self.gen_simple_into_reg(stmt.value, "R1")
                self.emit("LD      (R2), R1")
            else:
                self.gen_expr(stmt.value)
                self.emit("RCALL   _ACT4_APUSH_R1")
                self.gen_lvalue_addr(stmt.target)
                self.emit("LD      R2, R0")
                self.emit("RCALL   _ACT4_APOP_R1")
                self.emit("LD      (R2), R1")
        else:
            self.gen_lvalue_addr(stmt.target)
            self.emit("APUSH   R0")
            self.emit("LD      R1, (R0)")
            if self.is_simple_expr(stmt.value):
                self.gen_simple_into_reg(stmt.value, "R2")
            else:
                self.emit("RCALL   _ACT4_APUSH_R1")
                self.gen_expr(stmt.value)
                self.emit("LD      R2, R1")
                self.emit("RCALL   _ACT4_APOP_R1")

            base_op = stmt.op[:-1]
            if base_op == "+":
                self.emit("ADD     R1, R2")
            elif base_op == "-":
                self.emit("SUB     R1, R2")
            elif base_op == "&":
                self.emit("AND     R1, R2")
            elif base_op == "|":
                self.emit("OR      R1, R2")
            elif base_op == "^":
                self.emit("XOR     R1, R2")
            elif base_op == "*":
                if self.hw_math:
                    self.emit("RCALL   _ACT4_HW_MUL")
                else:
                    self.emit("RCALL   _ACT4_APUSH_R1")
                    self.emit("APUSH   R2")
                    self.emit("RCALL   MULT")
                    self.emit("RCALL   _ACT4_APOP_R1")
            elif base_op == "/":
                if self.hw_math:
                    self.emit("RCALL   _ACT4_HW_DIV")
                else:
                    self.emit("RCALL   _ACT4_APUSH_R1")
                    self.emit("APUSH   R2")
                    self.emit("RCALL   DIV")
                    self.emit("RCALL   _ACT4_APOP_R1")
            elif base_op == "%":
                if self.hw_math:
                    self.emit("RCALL   _ACT4_HW_MOD")
                else:
                    self.emit("RCALL   _ACT4_APUSH_R1")
                    self.emit("APUSH   R2")
                    self.emit("RCALL   MOD")
                    self.emit("RCALL   _ACT4_APOP_R1")
            elif base_op == "<<":
                if self.hw_math:
                    self.emit("RCALL   _ACT4_HW_SHL")
                else:
                    lbl_lp = self.new_label("shla_loop")
                    lbl_end = self.new_label("shla_done")
                    self.emit_raw(f"{lbl_lp}:")
                    self.emit(f"LOAD16  R0, {lbl_end}")
                    self.emit("JMP.Z   R0, R2")
                    self.emit("SHIFT.L R1")
                    self.emit("DEC     R2")
                    self.emit(f"LOAD16  R0, {lbl_lp}")
                    self.emit("JMP     R0")
                    self.emit_raw(f"{lbl_end}:")
            elif base_op == ">>":
                if self.hw_math:
                    self.emit("RCALL   _ACT4_HW_SHR")
                else:
                    lbl_lp = self.new_label("shra_loop")
                    lbl_end = self.new_label("shra_done")
                    self.emit_raw(f"{lbl_lp}:")
                    self.emit(f"LOAD16  R0, {lbl_end}")
                    self.emit("JMP.Z   R0, R2")
                    self.emit("SHIFT.R R1")
                    self.emit("DEC     R2")
                    self.emit(f"LOAD16  R0, {lbl_lp}")
                    self.emit("JMP     R0")
                    self.emit_raw(f"{lbl_end}:")

            self.emit("APOP    R0")
            self.emit("LD      (R0), R1")

    def gen_setbyte(self, stmt: SetByteStmt):
        if self.is_simple_expr(stmt.index_expr) and self.is_simple_expr(stmt.val_expr):
            self.gen_expr(stmt.base_expr)
            self.gen_simple_into_reg(stmt.index_expr, "R2")
            self.gen_simple_into_reg(stmt.val_expr, "R3")
            self.emit("RCALL   _ACT4_SETBYTE")
            return
        self.gen_expr(stmt.base_expr)
        self.emit("RCALL   _ACT4_APUSH_R1")

        self.gen_expr(stmt.index_expr)
        self.emit("RCALL   _ACT4_APUSH_R1")

        self.gen_expr(stmt.val_expr)
        self.emit("LD      R3, R1")

        self.emit("RCALL   _ACT4_APOP_R2")
        self.emit("RCALL   _ACT4_APOP_R1")
        self.emit("RCALL   _ACT4_SETBYTE")

    def resolve_var_label(self, name: str) -> str:
        if self.current_func:
            for pname, _ in self.current_func.params:
                if pname == name:
                    return f"_{self.current_func.name}_{pname}"
            for decl in self.current_func.locals_decls:
                if decl.name == name:
                    return f"_{self.current_func.name}_{name}"
        return f"_{name}"

    def resolve_fixed_address(self, name: str) -> Optional[int]:
        if self.current_func:
            for pname, _ in self.current_func.params:
                if pname == name:
                    return None
            for decl in self.current_func.locals_decls:
                if decl.name == name:
                    return decl.address
        if name in self.global_vars:
            return self.global_vars[name].address
        return None

    def infer_type_desc(self, expr: Expr) -> Optional[TypeDesc]:
        if isinstance(expr, VarRef):
            if self.current_func:
                for pname, ptype in self.current_func.params:
                    if pname == expr.name:
                        return ptype
                for decl in self.current_func.locals_decls:
                    if decl.name == expr.name:
                        return decl.typ
            if expr.name in self.global_vars:
                return self.global_vars[expr.name].typ
            return None
        elif isinstance(expr, IndexAccess):
            td = self.infer_type_desc(expr.target)
            if td is None:
                return None
            if td.array_size is not None:
                return TypeDesc(
                    td.base_type,
                    is_pointer=td.is_pointer,
                    array_size=None,
                    is_func_ptr=td.is_func_ptr,
                    func_params=td.func_params,
                    func_ret=td.func_ret,
                )
            if td.is_pointer:
                return TypeDesc(td.base_type, is_pointer=False, array_size=None)
            return TypeDesc(td.base_type)
        elif isinstance(expr, MemberAccess):
            typ_name = self.infer_type(expr.target)
            if typ_name in self.structs:
                for fname, ftype, _ in self.structs[typ_name].fields:
                    if fname == expr.member:
                        return ftype
            return None
        elif isinstance(expr, UnaryOp):
            if expr.op == "*":
                td = self.infer_type_desc(expr.operand)
                if td is None:
                    return None
                if td.array_size is not None:
                    return TypeDesc(
                        td.base_type,
                        is_pointer=td.is_pointer,
                        array_size=None,
                        is_func_ptr=td.is_func_ptr,
                        func_params=td.func_params,
                        func_ret=td.func_ret,
                    )
                if td.is_pointer:
                    return TypeDesc(td.base_type, is_pointer=False, array_size=None)
                return td
            elif expr.op == "&":
                td = self.infer_type_desc(expr.operand)
                if td is not None:
                    return TypeDesc(td.base_type, is_pointer=True)
                return TypeDesc("u16", is_pointer=True)
        elif isinstance(expr, CallExpr):
            if isinstance(expr.callee, VarRef) and expr.callee.name in self.functions:
                return self.functions[expr.callee.name].ret_type
        elif isinstance(expr, BinaryOp):
            if expr.op in ("+", "-"):
                lhs_td = self.infer_type_desc(expr.lhs)
                if lhs_td is not None and (lhs_td.is_pointer or lhs_td.array_size is not None):
                    return TypeDesc(lhs_td.base_type, is_pointer=True)
        return None

    def is_array_expr(self, expr: Expr) -> bool:
        td = self.infer_type_desc(expr)
        return td is not None and td.array_size is not None

    def infer_type(self, expr: Expr) -> str:
        td = self.infer_type_desc(expr)
        return td.base_type if td is not None else "u16"

    def get_member_type_name(self, target: Expr, member: str) -> Optional[str]:
        typ_name = self.infer_type(target)
        if typ_name in self.structs:
            for fname, ftype, _ in self.structs[typ_name].fields:
                if fname == member:
                    if ftype.is_pointer or ftype.is_func_ptr:
                        return None
                    return ftype.base_type
        return None

    def get_member_offset(self, target: Expr, member: str) -> int:
        typ_name = self.infer_type(target)
        if typ_name in self.structs:
            for fname, _, off in self.structs[typ_name].fields:
                if fname == member:
                    return off
        return 0

    def get_index_elem_word_size(self, target: Expr) -> int:
        td = self.infer_type_desc(target)
        if td is not None:
            if td.array_size is not None:
                elem = TypeDesc(
                    td.base_type,
                    is_pointer=td.is_pointer,
                    array_size=None,
                    is_func_ptr=td.is_func_ptr,
                )
                return elem.word_size(self.structs)
            if td.is_pointer:
                elem = TypeDesc(td.base_type, is_pointer=False, array_size=None)
                return elem.word_size(self.structs)
        return 1

    def gen_cond_branch(self, cond: Expr, invert: bool, target_label: str):
        if isinstance(cond, BinaryOp) and cond.op == "||":
            if invert:
                lbl_true = self.new_label("or_true")
                self.gen_cond_branch(cond.lhs, invert=False, target_label=lbl_true)
                self.gen_cond_branch(cond.rhs, invert=True, target_label=target_label)
                self.emit_raw(f"{lbl_true}:")
            else:
                self.gen_cond_branch(cond.lhs, invert=False, target_label=target_label)
                self.gen_cond_branch(cond.rhs, invert=False, target_label=target_label)
            return

        if isinstance(cond, BinaryOp) and cond.op == "&&":
            if invert:
                self.gen_cond_branch(cond.lhs, invert=True, target_label=target_label)
                self.gen_cond_branch(cond.rhs, invert=True, target_label=target_label)
            else:
                lbl_false = self.new_label("and_false")
                self.gen_cond_branch(cond.lhs, invert=True, target_label=lbl_false)
                self.gen_cond_branch(cond.rhs, invert=False, target_label=target_label)
                self.emit_raw(f"{lbl_false}:")
            return

        if isinstance(cond, BinaryOp) and cond.op in ("==", "!=", "<", ">", "<=", ">="):
            op = cond.op
            if invert:
                inv_map = {"==": "!=", "!=": "==", "<": ">=", ">": "<=", "<=": ">", ">=": "<"}
                op = inv_map[op]

            rhs_const = self.get_const_val(cond.rhs)
            if op in ("==", "!=") and rhs_const == 0:
                self.gen_expr(cond.lhs)
                if op == "==":
                    self.emit(f"LOAD16  R0, {target_label}")
                    self.emit("JMP.Z   R0, R1")
                else:
                    lbl_skip = self.new_label("eq_skip")
                    self.emit(f"LOAD16  R0, {lbl_skip}")
                    self.emit("JMP.Z   R0, R1")
                    self.emit(f"LOAD16  R0, {target_label}")
                    self.emit("JMP     R0")
                    self.emit_raw(f"{lbl_skip}:")
                return

            if self.is_simple_expr(cond.rhs):
                self.gen_expr(cond.lhs)
                self.gen_simple_into_reg(cond.rhs, "R2")
            else:
                self.gen_expr(cond.lhs)
                self.emit("RCALL   _ACT4_APUSH_R1")

                self.gen_expr(cond.rhs)
                self.emit("LD      R2, R1")
                self.emit("RCALL   _ACT4_APOP_R1")

            if op == "==":
                self.emit("SUB     R1, R2")
                self.emit(f"LOAD16  R0, {target_label}")
                self.emit(f"JMP.Z   R0, R1")
            elif op == "!=":
                lbl_skip = self.new_label("eq_skip")
                self.emit("SUB     R1, R2")
                self.emit(f"LOAD16  R0, {lbl_skip}")
                self.emit(f"JMP.Z   R0, R1")
                self.emit(f"LOAD16  R0, {target_label}")
                self.emit(f"JMP     R0")
                self.emit_raw(f"{lbl_skip}:")
            elif op == "<":
                self.emit("RCALL   _CMP_LT")
                self.emit(f"LOAD16  R2, {target_label}")
                self.emit("DEC     R1")
                self.emit(f"JMP.Z   R2, R1")
            elif op == ">":
                self.emit("RCALL   _CMP_GT")
                self.emit(f"LOAD16  R2, {target_label}")
                self.emit("DEC     R1")
                self.emit(f"JMP.Z   R2, R1")
            elif op == "<=":
                self.emit("RCALL   _CMP_LE")
                self.emit(f"LOAD16  R2, {target_label}")
                self.emit("DEC     R1")
                self.emit(f"JMP.Z   R2, R1")
            elif op == ">=":
                self.emit("RCALL   _CMP_GE")
                self.emit(f"LOAD16  R2, {target_label}")
                self.emit("DEC     R1")
                self.emit(f"JMP.Z   R2, R1")
        else:
            self.gen_expr(cond)
            if invert:
                self.emit(f"LOAD16  R0, {target_label}")
                self.emit(f"JMP.Z   R0, R1")
            else:
                lbl_skip = self.new_label("skip")
                self.emit(f"LOAD16  R0, {lbl_skip}")
                self.emit(f"JMP.Z   R0, R1")
                self.emit(f"LOAD16  R0, {target_label}")
                self.emit(f"JMP     R0")
                self.emit_raw(f"{lbl_skip}:")

    def gen_lvalue_addr(self, expr: Expr):
        if isinstance(expr, VarRef):
            addr = self.resolve_fixed_address(expr.name)
            if addr is not None:
                self.emit_load_const("R0", addr)
            else:
                lbl = self.resolve_var_label(expr.name)
                self.emit(f"LOAD16  R0, {lbl}")

        elif isinstance(expr, UnaryOp) and expr.op == "*":
            self.gen_expr(expr.operand)  # R1 = pointer address
            self.emit("LD      R0, R1")

        elif isinstance(expr, IndexAccess):
            elem_sz = self.get_index_elem_word_size(expr.target)
            idx_const = self.get_const_val(expr.index)
            if idx_const is not None:
                self.gen_expr(expr.target)
                off = (idx_const * elem_sz) & 0xFFFF
                if off != 0:
                    self.emit_load_const("R2", off)
                    self.emit("ADD     R1, R2")
                self.emit("LD      R0, R1")
            elif self.is_simple_expr(expr.target):
                self.gen_expr(expr.index)
                if elem_sz > 1:
                    if (elem_sz & (elem_sz - 1)) == 0 and elem_sz <= 64:
                        s = elem_sz
                        while s > 1:
                            self.emit("SHIFT.L R1")
                            s >>= 1
                    else:
                        if self.hw_math:
                            self.emit_load_const("R2", elem_sz)
                            self.emit("RCALL   _ACT4_HW_MUL")
                        else:
                            self.emit("RCALL   _ACT4_APUSH_R1")
                            self.emit_load_const("R1", elem_sz)
                            self.emit("RCALL   _ACT4_APUSH_R1")
                            self.emit("RCALL   MULT")
                            self.emit("RCALL   _ACT4_APOP_R1")
                self.gen_simple_into_reg(expr.target, "R2")
                self.emit("ADD     R1, R2")
                self.emit("LD      R0, R1")
            else:
                self.gen_expr(expr.target)
                self.emit("RCALL   _ACT4_APUSH_R1")

                self.gen_expr(expr.index)
                if elem_sz > 1:
                    if (elem_sz & (elem_sz - 1)) == 0 and elem_sz <= 64:
                        s = elem_sz
                        while s > 1:
                            self.emit("SHIFT.L R1")
                            s >>= 1
                    else:
                        if self.hw_math:
                            self.emit_load_const("R2", elem_sz)
                            self.emit("RCALL   _ACT4_HW_MUL")
                        else:
                            self.emit("RCALL   _ACT4_APUSH_R1")
                            self.emit_load_const("R1", elem_sz)
                            self.emit("RCALL   _ACT4_APUSH_R1")
                            self.emit("RCALL   MULT")
                            self.emit("RCALL   _ACT4_APOP_R1")

                self.emit("RCALL   _ACT4_APOP_R2")
                self.emit("ADD     R1, R2")
                self.emit("LD      R0, R1")

        elif isinstance(expr, MemberAccess):
            offset = self.get_member_offset(expr.target, expr.member)
            if expr.is_arrow:
                self.gen_expr(expr.target)
            else:
                self.gen_lvalue_addr(expr.target)
                self.emit("LD      R1, R0")
            if offset != 0:
                self.emit_load_const("R2", offset)
                self.emit("ADD     R1, R2")
            self.emit("LD      R0, R1")
        else:
            raise CompilerError(f"Cannot take address of non-lvalue expression: {expr}")

    def gen_expr(self, expr: Expr):
        if isinstance(expr, IntLit):
            self.emit_load_const("R1", expr.val)

        elif isinstance(expr, StrLit):
            self.emit(f"LOAD16  R1, {expr.label}")

        elif isinstance(expr, VarRef):
            self.gen_simple_into_reg(expr, "R1")

        elif isinstance(expr, UnaryOp):
            if expr.op == "&":
                self.gen_lvalue_addr(expr.operand)
                self.emit("LD      R1, R0")
            elif expr.op == "*":
                self.gen_expr(expr.operand)
                self.emit("LD      R0, R1")
                self.emit("LD      R1, (R0)")
            elif expr.op == "~":
                self.gen_expr(expr.operand)
                self.emit("NOT     R1")
            elif expr.op == "-":
                self.gen_expr(expr.operand)
                self.emit("LD      R2, R1")
                self.emit("LD0     R1")
                self.emit("SUB     R1, R2")
            elif expr.op == "!":
                self.gen_expr(expr.operand)
                lbl_true = self.new_label("not_true")
                lbl_done = self.new_label("not_done")
                self.emit(f"LOAD16  R0, {lbl_true}")
                self.emit(f"JMP.Z   R0, R1")
                self.emit("LD0     R1")
                self.emit(f"LOAD16  R0, {lbl_done}")
                self.emit(f"JMP     R0")
                self.emit_raw(f"{lbl_true}:")
                self.emit("LD0     R1")
                self.emit("INC     R1")
                self.emit_raw(f"{lbl_done}:")

        elif isinstance(expr, BinaryOp):
            self.gen_binary(expr)

        elif isinstance(expr, IndexAccess):
            self.gen_lvalue_addr(expr)
            if self.is_array_expr(expr):
                self.emit("LD      R1, R0")
            else:
                self.emit("LD      R1, (R0)")

        elif isinstance(expr, MemberAccess):
            self.gen_lvalue_addr(expr)
            if self.is_array_expr(expr):
                self.emit("LD      R1, R0")
            else:
                self.emit("LD      R1, (R0)")

        elif isinstance(expr, CallExpr):
            self.gen_call(expr)

        elif isinstance(expr, GetByteExpr):
            if self.is_simple_expr(expr.index_expr):
                self.gen_expr(expr.base_expr)
                self.gen_simple_into_reg(expr.index_expr, "R2")
                self.emit("RCALL   _ACT4_GETBYTE")
            else:
                self.gen_expr(expr.base_expr)
                self.emit("RCALL   _ACT4_APUSH_R1")
                self.gen_expr(expr.index_expr)
                self.emit("LD      R2, R1")
                self.emit("RCALL   _ACT4_APOP_R1")
                self.emit("RCALL   _ACT4_GETBYTE")

    def gen_binary(self, expr: BinaryOp):
        if expr.op in ("&&", "||"):
            lbl_false = self.new_label("log_false")
            lbl_done = self.new_label("log_done")
            self.gen_cond_branch(expr, invert=True, target_label=lbl_false)
            self.emit("LD0     R1")
            self.emit("INC     R1")
            self.emit(f"LOAD16  R0, {lbl_done}")
            self.emit("JMP     R0")
            self.emit_raw(f"{lbl_false}:")
            self.emit("LD0     R1")
            self.emit_raw(f"{lbl_done}:")
            return

        rhs_const = self.get_const_val(expr.rhs)
        if expr.op == ">>" and rhs_const is not None:
            self.gen_expr(expr.lhs)
            cnt = rhs_const & 0x0F
            if self.hw_math and cnt >= 4:
                self.emit_load_const("R2", cnt)
                self.emit("RCALL   _ACT4_HW_SHR")
            else:
                for _ in range(cnt):
                    self.emit("SHIFT.R R1")
            return
        if expr.op == "<<" and rhs_const is not None:
            self.gen_expr(expr.lhs)
            cnt = rhs_const & 0x0F
            if self.hw_math and cnt >= 4:
                self.emit_load_const("R2", cnt)
                self.emit("RCALL   _ACT4_HW_SHL")
            else:
                for _ in range(cnt):
                    self.emit("SHIFT.L R1")
            return
        if expr.op == "*" and rhs_const is not None and rhs_const > 0 and (rhs_const & (rhs_const - 1)) == 0 and rhs_const <= 64:
            self.gen_expr(expr.lhs)
            s = rhs_const
            while s > 1:
                self.emit("SHIFT.L R1")
                s >>= 1
            return
        if expr.op == "+" and rhs_const == 1:
            self.gen_expr(expr.lhs)
            self.emit("INC     R1")
            return
        if expr.op == "-" and rhs_const == 1:
            self.gen_expr(expr.lhs)
            self.emit("DEC     R1")
            return

        if self.is_simple_expr(expr.rhs):
            self.gen_expr(expr.lhs)
            self.gen_simple_into_reg(expr.rhs, "R2")
        else:
            self.gen_expr(expr.lhs)
            self.emit("RCALL   _ACT4_APUSH_R1")

            self.gen_expr(expr.rhs)
            self.emit("LD      R2, R1")
            self.emit("RCALL   _ACT4_APOP_R1")

        if expr.op == "+":
            self.emit("ADD     R1, R2")
        elif expr.op == "-":
            self.emit("SUB     R1, R2")
        elif expr.op == "&":
            self.emit("AND     R1, R2")
        elif expr.op == "|":
            self.emit("OR      R1, R2")
        elif expr.op == "^":
            self.emit("XOR     R1, R2")
        elif expr.op == "==":
            lbl_true = self.new_label("eq_true")
            lbl_done = self.new_label("eq_done")
            self.emit("SUB     R1, R2")
            self.emit(f"LOAD16  R0, {lbl_true}")
            self.emit("JMP.Z   R0, R1")
            self.emit("LD0     R1")
            self.emit(f"LOAD16  R0, {lbl_done}")
            self.emit("JMP     R0")
            self.emit_raw(f"{lbl_true}:")
            self.emit("LD0     R1")
            self.emit("INC     R1")
            self.emit_raw(f"{lbl_done}:")
        elif expr.op == "!=":
            lbl_false = self.new_label("ne_false")
            lbl_done = self.new_label("ne_done")
            self.emit("SUB     R1, R2")
            self.emit(f"LOAD16  R0, {lbl_false}")
            self.emit("JMP.Z   R0, R1")
            self.emit("LD0     R1")
            self.emit("INC     R1")
            self.emit(f"LOAD16  R0, {lbl_done}")
            self.emit("JMP     R0")
            self.emit_raw(f"{lbl_false}:")
            self.emit("LD0     R1")
            self.emit_raw(f"{lbl_done}:")
        elif expr.op == "<":
            self.emit("RCALL   _CMP_LT")
        elif expr.op == ">":
            self.emit("RCALL   _CMP_GT")
        elif expr.op == "<=":
            self.emit("RCALL   _CMP_LE")
        elif expr.op == ">=":
            self.emit("RCALL   _CMP_GE")
        elif expr.op == "*":
            if self.hw_math:
                self.emit("RCALL   _ACT4_HW_MUL")
            else:
                self.emit("RCALL   _ACT4_APUSH_R1")
                self.emit("APUSH   R2")
                self.emit("RCALL   MULT")
                self.emit("RCALL   _ACT4_APOP_R1")
        elif expr.op == "/":
            if self.hw_math:
                self.emit("RCALL   _ACT4_HW_DIV")
            else:
                self.emit("RCALL   _ACT4_APUSH_R1")
                self.emit("APUSH   R2")
                self.emit("RCALL   DIV")
                self.emit("RCALL   _ACT4_APOP_R1")
        elif expr.op == "%":
            if self.hw_math:
                self.emit("RCALL   _ACT4_HW_MOD")
            else:
                self.emit("RCALL   _ACT4_APUSH_R1")
                self.emit("APUSH   R2")
                self.emit("RCALL   MOD")
                self.emit("RCALL   _ACT4_APOP_R1")
        elif expr.op == ">>":
            if self.hw_math:
                self.emit("RCALL   _ACT4_HW_SHR")
            else:
                lbl_lp = self.new_label("shr_loop")
                lbl_end = self.new_label("shr_done")
                self.emit_raw(f"{lbl_lp}:")
                self.emit(f"LOAD16  R0, {lbl_end}")
                self.emit("JMP.Z   R0, R2")
                self.emit("SHIFT.R R1")
                self.emit("DEC     R2")
                self.emit(f"LOAD16  R0, {lbl_lp}")
                self.emit("JMP     R0")
                self.emit_raw(f"{lbl_end}:")
        elif expr.op == "<<":
            if self.hw_math:
                self.emit("RCALL   _ACT4_HW_SHL")
            else:
                lbl_lp = self.new_label("shl_loop")
                lbl_end = self.new_label("shl_done")
                self.emit_raw(f"{lbl_lp}:")
                self.emit(f"LOAD16  R0, {lbl_end}")
                self.emit("JMP.Z   R0, R2")
                self.emit("SHIFT.L R1")
                self.emit("DEC     R2")
                self.emit(f"LOAD16  R0, {lbl_lp}")
                self.emit("JMP     R0")
                self.emit_raw(f"{lbl_end}:")

    def gen_call(self, call: CallExpr):
        if isinstance(call.callee, VarRef) and call.callee.name in self.functions:
            fn = self.functions[call.callee.name]
            cur_name = self.current_func.name if self.current_func else ""
            if len(call.args) == 1:
                pname = fn.params[0][0]
                self.gen_expr(call.args[0])
                self.emit(f"LOAD16  R0, _{fn.name}_{pname}")
                self.emit("LD      (R0), R1")
            elif len(call.args) > 1:
                if fn.name != cur_name and not any(self.expr_contains_call(a) for a in call.args):
                    for idx, arg_expr in enumerate(call.args):
                        pname = fn.params[idx][0]
                        self.gen_expr(arg_expr)
                        self.emit(f"LOAD16  R0, _{fn.name}_{pname}")
                        self.emit("LD      (R0), R1")
                else:
                    for arg_expr in call.args:
                        self.gen_expr(arg_expr)
                        self.emit("RCALL   _ACT4_APUSH_R1")
                    for idx in range(len(call.args) - 1, -1, -1):
                        pname = fn.params[idx][0]
                        self.emit("RCALL   _ACT4_APOP_R1")
                        self.emit(f"LOAD16  R0, _{fn.name}_{pname}")
                        self.emit("LD      (R0), R1")
            self.emit(f"RCALL   _{fn.name}")
        else:
            if len(call.args) == 1:
                self.gen_expr(call.args[0])
                self.emit("LOAD16  R0, _act4_arg0")
                self.emit("LD      (R0), R1")
            elif len(call.args) > 1:
                for arg_expr in call.args:
                    self.gen_expr(arg_expr)
                    self.emit("RCALL   _ACT4_APUSH_R1")
                for idx in range(len(call.args) - 1, -1, -1):
                    self.emit("RCALL   _ACT4_APOP_R1")
                    self.emit(f"LOAD16  R0, _act4_arg{idx}")
                    self.emit("LD      (R0), R1")
            self.gen_expr(call.callee)
            self.emit("LD      R2, R1")
            self.emit("LINK    R2, R0")

# ==============================================================================
# CLI Driver
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(description="ACT4 Compiler for MiniRISC4 Architecture (act4c)")
    parser.add_argument("input", help="ACT4 source file (.a4)")
    parser.add_argument("-o", "--output", default=None, help="Output assembly file (.asm)")
    parser.add_argument("--org", type=lambda x: int(x, 0), default=0x0200,
                        help="Code origin address (default: 0x0200)")
    parser.add_argument("--nopreamble", action="store_true",
                        help="Omit startup vector and stack initialization preamble")
    parser.add_argument("--hw-math", action="store_true",
                        help="Lower *, /, %%, and shifts to HW Math Accelerator (0x0010-0x0016) with startup CPU_CAPS guard")
    parser.add_argument("-I", "-i", "--include", action="append", default=[],
                        help="Add directory to import search path")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"error: Source file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    with open(args.input, "r", encoding="utf-8") as f:
        src = f.read()

    tokens = tokenize(src, args.input)

    structs: Dict[str, StructDef] = {}
    constants: Dict[str, int] = {}
    parser_obj = Parser(tokens, structs, constants)

    def canonical_file(filepath: str) -> str:
        return os.path.normcase(os.path.realpath(os.path.abspath(filepath)))

    imported_files = {canonical_file(args.input)}
    search_dirs = [os.path.dirname(os.path.abspath(args.input))] + list(args.include)

    def resolve_import(rel_name: str, base_file: str) -> str:
        local_candidate = os.path.join(os.path.dirname(os.path.abspath(base_file)), rel_name)
        if os.path.exists(local_candidate):
            return canonical_file(local_candidate)
        for d in search_dirs:
            cand = os.path.join(d, rel_name)
            if os.path.exists(cand):
                return canonical_file(cand)
        raise CompilerError(f"Imported file not found: '{rel_name}'", filename=base_file, line=1)

    def parse_file_with_imports(filepath: str) -> List[ASTNode]:
        with open(filepath, "r", encoding="utf-8") as fh:
            fsrc = fh.read()
        ftoks = tokenize(fsrc, filepath)
        fparser = Parser(ftoks, structs, constants, str_dedup=parser_obj.str_dedup)
        fparser.str_count = parser_obj.str_count
        raw_nodes = fparser.parse_program()
        parser_obj.str_count = fparser.str_count
        parser_obj.string_literals.extend(fparser.string_literals)

        out_nodes: List[ASTNode] = []
        # Re-scan import strings in order
        for idx, t in enumerate(ftoks):
            if t.type == "IMPORT" and idx + 1 < len(ftoks) and ftoks[idx + 1].type == "STR_LIT":
                imp_rel = ftoks[idx + 1].value[1:-1]
                imp_abs = resolve_import(imp_rel, filepath)
                if imp_abs not in imported_files:
                    imported_files.add(imp_abs)
                    out_nodes.extend(parse_file_with_imports(imp_abs))
        out_nodes.extend(raw_nodes)
        return out_nodes

    try:
        ast = parse_file_with_imports(canonical_file(args.input))
    except CompilerError as e:
        print(e, file=sys.stderr)
        sys.exit(1)

    codegen = CodeGen(ast, structs, constants, parser_obj.string_literals,
                      org=args.org, no_preamble=args.nopreamble, hw_math=args.hw_math)
    asm_output = codegen.generate()

    out_file = args.output
    if not out_file:
        base, _ = os.path.splitext(args.input)
        out_file = base + ".asm"

    with open(out_file, "w", encoding="utf-8") as f:
        f.write(asm_output)

    print(f"Successfully compiled '{args.input}' -> '{out_file}'")

if __name__ == "__main__":
    main()

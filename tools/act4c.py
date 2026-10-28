TRAP_BASE = 0x0100
TRAP_STRIDE = 16
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
    ("SHL_ASSIGN", r"<<="),
    ("SHR_ASSIGN", r">>="),
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

class StructDef:
    def __init__(self, name: str, fields: List[Tuple[str, TypeDesc, int]]):
        self.name = name
        self.fields = fields
        self.word_size = sum(f[1].word_size({}) for f in fields)

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
        self.trap_vector = trap_vector

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
# Parser
# ==============================================================================

class Parser:
    def __init__(self, tokens: List[Token], structs: Dict[str, StructDef], constants: Dict[str, int]):
        self.tokens = tokens
        self.pos = 0
        self.structs = structs
        self.constants = constants
        self.string_literals: List[Tuple[str, str]] = []
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
            elif self.match("U16", "VOID") or (self.match("IDENT") and self.cur().value in self.structs) or self.match("FUNC"):
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
        self.structs[name_tok.value] = StructDef(name_tok.value, fields)

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
        elif self.match("IDENT") and self.cur().value in self.structs:
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
        if self.match("IDENT") and self.cur().value in self.structs:
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

        # Handle prefix ++ / --
        if self.match("INC", "DEC"):
            op_tok = self.consume(self.cur().type)
            target = self.parse_unary_or_postfix()
            self.consume("SEMI")
            return IncDecStmt(target, op_tok.value, is_postfix=False)

        expr = self.parse_unary_or_postfix()

        # Handle postfix ++ / --
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
        lines = []
        while not self.match("RBRACE"):
            tok = self.tokens[self.pos]
            self.pos += 1
            lines.append(tok.value)
        self.consume("RBRACE")
        return AsmBlock(" ".join(lines))

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
            lbl = f"_str_lit_{self.str_count}"
            self.str_count += 1
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
# Code Generator
# ==============================================================================

class CodeGen:
    def __init__(self, ast: List[ASTNode], structs: Dict[str, StructDef], constants: Dict[str, int],
                 string_literals: List[Tuple[str, str]], org: int = 0x0100, no_preamble: bool = False):
        self.ast = ast
        self.structs = structs
        self.constants = constants
        self.string_literals = string_literals
        self.org = org
        self.no_preamble = no_preamble
        self.asm: List[str] = []
        self.label_counter = 0

        self.global_vars: Dict[str, VarDecl] = {}
        self.functions: Dict[str, FunctionDef] = {}
        self.current_func: Optional[FunctionDef] = None
        self.loop_stack: List[Tuple[str, str]] = []
        self.trap_bindings: Dict[int, str] = {}

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
        self.emit_raw('.include "M4R_LIB.asm"')
        self.emit_raw("")

        for name, val in self.constants.items():
            self.emit_raw(f".define {name} 0x{val:04X}")
        self.emit_raw("")

        self.emit_raw(f".org 0x{self.org:04X}")
        self.emit_raw("")

        if not self.no_preamble:
            self.emit_raw("; --- Entry Point ---")
            self.emit_raw("_start:")
            self.emit("START_PROGRAM")
            self.emit_raw("_halt:")
            self.emit("LOAD16  R0, _halt")
            self.emit("JMP     R0")
            self.emit_raw("")

        for node in self.ast:
            if isinstance(node, FunctionDef):
                self.gen_function(node)

        self.emit_raw("; ==============================================================================")
        self.emit_raw("; Global Data & Static Storage")
        self.emit_raw("; ==============================================================================")

        for i in range(8):
            self.emit_raw(f"_act4_arg{i}: .word 0")

        for i in range(8):
            self.emit_raw(f"_act4_t{i}: .word 0")

        for name, decl in self.global_vars.items():
            if decl.is_const or decl.address is not None:
                continue
            lbl = f"_{name}"
            if decl.array_inits is not None:
                inits = [f"0x{self.eval_const_init(e):04X}" for e in decl.array_inits]
                self.emit_raw(f"{lbl}: .word " + ", ".join(inits))
            elif decl.typ.array_size is not None:
                zeros = ", ".join(["0"] * decl.typ.array_size)
                self.emit_raw(f"{lbl}: .word {zeros}")
            elif decl.init_expr is not None:
                v = self.eval_const_init(decl.init_expr)
                self.emit_raw(f"{lbl}: .word 0x{v:04X}")
            else:
                sz = decl.typ.word_size(self.structs)
                zeros = ", ".join(["0"] * sz)
                self.emit_raw(f"{lbl}: .word {zeros}")

        if self.string_literals:
            self.emit_raw("")
            self.emit_raw("; --- String Literals ---")
            for lbl, s in self.string_literals:
                clean_s = s.replace('"', '\\"')
                self.emit_raw(f'{lbl}: .asciz "{clean_s}"')

        if self.trap_bindings:
            self.emit_raw("")
            self.emit_raw("; ==============================================================================")
            self.emit_raw("; Trap Vector Table Bindings (0xFFF0 - 0xFFFF)")
            self.emit_raw("; ==============================================================================")
            for vec in sorted(self.trap_bindings.keys()):
                fn_name = self.trap_bindings[vec]
                trap_addr = 0xFFF0 + vec
                self.emit_raw(f".org 0x{trap_addr:04X}")
                self.emit_raw(f"    .word _{fn_name}")

        return "\n".join(self.asm) + "\n"

    def eval_const_init(self, expr: Any) -> int:
        if isinstance(expr, IntLit):
            return expr.val
        if isinstance(expr, VarRef) and expr.name in self.constants:
            return self.constants[expr.name]
        return 0

    def gen_function(self, fn: FunctionDef):
        self.current_func = fn
        self.emit_raw(f"; --- Function: {fn.name} ---")
        if fn.trap_vector is not None:
            self.emit_raw(f"; Bound to hardware Trap Vector {fn.trap_vector} (0x{0xFFF0 + fn.trap_vector:04X})")
        self.emit_raw(f"_{fn.name}:")
        self.emit("RPUSH   R0")

        for stmt in fn.body:
            self.gen_stmt(stmt)

        self.emit("RRET")
        self.emit_raw("")

        for decl in fn.locals_decls:
            if decl.address is not None:
                continue
            lbl = f"_{fn.name}_{decl.name}"
            sz = decl.typ.word_size(self.structs)
            zeros = ", ".join(["0"] * sz)
            self.emit_raw(f"{lbl}: .word {zeros}")

        for pname, _ in fn.params:
            self.emit_raw(f"_{fn.name}_{pname}: .word 0")
        self.emit_raw("")

        self.current_func = None

    def gen_stmt(self, stmt: ASTNode):
        if isinstance(stmt, CommentNode):
            text = stmt.text
            if text.startswith("//"):
                text = text[2:].strip()
            self.emit_raw(f"; // {text}")

        elif isinstance(stmt, AsmBlock):
            self.emit_raw("    ; --- Inline Assembly ---")
            for line in stmt.asm_text.splitlines():
                self.emit_raw(f"    {line.strip()}")

        elif isinstance(stmt, ReturnStmt):
            if stmt.expr is not None:
                self.gen_expr(stmt.expr)
            self.emit("RRET")

        elif isinstance(stmt, BreakStmt):
            if not self.loop_stack:
                raise CompilerError("break statement outside of loop")
            lbl_break, _ = self.loop_stack[-1]
            self.emit(f"LOAD16  R0, {lbl_break}")
            self.emit("JMP     R0")

        elif isinstance(stmt, ContinueStmt):
            if not self.loop_stack:
                raise CompilerError("continue statement outside of loop")
            _, lbl_cont = self.loop_stack[-1]
            self.emit(f"LOAD16  R0, {lbl_cont}")
            self.emit("JMP     R0")

        elif isinstance(stmt, IfStmt):
            lbl_else = self.new_label("else")
            lbl_end = self.new_label("endif")
            self.gen_cond_branch(stmt.cond, invert=True, target_label=lbl_else if stmt.else_block else lbl_end)
            for s in stmt.then_block:
                self.gen_stmt(s)
            if stmt.else_block:
                self.emit(f"LOAD16  R0, {lbl_end}")
                self.emit("JMP     R0")
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
            self.emit("JMP     R0")
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
            self.gen_expr(stmt.value)
            self.emit("LOAD16  R0, _act4_t0")
            self.emit("LD      (R0), R1")
            self.gen_lvalue_addr(stmt.target)
            self.emit("LOAD16  R2, _act4_t0")
            self.emit("LD      R1, (R2)")
            self.emit("LD      (R0), R1")
        else:
            self.gen_lvalue_addr(stmt.target)
            self.emit("LOAD16  R1, _act4_t4")
            self.emit("LD      (R1), R0")

            self.emit("LD      R1, (R0)")
            self.emit("LOAD16  R0, _act4_t5")
            self.emit("LD      (R0), R1")

            self.gen_expr(stmt.value)
            self.emit("LD      R2, R1")
            self.emit("LOAD16  R0, _act4_t5")
            self.emit("LD      R1, (R0)")

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
                self.emit("APUSH   R1")
                self.emit("APUSH   R2")
                self.emit("RCALL   MULT")
                self.emit("APOP    R1")
            elif base_op == "/":
                self.emit("APUSH   R1")
                self.emit("APUSH   R2")
                self.emit("RCALL   DIV")
                self.emit("APOP    R1")
            elif base_op == "%":
                self.emit("APUSH   R1")
                self.emit("APUSH   R2")
                self.emit("RCALL   MOD")
                self.emit("APOP    R1")

            self.emit("LOAD16  R0, _act4_t4")
            self.emit("LD      R0, (R0)")
            self.emit("LD      (R0), R1")

    def gen_setbyte(self, stmt: SetByteStmt):
        self.gen_expr(stmt.base_expr)
        self.emit("LOAD16  R0, _act4_t0")
        self.emit("LD      (R0), R1")

        self.gen_expr(stmt.index_expr)
        self.emit("LOAD16  R0, _act4_t1")
        self.emit("LD      (R0), R1")

        self.gen_expr(stmt.val_expr)
        self.emit("LOAD16  R0, _act4_t2")
        self.emit("LD      (R0), R1")

        self.emit("LOAD16  R0, _act4_t1")
        self.emit("LD      R1, (R0)")
        self.emit("SHIFT.R R1")
        self.emit("LOAD16  R0, _act4_t0")
        self.emit("LD      R2, (R0)")
        self.emit("ADD     R1, R2")
        self.emit("LOAD16  R0, _act4_t3")
        self.emit("LD      (R0), R1")

        self.emit("LD      R0, R1")
        self.emit("LD      R1, (R0)")

        self.emit("LOAD16  R0, _act4_t2")
        self.emit("LD      R2, (R0)")

        self.emit("LOAD16  R0, _act4_t1")
        self.emit("LD      R3, (R0)")
        self.emit("LD0     R0")
        self.emit("INC     R0")
        self.emit("AND     R3, R0")

        lbl_hi = self.new_label("set_hi")
        lbl_done = self.new_label("set_done")

        self.emit(f"LOAD16  R0, {lbl_hi}")
        self.emit("JMP.Z   R0, R3")

        self.emit("BYTE_SET_HI R1, R2")
        self.emit(f"LOAD16  R0, {lbl_done}")
        self.emit("JMP     R0")

        self.emit_raw(f"{lbl_hi}:")
        self.emit("BYTE_SET_LO R1, R2")

        self.emit_raw(f"{lbl_done}:")
        self.emit("LOAD16  R0, _act4_t3")
        self.emit("LD      R0, (R0)")
        self.emit("LD      (R0), R1")

    def gen_lvalue_addr(self, expr: Expr):
        if isinstance(expr, VarRef):
            lbl = self.resolve_var_label(expr.name)
            if expr.name in self.global_vars and self.global_vars[expr.name].address is not None:
                addr = self.global_vars[expr.name].address
                self.emit(f"LOAD16  R0, 0x{addr:04X}")
            else:
                self.emit(f"LOAD16  R0, {lbl}")

        elif isinstance(expr, UnaryOp) and expr.op == "*":
            self.gen_expr(expr.operand)
            self.emit("LD      R0, R1")

        elif isinstance(expr, IndexAccess):
            self.gen_expr(expr.target)
            self.emit("LOAD16  R0, _act4_t0")
            self.emit("LD      (R0), R1")

            self.gen_expr(expr.index)
            self.emit("LOAD16  R0, _act4_t0")
            self.emit("LD      R2, (R0)")
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
                self.emit(f"LOAD16  R2, {offset}")
                self.emit("ADD     R1, R2")
            self.emit("LD      R0, R1")
        else:
            raise CompilerError(f"Cannot take address of non-lvalue expression: {expr}")

    def resolve_var_label(self, name: str) -> str:
        if self.current_func:
            for pname, _ in self.current_func.params:
                if pname == name:
                    return f"_{self.current_func.name}_{pname}"
            for decl in self.current_func.locals_decls:
                if decl.name == name:
                    return f"_{self.current_func.name}_{name}"
        return f"_{name}"

    def get_member_offset(self, target: Expr, member: str) -> int:
        typ_name = self.infer_type(target)
        if typ_name in self.structs:
            sdef = self.structs[typ_name]
            for fname, _, off in sdef.fields:
                if fname == member:
                    return off
        return 0

    def infer_type(self, expr: Expr) -> str:
        if isinstance(expr, VarRef):
            if self.current_func:
                for pname, ptype in self.current_func.params:
                    if pname == expr.name:
                        return ptype.base_type
                for decl in self.current_func.locals_decls:
                    if decl.name == expr.name:
                        return decl.typ.base_type
            if expr.name in self.global_vars:
                return self.global_vars[expr.name].typ.base_type
        return "u16"

    def gen_cond_branch(self, cond: Expr, invert: bool, target_label: str):
        if isinstance(cond, BinaryOp) and cond.op in ("==", "!=", "<", ">", "<=", ">="):
            self.gen_expr(cond.lhs)
            self.emit("LOAD16  R0, _act4_t0")
            self.emit("LD      (R0), R1")

            self.gen_expr(cond.rhs)
            self.emit("LD      R2, R1")
            self.emit("LOAD16  R0, _act4_t0")
            self.emit("LD      R1, (R0)")

            op = cond.op
            if invert:
                inv_map = {"==": "!=", "!=": "==", "<": ">=", ">": "<=", "<=": ">", ">=": "<"}
                op = inv_map[op]

            if op == "==":
                self.emit("SUB     R1, R2")
                self.emit(f"LOAD16  R0, {target_label}")
                self.emit("JMP.Z   R0, R1")
            elif op == "!=":
                lbl_skip = self.new_label("eq_skip")
                self.emit("SUB     R1, R2")
                self.emit(f"LOAD16  R0, {lbl_skip}")
                self.emit("JMP.Z   R0, R1")
                self.emit(f"LOAD16  R0, {target_label}")
                self.emit("JMP     R0")
                self.emit_raw(f"{lbl_skip}:")
            elif op == "<":
                self.emit("RCALL   _CMP_LT")
                self.emit(f"LOAD16  R2, {target_label}")
                self.emit("JMP.Z   R2, R0")
            elif op == ">":
                self.emit("RCALL   _CMP_GT")
                self.emit(f"LOAD16  R2, {target_label}")
                self.emit("JMP.Z   R2, R0")
            elif op == "<=":
                self.emit("RCALL   _CMP_LE")
                self.emit(f"LOAD16  R2, {target_label}")
                self.emit("JMP.Z   R2, R0")
            elif op == ">=":
                self.emit("RCALL   _CMP_GE")
                self.emit(f"LOAD16  R2, {target_label}")
                self.emit("JMP.Z   R2, R0")
        else:
            self.gen_expr(cond)
            if invert:
                self.emit(f"LOAD16  R0, {target_label}")
                self.emit("JMP.Z   R0, R1")
            else:
                lbl_skip = self.new_label("skip")
                self.emit(f"LOAD16  R0, {lbl_skip}")
                self.emit("JMP.Z   R0, R1")
                self.emit(f"LOAD16  R0, {target_label}")
                self.emit("JMP     R0")
                self.emit_raw(f"{lbl_skip}:")

    def gen_expr(self, expr: Expr):
        if isinstance(expr, IntLit):
            self.emit(f"LOAD16  R1, 0x{expr.val:04X}")

        elif isinstance(expr, StrLit):
            self.emit(f"LOAD16  R1, {expr.label}")

        elif isinstance(expr, VarRef):
            lbl = self.resolve_var_label(expr.name)
            if expr.name in self.global_vars and self.global_vars[expr.name].address is not None:
                addr = self.global_vars[expr.name].address
                self.emit(f"LOAD16  R0, 0x{addr:04X}")
                self.emit("LD      R1, (R0)")
            else:
                self.emit(f"LOAD16  R0, {lbl}")
                self.emit("LD      R1, (R0)")

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
                self.emit("JMP.Z   R0, R1")
                self.emit("LD0     R1")
                self.emit(f"LOAD16  R0, {lbl_done}")
                self.emit("JMP     R0")
                self.emit_raw(f"{lbl_true}:")
                self.emit("LD0     R1")
                self.emit("INC     R1")
                self.emit_raw(f"{lbl_done}:")

        elif isinstance(expr, BinaryOp):
            self.gen_binary(expr)

        elif isinstance(expr, IndexAccess):
            self.gen_lvalue_addr(expr)
            self.emit("LD      R1, (R0)")

        elif isinstance(expr, MemberAccess):
            self.gen_lvalue_addr(expr)
            self.emit("LD      R1, (R0)")

        elif isinstance(expr, CallExpr):
            self.gen_call(expr)

        elif isinstance(expr, GetByteExpr):
            self.gen_expr(expr.base_expr)
            self.emit("LOAD16  R0, _act4_t0")
            self.emit("LD      (R0), R1")

            self.gen_expr(expr.index_expr)
            self.emit("LOAD16  R0, _act4_t1")
            self.emit("LD      (R0), R1")

            self.emit("SHIFT.R R1")
            self.emit("LOAD16  R0, _act4_t0")
            self.emit("LD      R2, (R0)")
            self.emit("ADD     R1, R2")
            self.emit("LD      R0, R1")
            self.emit("LD      R1, (R0)")

            self.emit("LOAD16  R0, _act4_t1")
            self.emit("LD      R2, (R0)")
            self.emit("LD0     R0")
            self.emit("INC     R0")
            self.emit("AND     R2, R0")

            lbl_hi = self.new_label("get_hi")
            lbl_done = self.new_label("get_done")
            self.emit(f"LOAD16  R0, {lbl_hi}")
            self.emit("JMP.Z   R0, R2")

            self.emit("BYTE_GET_HI R1, R1")
            self.emit(f"LOAD16  R0, {lbl_done}")
            self.emit("JMP     R0")

            self.emit_raw(f"{lbl_hi}:")
            self.emit("BYTE_GET_LO R1, R1")
            self.emit_raw(f"{lbl_done}:")

    def gen_binary(self, expr: BinaryOp):
        self.gen_expr(expr.lhs)
        self.emit("LOAD16  R0, _act4_t0")
        self.emit("LD      (R0), R1")

        self.gen_expr(expr.rhs)
        self.emit("LD      R2, R1")
        self.emit("LOAD16  R0, _act4_t0")
        self.emit("LD      R1, (R0)")

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
        elif expr.op == "*":
            self.emit("APUSH   R1")
            self.emit("APUSH   R2")
            self.emit("RCALL   MULT")
            self.emit("APOP    R1")
        elif expr.op == "/":
            self.emit("APUSH   R1")
            self.emit("APUSH   R2")
            self.emit("RCALL   DIV")
            self.emit("APOP    R1")
        elif expr.op == "%":
            self.emit("APUSH   R1")
            self.emit("APUSH   R2")
            self.emit("RCALL   MOD")
            self.emit("APOP    R1")
        elif expr.op == ">>":
            if isinstance(expr.rhs, IntLit):
                for _ in range(expr.rhs.val & 0x0F):
                    self.emit("SHIFT.R R1")
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
            if isinstance(expr.rhs, IntLit):
                for _ in range(expr.rhs.val & 0x0F):
                    self.emit("SHIFT.L R1")
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
            for idx, arg_expr in enumerate(call.args):
                pname = fn.params[idx][0]
                self.gen_expr(arg_expr)
                self.emit(f"LOAD16  R0, _{fn.name}_{pname}")
                self.emit("LD      (R0), R1")
            self.emit(f"RCALL   _{fn.name}")
        else:
            # Indirect call via function pointer
            for idx, arg_expr in enumerate(call.args):
                self.gen_expr(arg_expr)
                self.emit(f"LOAD16  R0, _act4_arg{idx}")
                self.emit("LD      (R0), R1")
            self.gen_expr(call.callee)
            # Use R2 to branch to avoid clobbering link return address in R0
            self.emit("LD      R2, R1")
            self.emit("LINK    R2, R0")

# ==============================================================================
# CLI Driver
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(description="ACT4 Compiler for MiniRISC4 Architecture (act4c)")
    parser.add_argument("input", help="ACT4 source file (.a4)")
    parser.add_argument("-o", "--output", default=None, help="Output assembly file (.asm) (default: a_out.asm)")
    parser.add_argument("--org", type=lambda x: int(x, 0), default=0x0200,
                        help="Code origin address (default: 0x0100)")
    parser.add_argument("--nopreamble", action="store_true",
                        help="Omit startup vector and stack initialization preamble")
    parser.add_argument("-I", "--include", action="append", default=[],
                        help="Add directory to import search path")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"error: Source file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(args.input):
        print(f"error: Source file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    with open(args.input, "r", encoding="utf-8") as f:
        src = f.read()

    tokens = tokenize(src, args.input)

    structs: Dict[str, StructDef] = {}
    constants: Dict[str, int] = {}
    parser_obj = Parser(tokens, structs, constants)

    try:
        ast = parser_obj.parse_program()
    except CompilerError as e:
        print(e, file=sys.stderr)
        sys.exit(1)

    codegen = CodeGen(ast, structs, constants, parser_obj.string_literals,
                      org=args.org, no_preamble=args.nopreamble)
    asm_output = codegen.generate()

    out_file = args.output if args.output else "a_out.asm"
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(asm_output)

    print(f"Successfully compiled '{args.input}' -> '{out_file}'")

if __name__ == "__main__":
    main()
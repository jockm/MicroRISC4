#!/usr/bin/env python3
"""
tools/lib2vlog.py - Generate 4-state Verilog behavioral cell models from a
Liberty (.lib) file for post-route Gate-Level Simulation (GLS) of ORFS 6_final.v.

Usage:
  python3 tools/lib2vlog.py --lib <pdk.lib> --netlist <6_final.v> --out <cells.v>

Only emits behavioral models for standard cells actually instantiated in the
target gate-level netlist (including physical fill/tap/decap/diode stubs),
keeping GLS compilation fast and self-contained across sky130hd, ihp-sg13g2,
nangate45, and asap7.
"""

import argparse
import re
import sys
from pathlib import Path


def find_instantiated_cells(netlist_text: str) -> set[str]:
    """Return all module types instantiated in an ORFS gate-level Verilog netlist."""
    # Match lines like:  sky130_fd_sc_hd__nand2_1 _1234_ (
    # or:                sg13g2_dfrbp_1 \foo.bar (
    ignore = {
        "module", "endmodule", "wire", "reg", "input", "output", "inout",
        "assign", "localparam", "parameter", "integer", "begin", "end",
    }
    cells = set()
    for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_$]*)\s+(?:\\[^\s]+|[A-Za-z_][A-Za-z0-9_$]*)\s*\(", netlist_text, re.M):
        mod = m.group(1)
        if mod not in ignore:
            cells.add(mod)
    return cells


def translate_liberty_expr(expr: str) -> str:
    """Translate a Liberty boolean expression into Verilog syntax."""
    s = expr.strip()
    # Handle Liberty postfix inversion: A' -> (~A) and (...) ' -> (~(...))
    # First tokenize cleanly
    tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_]*|[()!&|^*+'~01]", s)
    out: list[str] = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "'":
            # Postfix invert previous atom or parenthesized group
            if not out:
                raise ValueError(f"Unexpected postfix ' in: {expr}")
            if out[-1] == ")":
                depth = 0
                j = len(out) - 1
                while j >= 0:
                    if out[j] == ")":
                        depth += 1
                    elif out[j] == "(":
                        depth -= 1
                        if depth == 0:
                            break
                    j -= 1
                group = out[j:]
                out = out[:j] + ["(~", "("] + group + [")", ")"]
            else:
                prev = out.pop()
                out.append(f"(~{prev})")
        elif tok == "!":
            out.append("~")
        elif tok == "*":
            out.append("&")
        elif tok == "+":
            out.append("|")
        elif tok == "0":
            out.append("1'b0")
        elif tok == "1":
            out.append("1'b1")
        else:
            # Implicit AND between adjacent operands, e.g., "A B" or ") A" or "A ("
            if out and (
                re.match(r"^[A-Za-z_01(~]", tok)
                and (out[-1] == ")" or re.match(r"^(?:[A-Za-z_]|1'b|\(~)", out[-1]))
            ):
                out.append("&")
            out.append(tok)
        i += 1
    return " ".join(out)


def extract_block(text: str, start_brace_idx: int) -> tuple[str, int]:
    """Given index of '{', return (inside_text, index_after_matching_'}')."""
    depth = 0
    i = start_brace_idx
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start_brace_idx + 1 : i], i + 1
        i += 1
    raise ValueError("Unmatched '{' in Liberty file")


def parse_liberty_cells(lib_text: str, wanted: set[str]) -> dict[str, dict]:
    """Parse only the requested cell(...) blocks from a Liberty file."""
    # Strip /* ... */ comments
    lib_text = re.sub(r"/\*.*?\*/", "", lib_text, flags=re.S)
    result: dict[str, dict] = {}
    pat = re.compile(r'\bcell\s*\(\s*"?([A-Za-z0-9_]+)"?\s*\)\s*\{')
    pos = 0
    while True:
        m = pat.search(lib_text, pos)
        if not m:
            break
        cell_name = m.group(1)
        brace_idx = m.end() - 1
        body, end_pos = extract_block(lib_text, brace_idx)
        pos = end_pos
        if cell_name not in wanted:
            continue

        info: dict = {"inputs": [], "outputs": [], "ff": None, "latch": None}

        # Parse ff(...) if present
        ff_m = re.search(r'\bff\s*\(\s*"?([A-Za-z0-9_]+)"?\s*,\s*"?([A-Za-z0-9_]+)"?\s*\)\s*\{', body)
        if ff_m:
            iq, iqn = ff_m.group(1), ff_m.group(2)
            ff_body, _ = extract_block(body, ff_m.end() - 1)
            ff_data = {"iq": iq, "iqn": iqn}
            for attr in ("clocked_on", "next_state", "clear", "preset"):
                am = re.search(rf'\b{attr}\s*:\s*"([^"]+)"', ff_body)
                if am:
                    ff_data[attr] = am.group(1).strip()
            info["ff"] = ff_data

        # Parse latch(...) if present
        lat_m = re.search(r'\blatch\s*\(\s*"?([A-Za-z0-9_]+)"?\s*,\s*"?([A-Za-z0-9_]+)"?\s*\)\s*\{', body)
        if lat_m:
            iq, iqn = lat_m.group(1), lat_m.group(2)
            lat_body, _ = extract_block(body, lat_m.end() - 1)
            lat_data = {"iq": iq, "iqn": iqn}
            for attr in ("enable", "data_in", "clear", "preset"):
                am = re.search(rf'\b{attr}\s*:\s*"([^"]+)"', lat_body)
                if am:
                    lat_data[attr] = am.group(1).strip()
            info["latch"] = lat_data

        # Parse pin(...) blocks
        pin_pat = re.compile(r'\bpin\s*\(\s*"?([A-Za-z0-9_]+)"?\s*\)\s*\{')
        ppos = 0
        while True:
            pm = pin_pat.search(body, ppos)
            if not pm:
                break
            pin_name = pm.group(1)
            pin_body, pend = extract_block(body, pm.end() - 1)
            ppos = pend
            dir_m = re.search(r'\bdirection\s*:\s*"?([a-z]+)"?', pin_body)
            if not dir_m:
                continue
            direction = dir_m.group(1)
            if direction == "input":
                info["inputs"].append(pin_name)
            elif direction == "output":
                fn_m = re.search(r'\bfunction\s*:\s*"([^"]+)"', pin_body)
                fn = fn_m.group(1).strip() if fn_m else "0"
                info["outputs"].append((pin_name, fn))

        result[cell_name] = info
    return result


def emit_cell_verilog(name: str, info: dict) -> str:
    """Emit a 4-state Verilog behavioral module for a single Liberty cell."""
    in_pins = info["inputs"]
    out_pins = [p for p, _ in info["outputs"]]
    all_ports = in_pins + out_pins

    lines = []
    if not all_ports:
        lines.append(f"module {name} ();")
        lines.append("endmodule")
        return "\n".join(lines)

    lines.append(f"module {name} ({', '.join(all_ports)});")
    for p in in_pins:
        lines.append(f"  input wire {p};")
    for p in out_pins:
        lines.append(f"  output wire {p};")

    if info["ff"] is not None:
        ff = info["ff"]
        iq = ff["iq"]
        iqn = ff["iqn"]
        clk_raw = ff["clocked_on"]
        ns_expr = translate_liberty_expr(ff["next_state"])

        # Clock edge detection
        if clk_raw.startswith("!") or clk_raw.endswith("'"):
            clk_pin = clk_raw.lstrip("!").rstrip("'").strip()
            clk_edge = f"negedge {clk_pin}"
        else:
            clk_pin = clk_raw.strip()
            clk_edge = f"posedge {clk_pin}"

        sens = [clk_edge]
        clr_cond = None
        pre_cond = None
        if "clear" in ff:
            c_raw = ff["clear"]
            if c_raw.startswith("!") or c_raw.endswith("'"):
                cp = c_raw.lstrip("!").rstrip("'").strip()
                sens.append(f"negedge {cp}")
                clr_cond = f"!{cp}"
            else:
                cp = c_raw.strip()
                sens.append(f"posedge {cp}")
                clr_cond = cp
        if "preset" in ff:
            p_raw = ff["preset"]
            if p_raw.startswith("!") or p_raw.endswith("'"):
                pp = p_raw.lstrip("!").rstrip("'").strip()
                sens.append(f"negedge {pp}")
                pre_cond = f"!{pp}"
            else:
                pp = p_raw.strip()
                sens.append(f"posedge {pp}")
                pre_cond = pp

        lines.append(f"  reg {iq};")
        lines.append(f"  wire {iqn} = ~{iq};")
        lines.append(f"  always @({' or '.join(sens)}) begin")
        if clr_cond and pre_cond:
            lines.append(f"    if ({clr_cond}) {iq} <= 1'b0;")
            lines.append(f"    else if ({pre_cond}) {iq} <= 1'b1;")
            lines.append(f"    else {iq} <= {ns_expr};")
        elif clr_cond:
            lines.append(f"    if ({clr_cond}) {iq} <= 1'b0;")
            lines.append(f"    else {iq} <= {ns_expr};")
        elif pre_cond:
            lines.append(f"    if ({pre_cond}) {iq} <= 1'b1;")
            lines.append(f"    else {iq} <= {ns_expr};")
        else:
            lines.append(f"    {iq} <= {ns_expr};")
        lines.append("  end")
        for p, fn in info["outputs"]:
            lines.append(f"  assign {p} = {translate_liberty_expr(fn)};")
    elif info["latch"] is not None:
        lat = info["latch"]
        iq = lat["iq"]
        iqn = lat["iqn"]
        en_expr = translate_liberty_expr(lat["enable"])
        d_expr = translate_liberty_expr(lat["data_in"])
        lines.append(f"  reg {iq};")
        lines.append(f"  wire {iqn} = ~{iq};")
        lines.append("  always @(*) begin")
        lines.append(f"    if ({en_expr}) {iq} = {d_expr};")
        lines.append("  end")
        for p, fn in info["outputs"]:
            lines.append(f"  assign {p} = {translate_liberty_expr(fn)};")
    else:
        for p, fn in info["outputs"]:
            lines.append(f"  assign {p} = {translate_liberty_expr(fn)};")

    lines.append("endmodule")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate GLS Verilog cell models from Liberty .lib")
    ap.add_argument("--lib", required=True, nargs="+", help="Path(s) to Liberty .lib file(s)")
    ap.add_argument("--netlist", required=True, help="Path to ORFS post-route 6_final.v")
    ap.add_argument("--out", required=True, help="Output Verilog cell library path")
    args = ap.parse_args()

    netlist_text = Path(args.netlist).read_text(encoding="utf-8", errors="ignore")
    wanted = find_instantiated_cells(netlist_text)
    if not wanted:
        print("Error: no cell instances found in netlist", file=sys.stderr)
        return 1

    parsed: dict[str, dict] = {}
    for lib_path in args.lib:
        lib_text = Path(lib_path).read_text(encoding="utf-8", errors="ignore")
        parsed.update(parse_liberty_cells(lib_text, wanted - set(parsed.keys())))

    out_lines = [
        "// Auto-generated 4-state GLS behavioral cell models from PDK Liberty",
        "`timescale 1ns/1ps",
        "",
    ]

    # Physical-only cells (tap, fill, decap, antenna diode) have no Liberty entry
    stub_count = 0
    for cell_name in sorted(wanted):
        if cell_name in parsed:
            out_lines.append(emit_cell_verilog(cell_name, parsed[cell_name]))
            out_lines.append("")
        else:
            # Check port names used in netlist for this physical cell (e.g. DIODE has .DIODE(...))
            inst_m = re.search(rf"\b{re.escape(cell_name)}\s+(?:\\[^\s]+|[A-Za-z_][A-Za-z0-9_$]*)\s*\(([^;]*?)\);", netlist_text, re.S)
            port_names = []
            if inst_m:
                port_names = sorted(set(re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)\s*\(", inst_m.group(1))))
            if port_names:
                out_lines.append(f"module {cell_name} ({', '.join(port_names)});")
                for pn in port_names:
                    out_lines.append(f"  input wire {pn};")
                out_lines.append("endmodule\n")
            else:
                out_lines.append(f"module {cell_name} ();\nendmodule\n")
            stub_count += 1

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("\n".join(out_lines), encoding="utf-8")
    print(f"Generated {len(parsed)} Liberty behavioral models + {stub_count} physical stubs -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

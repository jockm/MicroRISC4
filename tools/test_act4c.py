#!/usr/bin/env python3
"""Focused host-compiler compatibility fixtures for the resident compiler port."""

import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = REPO_ROOT / "tools"
LIB_DIR = REPO_ROOT / "lib"
COMPILER = TOOLS_DIR / "act4c.py"
ASSEMBLER = TOOLS_DIR / "mr4asm.py"
BASELINE_ASSEMBLY_SHA256 = "41906febc9cffac311d453c36d6125a14c979a3bdd78feafa4d3a9865b34c027"
BASELINE_BINARY_SHA256 = "43f46a9203848fc10b7ed51dcb257f17779029008183f3a7f8458a306ad4cf95"


def run_compiler(source: Path, *options: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(COMPILER), str(source), *options],
        capture_output=True,
        text=True,
        check=False,
    )


def run_assembler(assembly: Path, output: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(ASSEMBLER),
            "-I",
            str(LIB_DIR),
            str(assembly),
            "-o",
            str(output),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


class Act4CompilerBaselineTests(unittest.TestCase):
    def test_default_output_is_deterministic_and_assembles(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "baseline.a4"
            source.write_text(
                "const u16 ANSWER = 42;\n"
                "u16 marker = ANSWER;\n"
                "u16 zeroed[2];\n"
                "void main(void) {}\n",
                encoding="utf-8",
            )

            first = run_compiler(source)
            self.assertEqual(first.returncode, 0, first.stderr)
            assembly = source.with_suffix(".asm")
            first_output = assembly.read_text(encoding="utf-8")
            self.assertEqual(
                hashlib.sha256(first_output.encode("utf-8")).hexdigest(),
                BASELINE_ASSEMBLY_SHA256,
            )
            self.assertIn(".define ANSWER 0x002A", first_output)
            self.assertIn(".org 0x0200", first_output)
            self.assertIn("_marker: .word 0x002A", first_output)
            self.assertIn("_zeroed: .resw 2", first_output)
            self.assertIn('.include "M4R_LIB.asm"', first_output)

            second = run_compiler(source)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(assembly.read_text(encoding="utf-8"), first_output)

            binary = Path(temp_dir) / "baseline.bin"
            assembled = run_assembler(assembly, binary)
            self.assertEqual(assembled.returncode, 0, assembled.stderr)
            self.assertTrue(binary.is_file())
            self.assertGreater(binary.stat().st_size, 0)
            self.assertEqual(
                hashlib.sha256(binary.read_bytes()).hexdigest(),
                BASELINE_BINARY_SHA256,
            )

    def test_codegen_options_are_reflected_in_output(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "options.a4"
            output = Path(temp_dir) / "options.asm"
            source.write_text(
                "void main(void) {\n"
                "    u16 lhs = 7;\n"
                "    u16 rhs = 3;\n"
                "    u16 product = lhs * rhs;\n"
                "}\n",
                encoding="utf-8",
            )

            result = run_compiler(
                source,
                "-o",
                str(output),
                "--org",
                "0x0400",
                "--nopreamble",
                "--hw-math",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            assembly = output.read_text(encoding="utf-8")
            self.assertIn(".org 0x0400", assembly)
            self.assertNotIn(".org 0x0100", assembly)
            self.assertIn("_act4_require_hw_math:", assembly)
            self.assertIn("_ACT4_HW_MUL:", assembly)
            self.assertIn("RCALL   _ACT4_HW_MUL", assembly)

    def test_nested_relative_and_include_imports_are_deduplicated(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_dir = root / "src"
            include_dir = root / "include"
            source_dir.mkdir()
            include_dir.mkdir()
            source = source_dir / "main.a4"
            (source_dir / "shared.a4").write_text(
                "u16 shared_value(void) { return 5; }\n",
                encoding="utf-8",
            )
            (source_dir / "outer.a4").write_text(
                'import "shared.a4";\n'
                "u16 outer_value(void) { return shared_value(); }\n",
                encoding="utf-8",
            )
            (include_dir / "extra.a4").write_text(
                "u16 extra_value(void) { return 7; }\n",
                encoding="utf-8",
            )
            source.write_text(
                'import "outer.a4";\n'
                'import "shared.a4";\n'
                'import "extra.a4";\n'
                "void main(void) {\n"
                "    u16 total = outer_value() + shared_value() + extra_value();\n"
                "}\n",
                encoding="utf-8",
            )
            output = root / "imports.asm"

            result = run_compiler(source, "-I", str(include_dir), "-o", str(output))
            self.assertEqual(result.returncode, 0, result.stderr)
            assembly = output.read_text(encoding="utf-8")
            self.assertEqual(assembly.count("_shared_value:"), 1)
            self.assertEqual(assembly.count("_outer_value:"), 1)
            self.assertEqual(assembly.count("_extra_value:"), 1)

    def test_trap_data_payload_defaults_to_zero(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "trap.a4"
            output = Path(temp_dir) / "trap.asm"
            source.write_text(
                "void main(void) {\n"
                "    trap(2);\n"
                "    trap(3, 0xA5);\n"
                "}\n",
                encoding="utf-8",
            )

            result = run_compiler(source, "-o", str(output))
            self.assertEqual(result.returncode, 0, result.stderr)
            assembly = output.read_text(encoding="utf-8")
            self.assertIn("TRAP    R1, 0x00", assembly)
            self.assertIn("TRAP    R1, 0xA5", assembly)
            assembled = run_assembler(output, Path(temp_dir) / "trap.bin")
            self.assertEqual(assembled.returncode, 0, assembled.stderr)

    def test_invalid_source_reports_location_and_does_not_write_output(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "invalid.a4"
            output = Path(temp_dir) / "invalid.asm"
            source.write_text(
                "void main(void) {\n"
                "    if (1) return;\n"
                "}\n",
                encoding="utf-8",
            )

            result = run_compiler(source, "-o", str(output))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid.a4:2:", result.stderr)
            self.assertIn("error:", result.stderr)
            self.assertFalse(output.exists())

    def test_help_lists_supported_compiler_options(self):
        result = subprocess.run(
            [sys.executable, str(COMPILER), "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for option in ("--output", "--org", "--nopreamble", "--hw-math", "--include"):
            self.assertIn(option, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)

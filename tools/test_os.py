#!/usr/bin/env python3
"""
tools/test_os.py - Automated regression test suite for the MicroRISC4
ACT4 compiler, runtime library, FAT32 filesystem, Trap ISRs, and
Core 0 + Worker Core 1 userland execution.

Usage:
    python3 tools/test_os.py [--sd-image /tmp/mr4_sd.img] [--filter <substr>]
"""

import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import traceback
from collections import deque
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = REPO_ROOT / "tools"
LIB_DIR = REPO_ROOT / "lib"
BUILD_DIR = REPO_ROOT / "build"
OS_BUILD = BUILD_DIR / "os"

sys.path.insert(0, str(TOOLS_DIR))
import mr4sim  # noqa: E402


def compile_and_assemble(
    src_path: Path,
    out_bin: Path,
    *,
    org: int | None = None,
    nopreamble: bool = False,
    sparsebin: bool = False,
    hw_math: bool = False,
) -> Path:
    asm_path = out_bin.with_suffix(".asm")
    lst_path = out_bin.with_suffix(".lst")
    cmd_c = [
        sys.executable,
        str(TOOLS_DIR / "act4c.py"),
        str(src_path),
        "-o",
        str(asm_path),
        "-I",
        str(LIB_DIR),
    ]
    if org is not None:
        cmd_c.extend(["--org", hex(org)])
    if nopreamble:
        cmd_c.append("--nopreamble")
    if hw_math:
        cmd_c.append("--hw-math")
    subprocess.run(cmd_c, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    cmd_a = [
        sys.executable,
        str(TOOLS_DIR / "mr4asm.py"),
        "-I",
        str(LIB_DIR),
        str(asm_path),
        "-o",
        str(out_bin),
        "-l",
        str(lst_path),
    ]
    if sparsebin:
        cmd_a.append("--sparsebin")
    subprocess.run(cmd_a, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return lst_path


def attach_uart_and_watch(sim: mr4sim.MicroRISC4Sim):
    """Capture UART TX output and watch for illegal writes to low memory 0x0000..0x0009."""
    uart_out: list[str] = []
    bad_writes: list[tuple[int, int, int, int]] = []
    orig_write = sim.write_mem

    def watched_write(addr: int, val: int):
        am = addr & 0xFFFF
        vm = val & 0xFFFF
        if am == mr4sim.ADDR_UART_TX:
            uart_out.append(chr(vm & 0xFF))
            return
        if am <= 0x0009:
            if am in (0x0004, 0x0005):
                if vm < 0xE000:
                    bad_writes.append((sim.cycles, sim.pc, am, vm))
            else:
                bad_writes.append((sim.cycles, sim.pc, am, vm))
        orig_write(addr, val)

    sim.write_mem = watched_write
    sim._poll_stdin = lambda: None
    return uart_out, bad_writes


def read_fat32_file(image: bytes | bytearray, path: str) -> bytes:
    part_lba = struct.unpack_from("<I", image, 454)[0]
    bpb = image[part_lba * 512 : (part_lba + 1) * 512]
    spc = bpb[13]
    reserved = struct.unpack_from("<H", bpb, 14)[0]
    num_fats = bpb[16]
    fat_size = struct.unpack_from("<I", bpb, 36)[0]
    root_cluster = struct.unpack_from("<I", bpb, 44)[0]
    fat_offset = (part_lba + reserved) * 512
    data_lba = part_lba + reserved + num_fats * fat_size

    def next_cluster(cluster: int) -> int:
        return struct.unpack_from("<I", image, fat_offset + cluster * 4)[0] & 0x0FFFFFFF

    def cluster_chain(first: int):
        cluster = first
        while 2 <= cluster < 0x0FFFFFF8:
            yield cluster
            cluster = next_cluster(cluster)

    def find_entry(directory_cluster: int, component: str) -> bytes:
        base, _, ext = component.upper().partition(".")
        short_name = (base[:8].ljust(8) + ext[:3].ljust(3)).encode("ascii")
        for cluster in cluster_chain(directory_cluster):
            cluster_offset = (data_lba + (cluster - 2) * spc) * 512
            for offset in range(0, spc * 512, 32):
                entry = image[cluster_offset + offset : cluster_offset + offset + 32]
                if entry[0] == 0:
                    break
                if entry[0] == 0xE5 or entry[11] == 0x0F:
                    continue
                if entry[:11] == short_name:
                    return entry
        raise AssertionError(f"FAT32 path component not found: {component}")

    components = [part for part in path.replace("\\", "/").split("/") if part]
    directory_cluster = root_cluster
    entry = b""
    for index, component in enumerate(components):
        entry = find_entry(directory_cluster, component)
        if index + 1 < len(components):
            directory_cluster = (
                (struct.unpack_from("<H", entry, 20)[0] << 16)
                | struct.unpack_from("<H", entry, 26)[0]
            )

    first_cluster = (
        (struct.unpack_from("<H", entry, 20)[0] << 16)
        | struct.unpack_from("<H", entry, 26)[0]
    )
    size = struct.unpack_from("<I", entry, 28)[0]
    content = bytearray()
    for cluster in cluster_chain(first_cluster):
        cluster_offset = (data_lba + (cluster - 2) * spc) * 512
        content.extend(image[cluster_offset : cluster_offset + spc * 512])
        if len(content) >= size:
            break
    return bytes(content[:size])


def run_until_prompt(sim, uart_out, max_steps=6000000, worker=None) -> bool:
    start = len(uart_out)
    for _ in range(max_steps):
        sim.step()
        if worker is not None:
            worker.step()
        if sim.halted:
            return False
        if len(uart_out) > start and is_shell_prompt("".join(uart_out[start:])):
            return True
    return False


def is_shell_prompt(text: str) -> bool:
    prompt_line = text.rsplit("\n", 1)[-1]
    return "mr4:" in prompt_line and prompt_line.endswith("> ")


def has_shell_prompt(text: str) -> bool:
    return "mr4:" in text


def shell_prompt_count(text: str) -> int:
    return text.count("mr4:")


# ------------------------------------------------------------------------------
# Test 1: ACT4 compiler & M4R_LIB runtime (MULT, DIV/MOD, structs, array decay)
# ------------------------------------------------------------------------------
def test_compiler_runtime(_args):
    src = """
u16 uart_tx @ 0x000F;

type Item {
    u16 tag;
    u16 name[4];
};

Item items[3];

void putc(u16 c) {
    while (uart_tx != 0) {}
    uart_tx = c;
}

void puts(u16 *s) {
    u16 i = 0;
    u16 c = 0;
    while (true) {
        c = getbyte(s, i);
        if (c == 0) { return; }
        putc(c);
        i++;
    }
}

void check(u16 cond, u16 code) {
    if (cond == 0) {
        puts("FAIL:");
        putc(code);
        putc(10);
        while (true) {}
    }
}

void set_item_name(Item *it, u16 *src) {
    u16 i = 0;
    u16 c = 0;
    while (i < 7) {
        c = getbyte(src, i);
        setbyte(it->name, i, c);
        if (c == 0) { return; }
        i++;
    }
    setbyte(it->name, 7, 0);
}

void main(void) {
    u16 a = 0;
    u16 b = 0;
    u16 q = 0;
    u16 r = 0;

    a = 0; b = 10; check(a * b == 0, 65);
    a = 1; b = 10; check(a * b == 10, 66);
    a = 7; b = 11; check(a * b == 77, 67);
    a = 300; b = 200; check(a * b == 60000, 68);
    a = 0xFFFF; b = 0xFFFF; check(a * b == 1, 69);

    a = 100; b = 7; q = a / b; r = a % b;
    check(q == 14, 70);
    check(r == 2, 71);
    a = 65535; b = 40000; q = a / b; r = a % b;
    check(q == 1, 72);
    check(r == 25535, 73);
    a = 60000; b = 1000; q = a / b; r = a % b;
    check(q == 60, 74);
    check(r == 0, 75);

    items[0].tag = 11;
    items[1].tag = 22;
    items[2].tag = 33;
    set_item_name(&items[0], "alpha");
    set_item_name(&items[1], "beta");
    set_item_name(&items[2], "gamma");

    check(items[0].tag == 11, 76);
    check(items[1].tag == 22, 77);
    check(items[2].tag == 33, 78);
    check(getbyte(items[0].name, 0) == 97, 79);
    check(getbyte(items[1].name, 0) == 98, 80);
    check(getbyte(items[2].name, 4) == 97, 81);

    setbyte(items[2].name, 0, getbyte(items[0].name, 0));
    check(getbyte(items[2].name, 0) == 97, 82);

    a = 5;
    a += (items[1].tag * 2);
    check(a == 49, 83);

    puts("PASS\\n");
    while (true) {}
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        a4 = p / "rt.a4"
        out_bin = p / "rt.bin"
        a4.write_text(src, encoding="utf-8")
        compile_and_assemble(a4, out_bin)

        sim = mr4sim.MicroRISC4Sim(core_id=0)
        sim.load_binary(str(out_bin))
        sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(sim)

        for _ in range(250000):
            sim.step()
            if "\n" in "".join(uart_out):
                break

        res = "".join(uart_out).strip()
        assert res == "PASS", f"Unexpected runtime test output: {res!r}"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert sim.mem[0x0005] == 0xFAFF, f"ASP leaked: 0x{sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 2: @ trap(N) ISR direct-stride dispatch, register preservation & nesting
# ------------------------------------------------------------------------------
def test_trap_isr(_args):
    src = """
u16 uart_tx @ 0x000F;
u16 t1_count = 0;
u16 t2_count = 0;
u16 saved_r1 = 0;
u16 saved_r2 = 0;
u16 saved_r3 = 0;

void putc(u16 c) {
    while (uart_tx != 0) {}
    uart_tx = c;
}

void puts(u16 *s) {
    u16 i = 0;
    u16 c = 0;
    while (true) {
        c = getbyte(s, i);
        if (c == 0) { return; }
        putc(c);
        i++;
    }
}

void on_trap2(void) @ trap(2) {
    u16 tmp = t2_count + 1;
    t2_count = tmp;
    if (t2_count == 1) {
        return;
    }
    t2_count = t2_count + 10;
}

void on_trap1(void) @ trap(1) {
    u16 v = 0x1234;
    t1_count = t1_count + 1;
    trap(2, 0x00);
    v = v + t1_count;
}

void fail(u16 code) {
    puts("FAIL:");
    putc(code);
    putc(10);
    while (true) {}
}

void main(void) {
    asm {
        LOAD16  R1, 0x1111
        LOAD16  R2, 0x2222
        LOAD16  R3, 0x3333
        LD0     R0
        INC     R0
        TRAP    R0, 0x42
        LOAD16  R0, _saved_r1
        LD      (R0), R1
        LOAD16  R0, _saved_r2
        LD      (R0), R2
        LOAD16  R0, _saved_r3
        LD      (R0), R3
    }

    if (t1_count != 1) { fail(65); }
    if (t2_count != 1) { fail(66); }
    if (saved_r1 != 0x1111) { fail(67); }
    if (saved_r2 != 0x2222) { fail(68); }
    if (saved_r3 != 0x3333) { fail(69); }

    trap(2, 0x00);
    if (t2_count != 12) { fail(70); }

    puts("PASS\\n");
    while (true) {}
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        a4 = p / "trap.a4"
        out_bin = p / "trap.bin"
        a4.write_text(src, encoding="utf-8")
        compile_and_assemble(a4, out_bin)

        sim = mr4sim.MicroRISC4Sim(core_id=0)
        sim.load_binary(str(out_bin))
        sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(sim)

        for _ in range(100000):
            sim.step()
            if "\n" in "".join(uart_out):
                break

        res = "".join(uart_out).strip()
        assert res == "PASS", f"Unexpected trap ISR output: {res!r}"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert sim.mem[0x0005] == 0xFAFF, f"ASP leaked: 0x{sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 3: Core 0 OS boot, PCB init, shell commands, FAT32 ls/cat/write/rm
# ------------------------------------------------------------------------------
def test_os_shell_fs(args):
    img_bytes = Path(args.sd_image).read_bytes()
    part_lba = struct.unpack_from("<I", img_bytes, 454)[0]
    bpb = img_bytes[part_lba * 512 : (part_lba + 1) * 512]
    spc = bpb[13]
    rsvd = struct.unpack_from("<H", bpb, 14)[0]
    num_fats = bpb[16]
    fat_sz = struct.unpack_from("<I", bpb, 36)[0]
    root_clus = struct.unpack_from("<I", bpb, 44)[0]
    fat1_off = (part_lba + rsvd) * 512
    fat2_off = (part_lba + rsvd + fat_sz) * 512
    data_lba = part_lba + rsvd + num_fats * fat_sz
    root_off = (data_lba + (root_clus - 2) * spc) * 512

    readme_clus = None
    bin_clus = None
    work_clus = None
    for idx in range(16):
        ent = img_bytes[root_off + idx * 32 : root_off + (idx + 1) * 32]
        name = ent[0:11].decode("ascii", errors="ignore")
        clus = (struct.unpack_from("<H", ent, 20)[0] << 16) | struct.unpack_from("<H", ent, 26)[0]
        if name == "README  TXT":
            readme_clus = clus
        elif name == "BIN        ":
            bin_clus = clus
        elif name == "WORK       ":
            work_clus = clus
    assert readme_clus is not None and bin_clus is not None and work_clus is not None

    ls_clus = None
    bin_off = (data_lba + (bin_clus - 2) * spc) * 512
    for idx in range(16):
        ent = img_bytes[bin_off + idx * 32 : bin_off + (idx + 1) * 32]
        name = ent[0:11].decode("ascii", errors="ignore")
        clus = (struct.unpack_from("<H", ent, 20)[0] << 16) | struct.unpack_from("<H", ent, 26)[0]
        if name == "LS      PRG":
            ls_clus = clus
    assert ls_clus is not None

    sim = mr4sim.MicroRISC4Sim(core_id=0)
    sim.sd_card = mr4sim.SpiSdCard(img_bytes)
    sim.load_binary(str(OS_BUILD / "os_main.bin"))
    sim.load_symbols(str(OS_BUILD / "os_main.lst"))
    sim.pc = 0x0100
    uart_out, bad_writes = attach_uart_and_watch(sim)

    assert run_until_prompt(sim, uart_out, 1500000), "OS boot timed out"

    # Verify procs[0] initialized cleanly
    procs_addr = sim.sym_to_addr["_procs"]
    assert sim.mem[procs_addr] == 2, f"Expected procs[0].state==2, got {sim.mem[procs_addr]}"
    raw = bytearray()
    for w in range(8):
        word = sim.mem[procs_addr + 2 + w]
        raw.append(word & 0xFF)
        raw.append((word >> 8) & 0xFF)
    p0_name = raw.split(b"\x00", 1)[0].decode("ascii", errors="replace")
    assert p0_name == "os_kernel", f"Unexpected procs[0].name: {p0_name!r}"

    cmds = [
        "cd /",
        "help",
        "ps",
        "ls",
        "ls /bin",
        "echo Hello MicroRISC4 world",
        "clear",
        "stat",
        "stat README.TXT",
        "stat NOFILE.TXT",
        "cat",
        "cat README.TXT",
        "cat readme.txt",
        "cat NOFILE.TXT",
        "write",
        "write note.txt Hello MicroRISC4!",
        "cat NOTE.TXT",
        "write NOTE.TXT Updated line",
        "cat note.txt",
        "rm",
        "rm NOFILE.TXT",
        "rm NOTE.TXT",
        "cat NOTE.TXT",
        "rm readme.txt",
        "cat README.TXT",
    ]
    for cmd in cmds:
        for ch in cmd + "\r":
            sim.rx_queue.append(ord(ch))
        assert run_until_prompt(sim, uart_out, 6000000), f"Command {cmd!r} timed out"

    text = "".join(uart_out)
    for snippet in (
        "FAT32 mounted OK",
        "0    RUN    os_kernel",
        "BIN",
        "WORK",
        "LS.PRG",
        "Hello MicroRISC4 world",
        "\x1b[2J\x1b[H",
        "Usage: stat <file>",
        "README.TXT  size=37 bytes  attr=0x0020",
        "Usage: cat <file>",
        "Hello from MicroRISC4 FAT32 SD card!",
        "File not found: NOFILE.TXT",
        "Usage: write <file> <text>",
        "Wrote note.txt",
        "Hello MicroRISC4!",
        "Wrote NOTE.TXT",
        "Updated line",
        "Usage: rm <file>",
        "Removed NOTE.TXT",
        "File not found: NOTE.TXT",
        "Removed readme.txt",
        "File not found: README.TXT",
    ):
        assert snippet in text, f"Missing expected UART output {snippet!r}"

    fat1_readme = struct.unpack_from("<I", sim.sd_card.image, fat1_off + readme_clus * 4)[0]
    fat2_readme = struct.unpack_from("<I", sim.sd_card.image, fat2_off + readme_clus * 4)[0]
    fat1_ls = struct.unpack_from("<I", sim.sd_card.image, fat1_off + ls_clus * 4)[0]
    fat1_root = struct.unpack_from("<I", sim.sd_card.image, fat1_off + root_clus * 4)[0]
    assert fat1_readme == 0 and fat2_readme == 0, "README.TXT cluster not freed in both FAT copies"
    assert fat1_ls != 0 and fat1_root == 0x0FFFFFFF, "Adjacent FAT entries corrupted"
    assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
    assert sim.mem[0x0005] == 0xFAFF, f"ASP leaked: 0x{sim.mem[0x0005]:04X}"


def test_os_resident_assembler(_args):
    source = """\
.include "common.inc"
.define TEST_VALUE (0x1230 + 4)
.equ TEST_WORD 0xABCD
.org 0x0408
.byte 0xA5, 0x5A
.org 0x0400
START_PROGRAM
_main:
GET_CPUID R1
FIFO_POP R2
FIFO_PUSH R2
TRIGGER_TRAP 1, 0x12
SWAP R1, R2
LOAD16 R1, TEST_VALUE
LD0 R0
NOT R1
NEG R2
XCHGALL
SAVEALL
LOADALL
STPUSH 4, R0
STPOP 4, R0
RPUSH R0
RPOP R0
APUSH R1
APOP R1
PUSHALL
POPALL
RCALL target
RRET
BYTE_GET_LO R0, R1
BYTE_GET_HI R0, R1
BYTE_SET_LO R0, R1
BYTE_SET_HI R0, R1
target:
NOP
ERET
.word TEST_WORD + CPUID, >TEST_VALUE
.hex DEADBEEF 1
.byte 'A', 0x42
.asciz "HI\\r\\n"
.resw 2
.align
"""
    bad_source = ".macro BAD x\nNOP\n.endmacro\n"
    unsupported_uart_sources = {
        "PUTC.ASM": "PUTC R0\n",
        "GETC.ASM": "GETC R1\n",
    }
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        sd_root = root / "sd_root"
        (sd_root / "BIN").mkdir(parents=True)
        work = sd_root / "WORK"
        work.mkdir()
        shutil.copy(OS_BUILD / "asm.prg", sd_root / "BIN" / "ASM.PRG")
        hello_source = REPO_ROOT / "sdcard" / "WORK" / "HELLO.ASM"
        shutil.copy(hello_source, work / "HELLO.ASM")
        hello_prg = work / "HELLO.PRG"
        subprocess.run(
            [
                sys.executable,
                str(TOOLS_DIR / "mr4asm.py"),
                "-I",
                str(LIB_DIR),
                "--sparsebin",
                str(hello_source),
                "-o",
                str(hello_prg),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        source_path = work / "SAMPLE.ASM"
        source_path.write_text(source, encoding="utf-8")
        (work / "BAD.ASM").write_text(bad_source, encoding="utf-8")
        for filename, contents in unsupported_uart_sources.items():
            (work / filename).write_text(contents, encoding="utf-8")

        sd_img = root / "asm_test.img"
        subprocess.run(
            [
                sys.executable,
                str(TOOLS_DIR / "mksdimage.py"),
                str(sd_root),
                "-o",
                str(sd_img),
                "--size-mb",
                "16",
                "--spc",
                "1",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        sim = mr4sim.MicroRISC4Sim(core_id=0)
        sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        sim.load_binary(str(OS_BUILD / "os_main.bin"))
        sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(sim)

        worker = mr4sim.MicroRISC4Sim(core_id=1)
        worker.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker.pc = 0x0100
        worker._poll_stdin = lambda: None
        mr4sim.connect_os_worker(sim, worker)
        assert run_until_prompt(sim, uart_out, 1500000, worker=worker), "OS boot timed out"

        procs_addr = sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10

        def run_app(command: str, max_steps: int = 50000000) -> str:
            start = len(uart_out)
            for ch in command + "\r":
                sim.rx_queue.append(ord(ch))
            completed = run_until_prompt(sim, uart_out, max_steps, worker=worker)
            output = "".join(uart_out[start:])
            assert completed, (
                f"{command} prompt timeout; output={output!r}; "
                f"os_pc=0x{sim.pc:04X}; worker_pc=0x{worker.pc:04X}; "
                f"state={sim.mem[pid1_state]}; "
                f"worker_syscall={worker.mem[0x03F4]:04X}"
            )
            return output

        output = run_app("! ASM.PRG SAMPLE.ASM OUT.PRG")
        assert "asm: wrote OUT.PRG" in output, f"Assembler failed:\n{output}"
        assert sim.mem[pid1_state] == 0 and sim.mem[pid1_state + 1] == 0

        expected = root / "expected.prg"
        reference = subprocess.run(
            [
                sys.executable,
                str(TOOLS_DIR / "mr4asm.py"),
                "-I",
                str(LIB_DIR),
                "--sparsebin",
                str(source_path),
                "-o",
                str(expected),
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert reference.returncode == 0, reference.stderr.decode("utf-8", errors="replace")
        actual_bytes = read_fat32_file(sim.sd_card.image, "WORK/OUT.PRG")
        assert actual_bytes == expected.read_bytes(), (
            f"Resident assembler output differs from mr4asm.py "
            f"({len(actual_bytes)} vs {expected.stat().st_size} bytes)"
        )

        hello_output = run_app("! HELLO.PRG")
        assert "Hello from Mr4OS!" in hello_output, f"HELLO.ASM syscall output missing:\n{hello_output}"
        assert sim.mem[pid1_state] == 0 and sim.mem[pid1_state + 1] == 0

        output = run_app("! ASM.PRG BAD.ASM SHOULD.PRG")
        assert "general preprocessor directives are not supported" in output, output
        assert sim.mem[pid1_state] == 0 and sim.mem[pid1_state + 1] == 1
        for filename in unsupported_uart_sources:
            output = run_app(f"! ASM.PRG {filename} SHOULD.PRG")
            assert "unknown instruction or directive" in output, output
            assert sim.mem[pid1_state] == 0 and sim.mem[pid1_state + 1] == 1
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"


# ------------------------------------------------------------------------------
# Test 4: Lean Ring MBOX Doorbell (Trap 14 ERET) -> GO Grant -> SYS_PUTC -> Shell
# ------------------------------------------------------------------------------
def test_os_async_trap1(args):
    sim = mr4sim.MicroRISC4Sim(core_id=0)
    peer = mr4sim.MicroRISC4Sim(core_id=1)
    peer.halted = True  # Synthetic peer NI only
    fabric = mr4sim.connect_os_worker(sim, peer)

    sim.sd_card = mr4sim.SpiSdCard(Path(args.sd_image).read_bytes())
    sim.load_binary(str(OS_BUILD / "os_main.bin"))
    sim.load_symbols(str(OS_BUILD / "os_main.lst"))
    sim.pc = 0x0100
    uart_out, bad_writes = attach_uart_and_watch(sim)

    assert run_until_prompt(sim, uart_out, 1500000), "OS boot timed out"

    # Mark PID 1 running & console-enabled, then ring Core 0's Lean Ring MBOX doorbell
    procs_addr = sim.sym_to_addr["_procs"]
    sim.mem[procs_addr + 10] = 2  # PROC_RUN
    sim.mem[sim.sym_to_addr["_proc_con_out"] + 1] = 1

    peer.noc_ni.set_sel(0)
    assert peer.noc_ni.send_mbox(0x5302), "Failed to send MBOX doorbell"

    # Wait for Core 0's Trap 14 (ERET) + main loop to grant "GO" (0x474F)
    got_grant = False
    for _ in range(100000):
        sim.step()
        if len(peer.noc_ni.rx_fifo) >= 1:
            tok = peer.noc_ni.fifo_r()
            assert tok == 0x474F, f"Expected CMD_SYS_GRANT (0x474F), got 0x{tok:04X}"
            got_grant = True
            break
    assert got_grant, "Core 0 did not send CMD_SYS_GRANT after MBOX doorbell"

    # Stream Class A SYS_PUTC('!') packet into Core 0's Lean Ring RX FIFO
    for w in ((1 << 8) | 0x02, 2, ord("!"), 0):
        assert peer.noc_ni.send_data(w), f"Failed to push syscall word 0x{w:04X}"

    for _ in range(100000):
        sim.step()
        if len(peer.noc_ni.rx_fifo) >= 2:
            break

    reply = [peer.noc_ni.fifo_r(), peer.noc_ni.fifo_r()]
    assert reply == [0, 0], f"Unexpected SYS_PUTC reply: {reply}"
    assert "mr4:" in "".join(uart_out) and "> !" in "".join(uart_out), "SYS_PUTC '!' missing from UART"

    for ch in "ps\r":
        sim.rx_queue.append(ord(ch))
    assert run_until_prompt(sim, uart_out, 1500000), "Shell unresponsive after Lean Ring Trap 14"
    assert "0    RUN    os_kernel" in "".join(uart_out)
    assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
    assert sim.mem[0x0005] == 0xFAFF, f"ASP leaked: 0x{sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 5: 2-core Core 0 + Worker Core 1 userland suite (LS, PS, CAT, WRTEST)
# ------------------------------------------------------------------------------
def test_os_multicore_apps(_args):
    wrtest_src = """
import "sys.a4";

u16 rbuf[32];

void main(void) {
    u16 fd = 0;
    u16 written = 0;
    u16 nwords = 0;

    if (sys_open("APP.TXT", O_WRONLY, &fd) != 0) {
        sys_puts("WRTEST: open write failed\\r\\n");
        sys_exit(1);
    }
    if (sys_write(fd, "Userland write OK!\\n", 19, &written) != 0 || written != 19) {
        sys_puts("WRTEST: write failed\\r\\n");
        sys_close(fd);
        sys_exit(2);
    }
    sys_close(fd);

    if (sys_open("app.txt", O_RDONLY, &fd) != 0) {
        sys_puts("WRTEST: open read failed\\r\\n");
        sys_exit(3);
    }
    if (sys_read(fd, rbuf, 31, &nwords) != 0) {
        sys_puts("WRTEST: read failed\\r\\n");
        sys_close(fd);
        sys_exit(4);
    }
    rbuf[nwords] = 0;
    sys_puts("READBACK:");
    sys_puts(rbuf);
    sys_close(fd);
    sys_exit(0);
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        a4 = p / "wrtest.a4"
        wr_bin = p / "wrtest.bin"
        a4.write_text(wrtest_src, encoding="utf-8")
        compile_and_assemble(a4, wr_bin, org=0x0400, nopreamble=True, sparsebin=True)

        # >4K-word binary proving streaming loader lifts the old RUN_BUF_MAX=4096 cap
        # (uses non-zero initialized data so .bss trimming keeps it >8KB on disk, plus
        #  a .bss array to verify runtime zero-fill!)
        big_inits = ", ".join(["1"] + ["0"] * 4198 + ["2"])
        big_src = f"""
import "sys.a4";

u16 big_pad[4200] = {{ {big_inits} }};
u16 big_bss[256];

void main(void) {{
    if (big_pad[0] != 1 || big_pad[4199] != 2 || big_bss[0] != 0 || big_bss[255] != 0) {{
        sys_puts("BIGAPP_FAIL\\r\\n");
        sys_exit(1);
    }}
    big_pad[0] = 0x1234;
    big_pad[4199] = 0x5678;
    if (big_pad[0] == 0x1234 && big_pad[4199] == 0x5678) {{
        sys_puts("BIGAPP_OK\\r\\n");
        sys_exit(0);
    }}
    sys_puts("BIGAPP_FAIL\\r\\n");
    sys_exit(1);
}}
"""
        big_a4 = p / "bigapp.a4"
        big_bin = p / "bigapp.bin"
        big_a4.write_text(big_src, encoding="utf-8")
        compile_and_assemble(big_a4, big_bin, org=0x0400, nopreamble=True, sparsebin=True)
        assert big_bin.stat().st_size > 8192, f"Expected >8KB (>4096-word) binary, got {big_bin.stat().st_size}B"

        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(OS_BUILD / "ls.prg", sd_root / "LS.PRG")
        shutil.copy(OS_BUILD / "ps.prg", sd_root / "PS.PRG")
        shutil.copy(OS_BUILD / "cat.prg", sd_root / "CAT.PRG")
        shutil.copy(wr_bin, sd_root / "WRTEST.PRG")
        shutil.copy(big_bin, sd_root / "BIGAPP.PRG")
        (sd_root / "README.TXT").write_text("Hello from MicroRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "mc_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None

        mr4sim.connect_os_worker(os_sim, worker_sim)

        assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state_addr = procs_addr + 10

        def run_app(cmd: str, marker: str) -> str:
            start = len(uart_out)
            for ch in cmd + "\r":
                os_sim.rx_queue.append(ord(ch))
            assert run_until_prompt(os_sim, uart_out, 14000000, worker=worker_sim), f"{cmd} prompt timeout"
            seg = "".join(uart_out[start:])
            assert os_sim.mem[pid1_state_addr] == 0 and marker in seg, (
                f"{cmd} failed or missed {marker!r}; output:\n{seg}"
            )
            assert os_sim.mem[pid1_state_addr + 1] == 0, f"{cmd} exit_code={os_sim.mem[pid1_state_addr + 1]}"
            return seg

        seg_ls = run_app("! LS.PRG", "README.TXT")
        seg_ps = run_app("!PS.PRG", "1    RUN    PS.PRG")
        seg_cat = run_app("! CAT.PRG", "Hello from MicroRISC4 FAT32 SD card!")
        seg_wr = run_app("! WRTEST.PRG", "READBACK:Userland write OK!")
        seg_cat_arg = run_app("! CAT.PRG APP.TXT", "Userland write OK!")
        seg_cat_nospace = run_app("!CAT.PRG app.txt", "Userland write OK!")
        assert "Userland write OK!" in seg_cat_arg and "Userland write OK!" in seg_cat_nospace
        seg_big = run_app("! BIGAPP.PRG", "BIGAPP_OK")
        assert "BIGAPP_OK" in seg_big

        # Confirm Core 0 shell reads back APP.TXT written by Worker Core 1
        for ch in "cat APP.TXT\r":
            os_sim.rx_queue.append(ord(ch))
        assert run_until_prompt(os_sim, uart_out, 4000000, worker=worker_sim), "cat APP.TXT failed"

        assert "CAT.PRG" in seg_ls and "PS.PRG" in seg_ls and "WRTEST.PRG" in seg_ls
        assert "0    RUN    os_kernel" in seg_ps and "1    RUN    PS.PRG" in seg_ps
        assert "Hello from MicroRISC4 FAT32 SD card!" in seg_cat
        assert "READBACK:Userland write OK!" in seg_wr
        assert "".join(uart_out).count("Userland write OK!") >= 2

        fds_addr = os_sim.sym_to_addr["_fds"]
        open_fds = [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0]
        assert not open_fds, f"Leaked open FDs: {open_fds}"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
        assert worker_sim.mem[0x0004] == 0xFEFF, f"Core 1 RSP leaked: 0x{worker_sim.mem[0x0004]:04X}"
        assert worker_sim.mem[0x0005] == 0xFAFF, f"Core 1 ASP leaked: 0x{worker_sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 6: MuL structured interpreter and OS filesystem commands
# ------------------------------------------------------------------------------
def test_os_mul(_args):
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        sd_root = p / "sd_root"
        shutil.copytree(BUILD_DIR / "sd_root", sd_root)
        (sd_root / "TEST.MUL").write_text(
            "set n 0\n"
            "expr 2+3*4\n"
            "if {(2 + 3) * 4 == 20}\n"
            "puts MUL_EXPR_OK\n"
            "end\n"
            "set greeting {hello}\n"
            "puts \"$greeting from MuL\"\n"
            "while {$n < 3}\n"
            "puts $n\n"
            "incr n\n"
            "end\n"
            "if {$n == 3}\n"
            "puts MUL_CONTROL_OK\n"
            "else\n"
            "puts MUL_CONTROL_FAIL\n"
            "end\n"
            "set item0 apple\n"
            "set item1 banana\n"
            "set index 0\n"
            "while {$index < 2}\n"
            "puts $item$index\n"
            "incr index\n"
            "end\n"
            "set index 1\n"
            "set item$index cherry\n"
            "puts $item$index\n"
            "argc count\n"
            "puts $count\n"
            "argv 0 script\n"
            "argv 1 first\n"
            "argv 2 second\n"
            "puts $script\n"
            "puts $first $second\n"
            "args allargs\n"
            "puts $allargs\n"
            "write OUT.TXT {hello from MuL}\n"
            "append OUT.TXT {appended}\n"
            "mv OUT.TXT MOVED.TXT\n"
            "cat MOVED.TXT\n"
            "stat MOVED.TXT\n"
            "mkdir MULDIR\n"
            "ls\n"
            "cd MULDIR\n"
            "pwd\n"
            "cd /\n"
            "rmdir MULDIR\n"
            "rm MOVED.TXT\n"
            "gets response\n"
            "puts $response\n"
            "puts MUL_OS_OK\n",
            encoding="ascii",
        )
        sd_img = p / "mul_test.img"
        subprocess.run(
            [
                sys.executable,
                str(TOOLS_DIR / "mksdimage.py"),
                str(sd_root),
                "-o",
                str(sd_img),
                "--size-mb",
                "16",
                "--spc",
                "1",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None
        mr4sim.connect_os_worker(os_sim, worker_sim)

        assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"
        for ch in "cd /\r":
            os_sim.rx_queue.append(ord(ch))
        assert run_until_prompt(os_sim, uart_out, worker=worker_sim), "Could not switch to root directory"
        start = len(uart_out)
        for ch in "! MUL.PRG TEST.MUL alpha beta\r":
            os_sim.rx_queue.append(ord(ch))
        for _ in range(50000000):
            os_sim.step()
            worker_sim.step()
            if "".join(uart_out[-11:]).endswith("MuL input> "):
                break
        else:
            raise AssertionError("MuL script did not reach gets")
        for ch in "console input\r":
            os_sim.rx_queue.append(ord(ch))
            for _ in range(400):
                os_sim.step()
                worker_sim.step()
        assert run_until_prompt(
            os_sim, uart_out, 5000000, worker=worker_sim
        ), "MuL script timed out after gets"
        output = "".join(uart_out[start:])
        for expected in (
            "14\r\n",
            "MUL_EXPR_OK",
            "hello from MuL",
            "0\r\n1\r\n2\r\n",
            "MUL_CONTROL_OK",
            "apple\r\nbanana\r\ncherry\r\n",
            "3\r\n",
            "TEST.MUL",
            "alpha beta",
            "TEST.MUL alpha beta",
            "hello from MuL\r\nappended\r\n",
            "MOVED.TXT",
            "/MULDIR",
            "console input",
            "MUL_OS_OK",
        ):
            assert expected in output, f"MuL output missing {expected!r}:\n{output}"
        assert "MUL_CONTROL_FAIL" not in output

        procs_addr = os_sim.sym_to_addr["_procs"]
        assert os_sim.mem[procs_addr + 10] == 0, "MuL worker did not exit"
        assert os_sim.mem[procs_addr + 11] == 0, "MuL returned a nonzero exit code"
        fds_addr = os_sim.sym_to_addr["_fds"]
        open_fds = [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0]
        assert not open_fds, f"MuL leaked open FDs: {open_fds}"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert worker_sim.mem[0x0004] == 0xFEFF, "MuL leaked the return stack"
        assert worker_sim.mem[0x0005] == 0xFAFF, "MuL leaked the argument stack"


# ------------------------------------------------------------------------------
# Test 7: Multi-worker (Cores 1..3) + userland SYS_SPAWN (Core 1 spawns Core 2)
# ------------------------------------------------------------------------------
def test_os_spawn_multiworker(_args):
    spawner_src = """
import "sys.a4";

u16 msg[8];

void main(void) {
    u16 child_pid = 0;
    if (sys_spawn("CAT.PRG NOTE.TXT", &child_pid) != 0) {
        sys_puts("SPAWN: failed\\r\\n");
        sys_exit(1);
    }
    // Emit status line atomically in a single SYS_WRITE_CON so concurrent
    // Core 2 output can interleave around (never inside) the parent's line.
    setbyte(msg, 0, 83);  // S
    setbyte(msg, 1, 80);  // P
    setbyte(msg, 2, 65);  // A
    setbyte(msg, 3, 87);  // W
    setbyte(msg, 4, 78);  // N
    setbyte(msg, 5, 69);  // E
    setbyte(msg, 6, 68);  // D
    setbyte(msg, 7, 58);  // :
    setbyte(msg, 8, child_pid + 48);
    setbyte(msg, 9, 13);
    setbyte(msg, 10, 10);
    setbyte(msg, 11, 0);
    sys_puts(msg);
    sys_exit(0);
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        a4 = p / "spawner.a4"
        sp_bin = p / "spawner.bin"
        a4.write_text(spawner_src, encoding="utf-8")
        compile_and_assemble(a4, sp_bin, org=0x0400, nopreamble=True, sparsebin=True)

        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(OS_BUILD / "cat.prg", sd_root / "CAT.PRG")
        shutil.copy(sp_bin, sd_root / "SPAWN.PRG")
        (sd_root / "NOTE.TXT").write_text("Hello from MicroRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "spawn_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        workers = []
        for cid in (1, 2, 3):
            ws = mr4sim.MicroRISC4Sim(core_id=cid)
            ws.load_binary(str(BUILD_DIR / "worker_stub.bin"))
            ws.pc = 0x0100
            ws._poll_stdin = lambda: None
            workers.append(ws)
        mr4sim.connect_os_workers(os_sim, workers)

        def step_all(max_steps, stop_fn):
            for _ in range(max_steps):
                os_sim.step()
                for ws in workers:
                    ws.step()
                if stop_fn():
                    return True
            return False

        # Boot OS
        assert step_all(1500000, lambda: is_shell_prompt("".join(uart_out))), "OS boot failed"

        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        pid2_state = procs_addr + 20

        start = len(uart_out)
        for ch in "! SPAWN.PRG\r":
            os_sim.rx_queue.append(ord(ch))
        assert step_all(
            14000000,
            lambda: len(uart_out) > start and is_shell_prompt("".join(uart_out[start:])),
        ), f"! SPAWN.PRG prompt timeout; output:\n{''.join(uart_out[start:])}"

        # Wait until BOTH parent (PID 1 on Core 1) and child (PID 2 on Core 2) finish
        def both_finished():
            if os_sim.mem[pid1_state] != 0 or os_sim.mem[pid2_state] != 0:
                return False
            seg_now = "".join(uart_out[start:])
            if "SPAWNED:2\r\n" not in seg_now:
                return False
            return "Hello from MicroRISC4 FAT32 SD card!" in seg_now.replace("SPAWNED:2\r\n", "")

        done = step_all(12000000, both_finished)
        seg = "".join(uart_out[start:])
        assert done, f"Multi-worker SYS_SPAWN failed; output:\n{seg}"
        assert os_sim.mem[pid1_state + 1] == 0, f"Parent PID 1 exit={os_sim.mem[pid1_state + 1]}"
        assert os_sim.mem[pid2_state + 1] == 0, f"Child PID 2 exit={os_sim.mem[pid2_state + 1]}"

        # Run `ps` so Core 0 returns to idle shell prompt and workers settle in _loader_idle
        ps_start = len(uart_out)
        for ch in "ps\r":
            os_sim.rx_queue.append(ord(ch))
        assert step_all(
            2000000,
            lambda: len(uart_out) > ps_start and is_shell_prompt("".join(uart_out[ps_start:])),
        ), "ps after multi-worker SYS_SPAWN timed out"
        ps_out = "".join(uart_out[ps_start:])
        assert "1    FREE" in ps_out and "2    FREE" in ps_out, f"Workers not reclaimed in ps:\n{ps_out}"

        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
        for idx, ws in enumerate(workers, start=1):
            assert ws.mem[0x0004] == 0xFEFF, f"Worker {idx} RSP leaked: 0x{ws.mem[0x0004]:04X}"
            assert ws.mem[0x0005] == 0xFAFF, f"Worker {idx} ASP leaked: 0x{ws.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 8: Shell line overflow/editing, worker exhaustion & Trap 14 kill recovery
# ------------------------------------------------------------------------------
def test_os_edge_shell_and_kill(_args):
    spin_src = """
import "sys.a4";

void main(void) {
    u16 fd = 0;
    // Deliberately open an FD and never close it so kill must reclaim it
    sys_open("README.TXT", O_RDONLY, &fd);
    while (true) {
    }
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        a4 = p / "spin.a4"
        spin_bin = p / "spin.bin"
        a4.write_text(spin_src, encoding="utf-8")
        compile_and_assemble(a4, spin_bin, org=0x0400, nopreamble=True, sparsebin=True)

        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(OS_BUILD / "cat.prg", sd_root / "CAT.PRG")
        shutil.copy(spin_bin, sd_root / "SPIN.PRG")
        (sd_root / "README.TXT").write_text("Hello from MicroRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "kill_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        workers = []
        for cid in (1, 2, 3):
            ws = mr4sim.MicroRISC4Sim(core_id=cid)
            ws.load_binary(str(BUILD_DIR / "worker_stub.bin"))
            ws.pc = 0x0100
            ws._poll_stdin = lambda: None
            workers.append(ws)
        mr4sim.connect_os_workers(os_sim, workers)

        def step_all(max_steps, stop_fn):
            for _ in range(max_steps):
                os_sim.step()
                for ws in workers:
                    ws.step()
                if stop_fn():
                    return True
            return False

        def send_cmd(cmd_str, max_steps=6000000):
            start = len(uart_out)
            for ch in cmd_str:
                os_sim.rx_queue.append(ord(ch))
            ok = step_all(max_steps, lambda: len(uart_out) > start and is_shell_prompt("".join(uart_out[start:])))
            assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
            return "".join(uart_out[start:])

        assert step_all(1500000, lambda: is_shell_prompt("".join(uart_out))), "OS boot failed"

        # 1. Shell edge cases: backspace (0x08 & 0x7F), >LINE_MAX clamping, unknown command
        out_bs = send_cmd("ecxo\x08\x7fho edit_ok\r")
        assert "\r\nedit_ok\r\n" in out_bs, f"Backspace edit failed: {out_bs!r}"

        long_line = "echo " + ("A" * 80) + "\r"
        out_long = send_cmd(long_line)
        # LINE_MAX = 64 -> max 63 chars: "echo " (5) + 58 'A's
        assert ("A" * 58) in out_long and ("A" * 59) not in out_long, f"Line clamp failed: {out_long!r}"

        out_unk = send_cmd("boguscmd\r")
        assert "Unknown command: boguscmd" in out_unk

        # 2. Exhaust all 3 worker cores with runaway SPIN.PRG instances
        assert "Spawned PID 1" in send_cmd("run SPIN.PRG\r")
        assert "Spawned PID 2" in send_cmd("run SPIN.PRG\r")
        assert "Spawned PID 3" in send_cmd("run SPIN.PRG\r")
        assert "No free worker core" in send_cmd("run SPIN.PRG\r")

        # Give workers time to execute their sys_open("README.TXT") and enter spin loop
        fds_addr = os_sim.sym_to_addr["_fds"]
        assert step_all(
            2000000,
            lambda: sum(1 for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0) == 3,
        ), "Expected all 3 runaway workers to hold open FDs"

        out_ps = send_cmd("ps\r")
        assert "1    RUN    SPIN.PRG" in out_ps
        assert "2    RUN    SPIN.PRG" in out_ps
        assert "3    RUN    SPIN.PRG" in out_ps

        # 3. Invalid kill targets + kill PIDs 1..3 via Mailbox Trap 14
        assert "kill failed" in send_cmd("kill 0\r")
        assert "kill failed" in send_cmd("kill 9\r")
        assert "Killed PID 1" in send_cmd("kill 1\r")
        assert "Killed PID 2" in send_cmd("kill 2\r")
        assert "Killed PID 3" in send_cmd("kill 3\r")
        assert "kill failed" in send_cmd("kill 1\r")

        # Verify all 3 leaked FDs were reclaimed by fat32_close_owner
        open_fds = [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0]
        assert not open_fds, f"Leaked FDs after kill: {open_fds}"

        # 4. Verify killed worker Core 1 cleanly resets and executes CAT.PRG in foreground
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        out_cat = send_cmd("! CAT.PRG\r", max_steps=12000000)
        assert "Hello from MicroRISC4 FAT32 SD card!" in out_cat, (
            f"Worker 1 failed to run CAT.PRG after Trap 14 kill: {out_cat!r}"
        )
        assert os_sim.mem[pid1_state] == 0 and os_sim.mem[pid1_state + 1] == 0
        send_cmd("ps\r")

        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF
        for idx, ws in enumerate(workers, start=1):
            assert ws.mem[0x0004] == 0xFEFF, f"Worker {idx} RSP leaked: 0x{ws.mem[0x0004]:04X}"
            assert ws.mem[0x0005] == 0xFAFF, f"Worker {idx} ASP leaked: 0x{ws.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 9: FD exhaustion, invalid syscalls (Class A/B/C), & multi-cluster write/read
# ------------------------------------------------------------------------------
def test_os_stress_fd_syscalls_multicluster(_args):
    stress_src = """
import "sys.a4";

u16 fds_open[8];
u16 io_buf[64];

void fail(u16 code) {
    sys_puts("STRESS_FAIL:");
    sys_putc(code);
    sys_puts("\\r\\n");
    sys_exit(code);
}

void main(void) {
    u16 i = 0;
    u16 chunk = 0;
    u16 fd = 0;
    u16 extra_fd = 0;
    u16 written = 0;
    u16 nwords = 0;
    u16 expected = 0;
    u16 got = 0;
    u16 st = 0;

    // 1. Invalid syscalls: Class A (0x0F), Class B (0x1F), Class C (0x2F)
    // Verify Core 0 drains FIFO payload cleanly and returns ERR_UNKNOWN (0xFFFF)
    _sys_p1 = 0x1234;
    _sys_p2 = 0x5678;
    asm {
        LOAD16  R0, __sys_p1
        LD      R1, (R0)
        LOAD16  R0, __sys_p2
        LD      R2, (R0)
        LD0     R0
        INC     R0
        TRAP    R0, 0x0F
        LOAD16  R0, __sys_r1
        LD      (R0), R1
    }
    if (_sys_r1 != 0xFFFF) { fail(65); }

    _sys_p1 = io_buf;
    _sys_p2 = 3;
    _sys_p3 = 0x00AA;
    asm {
        LOAD16  R0, __sys_p1
        LD      R1, (R0)
        LOAD16  R0, __sys_p2
        LD      R2, (R0)
        LOAD16  R0, __sys_p3
        LD      R3, (R0)
        LD0     R0
        INC     R0
        TRAP    R0, 0x1F
        LOAD16  R0, __sys_r1
        LD      (R0), R1
    }
    if (_sys_r1 != 0xFFFF) { fail(66); }

    _sys_p1 = io_buf;
    _sys_p2 = 4;
    _sys_p3 = 0;
    asm {
        LOAD16  R0, __sys_p1
        LD      R1, (R0)
        LOAD16  R0, __sys_p2
        LD      R2, (R0)
        LOAD16  R0, __sys_p3
        LD      R3, (R0)
        LD0     R0
        INC     R0
        TRAP    R0, 0x2F
        LOAD16  R0, __sys_r1
        LD      (R0), R1
    }
    if (_sys_r1 != 0xFFFF) { fail(67); }

    // 2. Multi-cluster file write (640 bytes = 5 x 128B > 512B cluster size)
    if (sys_open("BIG.TXT", O_WRONLY, &fd) != 0) { fail(68); }
    chunk = 0;
    while (chunk < 5) {
        i = 0;
        while (i < 128) {
            setbyte(io_buf, i, ((chunk * 17) + i) & 0x00FF);
            i++;
        }
        if (sys_write(fd, io_buf, 128, &written) != 0 || written != 128) { fail(69); }
        chunk++;
    }
    sys_close(fd);

    // Read all 640 bytes back across the 512-byte cluster boundary and verify every byte
    if (sys_open("BIG.TXT", O_RDONLY, &fd) != 0) { fail(70); }
    chunk = 0;
    while (chunk < 5) {
        if (sys_read(fd, io_buf, 64, &nwords) != 0 || nwords != 64) { fail(71); }
        i = 0;
        while (i < 128) {
            expected = ((chunk * 17) + i) & 0x00FF;
            got = getbyte(io_buf, i);
            if (got != expected) { fail(72); }
            i++;
        }
        chunk++;
    }
    // Next read must return EOF (non-zero)
    if (sys_read(fd, io_buf, 64, &nwords) == 0) { fail(73); }
    sys_close(fd);

    // Unlink BIG.TXT via SYS_UNLINK to free both allocated clusters
    if (sys_unlink("BIG.TXT") != 0) { fail(74); }
    if (sys_open("BIG.TXT", O_RDONLY, &fd) == 0) { fail(75); }

    // 3. FD exhaustion: open all 8 FDs, verify 9th fails, close 1, reopen 1,
    // and deliberately exit with all 8 still open so kernel reclaims them!
    i = 0;
    while (i < 8) {
        if (sys_open("README.TXT", O_RDONLY, &fd) != 0) { fail(76); }
        fds_open[i] = fd;
        i++;
    }
    st = sys_open("README.TXT", O_RDONLY, &extra_fd);
    if (st == 0) { fail(77); }

    sys_close(fds_open[3]);
    if (sys_open("README.TXT", O_RDONLY, &extra_fd) != 0) { fail(78); }
    if (extra_fd != fds_open[3]) { fail(79); }

    sys_puts("STRESS_OK\\r\\n");
    sys_exit(0);
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        a4 = p / "stress.a4"
        st_bin = p / "stress.bin"
        a4.write_text(stress_src, encoding="utf-8")
        compile_and_assemble(a4, st_bin, org=0x0400, nopreamble=True, sparsebin=True)

        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(st_bin, sd_root / "STRESS.PRG")
        (sd_root / "README.TXT").write_text("Hello from MicroRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "stress_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        init_img = sd_img.read_bytes()
        part_lba = struct.unpack_from("<I", init_img, 454)[0]
        bpb = init_img[part_lba * 512 : (part_lba + 1) * 512]
        rsvd = struct.unpack_from("<H", bpb, 14)[0]
        fat_sz = struct.unpack_from("<I", bpb, 36)[0]
        fat1_off = (part_lba + rsvd) * 512
        fat2_off = (part_lba + rsvd + fat_sz) * 512

        def count_used_clusters(img_buf, fat_off):
            return sum(
                1 for c in range(2, 64)
                if (struct.unpack_from("<I", img_buf, fat_off + c * 4)[0] & 0x0FFFFFFF) != 0
            )

        init_used_f1 = count_used_clusters(init_img, fat1_off)

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(init_img)
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None
        mr4sim.connect_os_worker(os_sim, worker_sim)

        assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10

        start = len(uart_out)
        for ch in "! STRESS.PRG\r":
            os_sim.rx_queue.append(ord(ch))
        assert run_until_prompt(os_sim, uart_out, 30000000, worker=worker_sim), (
            f"! STRESS.PRG prompt timeout; out={''.join(uart_out[start:])!r}"
        )
        seg = "".join(uart_out[start:])
        assert os_sim.mem[pid1_state] == 0 and "STRESS_OK" in seg, f"STRESS.PRG failed; output:\n{seg}"
        assert os_sim.mem[pid1_state + 1] == 0, f"STRESS.PRG exit={os_sim.mem[pid1_state + 1]}"

        # Settle to prompt via `ps`
        for ch in "ps\r":
            os_sim.rx_queue.append(ord(ch))
        assert run_until_prompt(os_sim, uart_out, 2000000, worker=worker_sim)

        # Verify ALL 8 leaked FDs were auto-reclaimed on exit
        fds_addr = os_sim.sym_to_addr["_fds"]
        open_fds = [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0]
        assert not open_fds, f"Leaked FDs after STRESS.PRG exit: {open_fds}"

        # Verify multi-cluster BIG.TXT freed BOTH clusters cleanly in FAT1 & FAT2
        end_used_f1 = count_used_clusters(os_sim.sd_card.image, fat1_off)
        end_used_f2 = count_used_clusters(os_sim.sd_card.image, fat2_off)
        assert end_used_f1 == init_used_f1 and end_used_f2 == init_used_f1, (
            f"FAT cluster leak: init={init_used_f1}, after FAT1={end_used_f1}, FAT2={end_used_f2}"
        )

        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF
        assert worker_sim.mem[0x0004] == 0xFEFF
        assert worker_sim.mem[0x0005] == 0xFAFF


# ------------------------------------------------------------------------------
# Test 10: Cooperative fibers (lib/fiber.a4 + FIBERS.PRG) on a single worker core
# ------------------------------------------------------------------------------
def test_os_cooperative_fibers(args):
    os_sim = mr4sim.MicroRISC4Sim(core_id=0)
    os_sim.sd_card = mr4sim.SpiSdCard(Path(args.sd_image).read_bytes())
    os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
    os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
    os_sim.pc = 0x0100
    uart_out, bad_writes = attach_uart_and_watch(os_sim)

    worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
    worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
    worker_sim.pc = 0x0100
    worker_sim._poll_stdin = lambda: None
    mr4sim.connect_os_worker(os_sim, worker_sim)

    assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"
    procs_addr = os_sim.sym_to_addr["_procs"]
    pid1_state = procs_addr + 10

    start = len(uart_out)
    for ch in "! FIBERS.PRG\r":
        os_sim.rx_queue.append(ord(ch))
    assert run_until_prompt(os_sim, uart_out, 25000000, worker=worker_sim), (
        f"! FIBERS.PRG prompt timeout; out={''.join(uart_out[start:])!r}"
    )

    seg = "".join(uart_out[start:])
    assert os_sim.mem[pid1_state] == 0, f"FIBERS.PRG still running; output:\n{seg}"
    assert "A0 B0 C0 A1 B1 C1 A2 B2 C2 " in seg, f"Unexpected fiber interleaving:\n{seg}"
    assert "FIBERS_OK" in seg, f"FIBERS.PRG did not report FIBERS_OK:\n{seg}"
    assert os_sim.mem[pid1_state + 1] == 0, f"FIBERS.PRG exit={os_sim.mem[pid1_state + 1]}"

    # Settle via `ps`
    for ch in "ps\r":
        os_sim.rx_queue.append(ord(ch))
    assert run_until_prompt(os_sim, uart_out, 2000000, worker=worker_sim)

    assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
    assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
    assert worker_sim.mem[0x0004] == 0xFEFF, f"Core 1 RSP leaked: 0x{worker_sim.mem[0x0004]:04X}"
    assert worker_sim.mem[0x0005] == 0xFAFF, f"Core 1 ASP leaked: 0x{worker_sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 11: FAT32 Subdirectories (mkdir, cd, pwd, rmdir, nested paths & syscalls)
# ------------------------------------------------------------------------------
def test_os_fat32_subdirs(_args):
    dirapp_src = """
import "sys.a4";

DirEntry ent;
u16 rd_buf[32];

void fail(u16 code) {
    sys_puts("SUBDIR_APP_FAIL:");
    sys_putc(code);
    sys_puts("\\r\\n");
    sys_exit(code);
}

void main(void) {
    u16 fd = 0;
    u16 dfd = 0;
    u16 written = 0;
    u16 nwords = 0;
    u16 saw_out = 0;

    if (sys_mkdir("/APPDIR") != 0) {
        fail(65);               // 'A'
    }
    if (sys_open("/APPDIR/OUT.TXT", O_WRONLY, &fd) != 0) {
        fail(66);               // 'B'
    }
    if (sys_write(fd, "Subdir syscall OK!\\n", 19, &written) != 0 || written != 19) {
        fail(67);               // 'C'
    }
    sys_close(fd);

    if (sys_opendir("/APPDIR", &dfd) != 0) {
        fail(68);               // 'D'
    }
    while (sys_readdir(dfd, &ent) == 0) {
        if (getbyte(ent.name, 0) == 79 && getbyte(ent.name, 1) == 85 && getbyte(ent.name, 2) == 84) {
            saw_out = 1;
        }
    }
    sys_close(dfd);
    if (saw_out == 0) {
        fail(69);               // 'E'
    }

    if (sys_chdir("/APPDIR") != 0) {
        fail(70);               // 'F'
    }
    if (sys_open("OUT.TXT", O_RDONLY, &fd) != 0) {
        fail(71);               // 'G'
    }
    if (sys_read(fd, rd_buf, 16, &nwords) != 0 || nwords == 0) {
        fail(72);               // 'H'
    }
    rd_buf[nwords] = 0;
    sys_close(fd);

    sys_puts("APPREAD:");
    sys_puts(rd_buf);

    if (sys_chdir("/") != 0) {
        fail(73);               // 'I'
    }
    if (sys_unlink("/APPDIR/OUT.TXT") != 0) {
        fail(74);               // 'J'
    }
    if (sys_rmdir("/APPDIR") != 0) {
        fail(75);               // 'K'
    }
    sys_puts("SUBDIR_APP_OK\\r\\n");
    sys_exit(0);
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        a4 = p / "dirapp.a4"
        app_bin = p / "dirapp.bin"
        a4.write_text(dirapp_src, encoding="utf-8")
        compile_and_assemble(a4, app_bin, org=0x0400, nopreamble=True, sparsebin=True)

        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(OS_BUILD / "ls.prg", sd_root / "LS.PRG")
        shutil.copy(OS_BUILD / "cat.prg", sd_root / "CAT.PRG")
        shutil.copy(app_bin, sd_root / "DIRAPP.PRG")

        cwdapp_src = """
import "sys.a4";

void fail(u16 code) {
    sys_puts("CWDAPP_FAIL:");
    sys_putc(code);
    sys_puts("\\r\\n");
    sys_exit(code);
}

void main(void) {
    u16 fd = 0;
    u16 wr = 0;

    if (sys_mkdir("/WDIR") != 0) {
        fail(65);               // 'A'
    }
    if (sys_chdir("/WDIR") != 0) {
        fail(66);               // 'B'
    }
    if (sys_open("REL.TXT", O_WRONLY, &fd) != 0) {
        fail(67);               // 'C'
    }
    if (sys_write(fd, "worker_cwd_ok\\n", 14, &wr) != 0 || wr != 14) {
        fail(68);               // 'D'
    }
    sys_close(fd);
    // Core 0 shell is in /DOCS -> rmdir must fail (busy)
    if (sys_rmdir("/DOCS") == 0) {
        fail(69);               // 'E'
    }
    // Deliberately exit while still chdir'd in /WDIR; Core 0 shell must stay in /DOCS
    sys_puts("CWDAPP_OK\\r\\n");
    sys_exit(0);
}
"""
        cwd_a4 = p / "cwdapp.a4"
        cwd_bin = sd_root / "CWDAPP.PRG"
        cwd_a4.write_text(cwdapp_src, encoding="utf-8")
        compile_and_assemble(cwd_a4, cwd_bin, org=0x0400, nopreamble=True, sparsebin=True)
        (sd_root / "README.TXT").write_text("Hello from MicroRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "subdir_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None
        mr4sim.connect_os_worker(os_sim, worker_sim)

        assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"

        def send_cmd(cmd_str, max_steps=6000000):
            start = len(uart_out)
            for ch in cmd_str:
                os_sim.rx_queue.append(ord(ch))
            ok = run_until_prompt(os_sim, uart_out, max_steps, worker=worker_sim)
            assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
            return "".join(uart_out[start:])

        # 1. Root pwd + nested mkdir + duplicate rejection
        assert "\r\n/\r\n" in send_cmd("pwd\r")
        assert "Created docs" in send_cmd("mkdir docs\r")
        assert "Already exists: docs" in send_cmd("mkdir docs\r")
        assert "Created docs/sub" in send_cmd("mkdir docs/sub\r")

        # 2. cd into docs, ls shows . / .. / SUB, write/cat/stat inside subdir
        send_cmd("cd docs\r")
        assert "\r\n/DOCS\r\n" in send_cmd("pwd\r")
        out_ls = send_cmd("ls\r")
        assert "<DIR>  ." in out_ls and "<DIR>  .." in out_ls and "<DIR>  SUB" in out_ls, f"ls in /DOCS:\n{out_ls}"
        assert "Wrote note.txt" in send_cmd("write note.txt hello nested\r")
        assert "hello nested" in send_cmd("cat note.txt\r")
        out_st = send_cmd("stat sub\r")
        assert "SUB  size=0 bytes  attr=0x0010" in out_st, f"stat sub:\n{out_st}"

        # 3. Traverse deeper & test relative (..) and absolute (/...) paths
        send_cmd("cd sub\r")
        assert "\r\n/DOCS/SUB\r\n" in send_cmd("pwd\r")
        assert "hello nested" in send_cmd("cat ../note.txt\r")
        assert "Hello from MicroRISC4 FAT32 SD card!" in send_cmd("cat /README.TXT\r")
        assert "Wrote deep.txt" in send_cmd("write deep.txt deep ok\r")
        assert "NOTE.TXT" in send_cmd("ls /docs\r")

        # 4. Directory removal safety checks & rmdir cleanup
        assert "Is a directory (use rmdir): /docs" in send_cmd("rm /docs\r")
        assert "Cannot remove current dir: /docs/sub" in send_cmd("rmdir /docs/sub\r")
        send_cmd("cd ..\r")
        assert "\r\n/DOCS\r\n" in send_cmd("pwd\r")
        assert "Directory not empty: sub" in send_cmd("rmdir sub\r")
        assert "Removed sub/deep.txt" in send_cmd("rm sub/deep.txt\r")
        assert "Removed dir sub" in send_cmd("rmdir sub\r")
        assert "SUB" not in send_cmd("ls\r")
        send_cmd("cd /\r")
        assert "\r\n/\r\n" in send_cmd("pwd\r")

        # 4b. Userland LS.PRG and CAT.PRG taking directory/file path arguments via SYS_GETARGS
        out_uls = send_cmd("! LS.PRG /docs\r", max_steps=16000000)
        assert "NOTE.TXT" in out_uls, f"! LS.PRG /docs missed NOTE.TXT:\n{out_uls}"
        out_ucat = send_cmd("! CAT.PRG docs/note.txt\r", max_steps=16000000)
        assert "hello nested" in out_ucat, f"! CAT.PRG docs/note.txt missed content:\n{out_ucat}"

        # 5. Userland worker app using sys_mkdir / sys_open / sys_opendir / sys_chdir / sys_rmdir
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        seg = send_cmd("! DIRAPP.PRG\r", max_steps=25000000)
        assert os_sim.mem[pid1_state] == 0, f"DIRAPP.PRG still running; out={seg!r}"
        assert "APPREAD:Subdir syscall OK!" in seg, f"DIRAPP.PRG readback mismatch:\n{seg}"
        assert "SUBDIR_APP_OK" in seg, f"DIRAPP.PRG failed:\n{seg}"
        assert os_sim.mem[pid1_state + 1] == 0, f"DIRAPP.PRG exit={os_sim.mem[pid1_state + 1]}"
        assert "APPDIR" not in send_cmd("ls\r")

        # 6. Per-PID CWD isolation: child inherits shell CWD, worker chdir never mutates shell CWD
        send_cmd("cd docs\r")
        assert "\r\n/DOCS\r\n" in send_cmd("pwd\r")
        out_inh_ls = send_cmd("! /LS.PRG\r", max_steps=16000000)
        assert "NOTE.TXT" in out_inh_ls, f"Inherited CWD ! /LS.PRG missed NOTE.TXT:\n{out_inh_ls}"

        out_cwdapp = send_cmd("! /CWDAPP.PRG\r", max_steps=16000000)
        assert "CWDAPP_OK" in out_cwdapp, f"CWDAPP.PRG failed:\n{out_cwdapp}"
        assert os_sim.mem[pid1_state + 1] == 0
        # Shell must still be in /DOCS and /WDIR/REL.TXT must exist & be removable now that PID 1 exited
        assert "\r\n/DOCS\r\n" in send_cmd("pwd\r")
        assert "NOTE.TXT" in send_cmd("ls\r")
        assert "worker_cwd_ok" in send_cmd("cat /wdir/rel.txt\r")
        assert "Removed /wdir/rel.txt" in send_cmd("rm /wdir/rel.txt\r")
        assert "Removed dir /wdir" in send_cmd("rmdir /wdir\r")
        send_cmd("cd /\r")

        # Verify no FD/stack leaks and zero bad low-memory writes
        fds_addr = os_sim.sym_to_addr["_fds"]
        open_fds = [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0]
        assert not open_fds, f"Leaked open FDs: {open_fds}"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
        assert worker_sim.mem[0x0004] == 0xFEFF, f"Core 1 RSP leaked: 0x{worker_sim.mem[0x0004]:04X}"
        assert worker_sim.mem[0x0005] == 0xFAFF, f"Core 1 ASP leaked: 0x{worker_sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 12: Console ownership (run vs !, fg, bg, fg --fgoutput, Ctrl-Z, Ctrl-C)
# ------------------------------------------------------------------------------
def test_os_console_fg_bg(_args):
    bgwork_src = """
import "sys.a4";

void main(void) {
    u16 fd = 0;
    u16 wr = 0;
    // Output must be silently dropped while running in background (Option A)
    sys_puts("BG_MUTE_SHOULD_NOT_APPEAR\\r\\n");
    if (sys_open("BGDONE.TXT", O_WRONLY, &fd) == 0) {
        sys_write(fd, "bg_ran\\n", 7, &wr);
        sys_close(fd);
    }
    sys_exit(0);
}
"""
    echoapp_src = """
import "sys.a4";

void main(void) {
    u16 ch = 0;
    while (true) {
        if (sys_getc(&ch) == 0) {
            sys_puts("GOT:");
            sys_putc(ch);
            sys_puts("\\r\\n");
        }
    }
}
"""
    chat1_src = """
import "sys.a4";

void main(void) {
    u16 d = 0;
    while (true) {
        sys_puts("C1!\\r\\n");
        d = 0;
        while (d < 800) {
            d++;
        }
    }
}
"""
    chat2_src = """
import "sys.a4";

void main(void) {
    u16 d = 0;
    while (true) {
        sys_puts("C2!\\r\\n");
        d = 0;
        while (d < 800) {
            d++;
        }
    }
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        sd_root = p / "sd_root"
        sd_root.mkdir()
        for name, src in (
            ("BGWORK", bgwork_src),
            ("ECHOAPP", echoapp_src),
            ("CHAT1", chat1_src),
            ("CHAT2", chat2_src),
        ):
            a4 = p / f"{name.lower()}.a4"
            out_bin = sd_root / f"{name}.PRG"
            a4.write_text(src, encoding="utf-8")
            compile_and_assemble(a4, out_bin, org=0x0400, nopreamble=True, sparsebin=True)

        sd_img = p / "con_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        workers = []
        for cid in (1, 2, 3):
            ws = mr4sim.MicroRISC4Sim(core_id=cid)
            ws.load_binary(str(BUILD_DIR / "worker_stub.bin"))
            ws.pc = 0x0100
            ws._poll_stdin = lambda: None
            workers.append(ws)
        mr4sim.connect_os_workers(os_sim, workers)

        def step_all(max_steps, stop_fn):
            for _ in range(max_steps):
                os_sim.step()
                for ws in workers:
                    ws.step()
                if stop_fn():
                    return True
            return False

        def send_cmd(cmd_str, max_steps=8000000, wait_contains_prompt=False):
            start = len(uart_out)
            for ch in cmd_str:
                os_sim.rx_queue.append(ord(ch))
            if wait_contains_prompt:
                ok = step_all(max_steps, lambda: has_shell_prompt("".join(uart_out[start:])))
            else:
                ok = step_all(max_steps, lambda: len(uart_out) > start and is_shell_prompt("".join(uart_out[start:])))
            assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
            return "".join(uart_out[start:])

        assert step_all(1500000, lambda: is_shell_prompt("".join(uart_out))), "OS boot failed"

        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        fg_pid_addr = os_sim.sym_to_addr["_fg_pid"]

        # 1. Background `run` mutes console output (Option A) while still completing work
        bg_start = len(uart_out)
        assert "Spawned PID 1" in send_cmd("run BGWORK.PRG\r")
        assert step_all(10000000, lambda: os_sim.mem[pid1_state] == 0), "BGWORK.PRG did not exit"
        assert "BG_MUTE_SHOULD_NOT_APPEAR" not in "".join(uart_out[bg_start:])
        assert "bg_ran" in send_cmd("cat BGDONE.TXT\r")

        # 2. `run` + `fg <pid>` hands keyboard input (SYS_GETC) & output; Ctrl-Z detaches; Ctrl-C kills
        assert "Spawned PID 1" in send_cmd("run ECHOAPP.PRG\r")
        fg_start = len(uart_out)
        for ch in "fg 1\r":
            os_sim.rx_queue.append(ord(ch))
        assert step_all(2000000, lambda: os_sim.mem[fg_pid_addr] == 1), "fg 1 did not attach foreground"
        for ch in "xy":
            os_sim.rx_queue.append(ord(ch))
        assert step_all(
            4000000,
            lambda: "GOT:x" in "".join(uart_out[fg_start:]) and "GOT:y" in "".join(uart_out[fg_start:]),
        ), f"Foreground SYS_GETC echo failed: {''.join(uart_out[fg_start:])!r}"

        # Ctrl-Z detaches back to shell prompt while PID 1 keeps running in background
        cz_start = len(uart_out)
        os_sim.rx_queue.append(0x1A)
        assert step_all(
            2000000,
            lambda: os_sim.mem[fg_pid_addr] == 0 and is_shell_prompt("".join(uart_out[cz_start:])),
        ), f"Ctrl-Z failed: {''.join(uart_out[cz_start:])!r}"
        assert "[Backgrounded PID 1]" in "".join(uart_out[cz_start:])
        out_ps = send_cmd("ps\r")
        assert "1    RUN    ECHOAPP.PRG" in out_ps and "[FG]" not in out_ps

        # Re-attach with `fg 1` and kill with Ctrl-C
        for ch in "fg 1\r":
            os_sim.rx_queue.append(ord(ch))
        assert step_all(2000000, lambda: os_sim.mem[fg_pid_addr] == 1), "Second fg 1 failed"
        cc_start = len(uart_out)
        os_sim.rx_queue.append(0x03)
        assert step_all(
            2000000,
            lambda: os_sim.mem[fg_pid_addr] == 0
            and os_sim.mem[pid1_state] == 0
            and is_shell_prompt("".join(uart_out[cc_start:])),
        ), f"Ctrl-C failed: {''.join(uart_out[cc_start:])!r}"
        assert "^C Killed PID 1" in "".join(uart_out[cc_start:])

        # 3. Simultaneous multi-core output via `fg --fgoutput <pid>` while shell keeps keyboard input
        quiet_start = len(uart_out)
        assert "Spawned PID 1" in send_cmd("run CHAT1.PRG\r")
        assert "Spawned PID 2" in send_cmd("run CHAT2.PRG\r")
        assert "quiet_ok" in send_cmd("echo quiet_ok\r")
        quiet_seg = "".join(uart_out[quiet_start:])
        assert "C1!" not in quiet_seg and "C2!" not in quiet_seg, f"Background chatters leaked output: {quiet_seg!r}"

        assert "Console output enabled for PID 1" in send_cmd("fg --fgoutput 1\r", wait_contains_prompt=True)
        assert "Console output enabled for PID 2" in send_cmd("fg --fgoutput 2\r", wait_contains_prompt=True)
        assert os_sim.mem[fg_pid_addr] == 0, "fg --fgoutput should keep keyboard input on Core 0 shell"

        multi_start = len(uart_out)
        assert step_all(
            4000000,
            lambda: "C1!" in "".join(uart_out[multi_start:]) and "C2!" in "".join(uart_out[multi_start:]),
        ), f"Expected simultaneous output from Core 1 and Core 2: {''.join(uart_out[multi_start:])!r}"

        # Shell still accepts commands while both cores output; `ps` shows [OUT] on both
        out_ps2 = send_cmd("ps\r", wait_contains_prompt=True)
        assert "1    RUN    CHAT1.PRG  [OUT]" in out_ps2, f"Missing [OUT] on PID 1:\n{out_ps2}"
        assert "2    RUN    CHAT2.PRG  [OUT]" in out_ps2, f"Missing [OUT] on PID 2:\n{out_ps2}"

        assert "Backgrounded PID 1" in send_cmd("bg 1\r", wait_contains_prompt=True)
        assert "Backgrounded PID 2" in send_cmd("bg 2\r", wait_contains_prompt=True)
        assert "Killed PID 1" in send_cmd("kill 1\r")
        assert "Killed PID 2" in send_cmd("kill 2\r")
        send_cmd("ps\r")

        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
        for idx, ws in enumerate(workers, start=1):
            assert ws.mem[0x0004] == 0xFEFF, f"Worker {idx} RSP leaked: 0x{ws.mem[0x0004]:04X}"
            assert ws.mem[0x0005] == 0xFAFF, f"Worker {idx} ASP leaked: 0x{ws.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 13: Worker crash reporting (Trap 15 align fault + unhandled Trap 5)
# ------------------------------------------------------------------------------
def test_os_worker_fault_reporting(_args):
    align_bad_src = """
import "sys.a4";

// Slot 0 = 0x00 (LD R0, R0), Slot 1 = 0xF8 (PUSH8 R0 in Slot 1 -> hardware Trap 15)
u16 bad_insn = 0xF800;

void main(void) {
    u16 fd = 0;
    // Open an FD before crashing so Core 0 must reclaim it on fault
    sys_open("README.TXT", O_RDONLY, &fd);
    asm {
        LOAD16  R0, _bad_insn
        JMP     R0
    }
    sys_exit(0);
}
"""
    trap5_bad_src = """
import "sys.a4";

void main(void) {
    u16 fd = 0;
    sys_open("README.TXT", O_RDONLY, &fd);
    trap(5, 0);
    sys_exit(0);
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(OS_BUILD / "cat.prg", sd_root / "CAT.PRG")
        (sd_root / "README.TXT").write_text("Hello from MicroRISC4 FAT32 SD card!\n", encoding="utf-8")

        for name, src in (("ALIGNBAD", align_bad_src), ("TRAPBAD", trap5_bad_src)):
            a4 = p / f"{name.lower()}.a4"
            out_bin = sd_root / f"{name}.PRG"
            a4.write_text(src, encoding="utf-8")
            compile_and_assemble(a4, out_bin, org=0x0400, nopreamble=True, sparsebin=True)

        sd_img = p / "fault_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None
        mr4sim.connect_os_worker(os_sim, worker_sim)

        assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        fds_addr = os_sim.sym_to_addr["_fds"]

        def send_cmd(cmd_str, max_steps=10000000):
            start = len(uart_out)
            for ch in cmd_str:
                os_sim.rx_queue.append(ord(ch))
            ok = run_until_prompt(os_sim, uart_out, max_steps, worker=worker_sim)
            assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
            return "".join(uart_out[start:])

        # 1. Foreground Trap 15 alignment fault -> Core 0 reports fault, reclaims PID & FD, restores prompt
        out_align = send_cmd("! ALIGNBAD.PRG\r")
        assert "[FAULT] PID 1 (ALIGNBAD.PRG): align fault (0xFF0F)" in out_align, f"Missing Trap 15 notice:\n{out_align}"
        assert os_sim.mem[pid1_state] == 0
        assert os_sim.mem[pid1_state + 1] == 0xFF0F
        assert not [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0], "Leaked FD after Trap 15"

        # 2. Background unhandled Trap 5 -> Core 0 still reports fault & reclaims PID + FD
        bg_start = len(uart_out)
        assert "Spawned PID 1" in send_cmd("run TRAPBAD.PRG\r")
        done = False
        for _ in range(8000000):
            os_sim.step()
            worker_sim.step()
            if os_sim.mem[pid1_state] == 0 and "[FAULT] PID 1 (TRAPBAD.PRG): unhandled trap 5 (0xFF05)" in "".join(uart_out[bg_start:]):
                done = True
                break
        assert done, f"Missing background Trap 5 fault report:\n{''.join(uart_out[bg_start:])}"
        assert os_sim.mem[pid1_state + 1] == 0xFF05
        assert not [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0], "Leaked FD after Trap 5"

        # 3. Worker Core 1 cleanly runs CAT.PRG after both crashes
        out_cat = send_cmd("! CAT.PRG\r")
        assert "Hello from MicroRISC4 FAT32 SD card!" in out_cat
        assert os_sim.mem[pid1_state] == 0 and os_sim.mem[pid1_state + 1] == 0
        send_cmd("ps\r")

        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
        assert worker_sim.mem[0x0004] == 0xFEFF, f"Core 1 RSP leaked: 0x{worker_sim.mem[0x0004]:04X}"
        assert worker_sim.mem[0x0005] == 0xFAFF, f"Core 1 ASP leaked: 0x{worker_sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 14: Everyday FS ops & syscalls (append, cp, mv, df, O_APPEND, SYS_RENAME, SYS_STAT, SYS_GETCWD)
# ------------------------------------------------------------------------------
def test_os_fs_ops_syscalls(_args):
    fsapp_src = """
import "sys.a4";

DirEntry st;
u16 cwd_buf[32];
u16 rd_buf[32];

void fail(u16 code) {
    sys_puts("FSAPP_FAIL:");
    sys_putc(code);
    sys_puts("\\r\\n");
    sys_exit(code);
}

void main(void) {
    u16 fd = 0;
    u16 wr = 0;
    u16 nw = 0;

    if (sys_open("A.TXT", O_WRONLY, &fd) != 0) {
        fail(65);               // 'A'
    }
    if (sys_write(fd, "hello_", 6, &wr) != 0 || wr != 6) {
        fail(66);               // 'B'
    }
    sys_close(fd);

    if (sys_open("A.TXT", O_APPEND, &fd) != 0) {
        fail(67);               // 'C'
    }
    if (sys_write(fd, "world\\n", 6, &wr) != 0 || wr != 6) {
        fail(68);               // 'D'
    }
    sys_close(fd);

    if (sys_stat("A.TXT", &st) != 0 || st.size_lo != 12) {
        fail(69);               // 'E'
    }
    if (sys_rename("A.TXT", "/BOX2/B.TXT") != 0) {
        fail(70);               // 'F'
    }
    if (sys_chdir("/BOX2") != 0) {
        fail(71);               // 'G'
    }
    if (sys_getcwd(cwd_buf, 32) != 0) {
        fail(72);               // 'H'
    }
    sys_puts("CWD:");
    sys_puts(cwd_buf);
    sys_puts("\\r\\n");

    if (sys_open("B.TXT", O_RDONLY, &fd) != 0) {
        fail(73);               // 'I'
    }
    if (sys_read(fd, rd_buf, 16, &nw) != 0 || nw == 0) {
        fail(74);               // 'J'
    }
    rd_buf[nw] = 0;
    sys_close(fd);
    sys_puts("READ:");
    sys_puts(rd_buf);
    sys_puts("FSAPP_OK\\r\\n");
    sys_exit(0);
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        sd_root = p / "sd_root"
        sd_root.mkdir()
        a4 = p / "fsapp.a4"
        app_bin = sd_root / "FSAPP.PRG"
        a4.write_text(fsapp_src, encoding="utf-8")
        compile_and_assemble(a4, app_bin, org=0x0400, nopreamble=True, sparsebin=True)

        sd_img = p / "fsops_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None
        mr4sim.connect_os_worker(os_sim, worker_sim)

        assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"

        def send_cmd(cmd_str, max_steps=16000000):
            start = len(uart_out)
            for ch in cmd_str:
                os_sim.rx_queue.append(ord(ch))
            ok = run_until_prompt(os_sim, uart_out, max_steps, worker=worker_sim)
            assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
            return "".join(uart_out[start:])

        # 1. Shell write + append + cp + mv across directories
        assert "Wrote log.txt" in send_cmd("write log.txt line1\r")
        assert "Appended log.txt" in send_cmd("append log.txt line2\r")
        out_log = send_cmd("cat log.txt\r")
        assert "line1\r\nline2" in out_log, f"append mismatch:\n{out_log}"

        assert "Copied log.txt -> copy.txt" in send_cmd("cp log.txt copy.txt\r")
        assert "line1\r\nline2" in send_cmd("cat copy.txt\r")

        assert "Created box" in send_cmd("mkdir box\r")
        assert "Moved copy.txt -> box/moved.txt" in send_cmd("mv copy.txt box/moved.txt\r")
        assert "File not found: copy.txt" in send_cmd("cat copy.txt\r")
        assert "line1\r\nline2" in send_cmd("cat box/moved.txt\r")

        # 2. Cross-directory mv of a directory updates ".." cleanly
        assert "Created box2" in send_cmd("mkdir box2\r")
        assert "Moved box -> box2/mdir" in send_cmd("mv box box2/mdir\r")
        send_cmd("cd box2/mdir\r")
        assert "line1\r\nline2" in send_cmd("cat moved.txt\r")
        send_cmd("cd ..\r")
        assert "\r\n/BOX2\r\n" in send_cmd("pwd\r")
        send_cmd("cd /\r")

        # 3. Shell `df` scans FAT1 and reports clusters & KB free
        out_df = send_cmd("df\r", max_steps=35000000)
        assert "Clusters:" in out_df and "used," in out_df and "KB free)" in out_df, f"Unexpected df:\n{out_df}"

        # 4. Userland FSAPP.PRG exercising O_APPEND, SYS_STAT, SYS_RENAME, SYS_GETCWD
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        out_app = send_cmd("! FSAPP.PRG\r", max_steps=20000000)
        assert "CWD:/BOX2" in out_app, f"SYS_GETCWD mismatch:\n{out_app}"
        assert "READ:hello_world" in out_app, f"O_APPEND/SYS_RENAME readback mismatch:\n{out_app}"
        assert "FSAPP_OK" in out_app, f"FSAPP.PRG failed:\n{out_app}"
        assert os_sim.mem[pid1_state] == 0 and os_sim.mem[pid1_state + 1] == 0

        fds_addr = os_sim.sym_to_addr["_fds"]
        assert not [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0], "Leaked FDs"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF
        assert worker_sim.mem[0x0004] == 0xFEFF
        assert worker_sim.mem[0x0005] == 0xFAFF


# ------------------------------------------------------------------------------
# Test 15: Explicit !/run PATH lookup (no implicit launch) & 4-entry arrow history
# ------------------------------------------------------------------------------
def test_os_path_and_history(args):
    os_sim = mr4sim.MicroRISC4Sim(core_id=0)
    os_sim.sd_card = mr4sim.SpiSdCard(Path(args.sd_image).read_bytes())
    os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
    os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
    os_sim.pc = 0x0100
    uart_out, bad_writes = attach_uart_and_watch(os_sim)

    worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
    worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
    worker_sim.pc = 0x0100
    worker_sim._poll_stdin = lambda: None
    mr4sim.connect_os_worker(os_sim, worker_sim)

    assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"

    def send_cmd(cmd_str, max_steps=16000000):
        start = len(uart_out)
        for ch in cmd_str:
            os_sim.rx_queue.append(ord(ch))
        ok = run_until_prompt(os_sim, uart_out, max_steps, worker=worker_sim)
        assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
        return "".join(uart_out[start:])

    # 1. Strictly NO implicit launching: bare program name must be Unknown command
    assert "Unknown command: fibers" in send_cmd("fibers\r")

    # 2. Explicit `!` and `run`/`&` resolve .PRG, /BIN/<name>.PRG, and /<name>.PRG
    assert "FIBERS_OK" in send_cmd("! fibers\r")

    # Background `&fibers` and `& fibers` aliases for `run`
    procs_addr = os_sim.sym_to_addr["_procs"]
    pid1_state = procs_addr + 10
    bg_out = send_cmd("&fibers\r")
    assert "Spawned PID 1" in bg_out and "FIBERS_OK" not in bg_out, f"&fibers unexpected output:\n{bg_out}"
    for _ in range(8000000):
        os_sim.step()
        worker_sim.step()
        if os_sim.mem[pid1_state] == 0:
            break
    assert os_sim.mem[pid1_state] == 0 and os_sim.mem[pid1_state + 1] == 0
    bg_out2 = send_cmd("& fibers\r")
    assert "Spawned PID 1" in bg_out2, f"& fibers unexpected output:\n{bg_out2}"
    for _ in range(8000000):
        os_sim.step()
        worker_sim.step()
        if os_sim.mem[pid1_state] == 0:
            break
    assert os_sim.mem[pid1_state] == 0 and os_sim.mem[pid1_state + 1] == 0

    assert "Copied /bin/cat.prg -> /bin/mycat.prg" in send_cmd("cp /bin/cat.prg /bin/mycat.prg\r")
    assert "Copied /bin/cat.prg -> /rootcat.prg" in send_cmd("cp /bin/cat.prg /rootcat.prg\r")
    send_cmd("cd /work\r")
    assert "Wrote msg.txt" in send_cmd("write msg.txt found via path\r")
    out_bin = send_cmd("! mycat msg.txt\r")
    assert "found via path" in out_bin, f"! mycat via /BIN failed:\n{out_bin}"
    out_root = send_cmd("! rootcat msg.txt\r")
    assert "found via path" in out_root, f"! rootcat via / failed:\n{out_root}"
    out_cat = send_cmd("! cat msg.txt\r")
    assert "found via path" in out_cat, f"! cat via /BIN failed:\n{out_cat}"
    send_cmd("cd /\r")

    # 3. 4-entry Up/Down arrow history ring (ESC [ A / ESC [ B) + ignore ESC [ C
    for tok in ("one", "two", "three", "four", "five"):
        assert f"\r\n{tok}\r\n" in send_cmd(f"echo {tok}\r")

    # Ring holds: two, three, four, five. Up x4 clamps at "two"; Down x1 -> "three"; Enter runs "echo three"
    out_h1 = send_cmd("\x1b[A\x1b[A\x1b[A\x1b[A\x1b[A\x1b[B\r")
    assert "\r\nthree\r\n" in out_h1, f"History Up/Down recall failed:\n{out_h1!r}"

    # Up x1 -> "echo three", Down x1 -> blank line, Right arrow ignored, type "echo fresh"
    out_h2 = send_cmd("\x1b[A\x1b[B\x1b[Cecho fresh\r")
    assert "\r\nfresh\r\n" in out_h2, f"History Down-to-blank + ESC[C failed:\n{out_h2!r}"

    assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
    assert os_sim.mem[0x0005] == 0xFAFF
    assert worker_sim.mem[0x0004] == 0xFEFF
    assert worker_sim.mem[0x0005] == 0xFAFF


# ------------------------------------------------------------------------------
# Test 16: Terminal control & key-decoding library (lib/term.a4)
# ------------------------------------------------------------------------------
def test_os_term_lib(_args):
    termapp_src = """
import "sys.a4";
import "term.a4";

void main(void) {
    u16 k = 0;

    term_clear();
    term_cursor_hide();
    term_color(TERM_BRIGHT_GREEN, TERM_BLUE);
    term_puts_at(3, 5, "TERM_HDR:");
    term_put_dec(42);
    term_putc(47);
    term_put_hex(0x0BEE);
    term_reset();
    term_cursor_show();
    term_puts("\\r\\nREADY\\r\\n");

    while (true) {
        k = term_get_key();
        if (k == 113) {             // 'q' quits
            term_puts("TERM_OK\\r\\n");
            sys_exit(0);
        } else if (k == KEY_UP) {
            term_puts("K:UP\\r\\n");
        } else if (k == KEY_DOWN) {
            term_puts("K:DN\\r\\n");
        } else if (k == KEY_LEFT) {
            term_puts("K:LT\\r\\n");
        } else if (k == KEY_RIGHT) {
            term_puts("K:RT\\r\\n");
        } else if (k == KEY_PGUP) {
            term_puts("K:PU\\r\\n");
        } else if (k == KEY_PGDN) {
            term_puts("K:PD\\r\\n");
        } else if (k == KEY_HOME) {
            term_puts("K:HM\\r\\n");
        } else if (k == KEY_END) {
            term_puts("K:EN\\r\\n");
        } else if (k == KEY_DELETE) {
            term_puts("K:DL\\r\\n");
        } else if (k == KEY_F1) {
            term_puts("K:F1\\r\\n");
        } else if (k == KEY_ESC) {
            term_puts("K:ESC\\r\\n");
        } else if (k == KEY_BACKSPACE) {
            term_puts("K:BS\\r\\n");
        }
    }
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        sd_root = p / "sd_root"
        sd_root.mkdir()
        a4 = p / "termapp.a4"
        app_bin = sd_root / "TERMAPP.PRG"
        a4.write_text(termapp_src, encoding="utf-8")
        compile_and_assemble(a4, app_bin, org=0x0400, nopreamble=True, sparsebin=True)

        sd_img = p / "term_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None
        mr4sim.connect_os_worker(os_sim, worker_sim)

        assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"

        def step_until(max_steps, cond):
            for _ in range(max_steps):
                os_sim.step()
                worker_sim.step()
                if cond():
                    return True
            return False

        start = len(uart_out)
        for ch in "! termapp\r":
            os_sim.rx_queue.append(ord(ch))
        assert step_until(10000000, lambda: "READY\r\n" in "".join(uart_out[start:])), (
            f"TERMAPP.PRG did not reach READY; out={''.join(uart_out[start:])!r}"
        )

        hdr = "".join(uart_out[start:])
        assert "\x1b[2J\x1b[H" in hdr, f"Missing clear screen sequence: {hdr!r}"
        assert "\x1b[?25l" in hdr and "\x1b[?25h" in hdr, f"Missing cursor hide/show: {hdr!r}"
        assert "\x1b[92;44m" in hdr, f"Missing bright green on blue SGR: {hdr!r}"
        assert "\x1b[3;5HTERM_HDR:42/0BEE\x1b[0m" in hdr, f"Missing goto/dec/hex/reset: {hdr!r}"

        # Feed each special key sequence and verify decoded token
        key_cases = [
            ("\x1b[A", "K:UP"),
            ("\x1b[B", "K:DN"),
            ("\x1b[D", "K:LT"),
            ("\x1b[C", "K:RT"),
            ("\x1b[5~", "K:PU"),
            ("\x1b[6~", "K:PD"),
            ("\x1b[H", "K:HM"),
            ("\x1b[4~", "K:EN"),
            ("\x1b[3~", "K:DL"),
            ("\x1bOP", "K:F1"),
            ("\x7f", "K:BS"),
            ("\x1b", "K:ESC"),
        ]
        for seq, expect in key_cases:
            kstart = len(uart_out)
            for ch in seq:
                os_sim.rx_queue.append(ord(ch))
            ok = step_until(4000000, lambda: expect in "".join(uart_out[kstart:]))
            assert ok, f"Key {seq!r} did not decode to {expect!r}; out={''.join(uart_out[kstart:])!r}"

        # Quit cleanly with 'q' and confirm return to the shell prompt
        qstart = len(uart_out)
        os_sim.rx_queue.append(ord("q"))
        assert step_until(
            4000000,
            lambda: "TERM_OK" in "".join(uart_out[qstart:]) and is_shell_prompt("".join(uart_out[qstart:])),
        ), f"TERMAPP.PRG quit failed; out={''.join(uart_out[qstart:])!r}"

        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF
        assert worker_sim.mem[0x0004] == 0xFEFF
        assert worker_sim.mem[0x0005] == 0xFAFF


# ------------------------------------------------------------------------------
# Test 17: Sequential shell scripts (do <file>, @ <file>, @<file>)
# ------------------------------------------------------------------------------
def test_os_scripts(_args):
    spin_src = """
import "sys.a4";
void main(void) {
    sys_puts("SPIN_STARTED\\r\\n");
    while (true) {
    }
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(OS_BUILD / "cat.prg", sd_root / "CAT.PRG")
        shutil.copy(OS_BUILD / "fibers.prg", sd_root / "FIBERS.PRG")
        spin_a4 = p / "spin.a4"
        spin_a4.write_text(spin_src, encoding="utf-8")
        compile_and_assemble(spin_a4, sd_root / "SPIN.PRG", org=0x0400, nopreamble=True, sparsebin=True)

        bin_dir = sd_root / "BIN"
        bin_dir.mkdir()
        (bin_dir / "BOOT.DO").write_text("echo BOOT_DO_RAN\n", encoding="utf-8")
        (bin_dir / "HELLO.DO").write_text(
            "# Demo script in /BIN/HELLO.DO\n"
            "\n"
            "echo STEP_ONE\n"
            "mkdir /scdir\n"
            "cd /scdir\n"
            "write msg.txt from_script\n"
            "! cat msg.txt\n"
            "cd /\n"
            "&fibers\n"
            "echo STEP_DONE\n",
            encoding="utf-8",
        )
        work_dir = sd_root / "WORK"
        work_dir.mkdir()
        (work_dir / "ARGUMENT.TXT").write_text("PROGRAM_ARG_PASSED\n", encoding="utf-8")
        (work_dir / "ARGS.DO").write_text(
            "echo PARAMS:$1:$2\n"
            "! cat $1\n",
            encoding="utf-8",
        )
        (work_dir / "FULL.DO").write_text(
            "echo FULL_A\r\n"
            "   # indented comment\r\n"
            "echo FULL_B",
            encoding="utf-8",
        )
        (work_dir / "ABORT.DO").write_text(
            "! spin\n"
            "echo NEVER_PRINTED\n",
            encoding="utf-8",
        )

        sd_img = p / "script_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None
        mr4sim.connect_os_worker(os_sim, worker_sim)

        assert run_until_prompt(os_sim, uart_out, 1500000, worker=worker_sim), "OS boot failed"
        boot_out = "".join(uart_out)
        assert "BOOT_DO_RAN\r\n" in boot_out, f"/BIN/BOOT.DO did not run at boot:\n{boot_out!r}"
        assert boot_out.index("FAT32 mounted OK") < boot_out.index("BOOT_DO_RAN\r\n") < boot_out.rindex("mr4:")
        assert boot_out.endswith("mr4:/WORK> "), f"Boot prompt omitted current directory:\n{boot_out!r}"

        def send_cmd(cmd_str: str, max_steps: int = 20000000) -> str:
            start = len(uart_out)
            for ch in cmd_str:
                os_sim.rx_queue.append(ord(ch))
            ok = run_until_prompt(os_sim, uart_out, max_steps, worker=worker_sim)
            assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
            return "".join(uart_out[start:])

        assert "/WORK\r\n" in send_cmd("pwd\r"), "OS did not start in /WORK"
        assert send_cmd("cd /\r").endswith("mr4:/> "), "Prompt did not update for root directory"
        assert send_cmd("cd /WORK\r").endswith("mr4:/WORK> "), "Prompt did not update for /WORK"

        out_args = send_cmd("do args.do ARGUMENT.TXT second\r")
        assert "PARAMS:ARGUMENT.TXT:second\r\n" in out_args, f"Script parameters did not expand:\n{out_args!r}"
        assert "PROGRAM_ARG_PASSED" in out_args, f"Expanded argument did not reach CAT.PRG:\n{out_args!r}"
        out_at = send_cmd("@args.do ARGUMENT.TXT third\r")
        assert "PARAMS:ARGUMENT.TXT:third\r\n" in out_at, f"@ script parameters did not expand:\n{out_at!r}"
        assert "PROGRAM_ARG_PASSED" in out_at, f"@ argument did not reach CAT.PRG:\n{out_at!r}"
        out_at_spaced = send_cmd("@ args.do ARGUMENT.TXT fourth\r")
        assert "PARAMS:ARGUMENT.TXT:fourth\r\n" in out_at_spaced, (
            f"spaced @ script parameters did not expand:\n{out_at_spaced!r}"
        )

        # 1. @hello -> resolves /BIN/HELLO.DO, runs silently, waits on ! cat, launches &fibers
        out1 = send_cmd("@hello\r")
        assert "STEP_ONE" in out1, f"Missing STEP_ONE:\n{out1!r}"
        assert "from_script" in out1, f"Foreground ! cat inside script failed:\n{out1!r}"
        assert "Spawned PID 1" in out1, f"Background &fibers inside script failed:\n{out1!r}"
        assert "STEP_DONE" in out1, f"Script did not finish after fg app:\n{out1!r}"
        assert shell_prompt_count(out1) == 1, f"Expected silent execution (1 final prompt), got:\n{out1!r}"
        assert out1.index("STEP_ONE") < out1.index("from_script") < out1.index("STEP_DONE")

        # Wait for background &fibers to exit cleanly before next test
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        for _ in range(8000000):
            os_sim.step()
            worker_sim.step()
            if os_sim.mem[pid1_state] == 0:
                break
        assert os_sim.mem[pid1_state] == 0

        # 2. Full path via `do /work/full.do`, `@/work/full.do`, and `@ /work/full.do` (CRLF + no trailing newline)
        for invocation in ("do /work/full.do\r", "@/work/full.do\r", "@ /work/full.do\r"):
            out_f = send_cmd(invocation)
            assert "FULL_A" in out_f and "FULL_B" in out_f, f"{invocation!r} failed:\n{out_f!r}"
            assert shell_prompt_count(out_f) == 1, f"{invocation!r} printed extra prompts:\n{out_f!r}"

        # 3. Missing script error
        assert "Script not found" in send_cmd("do /no/such.do\r")

        # 4. Ctrl-C during a foreground command inside a script aborts the remaining script lines
        ab_start = len(uart_out)
        for ch in "@/work/abort.do\r":
            os_sim.rx_queue.append(ord(ch))
        reached = False
        for _ in range(10000000):
            os_sim.step()
            worker_sim.step()
            if "SPIN_STARTED" in "".join(uart_out[ab_start:]):
                reached = True
                break
        assert reached, f"ABORT.DO did not start SPIN.PRG; out={''.join(uart_out[ab_start:])!r}"
        os_sim.rx_queue.append(3)  # Ctrl-C
        assert run_until_prompt(os_sim, uart_out, 5000000, worker=worker_sim), "Ctrl-C script abort timed out"
        ab_out = "".join(uart_out[ab_start:])
        assert "^C Killed PID 1" in ab_out, f"Missing Ctrl-C kill notice:\n{ab_out!r}"
        assert "NEVER_PRINTED" not in ab_out, f"Script continued after Ctrl-C:\n{ab_out!r}"
        assert os_sim.mem[pid1_state] == 0

        # Verify no FDs leaked
        fds_addr = os_sim.sym_to_addr["_fds"]
        open_fds = [slot for slot in range(8) if os_sim.mem[fds_addr + slot * 15] != 0]
        assert not open_fds, f"Leaked FDs after scripts: {open_fds}"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF
        assert worker_sim.mem[0x0004] == 0xFEFF
        assert worker_sim.mem[0x0005] == 0xFAFF


# ------------------------------------------------------------------------------
# Test 18: Track B.2 Hardware Math Accelerator Codegen (--hw-math) & CPU_CAPS Guard
# ------------------------------------------------------------------------------
def test_hw_math_codegen(_args):
    # Part 1 & 2: Standalone program testing *, /, %, *=, /=, %=, <<, >>, <<=, >>=,
    # constant shifts >= 4, shift counts >= 16, div-by-zero parity, non-pow2 struct
    # indexing, and a math-heavy checksum loop for cycle-count speedup comparison.
    src = """
u16 uart_tx @ 0x000F;
u16 sentinel @ 0x2000;

type Triplet {
    u16 a;
    u16 b;
    u16 c;
};

Triplet tris[6];

void putc(u16 c) {
    while (uart_tx != 0) {}
    uart_tx = c;
}

void puts(u16 *s) {
    u16 i = 0;
    u16 c = 0;
    while (true) {
        c = getbyte(s, i);
        if (c == 0) { return; }
        putc(c);
        i++;
    }
}

void puthex(u16 v) {
    u16 i = 0;
    u16 nib = 0;
    while (i < 4) {
        nib = (v >> 12) & 0x000F;
        if (nib < 10) { putc(48 + nib); }
        else { putc(55 + nib); }
        v = v << 4;
        i++;
    }
}

void check(u16 cond, u16 code) {
    if (cond == 0) {
        puts("FAIL:");
        putc(code);
        putc(10);
        while (true) {}
    }
}

void main(void) {
    u16 x = 0;
    u16 y = 0;
    u16 sh = 0;
    u16 i = 0;
    u16 acc = 0;

    sentinel = 0xCAFE;

    // Basic *, /, %
    x = 300; y = 200; check(x * y == 60000, 65);
    x = 0xFFFF; y = 0xFFFF; check(x * y == 1, 66);
    x = 65535; y = 257; check(x / y == 255, 67);
    check(x % y == 0, 68);
    x = 54321; y = 123; check(x / y == 441, 69);
    check(x % y == 78, 70);

    // Divide-by-zero parity with M4R_LIB.asm (Q=0xFFFF, R=dividend)
    x = 1234; y = 0;
    check(x / y == 0xFFFF, 71);
    check(x % y == 1234, 72);

    // Compound assignments *=, /=, %=, <<=, >>=
    x = 17; x *= 19; check(x == 323, 73);
    x /= 10; check(x == 32, 74);
    x %= 7; check(x == 4, 75);
    sh = 5; x <<= sh; check(x == 128, 76);
    sh = 3; x >>= sh; check(x == 16, 77);

    // Constant shifts >= 4 & variable shifts including >= 16
    x = 0x00AB; check((x << 8) == 0xAB00, 78);
    x = 0xF123; check((x >> 4) == 0x0F12, 79);
    sh = 7; x = 0x00FF; check((x << sh) == 0x7F80, 80);
    sh = 9; x = 0x8000; check((x >> sh) == 0x0040, 81);
    sh = 16; x = 0xFFFF; check((x << sh) == 0, 82);
    check((x >> sh) == 0, 83);
    sh = 25; check((x << sh) == 0, 84);
    check((x >> sh) == 0, 85);

    // Non-power-of-two struct indexing (elem_sz = 3)
    i = 0;
    while (i < 6) {
        tris[i].a = i * 11 + 1;
        tris[i].b = i * 23 + 2;
        tris[i].c = i * 37 + 3;
        i++;
    }
    check(tris[4].a == 45, 86);
    check(tris[5].b == 117, 87);
    check(tris[3].c == 114, 88);

    // Math-heavy checksum loop to compare SW vs HW cycle counts
    acc = 0x1357;
    i = 1;
    while (i <= 40) {
        x = (i * 977) + 13;
        y = (i * 19) + 3;
        acc ^= (x / y) + (x % y) + (i << 5) + (x >> 6);
        i++;
    }
    puts("OK:");
    puthex(acc);
    putc(10);
    while (true) {}
}
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)
        a4 = p / "math_bench.a4"
        sw_bin = p / "math_sw.bin"
        hw_bin = p / "math_hw.bin"
        a4.write_text(src, encoding="utf-8")

        compile_and_assemble(a4, sw_bin, hw_math=False)
        compile_and_assemble(a4, hw_bin, hw_math=True)

        # 1a. Software baseline (M4R_LIB.asm)
        sim_sw = mr4sim.MicroRISC4Sim(core_id=0)
        sim_sw.load_binary(str(sw_bin))
        sim_sw.pc = 0x0100
        uart_sw, bad_sw = attach_uart_and_watch(sim_sw)
        for _ in range(500000):
            sim_sw.step()
            if "\n" in "".join(uart_sw):
                break
        out_sw = "".join(uart_sw).strip()
        sw_cycles = sim_sw.cycles
        assert out_sw.startswith("OK:"), f"SW math test failed: {out_sw!r}"
        assert not bad_sw, f"SW bad low-mem writes: {bad_sw}"
        assert sim_sw.mem[0x0005] == 0xFAFF

        # 1b. Hardware Math Accelerator (--hw-math + --enable-math)
        sim_hw = mr4sim.MicroRISC4Sim(core_id=0)
        sim_hw.enable_math = True
        sim_hw.load_binary(str(hw_bin))
        sim_hw.pc = 0x0100
        uart_hw, bad_hw = attach_uart_and_watch(sim_hw)
        for _ in range(500000):
            sim_hw.step()
            if "\n" in "".join(uart_hw):
                break
        out_hw = "".join(uart_hw).strip()
        hw_cycles = sim_hw.cycles
        assert out_hw == out_sw, f"HW/SW mismatch: hw={out_hw!r} vs sw={out_sw!r}"
        assert not bad_hw, f"HW bad low-mem writes: {bad_hw}"
        assert sim_hw.mem[0x0005] == 0xFAFF
        assert sim_hw.mem[0x2000] == 0xCAFE
        speedup = sw_cycles / max(hw_cycles, 1)
        assert speedup >= 2.0, f"Expected >=2.0x speedup, got {speedup:.2f}x (sw={sw_cycles}, hw={hw_cycles})"

        # 2. Startup CPU_CAPS guard when hardware math accelerator is ABSENT
        sim_nohw = mr4sim.MicroRISC4Sim(core_id=0)
        sim_nohw.enable_math = False
        sim_nohw.load_binary(str(hw_bin))
        sim_nohw.pc = 0x0100
        uart_nohw, bad_nohw = attach_uart_and_watch(sim_nohw)
        for _ in range(50000):
            sim_nohw.step()
        out_nohw = "".join(uart_nohw)
        assert "ERR: CPU lacks HW Math Accelerator (CPU_CAPS.b3=0)" in out_nohw, (
            f"Missing startup guard error message: {out_nohw!r}"
        )
        assert sim_nohw.r[1] == 1, f"Expected error exit code R1=1, got {sim_nohw.r[1]}"
        assert sim_nohw.mem[0x2000] == 0, f"_main body ran despite missing HW math! sentinel=0x{sim_nohw.mem[0x2000]:04X}"
        assert not bad_nohw, f"Guard bad low-mem writes: {bad_nohw}"

        # 3. MR4OS worker app (--nopreamble --hw-math) cleanly exits with code 1 when worker lacks HW math
        worker_app_src = """
import "sys.a4";

void main(void) {
    u16 a = 123;
    u16 b = 45;
    u16 c = a * b;
    sys_puts("SHOULD_NOT_RUN\\r\\n");
}
"""
        w_a4 = p / "hwapp.a4"
        w_bin = p / "hwapp.prg"
        w_a4.write_text(worker_app_src, encoding="utf-8")
        compile_and_assemble(w_a4, w_bin, org=0x0400, nopreamble=True, sparsebin=True, hw_math=True)

        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(w_bin, sd_root / "HWAPP.PRG")
        sd_img = p / "hwapp_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MicroRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        os_uart, os_bad = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MicroRISC4Sim(core_id=1)
        worker_sim.enable_math = False
        worker_sim.enable_uart = False
        worker_sim.load_binary(str(BUILD_DIR / "worker_stub.bin"))
        worker_sim.pc = 0x0100
        worker_sim._poll_stdin = lambda: None
        mr4sim.connect_os_workers(os_sim, [worker_sim])

        assert run_until_prompt(os_sim, os_uart, 1500000, worker=worker_sim), "OS boot failed"
        seg_start = len(os_uart)
        for ch in "! HWAPP.PRG\r":
            os_sim.rx_queue.append(ord(ch))
        assert run_until_prompt(os_sim, os_uart, 8000000, worker=worker_sim), "HWAPP.PRG did not exit cleanly"
        seg = "".join(os_uart[seg_start:])
        assert "ERR: CPU lacks HW Math Accelerator (CPU_CAPS.b3=0)" in seg, f"Missing worker guard msg:\n{seg!r}"
        assert "SHOULD_NOT_RUN" not in seg, f"Worker _main ran despite missing HW math!\n{seg!r}"
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        assert os_sim.mem[pid1_state] == 0, f"PID 1 still active: {os_sim.mem[pid1_state]}"
        assert os_sim.mem[pid1_state + 1] == 1, f"Expected PID 1 exit code 1, got {os_sim.mem[pid1_state + 1]}"
        assert not os_bad, f"OS bad low-mem writes: {os_bad}"
        assert worker_sim.mem[0x0004] == 0xFEFF, f"Worker RSP leaked: 0x{worker_sim.mem[0x0004]:04X}"
        assert worker_sim.mem[0x0005] == 0xFAFF, f"Worker ASP leaked: 0x{worker_sim.mem[0x0005]:04X}"
        print(f"    (hw_math speedup: {speedup:.2f}x — SW {sw_cycles} vs HW {hw_cycles} cycles, {out_hw})")


TESTS = [
    ("compiler_runtime", test_compiler_runtime),
    ("trap_isr", test_trap_isr),
    ("os_shell_fs", test_os_shell_fs),
    ("os_resident_assembler", test_os_resident_assembler),
    ("os_async_trap1", test_os_async_trap1),
    ("os_multicore_apps", test_os_multicore_apps),
    ("os_mul", test_os_mul),
    ("os_spawn_multiworker", test_os_spawn_multiworker),
    ("os_edge_shell_and_kill", test_os_edge_shell_and_kill),
    ("os_stress_fd_syscalls_multicluster", test_os_stress_fd_syscalls_multicluster),
    ("os_cooperative_fibers", test_os_cooperative_fibers),
    ("os_fat32_subdirs", test_os_fat32_subdirs),
    ("os_console_fg_bg", test_os_console_fg_bg),
    ("os_worker_fault_reporting", test_os_worker_fault_reporting),
    ("os_fs_ops_syscalls", test_os_fs_ops_syscalls),
    ("os_path_and_history", test_os_path_and_history),
    ("os_term_lib", test_os_term_lib),
    ("os_scripts", test_os_scripts),
    ("hw_math_codegen", test_hw_math_codegen),
]


def main() -> int:
    parser = argparse.ArgumentParser(description="MicroRISC4 OS & Toolchain Regression Suite")
    parser.add_argument("--sd-image", default="/tmp/mr4_sd.img", help="Path to FAT32 SD image")
    parser.add_argument("--filter", default=None, help="Only run tests whose name contains this substring")
    args = parser.parse_args()

    selected = [(n, fn) for n, fn in TESTS if not args.filter or args.filter in n]
    if not selected:
        print(f"No tests matched filter {args.filter!r}", file=sys.stderr)
        return 1

    passed = 0
    failed = 0
    t_start = time.monotonic()

    for name, fn in selected:
        t0 = time.monotonic()
        try:
            fn(args)
            dt = time.monotonic() - t0
            print(f"[PASS] {name} ({dt:.2f}s)")
            passed += 1
        except Exception as exc:
            dt = time.monotonic() - t0
            print(f"[FAIL] {name} ({dt:.2f}s): {exc}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            failed += 1

    total_dt = time.monotonic() - t_start
    print(f"\nMicroRISC4 OS Suite: {passed} passed, {failed} failed ({total_dt:.2f}s)")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

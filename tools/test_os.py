#!/usr/bin/env python3
"""
tools/test_os.py - Automated regression test suite for the MiniRISC4
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


def attach_uart_and_watch(sim: mr4sim.MiniRISC4Sim):
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


def run_until_prompt(sim, uart_out, max_steps=6000000, worker=None) -> bool:
    start = len(uart_out)
    for _ in range(max_steps):
        sim.step()
        if worker is not None:
            worker.step()
        if sim.halted:
            return False
        if len(uart_out) > start and "".join(uart_out[start:]).endswith("mr4> "):
            return True
    return False


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

        sim = mr4sim.MiniRISC4Sim(core_id=0)
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

        sim = mr4sim.MiniRISC4Sim(core_id=0)
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
    ls_clus = None
    for idx in range(16):
        ent = img_bytes[root_off + idx * 32 : root_off + (idx + 1) * 32]
        name = ent[0:11].decode("ascii", errors="ignore")
        clus = (struct.unpack_from("<H", ent, 20)[0] << 16) | struct.unpack_from("<H", ent, 26)[0]
        if name == "README  TXT":
            readme_clus = clus
        elif name == "LS      BIN":
            ls_clus = clus
    assert readme_clus is not None and ls_clus is not None

    sim = mr4sim.MiniRISC4Sim(core_id=0)
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
        "help",
        "ps",
        "ls",
        "cat",
        "cat README.TXT",
        "cat readme.txt",
        "cat NOFILE.TXT",
        "write",
        "write note.txt Hello MiniRISC4!",
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
        "LS.BIN",
        "Usage: cat <file>",
        "Hello from MiniRISC4 FAT32 SD card!",
        "File not found: NOFILE.TXT",
        "Usage: write <file> <text>",
        "Wrote note.txt",
        "Hello MiniRISC4!",
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


# ------------------------------------------------------------------------------
# Test 4: Asynchronous Trap 1 ISR -> handle_syscall(SYS_PUTC) -> shell resumes
# ------------------------------------------------------------------------------
def test_os_async_trap1(args):
    sim = mr4sim.MiniRISC4Sim(core_id=0)
    sim.sd_card = mr4sim.SpiSdCard(Path(args.sd_image).read_bytes())
    sim.load_binary(str(OS_BUILD / "os_main.bin"))
    sim.load_symbols(str(OS_BUILD / "os_main.lst"))
    sim.pc = 0x0100
    uart_out, bad_writes = attach_uart_and_watch(sim)

    fifo_in_q = deque()
    fifo_out_q = deque()
    sim.fifo_in_queue = fifo_in_q
    sim.fifo_out_queue = fifo_out_q

    assert run_until_prompt(sim, uart_out, 1500000), "OS boot timed out"

    # Enqueue Class A SYS_PUTC('!') from PID 1 and deliver async Trap 1
    fifo_in_q.extend([(1 << 8) | 0x02, 2, ord("!"), 0])
    sim.pending_traps.append(1)

    for _ in range(100000):
        sim.step()
        if len(fifo_out_q) >= 2:
            break

    assert list(fifo_out_q) == [0, 0], f"Unexpected SYS_PUTC reply: {list(fifo_out_q)}"
    assert "mr4> !" in "".join(uart_out), "SYS_PUTC '!' missing from UART"

    for ch in "ps\r":
        sim.rx_queue.append(ord(ch))
    assert run_until_prompt(sim, uart_out, 1500000), "Shell unresponsive after async Trap 1"
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

        sd_root = p / "sd_root"
        sd_root.mkdir()
        shutil.copy(OS_BUILD / "ls.bin", sd_root / "LS.BIN")
        shutil.copy(OS_BUILD / "ps.bin", sd_root / "PS.BIN")
        shutil.copy(OS_BUILD / "cat.bin", sd_root / "CAT.BIN")
        shutil.copy(wr_bin, sd_root / "WRTEST.BIN")
        (sd_root / "README.TXT").write_text("Hello from MiniRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "mc_test.img"
        subprocess.run(
            [sys.executable, str(TOOLS_DIR / "mksdimage.py"), str(sd_root),
             "-o", str(sd_img), "--size-mb", "16", "--spc", "1"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        os_sim = mr4sim.MiniRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        worker_sim = mr4sim.MiniRISC4Sim(core_id=1)
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
            assert run_until_prompt(os_sim, uart_out, 6000000, worker=worker_sim), f"{cmd} prompt timeout"
            done = False
            for _ in range(8000000):
                os_sim.step()
                worker_sim.step()
                if os_sim.mem[pid1_state_addr] == 0 and marker in "".join(uart_out[start:]):
                    done = True
                    break
            seg = "".join(uart_out[start:])
            assert done, f"{cmd} failed or missed {marker!r}; output:\n{seg}"
            assert os_sim.mem[pid1_state_addr + 1] == 0, f"{cmd} exit_code={os_sim.mem[pid1_state_addr + 1]}"
            return seg

        seg_ls = run_app("run LS.BIN", "README.TXT")
        seg_ps = run_app("run PS.BIN", "1    RUN    PS.BIN")
        seg_cat = run_app("run CAT.BIN", "Hello from MiniRISC4 FAT32 SD card!")
        seg_wr = run_app("run WRTEST.BIN", "READBACK:Userland write OK!")

        # Confirm Core 0 shell reads back APP.TXT written by Worker Core 1
        for ch in "cat APP.TXT\r":
            os_sim.rx_queue.append(ord(ch))
        assert run_until_prompt(os_sim, uart_out, 4000000, worker=worker_sim), "cat APP.TXT failed"

        assert "CAT.BIN" in seg_ls and "PS.BIN" in seg_ls and "WRTEST.BIN" in seg_ls
        assert "0    RUN    os_kernel" in seg_ps and "1    RUN    PS.BIN" in seg_ps
        assert "Hello from MiniRISC4 FAT32 SD card!" in seg_cat
        assert "READBACK:Userland write OK!" in seg_wr
        assert "".join(uart_out).count("Userland write OK!") >= 2

        fds_addr = os_sim.sym_to_addr["_fds"]
        open_fds = [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0]
        assert not open_fds, f"Leaked open FDs: {open_fds}"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
        assert worker_sim.mem[0x0004] == 0xFEFF, f"Core 1 RSP leaked: 0x{worker_sim.mem[0x0004]:04X}"
        assert worker_sim.mem[0x0005] == 0xFAFF, f"Core 1 ASP leaked: 0x{worker_sim.mem[0x0005]:04X}"


TESTS = [
    ("compiler_runtime", test_compiler_runtime),
    ("trap_isr", test_trap_isr),
    ("os_shell_fs", test_os_shell_fs),
    ("os_async_trap1", test_os_async_trap1),
    ("os_multicore_apps", test_os_multicore_apps),
]


def main() -> int:
    parser = argparse.ArgumentParser(description="MiniRISC4 OS & Toolchain Regression Suite")
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
            failed += 1

    total_dt = time.monotonic() - t_start
    print(f"\nMiniRISC4 OS Suite: {passed} passed, {failed} failed ({total_dt:.2f}s)")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

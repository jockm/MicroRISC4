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
        "echo Hello MiniRISC4 world",
        "clear",
        "stat",
        "stat README.TXT",
        "stat NOFILE.TXT",
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
        "Hello MiniRISC4 world",
        "\x1b[2J\x1b[H",
        "Usage: stat <file>",
        "README.TXT  size=36 bytes  attr=0x0020",
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

    # Enable console output for PID 1 and enqueue Class A SYS_PUTC('!') + async Trap 1
    sim.mem[sim.sym_to_addr["_proc_con_out"] + 1] = 1
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
            assert run_until_prompt(os_sim, uart_out, 14000000, worker=worker_sim), f"{cmd} prompt timeout"
            seg = "".join(uart_out[start:])
            assert os_sim.mem[pid1_state_addr] == 0 and marker in seg, (
                f"{cmd} failed or missed {marker!r}; output:\n{seg}"
            )
            assert os_sim.mem[pid1_state_addr + 1] == 0, f"{cmd} exit_code={os_sim.mem[pid1_state_addr + 1]}"
            return seg

        seg_ls = run_app("! LS.BIN", "README.TXT")
        seg_ps = run_app("!PS.BIN", "1    RUN    PS.BIN")
        seg_cat = run_app("! CAT.BIN", "Hello from MiniRISC4 FAT32 SD card!")
        seg_wr = run_app("! WRTEST.BIN", "READBACK:Userland write OK!")

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


# ------------------------------------------------------------------------------
# Test 6: Multi-worker (Cores 1..3) + userland SYS_SPAWN (Core 1 spawns Core 2)
# ------------------------------------------------------------------------------
def test_os_spawn_multiworker(_args):
    spawner_src = """
import "sys.a4";

u16 msg[8];

void main(void) {
    u16 child_pid = 0;
    if (sys_spawn("CAT.BIN", &child_pid) != 0) {
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
        shutil.copy(OS_BUILD / "cat.bin", sd_root / "CAT.BIN")
        shutil.copy(sp_bin, sd_root / "SPAWN.BIN")
        (sd_root / "README.TXT").write_text("Hello from MiniRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "spawn_test.img"
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

        workers = []
        for cid in (1, 2, 3):
            ws = mr4sim.MiniRISC4Sim(core_id=cid)
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
        assert step_all(1500000, lambda: "".join(uart_out).endswith("mr4> ")), "OS boot failed"

        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        pid2_state = procs_addr + 20

        start = len(uart_out)
        for ch in "! SPAWN.BIN\r":
            os_sim.rx_queue.append(ord(ch))
        assert step_all(
            14000000,
            lambda: len(uart_out) > start and "".join(uart_out[start:]).endswith("mr4> "),
        ), f"! SPAWN.BIN prompt timeout; output:\n{''.join(uart_out[start:])}"

        # Wait until BOTH parent (PID 1 on Core 1) and child (PID 2 on Core 2) finish
        def both_finished():
            if os_sim.mem[pid1_state] != 0 or os_sim.mem[pid2_state] != 0:
                return False
            seg_now = "".join(uart_out[start:])
            if "SPAWNED:2\r\n" not in seg_now:
                return False
            return "Hello from MiniRISC4 FAT32 SD card!" in seg_now.replace("SPAWNED:2\r\n", "")

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
            lambda: len(uart_out) > ps_start and "".join(uart_out[ps_start:]).endswith("mr4> "),
        ), "ps after multi-worker SYS_SPAWN timed out"
        ps_out = "".join(uart_out[ps_start:])
        assert "1    FREE" in ps_out and "2    FREE" in ps_out, f"Workers not reclaimed in ps:\n{ps_out}"

        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
        for idx, ws in enumerate(workers, start=1):
            assert ws.mem[0x0004] == 0xFEFF, f"Worker {idx} RSP leaked: 0x{ws.mem[0x0004]:04X}"
            assert ws.mem[0x0005] == 0xFAFF, f"Worker {idx} ASP leaked: 0x{ws.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 7: Shell line overflow/editing, worker exhaustion & Trap 14 kill recovery
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
        shutil.copy(OS_BUILD / "cat.bin", sd_root / "CAT.BIN")
        shutil.copy(spin_bin, sd_root / "SPIN.BIN")
        (sd_root / "README.TXT").write_text("Hello from MiniRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "kill_test.img"
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

        workers = []
        for cid in (1, 2, 3):
            ws = mr4sim.MiniRISC4Sim(core_id=cid)
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
            ok = step_all(max_steps, lambda: len(uart_out) > start and "".join(uart_out[start:]).endswith("mr4> "))
            assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
            return "".join(uart_out[start:])

        assert step_all(1500000, lambda: "".join(uart_out).endswith("mr4> ")), "OS boot failed"

        # 1. Shell edge cases: backspace (0x08 & 0x7F), >LINE_MAX clamping, unknown command
        out_bs = send_cmd("ecxo\x08\x7fho edit_ok\r")
        assert "\r\nedit_ok\r\n" in out_bs, f"Backspace edit failed: {out_bs!r}"

        long_line = "echo " + ("A" * 80) + "\r"
        out_long = send_cmd(long_line)
        # LINE_MAX = 64 -> max 63 chars: "echo " (5) + 58 'A's
        assert ("A" * 58) in out_long and ("A" * 59) not in out_long, f"Line clamp failed: {out_long!r}"

        out_unk = send_cmd("boguscmd\r")
        assert "Unknown command: boguscmd" in out_unk

        # 2. Exhaust all 3 worker cores with runaway SPIN.BIN instances
        assert "Spawned PID 1" in send_cmd("run SPIN.BIN\r")
        assert "Spawned PID 2" in send_cmd("run SPIN.BIN\r")
        assert "Spawned PID 3" in send_cmd("run SPIN.BIN\r")
        assert "No free worker core" in send_cmd("run SPIN.BIN\r")

        # Give workers time to execute their sys_open("README.TXT") and enter spin loop
        fds_addr = os_sim.sym_to_addr["_fds"]
        assert step_all(
            2000000,
            lambda: sum(1 for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0) == 3,
        ), "Expected all 3 runaway workers to hold open FDs"

        out_ps = send_cmd("ps\r")
        assert "1    RUN    SPIN.BIN" in out_ps
        assert "2    RUN    SPIN.BIN" in out_ps
        assert "3    RUN    SPIN.BIN" in out_ps

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

        # 4. Verify killed worker Core 1 cleanly resets and executes CAT.BIN in foreground
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        out_cat = send_cmd("! CAT.BIN\r", max_steps=12000000)
        assert "Hello from MiniRISC4 FAT32 SD card!" in out_cat, (
            f"Worker 1 failed to run CAT.BIN after Trap 14 kill: {out_cat!r}"
        )
        assert os_sim.mem[pid1_state] == 0 and os_sim.mem[pid1_state + 1] == 0
        send_cmd("ps\r")

        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF
        for idx, ws in enumerate(workers, start=1):
            assert ws.mem[0x0004] == 0xFEFF, f"Worker {idx} RSP leaked: 0x{ws.mem[0x0004]:04X}"
            assert ws.mem[0x0005] == 0xFAFF, f"Worker {idx} ASP leaked: 0x{ws.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 8: FD exhaustion, invalid syscalls (Class A/B/C), & multi-cluster write/read
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
        shutil.copy(st_bin, sd_root / "STRESS.BIN")
        (sd_root / "README.TXT").write_text("Hello from MiniRISC4 FAT32 SD card!\n", encoding="utf-8")
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

        os_sim = mr4sim.MiniRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(init_img)
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
        pid1_state = procs_addr + 10

        start = len(uart_out)
        for ch in "! STRESS.BIN\r":
            os_sim.rx_queue.append(ord(ch))
        assert run_until_prompt(os_sim, uart_out, 30000000, worker=worker_sim), (
            f"! STRESS.BIN prompt timeout; out={''.join(uart_out[start:])!r}"
        )
        seg = "".join(uart_out[start:])
        assert os_sim.mem[pid1_state] == 0 and "STRESS_OK" in seg, f"STRESS.BIN failed; output:\n{seg}"
        assert os_sim.mem[pid1_state + 1] == 0, f"STRESS.BIN exit={os_sim.mem[pid1_state + 1]}"

        # Settle to prompt via `ps`
        for ch in "ps\r":
            os_sim.rx_queue.append(ord(ch))
        assert run_until_prompt(os_sim, uart_out, 2000000, worker=worker_sim)

        # Verify ALL 8 leaked FDs were auto-reclaimed on exit
        fds_addr = os_sim.sym_to_addr["_fds"]
        open_fds = [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0]
        assert not open_fds, f"Leaked FDs after STRESS.BIN exit: {open_fds}"

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
# Test 9: Cooperative fibers (lib/fiber.a4 + FIBERS.BIN) on a single worker core
# ------------------------------------------------------------------------------
def test_os_cooperative_fibers(args):
    os_sim = mr4sim.MiniRISC4Sim(core_id=0)
    os_sim.sd_card = mr4sim.SpiSdCard(Path(args.sd_image).read_bytes())
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
    pid1_state = procs_addr + 10

    start = len(uart_out)
    for ch in "! FIBERS.BIN\r":
        os_sim.rx_queue.append(ord(ch))
    assert run_until_prompt(os_sim, uart_out, 25000000, worker=worker_sim), (
        f"! FIBERS.BIN prompt timeout; out={''.join(uart_out[start:])!r}"
    )

    seg = "".join(uart_out[start:])
    assert os_sim.mem[pid1_state] == 0, f"FIBERS.BIN still running; output:\n{seg}"
    assert "A0 B0 C0 A1 B1 C1 A2 B2 C2 " in seg, f"Unexpected fiber interleaving:\n{seg}"
    assert "FIBERS_OK" in seg, f"FIBERS.BIN did not report FIBERS_OK:\n{seg}"
    assert os_sim.mem[pid1_state + 1] == 0, f"FIBERS.BIN exit={os_sim.mem[pid1_state + 1]}"

    # Settle via `ps`
    for ch in "ps\r":
        os_sim.rx_queue.append(ord(ch))
    assert run_until_prompt(os_sim, uart_out, 2000000, worker=worker_sim)

    assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
    assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
    assert worker_sim.mem[0x0004] == 0xFEFF, f"Core 1 RSP leaked: 0x{worker_sim.mem[0x0004]:04X}"
    assert worker_sim.mem[0x0005] == 0xFAFF, f"Core 1 ASP leaked: 0x{worker_sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 10: FAT32 Subdirectories (mkdir, cd, pwd, rmdir, nested paths & syscalls)
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
        shutil.copy(app_bin, sd_root / "DIRAPP.BIN")
        (sd_root / "README.TXT").write_text("Hello from MiniRISC4 FAT32 SD card!\n", encoding="utf-8")
        sd_img = p / "subdir_test.img"
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
        assert "Hello from MiniRISC4 FAT32 SD card!" in send_cmd("cat /README.TXT\r")
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

        # 5. Userland worker app using sys_mkdir / sys_open / sys_opendir / sys_chdir / sys_rmdir
        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        seg = send_cmd("! DIRAPP.BIN\r", max_steps=25000000)
        assert os_sim.mem[pid1_state] == 0, f"DIRAPP.BIN still running; out={seg!r}"
        assert "APPREAD:Subdir syscall OK!" in seg, f"DIRAPP.BIN readback mismatch:\n{seg}"
        assert "SUBDIR_APP_OK" in seg, f"DIRAPP.BIN failed:\n{seg}"
        assert os_sim.mem[pid1_state + 1] == 0, f"DIRAPP.BIN exit={os_sim.mem[pid1_state + 1]}"
        assert "APPDIR" not in send_cmd("ls\r")

        # Verify no FD/stack leaks and zero bad low-memory writes
        fds_addr = os_sim.sym_to_addr["_fds"]
        open_fds = [i for i in range(8) if os_sim.mem[fds_addr + i * 15] != 0]
        assert not open_fds, f"Leaked open FDs: {open_fds}"
        assert not bad_writes, f"Bad low-memory writes: {bad_writes}"
        assert os_sim.mem[0x0005] == 0xFAFF, f"Core 0 ASP leaked: 0x{os_sim.mem[0x0005]:04X}"
        assert worker_sim.mem[0x0004] == 0xFEFF, f"Core 1 RSP leaked: 0x{worker_sim.mem[0x0004]:04X}"
        assert worker_sim.mem[0x0005] == 0xFAFF, f"Core 1 ASP leaked: 0x{worker_sim.mem[0x0005]:04X}"


# ------------------------------------------------------------------------------
# Test 11: Console ownership (run vs !, fg, bg, fg --fgoutput, Ctrl-Z, Ctrl-C)
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
            out_bin = sd_root / f"{name}.BIN"
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

        os_sim = mr4sim.MiniRISC4Sim(core_id=0)
        os_sim.sd_card = mr4sim.SpiSdCard(sd_img.read_bytes())
        os_sim.load_binary(str(OS_BUILD / "os_main.bin"))
        os_sim.load_symbols(str(OS_BUILD / "os_main.lst"))
        os_sim.pc = 0x0100
        uart_out, bad_writes = attach_uart_and_watch(os_sim)

        workers = []
        for cid in (1, 2, 3):
            ws = mr4sim.MiniRISC4Sim(core_id=cid)
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
                ok = step_all(max_steps, lambda: "mr4> " in "".join(uart_out[start:]))
            else:
                ok = step_all(max_steps, lambda: len(uart_out) > start and "".join(uart_out[start:]).endswith("mr4> "))
            assert ok, f"Command {cmd_str!r} timed out; out={''.join(uart_out[start:])!r}"
            return "".join(uart_out[start:])

        assert step_all(1500000, lambda: "".join(uart_out).endswith("mr4> ")), "OS boot failed"

        procs_addr = os_sim.sym_to_addr["_procs"]
        pid1_state = procs_addr + 10
        fg_pid_addr = os_sim.sym_to_addr["_fg_pid"]

        # 1. Background `run` mutes console output (Option A) while still completing work
        bg_start = len(uart_out)
        assert "Spawned PID 1" in send_cmd("run BGWORK.BIN\r")
        assert step_all(10000000, lambda: os_sim.mem[pid1_state] == 0), "BGWORK.BIN did not exit"
        assert "BG_MUTE_SHOULD_NOT_APPEAR" not in "".join(uart_out[bg_start:])
        assert "bg_ran" in send_cmd("cat BGDONE.TXT\r")

        # 2. `run` + `fg <pid>` hands keyboard input (SYS_GETC) & output; Ctrl-Z detaches; Ctrl-C kills
        assert "Spawned PID 1" in send_cmd("run ECHOAPP.BIN\r")
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
            lambda: os_sim.mem[fg_pid_addr] == 0 and "".join(uart_out[cz_start:]).endswith("mr4> "),
        ), f"Ctrl-Z failed: {''.join(uart_out[cz_start:])!r}"
        assert "[Backgrounded PID 1]" in "".join(uart_out[cz_start:])
        out_ps = send_cmd("ps\r")
        assert "1    RUN    ECHOAPP.BIN" in out_ps and "[FG]" not in out_ps

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
            and "".join(uart_out[cc_start:]).endswith("mr4> "),
        ), f"Ctrl-C failed: {''.join(uart_out[cc_start:])!r}"
        assert "^C Killed PID 1" in "".join(uart_out[cc_start:])

        # 3. Simultaneous multi-core output via `fg --fgoutput <pid>` while shell keeps keyboard input
        quiet_start = len(uart_out)
        assert "Spawned PID 1" in send_cmd("run CHAT1.BIN\r")
        assert "Spawned PID 2" in send_cmd("run CHAT2.BIN\r")
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
        assert "1    RUN    CHAT1.BIN  [OUT]" in out_ps2, f"Missing [OUT] on PID 1:\n{out_ps2}"
        assert "2    RUN    CHAT2.BIN  [OUT]" in out_ps2, f"Missing [OUT] on PID 2:\n{out_ps2}"

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


TESTS = [
    ("compiler_runtime", test_compiler_runtime),
    ("trap_isr", test_trap_isr),
    ("os_shell_fs", test_os_shell_fs),
    ("os_async_trap1", test_os_async_trap1),
    ("os_multicore_apps", test_os_multicore_apps),
    ("os_spawn_multiworker", test_os_spawn_multiworker),
    ("os_edge_shell_and_kill", test_os_edge_shell_and_kill),
    ("os_stress_fd_syscalls_multicluster", test_os_stress_fd_syscalls_multicluster),
    ("os_cooperative_fibers", test_os_cooperative_fibers),
    ("os_fat32_subdirs", test_os_fat32_subdirs),
    ("os_console_fg_bg", test_os_console_fg_bg),
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
            traceback.print_exc(file=sys.stderr)
            failed += 1

    total_dt = time.monotonic() - t_start
    print(f"\nMiniRISC4 OS Suite: {passed} passed, {failed} failed ({total_dt:.2f}s)")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

# MiniRISC4 Operating System: Project Roadmap & Developer Directives

## 1. Executive Summary & Project Vision

The **MiniRISC4 Operating System** is a lightweight 16-bit multitasking operating system designed for the custom MiniRISC4 processor architecture. The ecosystem comprises:
- **Compiler & Toolchain (`tools/act4c.py`, `tools/mr4asm.py`):** The ACT4 language compiler, assembler, and binary toolchain.
- **Simulator (`mr4sim.py`):** Cycle-accurate simulator for execution, debugging, memory inspection, and I/O tracing.
- **Core OS Kernel (`mr4src/act4/os/`):** Process table management, scheduler, trap handlers, memory buffers, and FAT32 filesystem stack.
- **Userland Applications (`mr4src/act4/apps/`):** Shell, file system utilities (`ls`, `cat`), and user space binaries executing via system call interface.

The ultimate objective of this project is a fully functional, stable operating system environment capable of booting on the MiniRISC4 hardware/simulator, mounting a FAT32 storage volume, running an interactive shell, managing process lifecycle (context switching, scheduling, multitasking, IPC), and executing userland programs.

---

## 2. Core OS Architecture & Component Map

```
+-------------------------------------------------------------------+
|                     Userland Applications                         |
|             (sh.a4, ls.a4, cat.a4, custom binaries)               |
+-------------------------------------------------------------------+
                                  | Syscall Interface (SVC / TRAP)
+-------------------------------------------------------------------+
|                        MiniRISC4 OS Kernel                        |
|  +--------------------+  +------------------+  +---------------+  |
|  | Process Scheduler  |  | Memory & Buffers |  | Syscall Engine|  |
|  | (ProcEntry, PCBs)  |  | (_sys_buf, Heap) |  | (sys_ent)     |  |
|  +--------------------+  +------------------+  +---------------+  |
|  +-------------------------------------------------------------+  |
|  |                FAT32 Filesystem & SD Driver                 |  |
|  |                (_fds, sector cache, cluster maps)           |  |
|  +-------------------------------------------------------------+  |
+-------------------------------------------------------------------+
                                  | Hardware Abstraction / Assembly
+-------------------------------------------------------------------+
|                       MiniRISC4 Simulator / HW                    |
|                (Registers R0-R15, Memory, Serial, SD)             |
+-------------------------------------------------------------------+
```

---

## 3. Comprehensive Project Roadmap

### Phase 1: Toolchain & Compiler Stabilization (`act4c.py`)
- [x] **Type Inference & Member Access:** Standardize type resolution for `IndexAccess` and `MemberAccess` chains (`infer_type_desc`, `procs[i].name`, `fds[i].cluster`, `out->name`, cross-import `const` lookup).
- [x] **Array Addressing & Address Decay:** Arrays within structs decay cleanly to memory addresses (`LD R1, R0`) rather than dereferencing invalid memory locations (`LD R1, (R0)`).
- [x] **LValue & Pointer Arithmetic:** Audited pointer offsets, struct pointer element sizing, re-entrant `APUSH`/`APOP` lowering, register-safe `STPUSH`/`STPOP` (`lib/common.inc`), and fixed `MULT`/`DIVMOD_CORE` (`lib/M4R_LIB.asm`).
- [x] **Struct Alignment & Allocation:** Verified static `.word` allocation matches `word_size(self.structs)` across `_procs`, `_fds`, `_sys_ent`, `_sh_ent`, and nested structs.
- [x] **Code-Size & Runtime Optimization (`act4c.py` / `M4R_LIB.asm`):** Added reachability dead-function elimination, string-literal deduplication, register-direct RHS evaluation & `== 0`/`!= 0` fast paths, direct multi-arg passing (avoiding `APUSH`/`APOP` when args contain no calls), power-of-2 shift scaling, compact small-constant loads (`LD0`, `LD0+INC`/`DEC`, `LD R0, imm4`), and shared `_ACT4_RET` / `_ACT4_APUSH_R1` / `_ACT4_APOP_R1/R2` / `_ACT4_GETBYTE` / `_ACT4_SETBYTE` helpers — cutting `os_main.bin` by **59%** (`0xEEE6` → `0x61C7`, **~39.2K words** free below `ASP`) and more than doubling simulation speed.

### Phase 2: OS Kernel Core & Memory Initialization
- [x] **Kernel Bootstrap & Stacks:** Validated `_reset_slot` (`0x0100`), `RSP`/`ASP` initialization, and zero-leak stack integrity (`ASP=0xFAFF`, `0` low-memory corruptions).
- [x] **Process Control Block (PCB) Management:** Process table allocation (`_procs`), state transitions (`FREE`, `LOAD`, `RUN`), PID tracking, per-PID CWD isolation (`_proc_cwd_hi`/`_proc_cwd_lo`, inherited on spawn and guarded in `rmdir`), per-PID command-line arguments (`_proc_args`), `ps`, `kill`, and automatic per-owner FD cleanup (`fat32_close_owner`).
- [x] **Memory & Buffer Layout:** Established clean boundaries for kernel buffers (`_sys_buf`, sector-streaming loader via `_sec_buf` without a 4K static image buffer), `0x0400` userland `--nopreamble`/`--sparsebin` entry trampoline, and stack regions.
- [x] **Trap & Interrupt Handling:** Direct-stride `@ trap(N)` ISR prologue/epilogue (`RPUSH`/`RPOP` `R0`–`R3`, nested trap support, early `return;` via `_iret`) aligned across `act4c.py`, `mr4sim.py`, and `cpu_core.dart`.

### Phase 3: Storage, Drivers & FAT32 Filesystem
- [x] **SD Card Block Layer:** SPI SDHC `CMD17` (`sd_read_sector`) and `CMD24` (`sd_write_sector`) block reads/writes verified in `mr4sim.py` without memory corruption.
- [x] **FAT32 Volume Mount:** Boot sector parser, MBR/BPB cluster-to-sector mapping (`_sec_per_clus`, `_root_clus_lo`, `_fat_num_fats`, `_fat_sz_lo`), and fixed `tools/mksdimage.py` BPB packing.
- [x] **Directory & File Operations:** Subdirectory support (`mkdir`, `rmdir`, `cd`, `pwd`) and full relative/absolute path traversal (`/` / `.` / `..`), directory enumeration (`ls [dir]`), case-insensitive 8.3 lookup, streaming open/read (`fat32_open`, `fat32_read_bytes`), create/overwrite/write with cluster allocation (`fat32_open_write`, `fat32_write_bytes`), `stat`, and unlink/rmdir with multi-cluster chain freeing across all FAT copies (`fat32_unlink`, `fat32_rmdir`).

### Phase 4: Process Management, Context Switching & Syscalls
- [x] **Multi-Core Process Execution & Cooperative Fibers:** Native multitasking across Core 0 (OS) + Worker Cores (1..N, scalable up to 255 cores via `worker_stub.asm` + `fifo_sel`), plus optional single-core cooperative fibers (`lib/fiber.a4`, `fibers.a4`) with per-fiber `RSP`/`ASP` stacks and `0xDEAD` canaries.
- [x] **Syscall Dispatcher:** Implemented 3-class Trap 1 syscall table (`SYS_EXIT`, `SYS_PUTC`, `SYS_GETC`, `SYS_KILL`, `SYS_CLOSE`, `SYS_WRITE_CON`, `SYS_SPAWN`, `SYS_OPEN`, `SYS_WRITE`, `SYS_OPENDIR`, `SYS_UNLINK`, `SYS_MKDIR`, `SYS_RMDIR`, `SYS_CHDIR`, `SYS_READ`, `SYS_READDIR`, `SYS_PS`, `SYS_GETARGS`) and `lib/sys.a4` wrappers.
- [x] **IPC & Messaging:** Validated inter-core FIFO (`0x000A`/`0x000B`), channel selector (`0x0021`), Mailbox Trap 1/14 (`0x000C`), and counting `_msg_pending` queue across Core 0 and Workers 1–3.

### Phase 5: Interactive Shell & Userland Application Suite
- [x] **Shell Interpreter (`os_shell.a4`):** Completed line editor (`_sh_line`), tokenizer (`_sh_cmd`, `_sh_arg`, multi-word payload offsets), console ownership (`! <file>` foreground, `run <file>` background with muted output, `fg [--fgoutput] <pid>`, `bg <pid>`, `Ctrl-Z` detach, `Ctrl-C` Trap 14 kill, foreground `SYS_GETC` routing), and built-ins (`help`, `ps`, `kill`, `pwd`, `cd`, `ls`, `mkdir`, `rmdir`, `cat`, `stat`, `write`, `rm`, `echo`, `clear`).
- [x] **Built-in & File Utilities:** Built standalone `0x0400` userland binaries (`ls.a4`, `ps.a4`, `cat.a4`, `fibers.a4`) packed onto the FAT32 SD image (`LS.BIN`, `PS.BIN`, `CAT.BIN`, `FIBERS.BIN`).
- [x] **Application Executable Loading:** Streams raw `--sparsebin` executables sector-by-sector directly from FAT32 (`fat32_read_next_sector` → `_sec_buf` → `fifo_out`, up to `0xF600` words / ~126 KB) into free worker cores (`worker_stub.asm`), executes userland syscalls, and reclaims workers cleanly on exit.

### Phase 6: System Integration, Stress Testing & Verification
- [x] **Full-System Simulation:** Complete boot sequence verified in `mr4sim.py` (`make sim-os` with 3 worker cores) from reset through FAT32 mount, interactive shell, and multi-core userland execution.
- [x] **Automated Test Suite:** Implemented `tools/test_os.py` (`make os-test` / `make test-os`, 11 suites) covering compiler/runtime math & structs, `@ trap(N)` ISRs, shell & FAT32 read/write/unlink/subdirectories, async Trap 1, multi-core `LS.BIN`/`PS.BIN`/`CAT.BIN`/`SYS_WRITE`/`SYS_SPAWN`, cooperative fibers (`FIBERS.BIN`), console ownership (`!`/`run`/`fg`/`bg`/`--fgoutput`/`Ctrl-Z`/`Ctrl-C`), and stress/edge cases.
- [x] **Stress & Edge Case Testing:** Verified shell line-buffer overflow clamping & backspace editing, 8-FD exhaustion + auto-reclamation on exit/kill, invalid Class A/B/C syscall payload draining (`ERR_UNKNOWN`), 3-worker core exhaustion + Trap 14 `kill` recovery, and multi-cluster (>512B) file write/readback/unlink.

---

## 4. Operational Directives for the Assistant (MiniRISC4 Persona)

To ensure consistent progress, high-quality code modification, and rapid bug resolution, adhere to the following developer directives:

### 1. Build Tools & Workflow
- **Primary Tooling:** Always prefer standard `make` targets for building and testing:
  - `make os-build` — Rebuilds the entire OS kernel assembly and binary output.
  - `make sd-img` — Creates/updates the FAT32 SD card image containing binaries.
  - `make sim-os` — Launches the simulator running the OS kernel image with 3 worker cores.
  - `make test-os` — Runs the automated OS, compiler, FAT32, and multi-core regression suite (`tools/test_os.py`).
  - `make apps` — Rebuilds all userland application binaries.
  - `make test` — Executes the automated ROHD HDL regression test suite.
- **Standalone Tooling (`./mbuild`):** Use `./mbuild` when testing isolated `.a4` or `.asm` source files:
  - `./mbuild -I lib source.a4 -o build/out.bin`
  - `./mbuild --sim build/out.bin`

### 2. Code Inspection & Patch Discipline
- **Inspect First:** Never guess line numbers or make blind replacements. Always inspect target files prior to editing.
- **Targeted Edits:** Apply focused diffs or structured patches rather than replacing entire files unnecessarily.
- **Context Verification:** If context is missing, truncated, or ambiguous, explicitly inspect or request the relevant code section before proposing modifications.

### 3. Architecture & Code Generation Rules
- **16-Bit Word Orientation:** Maintain awareness of MiniRISC4 16-bit word alignment and pointer addressing rules.
- **Calling Convention:** Ensure function parameters, return values, and register saving conform strictly to the MiniRISC4 ABI.
- **Data Allocation:** Verify that array sizes declared in ACT4 map directly to allocated `.word` buffers in generated assembly.

### 4. Verification Routine
- Every code change must be followed by:
  1. Build check (`make os-build` or `./mbuild`).
  2. Simulation test (`mr4sim.py` run or `make sim-os`).
  3. Context verification to confirm no unexpected side effects occurred in adjacent modules.
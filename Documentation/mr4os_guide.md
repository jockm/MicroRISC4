# MicroRISC4 Operating System (`mr4os`) Guide

**Architecture, Design Theory, User Experience, and Developer API Reference**

---

## Table of Contents

1. [Introduction & Design Philosophy](#1-introduction--design-philosophy)
2. [System Architecture & Theory](#2-system-architecture--theory)
   - [2.1 Asymmetric Multi-Core Topology (2–255 Cores)](#21-asymmetric-multi-core-topology-2255-cores)
   - [2.2 Memory Maps (Core 0 & Worker Cores)](#22-memory-maps-core-0--worker-cores)
   - [2.3 Inter-Core IPC, FIFOs, and Traps](#23-inter-core-ipc-fifos-and-traps)
   - [2.4 Streaming Executable Loader](#24-streaming-executable-loader)
   - [2.5 Three-Class Trap 1 Syscall Wire Protocol](#25-three-class-trap-1-syscall-wire-protocol)
   - [2.6 Process Lifecycle, Isolation & Fault Reporting](#26-process-lifecycle-isolation--fault-reporting)
   - [2.7 Console Ownership Model](#27-console-ownership-model)
   - [2.8 Storage & FAT32 Filesystem Architecture](#28-storage--fat32-filesystem-architecture)
   - [2.9 Multi-Core Processes vs. Cooperative Fibers](#29-multi-core-processes-vs-cooperative-fibers)
3. [User Experience & Shell Reference](#3-user-experience--shell-reference)
   - [3.1 Building, Booting, and Simulating](#31-building-booting-and-simulating)
   - [3.2 Interactive Line Editor & Command History](#32-interactive-line-editor--command-history)
   - [3.3 Explicit-Only Program Launching (`!`, `run`, `&`)](#33-explicit-only-program-launching--run-)
   - [3.4 Executable PATH Resolution](#34-executable-path-resolution)
   - [3.5 Script Files (`do` / `@`)](#35-script-files-do--)
   - [3.6 Console Ownership & Job Control Walkthrough](#36-console-ownership--job-control-walkthrough)
   - [3.7 Built-In Shell Commands](#37-built-in-shell-commands)
   - [3.8 Worker Crash & Fault Diagnostics](#38-worker-crash--fault-diagnostics)
4. [Developer & API Reference](#4-developer--api-reference)
   - [4.1 Writing & Building Userland Applications](#41-writing--building-userland-applications)
     - [MuL scripting interpreter](#mul-scripting-interpreter)
   - [4.2 Kernel Syscall Table (`0x01`–`0x25`)](#42-kernel-syscall-table-0x010x25)
   - [4.3 `lib/sys.a4` — System Call Client Library](#43-libsysa4--system-call-client-library)
   - [4.4 `lib/term.a4` — ANSI Terminal & Keyboard Library](#44-libterma4--ansi-terminal--keyboard-library)
   - [4.5 `lib/fiber.a4` — Cooperative Fiber Library](#45-libfibera4--cooperative-fiber-library)
   - [4.6 Complete Userland Examples](#46-complete-userland-examples)

---

## 1. Introduction & Design Philosophy

The **MicroRISC4 Operating System (`mr4os`)** is a lightweight, multi-core microkernel-style OS written in **ACT4** (the native C-like language for the 16-bit MicroRISC4 architecture) paired with a compact 16-bit assembly worker stub (`worker_stub.asm`).

Rather than forcing preemptive time-slicing, virtual memory, and an MMU onto a compact 16-bit FPGA soft-core, `mr4os` embraces the MicroRISC4 hardware's multi-core design through a **one-core-per-program** model:

- **Core 0 (OS Kernel & Shell):** Owns all physical I/O peripherals (UART console and SPI SD card), mounts the FAT32 filesystem, manages the process table, routes console input/output, and serves syscalls from worker cores.
- **Cores 1..N (Worker Cores):** Each worker core has its own completely private 64K-word (128 KB) RAM and runs a tiny resident stub (`0x0100–0x03FF`). When a program is launched, Core 0 streams its binary directly into an idle worker core's RAM at `0x0400` and lets it run at full hardware speed with zero context-switch overhead.
- **Hardware Isolation by Construction:** Because worker cores cannot directly read or overwrite Core 0's RAM or another worker's RAM, a runaway user application can only corrupt its own core. Core 0 can unconditionally reset any misbehaving worker via a hardware Mailbox Trap 14 signal.
- **Optional In-Process Concurrency:** When a single application needs multiple concurrent flows of control on its own core (e.g., background animation + keyboard UI + background calculation), it can include [`lib/fiber.a4`](../lib/fiber.a4) for cooperative round-robin coroutines without OS involvement.

---

## 2. System Architecture & Theory

### 2.1 Asymmetric Multi-Core Topology (2–255 Cores)

The wire protocol encodes core IDs in an 8-bit field (`0..255`), allowing `mr4os` to scale from **2 cores** (Core 0 + 1 worker) up to **255 worker cores** (Core 0 + Cores 1..255).

- **PID == Core ID:** Process IDs map 1:1 to physical core IDs. PID `0` is always the Core 0 OS kernel (`os_kernel`); PIDs `1..(MAX_CORES - 1)` are worker slots.
- **Default Configuration:** `MAX_CORES = 4` in `mr4src/act4/os/os_proc.a4` (Core 0 + 3 worker cores, matching `make sim-os` `--workers 3`).

```
                     ┌─────────────────────────────────────────┐
  UART (0x000E/0F) ◄─┤              Core 0 (PID 0)             │
  SPI SD (0x0018-1A)◄┤  os_main / os_shell / os_proc / os_fat32│
                     └──────┬────────────┬────────────┬────────┘
                 FIFO_SEL=1 │ FIFO_SEL=2 │ FIFO_SEL=3 │  (Inter-core FIFOs
                 Mailbox T1 │ Mailbox T1 │ Mailbox T1 │   + Mailbox Traps)
                     ┌──────▼──────┐ ┌───▼─────────┐ ┌▼────────────┐
                     │ Worker 1    │ │ Worker 2    │ │ Worker 3    │
                     │ worker_stub │ │ worker_stub │ │ worker_stub │
                     │ + App @0400 │ │ + App @0400 │ │ + App @0400 │
                     └─────────────┘ └─────────────┘ └─────────────┘
```

### 2.2 Memory Maps (Core 0 & Worker Cores)

MicroRISC4 is **word-addressed** (16 bits per address; `0x0000`–`0xFFFF` = 65,536 words = 128 KB per core).

#### Shared Hardware / MMIO Low Page (`0x0000–0x002F`)

| Address | Name | Core 0 | Worker Core | Description |
| :--- | :--- | :---: | :---: | :--- |
| `0x0004` | `RSP` | R/W | R/W | Hardware Return Stack Pointer (initialized to `0xFEFF`, grows down) |
| `0x0005` | `ASP` | R/W | R/W | Hardware Argument/Data Stack Pointer (initialized to `0xFAFF`, grows down) |
| `0x0006–0x0009` | ACT4 scratch | R/W | R/W | Compiler scratchpad temporaries |
| `0x000A` | `FIFO_IN` | R | R | Pop next 16-bit word from inbound inter-core FIFO (returns `0` when empty) |
| `0x000B` | `FIFO_OUT` | W | W | Push 16-bit word to outbound inter-core FIFO |
| `0x000C` | `MAILBOX` | W | W | Trigger remote hardware trap: `(target_core_id << 8) \| trap_vector` |
| `0x000D` | `CPUID` | R | R | Read-only hardware core ID (`0` on Core 0, `1..N` on workers) |
| `0x000E` | `UART_RX` | R | — | Bit 15 = data ready (`0x8000`), bits 7..0 = received ASCII byte |
| `0x000F` | `UART_TX` | R/W | — | Read: `0` when ready, non-zero while busy; Write: transmit byte |
| `0x0010–0x0017` | Stub scratch | — | R/W | `worker_stub.asm` private state (`STUB_ARG1..3`, `RET_PC`, `SYS_ID`, `ENTRY`) |
| `0x0018` | `SPI_CTRL` | R/W | — | Bit 0 = `CS_N` (`1` = deselected, `0` = selected); clock divider control |
| `0x0019` | `SPI_STAT` | R | — | Bit 0 = busy (`1` while transfer in progress) |
| `0x001A` | `SPI_DATA` | R/W | — | Write byte to initiate 8-bit SPI transfer; read received byte when idle |
| `0x0021` | `FIFO_SEL` | W | — | Selects which worker core channel Core 0's `FIFO_OUT` pushes to |

#### Worker Core Address Space (`0x0000–0xFFFF`)

| Range (Words) | Size | Region |
| :--- | :--- | :--- |
| `0x0000–0x002F` | 48 words | Hardware MMIO & `worker_stub.asm` private scratchpad (`0x0010–0x0017`) |
| `0x0100–0x01FF` | 256 words | Direct-stride hardware trap vector table (16 vectors × 16 words) |
| `0x0200–0x03FF` | 512 words | Resident `worker_stub.asm` loader, Trap 1 syscall bridge, and fault reporter |
| `0x0400–0xFAFF` | ~63,232 words (~126 KB) | **Userland Application Space** (`APP_LOAD_ADDR = 0x0400`, `APP_MAX_WORDS = 0xF600`) |
| `0xFAFF` ↓ | — | `ASP` initial top (grows downward toward userland heap/BSS) |
| `0xFEFF` ↓ | — | `RSP` initial top (grows downward toward `ASP`) |

Core 0 uses the same `0x0100` vector table and stack layout (`ASP = 0xFAFF`, `RSP = 0xFEFF`), with the compiled `os_main.bin` kernel occupying `0x0100` through roughly `0x7F80` (~32K words), leaving ~31.6K words (~62 KB) of free RAM below `ASP` for future kernel growth.

### 2.3 Inter-Core IPC, FIFOs, and Traps

Communication between Core 0 and worker cores uses two hardware primitives:

1. **Word-Streaming FIFOs (`0x000A` / `0x000B` + `0x0021`):**
   - Workers push syscall request words to `FIFO_OUT` (`0x000B`) and read replies from `FIFO_IN` (`0x000A`).
   - Core 0 reads inbound requests from `FIFO_IN` (`0x000A`), selects the target worker channel by writing `pid` to `FIFO_SEL` (`0x0021`), and writes replies or binary load streams to `FIFO_OUT` (`0x000B`).
2. **Mailbox Hardware Traps (`0x000C`):**
   - Writing `(target_core << 8) | trap_vec` pulses a hardware trap on `target_core`, jumping it to `0x0100 + (trap_vec * 0x10)`.
   - **Worker → Core 0 (`0x0001` = Core 0, Trap 1):** Signals that a complete syscall packet has been pushed into Core 0's inbound FIFO. Core 0's Trap 1 ISR (`on_msg_ready`) is a zero-spill handler that simply increments `msg_pending++` using hardware shadow registers so the shell loop is never disturbed. Core 0's main event loop drains `msg_pending` via `handle_syscall()` interleaved with `shell_poll()`.
   - **Core 0 → Worker (`(pid << 8) | 14` = Worker, Trap 14):** Preemptively kills the running user app on `pid`. `worker_stub.asm`'s `_trap14_kill` vector discards app state, resets `RSP`/`ASP`, and jumps directly back to `_stub_reset_idle`.

#### Worker Core Trap Vector Table (`0x0100–0x01FF`)

| Vector | Address | Handler | Behavior |
| :---: | :---: | :--- | :--- |
| `0` | `0x0100` | `_trap0_reset` | Resets `RSP`/`ASP` and enters `_loader_idle` |
| `1` | `0x0110` | `_trap1_syscall` | Saves return PC via `XCHG R0`, dispatches 3-class syscall bridge |
| `2..13` | `0x0120–0x01D0` | `_trapN_unhandled` | Reports `SYS_EXIT(0xFF00 \| vec)` to Core 0 and resets to idle |
| `14` | `0x01E0` | `_trap14_kill` | Remote kill from Core 0: resets stacks and returns to `_loader_idle` |
| `15` | `0x01F0` | `_trap15_align_fault` | Hardware Slot-1 alignment fault: reports `SYS_EXIT(0xFF0F)` and resets to idle |

### 2.4 Streaming Executable Loader

When idle, a worker core spins in `_loader_idle` polling `FIFO_IN` for `CMD_LOAD_MAGIC` (`0x4C44`, ASCII `"LD"`).

To launch a binary, Core 0 (`proc_spawn_from_file` in `os_proc.a4`):

1. Opens the `.PRG` file on FAT32 and verifies `0 < word_count <= APP_MAX_WORDS` (`0xF600`).
2. Allocates the first `PROC_FREE` worker core (`pid = 1..MAX_CORES-1`), sets state to `PROC_LOAD`, records the program name, copies command-line arguments (`proc_args`), inherits the parent's CWD cluster, and configures console ownership.
3. Selects `fifo_sel = pid` and writes the 4-word load header:
   ```
   [0x4C44, load_addr (0x0400), word_count, entry_addr (0x0400)]
   ```
4. Streams the executable **directly sector-by-sector** (`fat32_read_next_sector` → shared 256-word `sec_buf` → `fifo_out`) with zero dedicated staging RAM in Core 0.
5. Closes the file descriptor and transitions `procs[pid].state = PROC_RUN`.

The worker stub copies `word_count` words into RAM starting at `0x0400` and invokes `entry_addr` via `LINK R0, R0`. If `main()` returns normally instead of calling `sys_exit()`, the stub catches the return and emits `SYS_EXIT(R1)` automatically.

### 2.5 Three-Class Trap 1 Syscall Wire Protocol

Userland code invokes syscalls via `TRAP R0, <syscall_id>` (with `R0 = 1` selecting Trap 1). `worker_stub.asm` reads the upper byte of the `TRAP` instruction at `mem[return_pc - 1]` to obtain `syscall_id` and routes it by its upper nibble (`syscall_id & 0xF0`):

Every request begins with a 2-word transport header:
- **Word 0:** `(CPUID << 8) | syscall_id`
- **Word 1:** `payload_len` (number of following words — allows Core 0 to drain unknown syscalls cleanly without losing FIFO framing)

| Class | ID Range | App Input Regs | Worker → Core 0 Payload | Core 0 → Worker Reply | App Output Regs |
| :--- | :---: | :--- | :--- | :--- | :--- |
| **A: Scalar** | `0x00–0x0F` | `R1=arg1, R2=arg2` | `[len=2, arg1, arg2]` *(except `SYS_EXIT`: `[len=1, code]`, no reply)* | `[status, result]` | `R1=status, R2=result` |
| **B: Buffer Out** | `0x10–0x1F` | `R1=src_ptr, R2=word_len, R3=extra` | `[len=word_len+2, extra, word_len, w0..wN-1]` | `[status, result]` | `R1=status, R2=result` |
| **C: Buffer In** | `0x20–0x2F` | `R1=dst_ptr, R2=max_words, R3=extra` | `[len=2, extra, max_words]` | `[status, words_read, w0..wN-1]` | `R1=status, R2=words_read` (words written to `dst_ptr`) |

#### Standard Kernel Status Codes

| Constant | Value | Meaning |
| :--- | :---: | :--- |
| `ERR_OK` | `0x0000` | Success |
| `ERR_EMPTY` | `0x0001` | No input available (`SYS_GETC` when buffer empty or caller is not foreground) |
| `ERR_IO` | `0x0002` | I/O error, file/path not found, invalid argument, or no free slot |
| `ERR_EOF` | `0x0003` | End of file, end of directory, or end of process table |
| `ERR_UNKNOWN` | `0xFFFF` | Unrecognized syscall ID (payload drained cleanly) |

### 2.6 Process Lifecycle, Isolation & Fault Reporting

Core 0 maintains per-core state in `os_proc.a4`:

- **States:** `PROC_FREE (0)` → `PROC_LOAD (1)` → `PROC_RUN (2)` → `PROC_FREE (0)`.
- **Per-PID CWD Isolation:** Each core tracks its own FAT32 current directory cluster (`proc_cwd_hi[pid]`, `proc_cwd_lo[pid]`). Children inherit their spawning parent's CWD; calling `sys_chdir()` in a worker only updates that worker's CWD and never affects Core 0 or other workers. `fat32_rmdir()` checks `proc_is_cwd_in_use()` to prevent deleting any directory currently held as a CWD by Core 0 or any active worker.
- **Per-PID Command-Line Arguments:** Core 0 stores a 64-byte (`PROC_ARG_WORDS = 32`) NUL-terminated argument string per core in `proc_args[]`, retrieved via `sys_getargs()`.
- **Per-PID `stat` Cache:** `stat_cache[MAX_CORES]` isolates concurrent two-step `SYS_STAT_PATH` + `SYS_STAT_GET` calls across workers.
- **Clean Reclamation:** On `SYS_EXIT`, unhandled trap/fault, or `kill`/`Ctrl-C`, Core 0 automatically closes every open file/directory descriptor owned by that PID (`fat32_close_owner(pid)`), clears its console output and argument buffer, resets its CWD to root, restores the current-directory prompt if it was the foreground process, and marks the core `PROC_FREE`.

### 2.7 Console Ownership Model

Because multiple cores can execute simultaneously while sharing a single UART terminal, `mr4os` enforces an explicit **console ownership model**:

- **`fg_pid` (Keyboard Input Owner):**
  - When `fg_pid == 0`, the Core 0 interactive shell owns UART RX.
  - When `fg_pid == pid` (`1..MAX_CORES-1`), UART RX bytes are intercepted by Core 0:
    - **`Ctrl-Z` (`0x1A`):** Detaches `fg_pid` to the background (`proc_set_bg`), prints `[Backgrounded PID N]`, and returns the prompt with the current directory.
    - **`Ctrl-C` (`0x03`):** Sends Mailbox Trap 14 to kill `fg_pid`, prints `^C Killed PID N`, and returns the prompt with the current directory.
    - **All other bytes:** Enqueued into a 16-byte ring buffer (`fg_rx_buf`), which `SYS_GETC` pops exclusively for `fg_pid`. Background workers calling `SYS_GETC` immediately receive `ERR_EMPTY`.
- **`proc_con_out[pid]` (Console Output Permission):**
  - **Foreground launch (`!` / `!<app>` or `fg <pid>`):** Grants exclusive output (`proc_con_out[pid] = 1`, mutes other workers) and keyboard ownership (`fg_pid = pid`).
  - **Background launch (`run` / `&` / `&<app>` or `bg <pid>`):** Mutes output (`proc_con_out[pid] = 0`) so background jobs do not corrupt the shell prompt or another app's screen. (`SYS_PUTC` and `SYS_WRITE_CON` still succeed cleanly so the worker never blocks.)
  - **Shared output (`fg --fgoutput <pid>`):** Sets `proc_con_out[pid] = 1` *without* muting other cores and *without* taking keyboard input away from the Core 0 shell — ideal for monitoring background daemons or running multiple visible workers side by side.
  - **Child inheritance (`sys_spawn`):** A worker spawned via `SYS_SPAWN` inherits its parent's `proc_con_out` bit.

### 2.8 Storage & FAT32 Filesystem Architecture

Core 0 includes a standalone SPI SDv2/SDHC block driver (`os_sd.a4`) and FAT32 driver (`os_fat32.a4`):

- **Block Driver (`os_sd.a4`):** Initializes SDv2/SDHC cards at ~400 kHz (`CMD0`, `CMD8`, `ACMD41`, `CMD58`), switches to high-speed SPI, and supports single-block read (`CMD17`) and write (`CMD24`) with inlined byte-transfer loops for low overhead.
- **Volume Mount:** Parses MBR partition 0 (or direct superfloppy BPB), validates the `0xAA55` boot signature, and computes 32-bit `fat_lba`, `data_lba`, `root_clus`, `sec_per_clus`, and `data_clus` counts using 16-bit `(hi, lo)` pairs.
- **Naming & Paths:** Standard FAT32 **8.3** filenames (case-insensitive lookup, stored uppercase on disk). Full hierarchical path traversal supports absolute (`/BIN/LS.PRG`), relative (`SUB/FILE.TXT`), `.` (current directory), and `..` (parent directory).
- **File Descriptors:** `FD_MAX = 8` shared descriptors (`fds[0..7]`) tracking `owner_core`, cluster chain cursor, 32-bit file size/position, and parent directory LBA/offset for size synchronization on write/close.
- **Write & Metadata Operations:** Multi-cluster allocation and chain extension, `O_WRONLY` (create/truncate) and `O_APPEND` (seek to EOF), `unlink` (frees cluster chain and marks entry `0xE5`), `mkdir` (allocates cluster + seeds `.` and `..`), `rmdir` (verifies directory is empty and not any core's active CWD), `rename` (in-place or cross-directory move, updating the `..` entry when moving a directory), `copy`, `stat`, `df`, and `getcwd` (upward `..` directory walk reconstructing the canonical absolute path).

### 2.9 Multi-Core Processes vs. Cooperative Fibers

| Mechanism | Isolated RAM? | True Parallelism? | Preemptive Kill? | Best For |
| :--- | :---: | :---: | :---: | :--- |
| **Worker Cores (`!` / `&` / `sys_spawn`)** | Yes (separate 128 KB RAM) | Yes (simultaneous hardware execution) | Yes (`kill` / `Ctrl-C` via Trap 14) | Independent programs, CLI utilities, daemons, parallel compute workers |
| **Cooperative Fibers (`lib/fiber.a4`)** | Shared app RAM; private RSP/ASP slices | No (voluntary round-robin on 1 core) | N/A (same process) | In-process coroutines: TUI loops, animation + input handlers, protocol state machines |

Fibers are **purely an in-process library** — there are no OS shell commands for managing fibers. Up to `FIBER_MAX = 4` contexts (Fiber 0 = main stack, Fibers 1..3 = private 32-word RSP and 64-word ASP slices guarded by `0xDEAD` overflow canaries) switch in a few cycles via `fiber_yield()`.

---

## 3. User Experience & Shell Reference

### 3.1 Building, Booting, and Simulating

From the repository root:

```bash
# Build Core 0 kernel, worker_stub, and userland apps (LS, PS, CAT, XI, FIBERS, MUL)
make os-build

# Pack apps and README.TXT into a 16 MB FAT32 SD image (/tmp/mr4_sd.img)
make sd-img

# Boot Core 0 + 3 worker cores interactively in mr4sim.py
make sim-os

# Run the full 15-suite OS, compiler, FAT32, and multi-core regression suite
make os-test
```

On boot, Core 0 initializes the process table, mounts the SD card, changes to `/WORK` when present, and displays the current directory in the prompt:

```text
MicroRISC4 OS v0.1 (Core 0)
FAT32 mounted OK
mr4:/WORK>
```

### 3.2 Interactive Line Editor & Command History

The Core 0 shell (`os_shell.a4`) provides a non-blocking line editor with a **64-byte** (`LINE_MAX = 64`) input buffer. Its prompt displays the current directory, for example `mr4:/WORK> `:

- **Editing:** Printable ASCII (`0x20`–`0x7E`), `Backspace` (`0x08` or `0x7F`) with erase-echo (`\b \b`), and `Enter` (`\r` or `\n`).
- **4-Entry Command History:** Every non-empty submitted command is stored in a 4-slot circular history buffer (`HIST_MAX = 4`):
  - **Up Arrow (`ESC [ A`):** Recalls older commands (up to 4 entries back), cleanly erasing and redrawing the current line.
  - **Down Arrow (`ESC [ B`):** Steps forward toward newer commands, returning to an empty line past the newest entry.

### 3.3 Explicit-Only Program Launching (`!`, `run`, `&`)

`mr4os` enforces **strictly explicit program launching** — typing a bare program name like `fibers` or `LS.PRG` will **never** implicitly launch an executable; it reports `Unknown command: <name>`.

To launch a program on a worker core, you must use an explicit launcher:

| Syntax | Mode | Console Output | Keyboard Input | Shell Prompt |
| :--- | :--- | :--- | :--- | :--- |
| `! <app> [args]` or `!<app> [args]` | **Foreground** | Exclusive (`[FG]`) | Routed to app (`SYS_GETC`) | Returns when app exits, detaches (`Ctrl-Z`), or is killed (`Ctrl-C`) |
| `run <app> [args]` | **Background** | Muted (Option A) | Stays with shell | Returns immediately with `Spawned PID N (XXXX words)` |
| `& <app> [args]` or `&<app> [args]` | **Background** (alias for `run`) | Muted (Option A) | Stays with shell | Returns immediately with `Spawned PID N (XXXX words)` |

Both `!` and `&` accept an optional space between the sigil and the program name: `!cat README.TXT`, `! cat README.TXT`, `&fibers`, and `& fibers` are all valid.

### 3.4 Executable PATH Resolution

All explicit launchers (`!`, `run`, `&`) resolve `<app>` through `shell_resolve_exec_path()` in the following order (skipping directories):

1. **Exact path/name** as typed (relative to Core 0's CWD, or absolute if starting with `/`).
2. **`<app>.PRG`** in CWD (or the specified directory), if `<app>` contains no `.`.
3. **`/BIN/<app>`** (or `/BIN/<app>.PRG` if no `.`), if `<app>` contains no `/`.
4. **`/<app>`** (or `/<app>.PRG` if no `.`), if `<app>` contains no `/`.

For example, from `/WORK`, typing `!cat README.TXT` locates `/CAT.PRG` (or `/BIN/CAT.PRG`), launches it with CWD `/WORK`, and passes `"README.TXT"` via `sys_getargs()`.

### 3.5 Script Files (`do` / `@`)

`mr4os` supports sequential command scripts (no control flow) via **`do <file>`** or its shorthand alias **`@ <file>`** / **`@<file>`**:

- **Path Resolution:**
  - If `<file>` contains `/` (a full or explicit path such as `@/work/setup.do`), that exact path is opened directly.
  - Otherwise (a bare name such as `@setup` or `do setup`), the shell looks for `/BIN/<name>.DO` (or `/BIN/<name>` if `.` is present), falling back to `<name>` / `<name>.DO` in the current directory.
- **Silent Execution:** Script lines are executed silently without echoing commands or intermediate prompts — only explicit `echo` and program output appear, followed by a single prompt showing the current directory upon completion.
- **Formatting:** Both `\n` and `\r\n` line endings are supported (maximum 63 characters per line). Blank lines and lines whose first non-whitespace character is `#` are skipped.
- **Foreground Synchronization:** If a script line launches a foreground program (`!app`), the script automatically pauses until that worker exits before advancing to the next line. Background launches (`&app` / `run app`) proceed immediately.
- **Abort on `Ctrl-C`:** Pressing `Ctrl-C` kills any active foreground worker and aborts the remainder of the script cleanly, closing its file descriptor and returning to the prompt with the current directory.

### 3.6 Console Ownership & Job Control Walkthrough

```text
mr4:/WORK> &myworker
Spawned PID 1 (01A4 words)
mr4:/WORK> ps
PID  STATE  NAME
0    RUN    os_kernel
1    RUN    MYWORKER.PRG
2    FREE   -
3    FREE   -
mr4:/WORK> fg --fgoutput 1
Console output enabled for PID 1
mr4:/WORK> ps
PID  STATE  NAME
0    RUN    os_kernel
1    RUN    MYWORKER.PRG  [OUT]
2    FREE   -
3    FREE   -
mr4:/WORK> fg 1
... interactive output from PID 1; keystrokes now go to PID 1 ...
^Z
[Backgrounded PID 1]
mr4:/WORK> bg 1
Backgrounded PID 1
mr4:/WORK> kill 1
Killed PID 1
mr4:/WORK>
```

- `ps` annotates worker rows with **`[FG]`** when a worker owns both foreground input and exclusive output, or **`[OUT]`** when its console output is enabled while the shell retains keyboard input.
- Pressing **`Ctrl-Z`** while a foreground app is active detaches it cleanly to the background without terminating it.
- Pressing **`Ctrl-C`** while a foreground app is active terminates it immediately via Mailbox Trap 14 and reclaims its worker core and open file descriptors.

### 3.7 Built-In Shell Commands

| Command | Syntax | Description |
| :--- | :--- | :--- |
| `help` | `help` | Print the built-in command summary |
| `ps` | `ps` | List all core slots (`PID`, `STATE`, `NAME`, plus `[FG]` / `[OUT]` badges) |
| `!` | `! <file> [args]` / `!<file> [args]` | Launch `.PRG` executable on a worker core in the **foreground** (PATH-resolved) |
| `run` / `&` | `run <file> [args]` / `&<file> [args]` | Launch `.PRG` executable on a worker core in the **background** (muted output, PATH-resolved) |
| `do` / `@` | `do <file>` / `@<file>` | Run sequential commands silently from a script file (full path or `/BIN/<name>.DO`) |
| `fg` | `fg <pid>` | Attach running worker `pid` to foreground (exclusive output + keyboard input) |
| `fg --fgoutput` | `fg --fgoutput <pid>` | Enable UART output for `pid` without taking shell keyboard input or muting other cores |
| `bg` | `bg <pid>` | Mute UART output for `pid` (and release foreground input if attached) |
| `kill` | `kill <pid>` | Terminate worker `pid` via Trap 14, close its FDs, and free its core |
| `pwd` | `pwd` | Print Core 0's current working directory path |
| `cd` | `cd [dir]` | Change Core 0's CWD (absolute, relative, `.`, `..`; no arg returns to `/`) |
| `ls` | `ls [dir]` | List directory entries (`<DIR>` tag + 8.3 filenames) |
| `mkdir` | `mkdir <dir>` | Create a new subdirectory (supports nested paths) |
| `rmdir` | `rmdir <dir>` | Remove an empty subdirectory (fails if non-empty or in use as any core's CWD) |
| `cat` | `cat <file>` | Stream file contents to UART (normalizing `\n` to `\r\n`) |
| `stat` | `stat <path>` | Show entry name, byte size, FAT32 attribute hex, and starting cluster |
| `write` | `write <file> <text>` | Create or overwrite `<file>` with `<text>` followed by `\n` (up to 62 chars) |
| `append` | `append <file> <text>` | Append `<text>\n` to `<file>` (creating it if it does not exist) |
| `cp` | `cp <src> <dst>` | Copy file `<src>` to `<dst>` across directories or cluster chains |
| `mv` | `mv <src> <dst>` | Rename or move file/directory `<src>` to `<dst>` (updates `..` on dir move) |
| `rm` | `rm <file>` | Delete a file and free its FAT32 cluster chain (rejects directories) |
| `df` | `df` | Scan the FAT table and print used/free/total clusters and free KB |
| `echo` | `echo <text>` | Print `<text>` to UART |
| `clear` | `clear` | Clear terminal screen and home cursor (`ESC[2J ESC[H`) |

### 3.8 Worker Crash & Fault Diagnostics

If a userland program triggers a hardware alignment violation (Trap 15) or any unhandled trap vector (`2..13`), `worker_stub.asm` sends `SYS_EXIT(0xFF00 | vec)` to Core 0 and resets the worker core cleanly to idle. Core 0 prints a diagnostic banner, reclaims the core and its open FDs, and records `0xFF00 | vec` as its exit code:

```text
[FAULT] PID 1 (BADAPP.PRG): align fault (0xFF0F)
[FAULT] PID 2 (TRAPTEST.PRG): unhandled trap 7 (0xFF07)
```

---

## 4. Developer & API Reference

### 4.1 Writing & Building Userland Applications

Userland apps are standard ACT4 programs placed under `mr4src/act4/apps/` (or anywhere in your workspace) that import `sys.a4` (and optionally `term.a4` and/or `fiber.a4`).

#### Compilation & Packaging Flags

Worker applications **must** be compiled for load origin `0x0400` without the Core 0 boot preamble, and assembled with `--sparsebin` so the output `.prg` binary starts directly at word `0x0400`:

```bash
# 1. Compile ACT4 -> MicroRISC4 assembly (origin 0x0400, no boot preamble)
bin/compile mr4src/act4/apps/myapp.a4 -o build/os/myapp.asm \
    -I mr4src/act4/os -I lib --org 0x0400 --nopreamble

# 2. Assemble -> raw loadable .prg starting at 0x0400
python3 tools/mr4asm.py -I lib --sparsebin build/os/myapp.asm \
    -o build/os/myapp.prg -l build/os/myapp.lst

# 3. Copy onto SD image root (8.3 uppercase filename) and rebuild FAT32 image
cp build/os/myapp.prg build/sd_root/MYAPP.PRG
python3 tools/mksdimage.py build/sd_root -o /tmp/mr4_sd.img --size-mb 16 --spc 1
```

#### ACT4 Packed-String Convention

Because MicroRISC4 is word-addressed (16 bits per word), strings are **packed 2 bytes per 16-bit word** in little-endian byte order (low byte = even index, high byte = odd index), NUL-terminated. Always access individual characters via ACT4's built-in `getbyte(buf, byte_idx)` and `setbyte(buf, byte_idx, ch)` intrinsics rather than indexing `buf[i]` directly.

---

#### MuL scripting interpreter

For a complete tutorial and command/language reference, see the
[MuL Tutorial and Reference](mul_tutorial_and_reference.md). MuL is pronounced
“Mule”.

`MUL.PRG` is a small Picol-inspired interpreter with structured `if`/`else` and
`while` blocks. Unlike Picol, MuL closes blocks with `end`. Picol is credited
in the [MuL source header](../mr4src/act4/apps/mul.a4).
Build and package it with the other userland apps:

```text
! MUL.PRG              # Start the interactive prompt
! MUL.PRG HELLO.MUL    # Run a script from the current directory
```

Each command occupies one line; quotes and braces group arguments, and `$name`
expands a variable. Variables are set with `set name value` and incremented
with `incr name [amount]`. `puts` prints text, and `expr` evaluates unsigned
16-bit integer expressions using
parentheses, arithmetic, comparisons, `&&`, and `||`. Structured blocks use
`if {expression}`, optional `else`, `while {expression}`, and `end`:

```text
set n 0
while {$n < 3}
puts $n
incr n
end
```

The OS commands are `pwd`, `cd`, `ls`, `cat`, `write`, `append`, `mkdir`,
`rmdir`, `rm`, `mv`, `stat`, `ps`, and `run`. `gets name` reads a line from the
foreground console. `help` lists commands and `exit` ends MuL. File writes
accept up to 126 bytes of text per command and append a newline.

This initial version uses bounded storage: scripts are limited to 4094 bytes
and 128 lines, lines to 127 bytes, and the variable table to 16 entries (with
names limited to 23 bytes).
Blocks may nest 16 levels; loops may nest 8 levels.
User-defined procedures and nested command substitution are not implemented.

### 4.2 Kernel Syscall Table (`0x01`–`0x25`)

| ID | Name | Class | Input Regs (`TRAP R0, id`) | Return Regs | Description |
| :---: | :--- | :---: | :--- | :--- | :--- |
| `0x01` | `SYS_EXIT` | A | `R1=exit_code` | *(does not return)* | Terminate process, reclaim FDs/core; `0xFF00..0xFF0F` reserved for faults |
| `0x02` | `SYS_PUTC` | A | `R1=ch` | `R1=ERR_OK, R2=0` | Write single ASCII byte to UART (muted if `proc_con_out[pid] == 0`) |
| `0x03` | `SYS_GETC` | A | — | `R1=ERR_OK/ERR_EMPTY, R2=ch` | Non-blocking UART key pop (only succeeds when `pid == fg_pid`) |
| `0x04` | `SYS_KILL` | A | `R1=target_pid` | `R1=0/1/2, R2=0` | Send Trap 14 kill to `target_pid` (`1`=invalid PID, `2`=not running) |
| `0x05` | `SYS_CLOSE` | A | `R1=fd` | `R1=ERR_OK, R2=0` | Close open file or directory descriptor `fd` |
| `0x10` | `SYS_WRITE_CON` | B | `R1=str, R2=wlen, R3=0` | `R1=ERR_OK, R2=wlen` | Write NUL-terminated packed string to UART (muted if background) |
| `0x11` | `SYS_SPAWN` | B | `R1=cmd, R2=wlen, R3=0` | `R1=ERR_OK/ERR_IO, R2=child_pid` | Spawn `"PATH [ARGS]"` on a free worker; inherits CWD & `proc_con_out` |
| `0x12` | `SYS_OPEN` | B | `R1=path, R2=wlen, R3=mode` | `R1=ERR_OK/ERR_IO, R2=fd` | Open file (`mode`: `0=O_RDONLY`, `1=O_WRONLY`, `2=O_APPEND`) |
| `0x13` | `SYS_WRITE` | B | `R1=buf, R2=wlen, R3=(blen<<4)\|fd` | `R1=ERR_OK/ERR_IO, R2=bytes_written` | Write up to 128 bytes (`64` words) per call to open writable `fd` |
| `0x14` | `SYS_OPENDIR` | B | `R1=path, R2=wlen, R3=0` | `R1=ERR_OK/ERR_IO, R2=dir_fd` | Open directory for iteration via `SYS_READDIR` |
| `0x15` | `SYS_UNLINK` | B | `R1=path, R2=wlen, R3=0` | `R1=ERR_OK/ERR_IO, R2=detail` | Delete file and free its cluster chain |
| `0x16` | `SYS_MKDIR` | B | `R1=path, R2=wlen, R3=0` | `R1=ERR_OK/ERR_IO, R2=detail` | Create subdirectory |
| `0x17` | `SYS_RMDIR` | B | `R1=path, R2=wlen, R3=0` | `R1=ERR_OK/ERR_IO, R2=detail` | Remove empty subdirectory (not in use as any core's CWD) |
| `0x18` | `SYS_CHDIR` | B | `R1=path, R2=wlen, R3=0` | `R1=ERR_OK/ERR_IO, R2=detail` | Change calling worker's private CWD |
| `0x19` | `SYS_RENAME` | B | `R1="SRC DST", R2=wlen, R3=0` | `R1=ERR_OK/ERR_IO, R2=detail` | Rename or move file/directory (`"SRC DST"` space-separated pair) |
| `0x1A` | `SYS_STAT_PATH` | B | `R1=path, R2=wlen, R3=0` | `R1=ERR_OK/ERR_IO, R2=size_lo` | Populate caller's per-core `stat_cache[pid]` (step 1 of `sys_stat`) |
| `0x20` | `SYS_READ` | C | `R1=dst, R2=max_w, R3=fd` | `R1=ERR_OK/ERR_EOF, R2=words_read` | Read up to `min(max_w, 64)` words (128 bytes) from `fd` |
| `0x21` | `SYS_READDIR` | C | `R1=ent, R2=11, R3=dir_fd` | `R1=ERR_OK/ERR_EOF, R2=11` | Read next 11-word `DirEntry` from `dir_fd` |
| `0x22` | `SYS_PS` | C | `R1=proc, R2=10, R3=pid_idx` | `R1=ERR_OK/ERR_EOF, R2=10` | Read 10-word `ProcEntry` for core slot `pid_idx` |
| `0x23` | `SYS_GETARGS` | C | `R1=dst, R2=max_w, R3=0` | `R1=ERR_OK/ERR_IO, R2=words_read` | Copy calling process's NUL-terminated command-line args (max 32 words) |
| `0x24` | `SYS_STAT_GET` | C | `R1=ent, R2=11, R3=0` | `R1=ERR_OK/ERR_IO, R2=11` | Fetch cached 11-word `DirEntry` from `SYS_STAT_PATH` (step 2 of `sys_stat`) |
| `0x25` | `SYS_GETCWD` | C | `R1=dst, R2=max_w, R3=0` | `R1=ERR_OK/ERR_IO, R2=words_read` | Reconstruct and copy caller's canonical absolute CWD string |

---

### 4.3 `lib/sys.a4` — System Call Client Library

Include at the top of every userland application:

```c
import "sys.a4";
```

#### Constants & Data Types

```c
const u16 O_RDONLY = 0;   // Open existing file for reading
const u16 O_WRONLY = 1;   // Create or truncate file for writing
const u16 O_APPEND = 2;   // Open for appending at EOF (creates if missing)

type DirEntry {           // 11 words total
    u16 attr;             // FAT32 attributes (0x0010 = directory, 0x0020 = archive)
    u16 size_lo;          // File size low 16 bits
    u16 size_hi;          // File size high 16 bits
    u16 name[8];          // NUL-terminated 8.3 name ("FILENAME.EXT")
};

type ProcEntry {          // 10 words total
    u16 state;            // 0 = FREE, 1 = LOAD, 2 = RUN
    u16 exit_code;        // Last exit code (0xFFFF = killed, 0xFF00..0xFF0F = fault)
    u16 name[8];          // NUL-terminated process name (up to 15 chars)
};
```

#### Functions

All functions returning `u16` return `0` (`ERR_OK`) on success and non-zero (`ERR_EMPTY`, `ERR_IO`, `ERR_EOF`) on error/empty/EOF.

| Signature | Description |
| :--- | :--- |
| `void sys_exit(u16 code)` | Exit the application with status `code` (does not return). |
| `u16 sys_putc(u16 ch)` | Write a single ASCII character to the console. |
| `u16 sys_puts(u16 *s)` | Write a NUL-terminated packed string to the console (one atomic syscall). |
| `u16 sys_getc(u16 *out_ch)` | Non-blocking keyboard read. Stores byte in `*out_ch` and returns `0` if available, or `ERR_EMPTY` (`1`) if no key is queued or caller is not foreground. |
| `u16 sys_spawn(u16 *cmdline, u16 *out_pid)` | Spawn `"PATH [ARGS]"` on a free worker core; writes child PID to `*out_pid`. |
| `u16 sys_ps(u16 idx, ProcEntry *out_proc)` | Populate `out_proc` for core slot `idx` (`0..MAX_CORES-1`); returns `ERR_EOF` past last core. |
| `u16 sys_getargs(u16 *dst_buf, u16 max_words)` | Copy this process's command-line argument string (up to `max_words` words, max 32 words = 64 bytes) into `dst_buf`. |
| `u16 sys_open(u16 *path, u16 mode, u16 *out_fd)` | Open `path` with `O_RDONLY`, `O_WRONLY`, or `O_APPEND`; stores descriptor in `*out_fd`. |
| `u16 sys_close(u16 fd)` | Close a file or directory descriptor. |
| `u16 sys_read(u16 fd, u16 *dst_buf, u16 max_words, u16 *out_words)` | Read up to `min(max_words, 64)` words from `fd`; stores words read in `*out_words`. Returns `ERR_EOF` (`3`) at end of file. |
| `u16 sys_write(u16 fd, u16 *src_buf, u16 byte_len, u16 *out_written)` | Write up to 128 bytes (`byte_len` clamped to 128) from `src_buf` to `fd`; stores bytes written in `*out_written`. |
| `u16 sys_opendir(u16 *path, u16 *out_fd)` | Open directory `path` (e.g. `"."`, `"/"`, `"/BIN"`) for iteration; stores descriptor in `*out_fd`. |
| `u16 sys_readdir(u16 dir_fd, DirEntry *ent)` | Read next entry from `dir_fd` into `ent`; returns `ERR_EOF` (`3`) when done. |
| `u16 sys_stat(u16 *path, DirEntry *out_ent)` | Query metadata for `path` (performs `SYS_STAT_PATH` + `SYS_STAT_GET` atomically per core). |
| `u16 sys_unlink(u16 *path)` | Delete file `path`. |
| `u16 sys_mkdir(u16 *path)` | Create directory `path`. |
| `u16 sys_rmdir(u16 *path)` | Remove empty directory `path`. |
| `u16 sys_rename(u16 *src, u16 *dst)` | Rename or move `src` to `dst` (pack buffer limit: 30 chars for `src`, 63 combined). |
| `u16 sys_chdir(u16 *path)` | Change this process's private working directory. |
| `u16 sys_getcwd(u16 *dst_buf, u16 max_words)` | Copy this process's canonical absolute working directory path into `dst_buf`. |
| `u16 str_word_len(u16 *s)` | Utility: returns packed word count (including NUL terminator) of string `s`. |

> **Note on `SYS_KILL` (`0x04`):** Core 0 implements `SYS_KILL` (`R1 = target_pid`), and `lib/sys.a4` exports `const u16 SYS_KILL = 0x04;`. Applications needing programmatic process termination can invoke `TRAP R0, 0x04` with `R0 = 1, R1 = target_pid`.

---

### 4.4 `lib/term.a4` — ANSI Terminal & Keyboard Library

`lib/term.a4` builds on `lib/sys.a4` to provide ANSI/VT100 screen drawing, 16-color SGR styling, cursor positioning, and a stateful escape-sequence keyboard decoder.

```c
import "sys.a4";
import "term.a4";
```

#### Color Constants

| Normal (`0–7`) | Value | Bright (`8–15`) | Value |
| :--- | :---: | :--- | :---: |
| `TERM_BLACK` | `0` | `TERM_BRIGHT_BLACK` | `8` |
| `TERM_RED` | `1` | `TERM_BRIGHT_RED` | `9` |
| `TERM_GREEN` | `2` | `TERM_BRIGHT_GREEN` | `10` |
| `TERM_YELLOW` | `3` | `TERM_BRIGHT_YELLOW` | `11` |
| `TERM_BLUE` | `4` | `TERM_BRIGHT_BLUE` | `12` |
| `TERM_MAGENTA` | `5` | `TERM_BRIGHT_MAGENTA` | `13` |
| `TERM_CYAN` | `6` | `TERM_BRIGHT_CYAN` | `14` |
| `TERM_WHITE` | `7` | `TERM_BRIGHT_WHITE` | `15` |

#### Screen, Cursor, Color & Output Functions

Each escape sequence is assembled into an internal 32-byte buffer (`TERM_OUT_WORDS = 16`) and flushed in a single `sys_puts()` call to minimize IPC overhead.

| Function | ANSI Sequence / Behavior |
| :--- | :--- |
| `void term_clear(void)` | Clear entire screen and move cursor to `(1, 1)` (`ESC[2J ESC[H`) |
| `void term_clear_line(void)` | Erase entire current line (`ESC[2K`) |
| `void term_clear_eol(void)` | Erase from cursor to end of line (`ESC[K`) |
| `void term_goto(u16 row, u16 col)` | Move cursor to 1-based `(row, col)` (`ESC[row;colH`) |
| `void term_cursor_up(u16 n)` | Move cursor up `n` rows (`ESC[nA`; no-op if `n == 0`) |
| `void term_cursor_down(u16 n)` | Move cursor down `n` rows (`ESC[nB`) |
| `void term_cursor_right(u16 n)` | Move cursor right `n` columns (`ESC[nC`) |
| `void term_cursor_left(u16 n)` | Move cursor left `n` columns (`ESC[nD`) |
| `void term_cursor_hide(void)` | Hide hardware/terminal cursor (`ESC[?25l`) |
| `void term_cursor_show(void)` | Show terminal cursor (`ESC[?25h`) |
| `void term_fg(u16 color)` | Set foreground color (`0–7` → `30–37`, `8–15` → `90–97`) |
| `void term_bg(u16 color)` | Set background color (`0–7` → `40–47`, `8–15` → `100–107`) |
| `void term_color(u16 fg, u16 bg)` | Set both foreground and background in one sequence (`ESC[fg;bgm`) |
| `void term_bold(void)` | Enable bold/bright attribute (`ESC[1m`) |
| `void term_dim(void)` | Enable dim attribute (`ESC[2m`) |
| `void term_underline(void)` | Enable underline (`ESC[4m`) |
| `void term_reverse(void)` | Enable reverse video (`ESC[7m`) |
| `void term_reset(void)` | Reset all colors and text attributes (`ESC[0m`) |
| `void term_putc(u16 ch)` | Write single ASCII character |
| `void term_puts(u16 *s)` | Write packed string |
| `void term_puts_at(u16 row, u16 col, u16 *s)` | Position cursor at `(row, col)` and write packed string |
| `void term_put_dec(u16 v)` | Print unsigned 16-bit integer in decimal (`0`–`65535`) |
| `void term_put_hex(u16 w)` | Print 16-bit word as 4 uppercase hex digits (`0000`–`FFFF`) |

#### Keyboard Input & Escape-Sequence Decoder

| Function | Behavior |
| :--- | :--- |
| `u16 term_poll_key(void)` | **Non-blocking:** polls `sys_getc()` and advances the VT100/ANSI state machine. Returns `KEY_NONE` (`0`) when no complete key is ready, ASCII (`1..255`) for printable/control keys, or `KEY_*` (`0x0100+`) for special keys. |
| `u16 term_get_key(void)` | **Blocking:** spins on `term_poll_key()` until a complete key is decoded and returns it. |

#### Decoded Keycodes

| Constant | Value | Decoded Input Sequences |
| :--- | :---: | :--- |
| `KEY_NONE` | `0x0000` | No key ready (non-blocking `term_poll_key`) |
| `KEY_BACKSPACE` | `0x0008` | `0x08` (`BS`) or `0x7F` (`DEL`) |
| `KEY_TAB` | `0x0009` | `0x09` |
| `KEY_ENTER` | `0x000D` | `0x0D` (`\r`) or `0x0A` (`\n`) |
| `KEY_ESC` | `0x001B` | Standalone `ESC` (emitted after `TERM_ESC_IDLE_POLLS = 8` empty polls, or immediately when followed by a non-`[`/`O` key, with the following key replayed on the next call) |
| `KEY_UP` | `0x0101` | `ESC [ A` (also with modifier params like `ESC [ 1 ; 2 A`), `ESC O A` |
| `KEY_DOWN` | `0x0102` | `ESC [ B`, `ESC O B` |
| `KEY_RIGHT` | `0x0103` | `ESC [ C`, `ESC O C` |
| `KEY_LEFT` | `0x0104` | `ESC [ D`, `ESC O D` |
| `KEY_HOME` | `0x0105` | `ESC [ H`, `ESC O H`, `ESC [ 1 ~`, `ESC [ 7 ~` |
| `KEY_END` | `0x0106` | `ESC [ F`, `ESC O F`, `ESC [ 4 ~`, `ESC [ 8 ~` |
| `KEY_INSERT` | `0x0107` | `ESC [ 2 ~` |
| `KEY_DELETE` | `0x0108` | `ESC [ 3 ~` |
| `KEY_PGUP` | `0x0109` | `ESC [ 5 ~` |
| `KEY_PGDN` | `0x010A` | `ESC [ 6 ~` |
| `KEY_F1` | `0x0111` | `ESC O P`, `ESC [ 11 ~` |
| `KEY_F2` | `0x0112` | `ESC O Q`, `ESC [ 12 ~` |
| `KEY_F3` | `0x0113` | `ESC O R`, `ESC [ 13 ~` |
| `KEY_F4` | `0x0114` | `ESC O S`, `ESC [ 14 ~` |

> **Remember:** Keyboard input is only delivered to the active foreground worker (`fg_pid`). Launch interactive TUI apps with `!myapp` (or attach them with `fg <pid>`). Always call `term_cursor_show()` and `term_reset()` before `sys_exit(0)` so the shell returns cleanly.

---

### 4.5 `lib/fiber.a4` — Cooperative Fiber Library

`lib/fiber.a4` implements lightweight voluntary round-robin coroutines within a single userland process by swapping hardware `RSP` (`0x0004`) and `ASP` (`0x0005`).

```c
import "sys.a4";
import "fiber.a4";
```

#### Configuration Constants

| Constant | Default | Meaning |
| :--- | :---: | :--- |
| `FIBER_MAX` | `4` | Total fibers including Fiber 0 (main context) |
| `FIBER_SLOTS` | `FIBER_MAX - 1` (`3`) | Spawnable worker fiber slots (`1..FIBER_SLOTS`) |
| `FIBER_RSP_WORDS` | `32` | Return-stack words allocated per spawned fiber |
| `FIBER_ASP_WORDS` | `64` | Argument/data-stack words allocated per spawned fiber |
| `FIBER_CANARY` | `0xDEAD` | Sentinel value written at the bottom of each fiber's RSP and ASP |

#### Functions

| Signature | Description |
| :--- | :--- |
| `void fiber_init(void)` | Initialize the fiber table, mark Fiber 0 as `FIBER_READY`, reset slots `1..FIBER_SLOTS` to `FIBER_FREE`, and plant `0xDEAD` stack canaries. Call once before spawning. |
| `u16 fiber_spawn(u16 entry_addr)` | Allocate a free fiber slot to execute function `entry_addr` (ACT4 functions decay to their address automatically). Returns fiber ID (`1..FIBER_SLOTS`) on success, or `0` if full. |
| `void fiber_yield(void)` | Save the current fiber's `RSP`/`ASP` and resume the next `FIBER_READY` fiber round-robin. When a spawned fiber returns from its entry function, it automatically marks itself `FIBER_FREE` and yields to the next ready fiber. |
| `u16 fiber_active_count(void)` | Return the number of `FIBER_READY` fibers (including Fiber 0). Typically used by `main()` as `while (fiber_active_count() > 1) { fiber_yield(); }`. |
| `u16 fiber_check_canaries(void)` | Verify every spawned fiber's RSP and ASP bottom word still equals `0xDEAD`. Returns `0` if all stacks are intact, or the failing fiber ID (`1..FIBER_SLOTS`) on stack overflow. |

#### Important ACT4 Static-Local Rule for Fibers

ACT4 compiles local variables inside a function to **static memory addresses** unique to that function (not stack-frame slots). Therefore:
- **Do** give each concurrent fiber its own distinct top-level function (e.g., `fiber_a`, `fiber_b`, `fiber_c`) so their locals live at separate addresses.
- **Do not** call `fiber_yield()` inside a shared helper function invoked concurrently by two fibers, or spawn two simultaneous instances of the exact same function if it relies on local variables across yields (use per-fiber global arrays indexed by fiber ID instead).

---

### 4.6 Complete Userland Examples

#### Example 1: Reading Command-Line Arguments & Files (`cat`-style)

```c
import "sys.a4";

u16 arg_buf[32];
u16 read_buf[65];

void main(void) {
    u16 fd = 0;
    u16 nwords = 0;
    u16 *target = arg_buf;

    arg_buf[0] = 0;
    sys_getargs(arg_buf, 32);
    if (getbyte(arg_buf, 0) == 0) {
        target = "README.TXT";
    }

    if (sys_open(target, O_RDONLY, &fd) != 0) {
        sys_puts("Cannot open ");
        sys_puts(target);
        sys_puts("\r\n");
        sys_exit(1);
    }

    while (sys_read(fd, read_buf, 64, &nwords) == 0) {
        read_buf[nwords] = 0;
        sys_puts(read_buf);
    }

    sys_close(fd);
    sys_exit(0);
}
```

#### Example 2: Interactive Terminal App (`lib/term.a4`)

```c
import "sys.a4";
import "term.a4";

void main(void) {
    u16 row = 5;
    u16 col = 10;
    u16 key = 0;

    term_clear();
    term_cursor_hide();
    term_color(TERM_BRIGHT_CYAN, TERM_BLUE);
    term_puts_at(1, 1, " MicroRISC4 Terminal Demo (Arrows=Move, ESC/q=Quit) ");
    term_reset();

    while (true) {
        term_color(TERM_BRIGHT_GREEN, TERM_BLACK);
        term_puts_at(row, col, "@");
        term_reset();

        key = term_get_key();
        term_puts_at(row, col, " ");

        if (key == KEY_ESC || key == 113) {        // ESC or 'q'
            break;
        } else if (key == KEY_UP    && row > 2)  { row--; }
          else if (key == KEY_DOWN  && row < 20) { row++; }
          else if (key == KEY_LEFT  && col > 1)  { col--; }
          else if (key == KEY_RIGHT && col < 70) { col++; }
    }

    term_clear();
    term_cursor_show();
    term_reset();
    sys_exit(0);
}
```

#### Example 3: In-Process Cooperative Fibers (`lib/fiber.a4`)

```c
import "sys.a4";
import "fiber.a4";

void worker_a(void) {
    u16 i = 0;
    while (i < 3) {
        sys_puts("A ");
        fiber_yield();
        i++;
    }
}

void worker_b(void) {
    u16 i = 0;
    while (i < 3) {
        sys_puts("B ");
        fiber_yield();
        i++;
    }
}

void main(void) {
    fiber_init();
    fiber_spawn(worker_a);
    fiber_spawn(worker_b);

    while (fiber_active_count() > 1) {
        fiber_yield();
    }

    if (fiber_check_canaries() == 0) {
        sys_puts("\r\nDone (canaries OK)\r\n");
    }
    sys_exit(0);
}
```

---

## Related Documentation

- [MicroRISC4 ISA Specification](microrisc4_spec.md)
- [MicroRISC4 Memory Map & Software Conventions](microrisc4_memory_map_software_conventions.md)
- [MicroRISC4 Multi-Core Subsystem Configuration Guide](microrisc4_multi_core_subsystem_configuration_guide.md)
- [ACT4 Language & Compiler Reference Manual](act4_language_compiler_reference_manual.md)
- [MicroRISC4 Assembler Reference Manual](microrisc4_assembler_reference_manual.md)
- [MicroRISC4 OS Development Roadmap](RoadmapOS.md)

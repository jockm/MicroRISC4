# Getting Started with MicroRISC4

This guide covers installing the tools MicroRISC4 needs, cloning the repository,
building and testing the software and ROHD hardware models, programming the
ULX3S-85F FPGA, and running the ASIC RTL-to-GDS flow with OpenROAD via Docker.
Run all commands below from the repository root unless a step says otherwise.

## Prerequisites

- **Git** to clone the repository.
- **Python 3.10 or later** for the ACT4 compiler (`tools/act4c.py`), macro
  assembler (`tools/mr4asm.py`), instruction-level simulator (`tools/mr4sim.py`),
  FAT32 SD image builder (`tools/mksdimage.py`), and OS regression suite
  (`tools/test_os.py`).
- **Dart SDK 3.x** for the Intel ROHD hardware model (`hdl/rohd/`), unit and
  firmware co-simulation tests, and SystemVerilog generators (`generate.dart`,
  `generate_asic.dart`).
- **GNU Make** and **Bash** (`make` and `bash`; on Windows, provided via Git
  Bash + GnuWin32 and launched automatically by `mdev.cmd`).
- **OSS CAD Suite** (optional, required for FPGA synthesis, Verilog simulation,
  and ASIC preflight): provides `yosys`, `nextpnr-ecp5`, `ecppack`,
  `openFPGALoader`, `iverilog`, and `verilator`. Download the build for your
  platform from the
  [official OSS CAD Suite releases](https://github.com/YosysHQ/oss-cad-suite/releases).
- **Docker** (optional, required for the OpenROAD ASIC RTL-to-GDS flow,
  `make asic-flow`): runs the official `openroad/orfs` container image
  identically across Windows, macOS, and Linux with no native OpenROAD compile
  needed.

## Installing dependencies

### macOS

Install the Xcode Command Line Tools (provides `git`, `make`, and `python3`):

```sh
xcode-select --install
```

[Install Homebrew](https://brew.sh/) if needed, then install Dart (and Python
3.12 if your macOS `python3` is older than 3.10):

```sh
brew tap dart-lang/dart
brew install dart
```

For **OSS CAD Suite**, download the macOS (`arm64` or `x64`) archive from the
releases page, extract it to `/Users/<you>/oss-cad-suite`, and add its `bin`
directory to your `PATH` (in `~/.zshrc`):

```sh
export PATH="$HOME/oss-cad-suite/bin:$PATH"
```

### Windows

Install the core tools with `winget` from PowerShell or a Command Prompt:

```bat
winget install -e --id Git.Git
winget install -e --id GnuWin32.Make
winget install -e --id Google.DartSDK
winget install -e --id Python.Python.3.12
```

Git for Windows provides Git Bash, which the `Makefile` and `mbuild` driver
use. Open a new terminal after installing so it sees the updated `PATH`.

Windows may also run `python.exe` and `python3.exe` as shortcuts that open the
Microsoft Store instead of Python. Turn them off in **Settings → Apps →
Advanced app settings → App execution aliases** by switching off the
**App Installer** entries for `python.exe` and `python3.exe`.

For **OSS CAD Suite**, download the Windows build from the releases page and
extract it to `%USERPROFILE%\oss-cad-suite`, so that its tools live in
`%USERPROFILE%\oss-cad-suite\bin`.

#### The Windows development shell: `mdev.cmd`

On Windows, run every command in this guide from the shell opened by `mdev.cmd`
at the repository root. Double-click `mdev.cmd` or run it from a Command Prompt:

```bat
mdev.cmd
```

`mdev.cmd` locates the installed tools, puts OSS CAD Suite ahead of Git Bash's
`/mingw64/bin` (so `yosys` and `nextpnr-ecp5` load their own DLLs), and opens
an interactive Git Bash shell in the repository root:

| Tool | Where `mdev.cmd` looks |
|------|------------------------|
| Git Bash | `C:\Program Files\Git\bin\bash.exe` (required) |
| GnuWin32 (`make`) | `C:\Program Files (x86)\GnuWin32\bin` (required) |
| Dart SDK | WinGet `Google.DartSDK` package, then `PATH` (required) |
| OSS CAD Suite | `%USERPROFILE%\oss-cad-suite\bin` and `\lib` (used if present) |
| Python / Git / Docker | Standard Windows `PATH` |

*(Note: `mdev.cmd` also checks for LLVM/Node.js if you share a single Windows
dev environment with the sister Particle project.)*

### Linux

These steps are for Debian 12+ and Ubuntu 24.04+ with `apt`:

```sh
sudo apt update
sudo apt install -y git make python3 curl gpg apt-transport-https
```

Install the Dart SDK from Google's `apt` repository:

```sh
wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub \
  | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg
echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' \
  | sudo tee /etc/apt/sources.list.d/dart_stable.list
sudo apt update
sudo apt install -y dart
```

*(On ARM64 Linux, use `arch=arm64` instead of `arch=amd64`.)*

For **OSS CAD Suite**, download the Linux archive from the releases page,
extract it to `~/oss-cad-suite`, and add `export PATH="$HOME/oss-cad-suite/bin:$PATH"`
to `~/.bashrc`.

## Installing Docker for the ASIC flow (OpenROAD-flow-scripts)

The OpenROAD ASIC RTL-to-GDS flow (`make asic-flow`) runs inside the official
`openroad/orfs` Docker image. That image already bundles OpenROAD, Yosys,
OpenSTA, KLayout, and public reference PDKs (`nangate45`, `asap7`, `sky130hd`,
`ihp-sg13g2`), so **all projects on your machine share one image** and you do
not need to clone or compile OpenROAD natively.

### Windows (Docker Desktop + WSL2)

1. Enable **WSL2** if not already enabled (run PowerShell as Administrator,
   then reboot if prompted):

   ```powershell
   wsl --install --no-distribution
   ```

2. Install **Docker Desktop** via `winget`:

   ```powershell
   winget install -e --id Docker.DockerDesktop
   ```

3. Launch **Docker Desktop** from the Start menu, accept the prompts, and wait
   until the whale icon in the system tray shows **Engine running** (ensure
   **Settings → General → Use the WSL 2 based engine** is checked).
4. Open a fresh `mdev.cmd` shell and verify Docker works, then pull the shared
   OpenROAD-flow-scripts image once (~2–3 GB download, reused by all projects):

   ```sh
   docker --version
   docker run --rm hello-world
   docker pull openroad/orfs:latest
   ```

   > **Windows OpenSSH note:** If you connect to your Windows machine over SSH
   > and `docker pull` / `docker run` fails with
   > `A specified logon session does not exist`, Windows Credential Manager is
   > unavailable in non-interactive SSH sessions. Disable the Windows credential
   > helper for Docker Hub in `%USERPROFILE%\.docker\config.json` (public images
   > pull anonymously):
   >
   > ```bat
   > python -c "import json, os; p=os.path.expanduser('~/.docker/config.json'); d=json.load(open(p)); d.pop('credsStore', None); d['credHelpers']={'https://index.docker.io/v1/': ''}; json.dump(d, open(p,'w'), indent=2)"
   > ```

### macOS

Choose either **Docker Desktop** (GUI) or **Colima** (lightweight open-source
CLI-only runtime via Homebrew):

* **Option A — Docker Desktop:**
  ```sh
  brew install --cask docker
  # Launch Docker.app once from Applications, then:
  docker pull openroad/orfs:latest
  ```
* **Option B — Lightweight CLI (`colima` + `docker`):**
  ```sh
  brew install colima docker
  colima start --cpu 4 --memory 8
  docker pull openroad/orfs:latest
  ```

### Linux (Ubuntu / Debian)

Install Docker Engine following the official Debian/Ubuntu packages and add
your user to the `docker` group:

```sh
sudo apt update
sudo apt install -y docker.io
sudo usermod -aG docker "$USER"
# Log out and back in (or run `newgrp docker`), then:
docker pull openroad/orfs:latest
```

### Checking all installed tools

From your shell (on Windows, inside `mdev.cmd`):

```sh
git --version
python3 --version        # or `python --version` on Windows
dart --version
make --version
yosys -V                 # optional: OSS CAD Suite
nextpnr-ecp5 --version   # optional: OSS CAD Suite
docker --version         # optional: ASIC ORFS flow
```

## Get the source

```sh
git clone https://github.com/jockm/MicroRISC4.git
cd MicroRISC4
```

On Windows, launch `mdev.cmd` in the `MicroRISC4` folder and use that shell for
all commands below.

Optional: install the repository's pre-commit git hook (keeps macOS `._*`
AppleDouble metadata files out of commits on exFAT drives):

```sh
make install-hooks
```

## Build software and run tests

### 1. Fetch Dart dependencies and run ROHD hardware tests

```sh
make setup
make test-rohd
```

`make test-rohd` runs the full Intel ROHD hardware test suite (`CpuCore` 4-stage
pipeline hazards, 1-DSP `MathAccelerator`, `ICache`/`DCache` + JEDEC SDRAM,
Lean Ring NoC, `MemoryFactory` + `AsicBootRom`, `AsicTop`, and end-to-end
`act4c.py --hw-math` co-simulation).

### 2. Build MR4OS, userland apps, and run the OS regression suite

```sh
make apps
make os-build
make os-test
```

`make os-test` builds the FAT32 SD image (`build/sd_root` → `/tmp/mr4_sd.img`)
and runs the focused ACT4 host-compiler fixtures followed by the 20-scenario
ACT4 compiler, trap ISR, FAT32 filesystem, multi-core Lean Ring IPC, cooperative
fiber, shell script, and `--hw-math` codegen suite using `tools/mr4sim.py`.

### 3. Build and simulate individual programs

Use `mbuild` to compile ACT4 (`.a4`) or assemble `.asm` programs, or run them
in the interactive simulator/debugger:

```sh
./mbuild examples/hello.a4
make sim SIM_PROGRAM=build/monitor.bin
make debug SIM_PROGRAM=build/monitor.bin
```

To compile an ACT4 program targeting the optional 1-DSP Hardware Math
Accelerator (automatically emits a startup `CPU_CAPS` capability guard):

```sh
python3 tools/act4c.py my_app.a4 -o build/my_app.asm -I lib --hw-math
python3 tools/mr4asm.py -I lib build/my_app.asm -o build/my_app.bin
python3 tools/mr4sim.py --enable-math build/my_app.bin
```

## ULX3S-85F FPGA flow (OSS CAD Suite)

### Build and boot live 4-core MR4OS on ULX3S-85F

1. Build the 4-core MR4OS bitstream (`os_main.a4` on Core 0 + `worker_stub.asm`
   on Workers 1–3 + 32 MB SDRAM I/D caches + Lean Ring NoC + microSD SPI +
   4× 1-DSP Math Accelerators at 72 MHz):

   ```sh
   make os-build
   make ulx3s-mr4os
   make ulx3s-timing
   ```

2. Copy the contents of `build/sd_root/` (`BIN/` with `LS.PRG`, `CAT.PRG`,
   `PS.PRG`, `MUL.PRG`, `XI.PRG`, `FIBERS.PRG`, `ASM.PRG`, plus
   `WORK/HELLO.ASM` and `README.TXT`)
   to the root of a FAT32-formatted microSD card (standard MBR partition 1) and
   insert it into the ULX3S onboard microSD slot.
3. Load the bitstream into ULX3S SRAM and open the 3 Mbaud serial terminal:

   ```sh
   make ulx3s-prog
   make ulx3s-term
   ```

   Press **PWR** on the board to see `MiniRISC4 OS v0.1 (Core 0)`,
   `FAT32 mounted OK`, and the `mr4> ` prompt (`! ls`, `! cat README.TXT`,
   `! ps`, `&fibers`, `! mul`).

   From `/WORK`, assemble and run the included example:

   ```text
   ! ASM.PRG HELLO.ASM HELLO.PRG
   ! HELLO.PRG
   ```

### Custom ULX3S configurations

Any single- or multi-core configuration can be built with `make ulx3s-bit`:

```sh
make ulx3s-bit \
  ULX3S_PROGRAM=mr4src/asm/monitor.asm \
  ULX3S_CLOCK_MHZ=96 \
  ULX3S_ENABLE_SPI=1 \
  ULX3S_ENABLE_MATH=core0
```

See `make help` for all `ULX3S_*` overrides.

## ASIC RTL-to-GDS flow (OpenROAD via Docker)

The ASIC path (`build/asic/`) is completely separate from the ULX3S FPGA build.
See [Documentation/Road_to_OpenROAD.md](Documentation/Road_to_OpenROAD.md) for
architectural details.

### 1. Generate ASIC SystemVerilog and run Yosys structural preflight

```sh
make generate-asic
make asic-check
```

This assembles the cold-start Boot ROM (`mr4src/asm/asic_boot.asm`), generates
`build/asic/mr4_asic_top.sv` (`mr4_asic_top` with clean chip-level `clk`,
`rst_n`, `uart_*`, optional `spi_*`, and `debug_pc` ports), verifies zero
FPGA primitives or `$readmemh` calls, and runs Yosys `hierarchy -check`,
`proc`, `opt`, `check -assert`, and `stat`.

### 2. Run the end-to-end OpenROAD RTL-to-GDS dry run (Docker)

Make sure Docker is running, then invoke `make asic-flow`:

```sh
# Default: Nangate45 public reference PDK (standalone flop-RAM, zero external macros)
make asic-flow

# Or target ASAP7 (7nm predictive PDK) or SkyWater 130nm HD:
make asic-flow ASIC_PLATFORM=asap7
make asic-flow ASIC_PLATFORM=sky130hd
```

By default, `make asic-flow` generates `mr4_asic_top.sv` in standalone
`ASIC_MEM_TARGET=flop` mode (`1024` words RAM + `512`-word synthesizable
`AsicBootRom`) so the full synthesis → floorplan → placement → CTS → routing →
GDSII flow completes cleanly without requiring foundry SRAM Liberty/LEF files.

Outputs are written under `build/asic/orfs/`:

- **Logs:** `build/asic/orfs/logs/<platform>/mr4_asic_top/base/`
- **Reports (timing, area, power):** `build/asic/orfs/reports/<platform>/mr4_asic_top/base/`
- **Final netlist, DEF, and GDSII:** `build/asic/orfs/results/<platform>/mr4_asic_top/base/6_final.gds`

When you have a native Linux/WSL2 ORFS checkout instead of Docker, run:

```sh
make asic-flow ORFS_USE_DOCKER=0 ORFS_ROOT="$HOME/OpenROAD-flow-scripts"
```

When targeting a foundry PDK with compiled SRAM macros (`mr4_sram_dp_2048x16`),
switch to `ASIC_MEM_TARGET=sram ASIC_MEM_WORDS=2048` and supply the macro views
via `MR4_SRAM_LEFS`, `MR4_SRAM_LIBS`, and `MR4_SRAM_GDS` in `asic/mr4/config.mk`.

### 3. Hierarchical multi-core tile macro flow (`mr4_tile` → `mr4_quad_top`)

To harden one reusable compute tile (`mr4_tile`, with strapped `tile_id` and
registered Lean Ring boundary hops) and assemble a 4-tile hierarchical chip
(`mr4_quad_top`) with flat $F_{\max}$ scaling:

```sh
# 1. Structural preflight (ROHD generation + Yosys check on tile & blackbox quad)
make asic-tile-check

# 2. Harden ONE reusable mr4_tile macro and export LEF/LIB/GDS abstracts
make asic-tile-flow

# 3. Assemble 4x hardened mr4_tile macros into the hierarchical 4-core chip GDS
make asic-quad-flow
```

Pass `ASIC_PLATFORM=asap7` (or `sky130hd`) to both steps to target another PDK.

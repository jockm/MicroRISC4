# MiniRISC4 OS Integration Notes

Unzip this archive at the root of your MiniRISC4 repository to place all new files in their target directories.

## Files Included
- `hdl/rohd/lib/spi_master.dart` — SPI Mode 0 Master peripheral (MMIO `0x0018`–`0x001A`)
- `hdl/rohd/test/spi_master_test.dart` — ROHD loopback unit test
- `mr4src/asm/worker_stub.asm` — Worker Core Resident Stub (`0x0100`–`0x03FF`)
- `mr4src/act4/os/os_main.a4` — Core 0 kernel entry, Trap 1 ISR, syscall dispatcher
- `mr4src/act4/os/os_uart.a4` — UART I/O and packed string helpers
- `mr4src/act4/os/os_sd.a4` — SPI SDHC (SDv2) block driver
- `mr4src/act4/os/os_fat32.a4` — FAT32 mount, cluster walker, and directory reader
- `mr4src/act4/os/os_proc.a4` — Process table, worker loader, and Trap 14 kill
- `mr4src/act4/os/os_shell.a4` — Non-blocking interactive shell
- `lib/sys.a4` — User-space ACT4 syscall client library
- `mr4src/act4/apps/ls.a4` — Standalone user-space `ls` app (loads at `0x0400`)

## Existing File Hookups (Manual / Non-Destructive)
1. **`hdl/rohd/lib/cpu_config.dart`**: Add `final bool enableSpi;` (default `false`, `true` in `CpuConfig.multiCorePrimary()`).
2. **`hdl/rohd/lib/cpu_core.dart`**: Instantiate `SpiMaster` when `config.enableSpi` is true, OR `spiMatch` into `isMmio`, and MUX `spiRdata` into `portBRdata`.
3. **Compiling user apps**:
   ```bash
   python3 tools/act4c.py --org 0x0400 --nopreamble -I lib mr4src/act4/apps/ls.a4 -o build/ls.asm
   python3 tools/mr4asm.py lib/common.inc lib/M4R_LIB.asm build/ls.asm -o build/ls.bin
   ```

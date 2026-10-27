// ==============================================================================
// FILE: hdl/rohd/lib/cpu_config.dart
// MiniRISC4 Core Hardware Configuration Object
// ==============================================================================

class CpuConfig {
  /// Unique core identifier for multi-core configurations.
  final int coreId;

  /// Whether local MMIO UART is connected at 0x000E / 0x000F.
  final bool enableUart;

  /// Base address for this core's 16-word trap table (default: 0x0010).
  final int trapTableBase;

  /// Base address for scratchpad / stack pointers (default: 0x0000).
  final int scratchpadBase;

  /// Configurable physical memory depth in 16-bit words (default: 65,536 = 128 KB).
  final int memWords;

  const CpuConfig({
    this.coreId = 0,
    this.enableUart = true,
    this.trapTableBase = 0x0010,
    this.scratchpadBase = 0x0000,
    this.memWords = 65536,
  });

  /// Address bit width derived from memory capacity: log2(memWords).
  int get addrWidth => (memWords - 1).bitLength;

  /// Topmost valid word address in physical memory.
  int get memTop => memWords - 1;

  /// Standard Primary / I/O Core Preset (Full 64K RAM with UART).
  factory CpuConfig.primary() => const CpuConfig(
        coreId: 0,
        enableUart: true,
        memWords: 65536,
      );

  /// Secondary Worker / Accelerator Core Preset (Reduced RAM, no local UART).
  factory CpuConfig.worker({required int coreId, int memWords = 4096}) =>
      CpuConfig(
        coreId: coreId,
        enableUart: false,
        memWords: memWords,
      );
}

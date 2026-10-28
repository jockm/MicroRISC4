// ==============================================================================
// FILE: lib/cpu_config.dart
// MiniRISC4 Modular Hardware Configuration Object
// ==============================================================================

class CpuConfig {
  /// Unique core identifier (0 for primary or standalone, 1..N for workers).
  final int coreId;

  /// Whether hardware CPUID register is active at 0x000D.
  /// If false, 0x000D acts as an ordinary scratchpad RAM word.
  final bool enableCpuid;

  /// Whether local MMIO UART transceiver is enabled at 0x000E/0x000F.
  /// If false, 0x000E and 0x000F act as ordinary RAM words.
  final bool enableUart;

  /// Whether external inter-core trap trigger inputs are enabled.
  final bool enableCrossTraps;

  /// Whether hardware shadow registers and single-cycle XCHG are enabled.
  final bool enableShadowRegs;

  /// Base address for this core's 16-word trap/vector table (default: 0x0010).
  final int trapTableBase;

  /// Physical memory capacity in 16-bit words (default: 65,536 = 128 KB).
  final int memWords;

  const CpuConfig({
    this.coreId = 0,
    this.enableCpuid = true,
    this.enableUart = true,
    this.enableCrossTraps = false,
    this.enableShadowRegs = true,
    this.trapTableBase = 0x0010,
    this.memWords = 65536,
  });

  /// Address bit width derived from word count: ceil(log2(memWords)).
  int get addrWidth => (memWords - 1).bitLength;

  /// Highest valid physical memory address.
  int get memTop => memWords - 1;

  /// Factory: Standalone single-core system (full 64K RAM, UART, no cross-traps).
  factory CpuConfig.standalone() => const CpuConfig(
        coreId: 0,
        enableCpuid: false,
        enableUart: true,
        enableCrossTraps: false,
      );

  /// Factory: Multi-core Primary / I/O Core (Core 0, CPUID enabled, UART enabled).
  factory CpuConfig.multiCorePrimary() => const CpuConfig(
        coreId: 0,
        enableCpuid: true,
        enableUart: true,
        enableCrossTraps: true,
      );

  /// Factory: Multi-core Worker / Accelerator Core (CPUID enabled, reduced RAM, no UART).
  factory CpuConfig.worker({required int coreId, int memWords = 4096}) =>
      CpuConfig(
        coreId: coreId,
        enableCpuid: true,
        enableUart: false,
        enableCrossTraps: true,
        memWords: memWords,
      );
}

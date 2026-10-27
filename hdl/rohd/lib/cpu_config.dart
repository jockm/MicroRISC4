class CpuConfig {
  /// Unique hardware Core ID (e.g., 0, 1, 2...)
  final int coreId;

  /// Whether this core has local MMIO UART connected at 0x000E/0x000F
  final bool enableUart;

  /// Base address for this core's reset vector (default: 0xFFF0)
  final int trapTableBase;

  /// Base address for scratchpad / stack pointers
  final int scratchpadBase;

  const CpuConfig({
    this.coreId = 0,
    this.enableUart = true,
    this.trapTableBase = 0x0010,
    this.scratchpadBase = 0x0000,
  });

  /// Factory preset for Core 0 (Primary / I/O Core)
  factory CpuConfig.primary() => const CpuConfig(
        coreId: 0,
        enableUart: true,
      );

  /// Factory preset for Compute / Secondary Cores (no UART, shared memory)
  factory CpuConfig.worker({required int coreId}) => CpuConfig(
        coreId: coreId,
        enableUart: false,
        // Could place private trap tables at 0xFFE0, 0xFFD0, etc., or shared 0xFFF0
      );
}

// ==============================================================================
// FILE: hdl/rohd/lib/cpu_config.dart
// MiniRISC4 Modular Hardware Configuration Object
// ==============================================================================

class CpuConfig {
  final int coreId;
  final bool enableCpuid;
  final bool enableUart;
  final bool enableCrossTraps;
  final bool enableShadowRegs;
  final bool enableMathAccel; // Configurable Math Engine at 0x0010-0x0016
  final int trapTableBase;
  final int memWords;

  const CpuConfig({
    this.coreId = 0,
    this.enableCpuid = true,
    this.enableUart = true,
    this.enableCrossTraps = false,
    this.enableShadowRegs = true,
    this.enableMathAccel = false,
    this.trapTableBase = 0x0100,
    this.memWords = 65536,
  });

  int get addrWidth => (memWords - 1).bitLength;
  int get memTop => memWords - 1;

  /// Standalone core with standard peripherals.
  factory CpuConfig.standalone({bool enableMath = true}) => CpuConfig(
        coreId: 0,
        enableCpuid: false,
        enableUart: true,
        enableCrossTraps: false,
        enableMathAccel: enableMath,
      );

  /// Pipelined Compute / ALU Core: Math Accelerator enabled, no UART.
  factory CpuConfig.computeWorker(
          {required int coreId, int memWords = 16384}) =>
      CpuConfig(
        coreId: coreId,
        enableCpuid: true,
        enableUart: false,
        enableCrossTraps: true,
        enableMathAccel: true,
        memWords: memWords,
      );

  /// Lean I/O or Cache Controller Core: Minimal logic, no Math Accelerator.
  factory CpuConfig.leanWorker({required int coreId, int memWords = 1024}) =>
      CpuConfig(
        coreId: coreId,
        enableCpuid: true,
        enableUart: false,
        enableCrossTraps: true,
        enableMathAccel: false,
        memWords: memWords,
      );
}

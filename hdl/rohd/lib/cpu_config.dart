// ==============================================================================
// FILE: hdl/rohd/lib/cpu_config.dart
// MiniRISC4 Modular Hardware Configuration Object
// ==============================================================================

import 'constants.dart';
import 'memory_factory.dart';

class CpuConfig {
  final int coreId;
  final bool enableCpuid;
  final bool enableCpuInfo;
  final bool enableUart;
  final bool enableCrossTraps;
  final bool? enableEpc;
  final bool enableShadowRegs;
  final bool enableMathAccel;
  final bool enableFpu;
  final bool enableSpi;
  final bool enableNoc;
  final bool enableSdramCache;
  final bool isPipelined;
  final int memReadLatency;
  final MemoryTarget memoryTarget;
  final int bootRomBase;
  final List<int>? bootRomWords;
  final String? sramMacroName;
  final int clkFreqMhz;
  final int cpuVersionMajor;
  final int cpuVersionMinor;
  final int cpuCaps2;
  final int cacheLines;
  final int cacheLineWords;
  final int nocChannels;
  final int nocFifoDepth;
  final int trapTableBase;
  final int memWords;

  const CpuConfig({
    this.coreId = 0,
    this.enableCpuid = true,
    this.enableCpuInfo = true,
    this.enableUart = true,
    this.enableCrossTraps = false,
    this.enableEpc,
    this.enableShadowRegs = true,
    this.enableMathAccel = false,
    this.enableFpu = false,
    this.enableSpi = false,
    this.enableNoc = false,
    this.enableSdramCache = false,
    this.isPipelined = true,
    this.memReadLatency = 2,
    this.memoryTarget = MemoryTarget.fpgaEcp5,
    this.bootRomBase = 0x0100,
    this.bootRomWords,
    this.sramMacroName,
    this.clkFreqMhz = 48,
    this.cpuVersionMajor = MiniRISC4Constants.cpuVersionMajor,
    this.cpuVersionMinor = MiniRISC4Constants.cpuVersionMinor,
    this.cpuCaps2 = 0,
    this.cacheLines = 64,
    this.cacheLineWords = 8,
    this.nocChannels = 8,
    this.nocFifoDepth = 32,
    this.trapTableBase = 0x0100,
    this.memWords = 65536,
  });

  int get addrWidth => (memWords - 1).bitLength;
  int get memTop => memWords - 1;
  bool get hasEpc => enableEpc ?? enableCrossTraps;

  /// Read-only CPU_VER (0x001B): {major[7:0], minor[7:0]}.
  int get cpuVersionWord =>
      ((cpuVersionMajor & 0xFF) << 8) | (cpuVersionMinor & 0xFF);

  /// Read-only CPU_CAPS (0x001C): primary 16-bit capability flags.
  int get cpuCapsWord =>
      (enableShadowRegs ? MiniRISC4Constants.capShadowRegs : 0) |
      (enableCpuid ? MiniRISC4Constants.capCpuid : 0) |
      (enableUart ? MiniRISC4Constants.capUart : 0) |
      (enableMathAccel ? MiniRISC4Constants.capMathAccel : 0) |
      (enableFpu ? MiniRISC4Constants.capFpu : 0) |
      (enableSpi ? MiniRISC4Constants.capSpi : 0) |
      (enableNoc ? MiniRISC4Constants.capNoc : 0) |
      (enableCrossTraps ? MiniRISC4Constants.capCrossTraps : 0) |
      (hasEpc ? MiniRISC4Constants.capEpcEret : 0) |
      (enableSdramCache ? MiniRISC4Constants.capSdramCache : 0) |
      (isPipelined ? MiniRISC4Constants.capPipelined : 0);

  /// Read-only CPU_CAPS2 (0x001D): expansion capability word (reserved).
  int get cpuCaps2Word => cpuCaps2 & 0xFFFF;

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

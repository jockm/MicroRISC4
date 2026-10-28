// Modular CPU Configuration for MiniRISC4
class CpuConfig {
  final int coreId;
  final bool enableCpuid;
  final bool enableUart;
  final bool enableCrossTraps;
  final bool enableShadowRegs;
  final int trapTableBase;
  final int scratchpadBase;
  final int memWords;

  const CpuConfig({
    this.coreId = 0;
    this.enableCpuid = true;
    this.enableUart = true;
    this.enableCrossTraps = false;
    this.enableShadowRegs = true;
    this.trapTableBase = 0x0010;
    this.scratchpadBase = 0x0000;
    this.memWords = 65536;
  });

  int get addrWidth => (memWords - 1).bitLength;
  int get memTop => memWords - 1;

  factory CpuConfig.standalone() => const CpuConfig(
        coreId: 0,
        enableCpuid: false,
        enableUart: true,
        enableCrossTraps: false,
      );

  factory CpuConfig.multiCorePrimary() => const CpuConfig(
        coreId: 0,
        enableCpuid: true,
        enableUart: true,
        enableCrossTraps: true,
      );

  factory CpuConfig.worker({required int coreId, int memWords = 4096}) =>
      CpuConfig(
        coreId: coreId,
        enableCpuid: true,
        enableUart: false,
        enableCrossTraps: true,
        memWords: memWords,
      );
}

// ==============================================================================
// FILE: hdl/rohd/test/cpu_functional_test.dart
// Functional RTL Verification for MiniRISC4 CpuCore + TdpBram
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:minirisc4_rohd/cpu_config.dart';
import 'package:minirisc4_rohd/cpu_core.dart';

int pack(int s0, [int s1 = 0x00]) => ((s1 & 0xFF) << 8) | (s0 & 0xFF);
int ldReg(int rr, int rl) => (0x0 << 4) | (rr << 2) | rl;
int ldImm4(int imm4) => (0x1 << 4) | (imm4 & 0xF);
int ldPeek(int rr, int rl) => (0x2 << 4) | (rr << 2) | rl;
int ldPoke(int rr, int rl) => (0x3 << 4) | (rr << 2) | rl;
int ldPop(int rr, int rl) => (0x4 << 4) | (rr << 2) | rl;
int ldPush(int rr, int rl) => (0x5 << 4) | (rr << 2) | rl;
int opAdd(int rr, int rl) => (0x6 << 4) | (rr << 2) | rl;
int opSub(int rr, int rl) => (0x7 << 4) | (rr << 2) | rl;
int opOr(int rr, int rl) => (0x8 << 4) | (rr << 2) | rl;
int opXor(int rr, int rl) => (0x9 << 4) | (rr << 2) | rl;
int opAnd(int rr, int rl) => (0xA << 4) | (rr << 2) | rl;
int opXchg(int rl) => 0xBC | rl;
int opInc(int rl) => 0xC8 | rl;
int opDec(int rl) => 0xCC | rl;
int opJmpZ(int rr, int rl) => (0xD << 4) | (rr << 2) | rl;
int opJmp(int rl) => 0xF0 | rl;
int opLink(int rl) => 0xF4 | rl;
int push8Word(int rl, int imm8) => pack(0xF8 | rl, imm8);
int trapWord(int rl, int imm8) => pack(0xFC | rl, imm8);

Future<CpuCore> runProgram(
  Map<int, int> memory, {
  int cycles = 120,
  String? initHexFile,
  void Function(int byte)? onTxByte,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final rstN = Logic(name: 'rst_n');
  final rxData = Logic(name: 'mmio_rx_data', width: 16);
  final txStatus = Logic(name: 'mmio_tx_status', width: 16);

  final cpu = CpuCore(
    clk: clk,
    rstN: rstN,
    mmioRxData: rxData,
    mmioTxStatus: txStatus,
    config: const CpuConfig(
      coreId: 0,
      enableCpuid: false,
      enableUart: true,
      enableCrossTraps: false,
      enableMathAccel: false,
      trapTableBase: 0x0100,
      memWords: 65536,
    ),
    initHexFile: initHexFile,
    initialMemory: memory,
  );

  await cpu.build();

  rstN.put(0);
  rxData.put(0);
  txStatus.put(0);

  if (onTxByte != null) {
    clk.posedge.listen((_) {
      if (cpu.txStrobe.value.isValid && cpu.txStrobe.value.toBool()) {
        onTxByte(cpu.txData.value.toInt() & 0xFF);
      }
    });
  }

  Simulator.registerAction(22, () => rstN.put(1));
  Simulator.setMaxSimTime(25 + cycles * 10);
  await Simulator.run();
  return cpu;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('ALU, dual-slot packing, and XCHG shadow registers', () async {
    final mem = <int, int>{
      0x0100: pack(ldImm4(9), ldReg(1, 0)),       // R0=9; R1=9
      0x0101: pack(ldImm4(5), opAdd(1, 0)),       // R0=5; R1=14 (0x000E)
      0x0102: pack(opXchg(1), ldImm4(3)),         // shadow_r1=14, R1=0; R0=3
      0x0103: pack(opAdd(1, 0), opXchg(1)),       // R1=3; swap back -> R1=14, shadow_r1=3
      0x0104: pack(opSub(1, 0), ldImm4(6)),       // R1=11 (0x000B); R0=6
      0x0105: pack(opAnd(1, 0), ldImm4(1)),       // R1=11&6=2; R0=1
      0x0106: pack(opOr(1, 0), opInc(1)),         // R1=2|1=3; R1=4
      0x0107: push8Word(2, 0x05),                 // R2 = 0x0005
      0x0108: push8Word(2, 0x00),                 // R2 = 0x0500
      0x0109: pack(ldPoke(2, 1), opXchg(1)),      // mem[0x0500]=4; R1=shadow_r1(3)
      0x010A: pack(opInc(2), ldPoke(2, 1)),       // R2=0x0501; mem[0x0501]=3
      0x010B: push8Word(3, 0x01),                 // R3 = 0x0001
      0x010C: push8Word(3, 0x0D),                 // R3 = 0x010D (halt loop)
      0x010D: pack(opJmp(3), 0x00),               // JMP 0x010D
    };

    final cpu = await runProgram(mem, cycles: 100);
    expect(cpu.ram.mem[0x0500], equals(4));
    expect(cpu.ram.mem[0x0501], equals(3));
  });

  test('Full Descending stack push (LD --Rr, Rl) and pop (LD Rr, Rl++)', () async {
    final mem = <int, int>{
      0x0100: push8Word(3, 0x06),                 // SP (R3) = 0x0600
      0x0101: push8Word(3, 0x00),
      0x0102: push8Word(1, 0x12),                 // R1 = 0x1234
      0x0103: push8Word(1, 0x34),
      0x0104: pack(ldPush(3, 1), ldImm4(0)),      // --R3 (0x05FF), mem[0x05FF]=0x1234
      0x0105: push8Word(1, 0xAB),                 // R1 = 0xABCD
      0x0106: push8Word(1, 0xCD),
      0x0107: pack(ldPush(3, 1), ldPop(2, 3)),    // --R3 (0x05FE)=0xABCD; pop R2=0xABCD, R3=0x05FF
      0x0108: pack(ldPop(1, 3), 0x00),            // pop R1=0x1234, R3=0x0600
      0x0109: push8Word(0, 0x05),                 // R0 = 0x0510
      0x010A: push8Word(0, 0x10),
      0x010B: pack(ldPoke(0, 2), opInc(0)),       // mem[0x0510] = 0xABCD
      0x010C: pack(ldPoke(0, 1), opInc(0)),       // mem[0x0511] = 0x1234
      0x010D: pack(ldPoke(0, 3), 0x00),           // mem[0x0512] = 0x0600 (restored SP)
      0x010E: push8Word(3, 0x01),
      0x010F: push8Word(3, 0x10),
      0x0110: pack(opJmp(3), 0x00),
    };

    final cpu = await runProgram(mem, cycles: 120);
    expect(cpu.ram.mem[0x05FF], equals(0x1234));
    expect(cpu.ram.mem[0x05FE], equals(0xABCD));
    expect(cpu.ram.mem[0x0510], equals(0xABCD));
    expect(cpu.ram.mem[0x0511], equals(0x1234));
    expect(cpu.ram.mem[0x0512], equals(0x0600));
  });

  test('Direct Stride TRAP and Slot-1 Alignment Fault (0x01F0)', () async {
    final mem = <int, int>{
      // Reset at 0x0100: invoke TRAP 2 -> should jump to 0x0120 with R0 = 0x0102
      0x0100: pack(ldImm4(2), 0x00),
      0x0101: trapWord(0, 0x55),
      // Return from TRAP 2 lands at 0x0102: deliberately put LINK in Slot 1 -> TRAP 15 (0x01F0)
      0x0102: pack(0x00, opLink(1)),

      // TRAP 2 handler at 0x0120: write 0xBEEF to mem[0x0520], return via JMP R0
      0x0120: push8Word(1, 0x05),
      0x0121: push8Word(1, 0x20),
      0x0122: push8Word(2, 0xBE),
      0x0123: push8Word(2, 0xEF),
      0x0124: pack(ldPoke(1, 2), opJmp(0)),

      // TRAP 15 handler at 0x01F0: write 0xFA17 to mem[0x0521], then halt
      0x01F0: push8Word(1, 0x05),
      0x01F1: push8Word(1, 0x21),
      0x01F2: push8Word(2, 0xFA),
      0x01F3: push8Word(2, 0x17),
      0x01F4: pack(ldPoke(1, 2), 0x00),
      0x01F5: push8Word(3, 0x01),
      0x01F6: push8Word(3, 0xF7),
      0x01F7: pack(opJmp(3), 0x00),
    };

    final cpu = await runProgram(mem, cycles: 150);
    expect(cpu.ram.mem[0x0520], equals(0xBEEF));
    expect(cpu.ram.mem[0x0521], equals(0xFA17));
  });

  test('End-to-end monitor.asm firmware boots and prints banner + prompt', () async {
    final hexFile = File('system_image.hex');
    if (!hexFile.existsSync()) {
      markTestSkipped('system_image.hex not found; assemble monitor.asm first');
      return;
    }

    final txBytes = <int>[];
    await runProgram(
      const {},
      cycles: 40000,
      initHexFile: hexFile.path,
      onTxByte: (b) => txBytes.add(b),
    );

    final output = String.fromCharCodes(txBytes);
    expect(output, contains('MiniRISC4 ASM Monitor'));
    expect(output, contains('> '));
  });
}

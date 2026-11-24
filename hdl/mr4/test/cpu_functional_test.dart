// ==============================================================================
// FILE: hdl/mr4/test/cpu_functional_test.dart
// Functional RTL Verification for MicroRISC4 CpuCore + TdpBram
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:microrisc4_rohd/cpu_config.dart';
import 'package:microrisc4_rohd/cpu_core.dart';

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
int opShiftL(int rl) => 0xB0 | rl;
int opShiftR(int rl) => 0xB4 | rl;
int opShiftAr(int rl) => 0xB8 | rl;
int opXchg(int rl) => 0xBC | rl;
int opRotL(int rl) => 0xC0 | rl;
int opRotR(int rl) => 0xC4 | rl;
int opInc(int rl) => 0xC8 | rl;
int opDec(int rl) => 0xCC | rl;
int opJmpZ(int rr, int rl) => (0xD << 4) | (rr << 2) | rl;
int opJmpM(int rr, int rl) => (0xE << 4) | (rr << 2) | rl;
int opJmp(int rl) => 0xF0 | rl;
int opLink(int rl) => 0xF4 | rl;
int opEret() => 0x0F;
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
    expect(output, contains('MicroRISC4 ASM Monitor'));
    expect(output, contains('> '));
  });

  test('Pipeline hazards: RAW/WAW/XCHG forwarding, stalled-EX capture, store-to-load, EPC->ERET, zero-bubble PUSH8', () async {
    // Tests all 4-stage pipeline corner cases + verifies ~1.0 cycle/PUSH8 throughput!
    final mem = <int, int>{
      // 1. Seed data memory [0x0400] = 0x1000, [0x0401] = 0x0025
      0x0400: 0x1000,
      0x0401: 0x0025,
      0x0410: 0x5A5A,

      // 2. Back-to-back WB->EX & WB->ID RAW forwarding chain:
      //    R0=3, R1=R0(3), R1=R1+R0(6), R1=R1+R0(9), R2=R1+R0(12), R2=R2+R1(21=0x15)
      0x0100: pack(ldImm4(3), ldReg(1, 0)),
      0x0101: pack(opAdd(1, 0), opAdd(1, 0)),
      0x0102: pack(ldReg(2, 1), opAdd(2, 0)),
      0x0103: pack(opAdd(2, 1), 0x00),
      // Store R2 (0x0015) -> [0x0500]
      0x0104: push8Word(3, 0x05),
      0x0105: push8Word(3, 0x00),
      0x0106: pack(ldPoke(3, 2), 0x00),

      // 3. Back-to-back XCHG forwarding (shadow<->main 3x in a row + consumer):
      //    R1 = 9, shadow_r1 = 0
      //    XCHG R1 (R1=0, sh=9) ; XCHG R1 (R1=9, sh=0) ; INC R1 (R1=10) ; XCHG R1 (R1=0, sh=10) ; XCHG R1 (R1=10)
      0x0107: pack(opXchg(1), opXchg(1)),
      0x0108: pack(opInc(1), opXchg(1)),
      0x0109: pack(opXchg(1), opInc(3)),      // R1 = 10 (0x000A), R3 = 0x0501
      0x010A: pack(ldPoke(3, 1), 0x00),       // [0x0501] = 0x000A

      // 4. Stalled-EX forward capture test:
      //    R0 = 0x0400 (addr of 0x1000)
      //    PEEK R1, (R0)  ; LDI4 7 (writes R0=7 into WB while EX stalls on R1!)
      //    ADD R1, R0     ; (stalls in EX waiting for R1 while R0=7 retires from WB!)
      //    Expected R1 = 0x1000 + 7 = 0x1007 -> [0x0502]
      0x010B: push8Word(0, 0x04),
      0x010C: push8Word(0, 0x00),
      0x010D: pack(ldPeek(1, 0), ldImm4(7)),
      0x010E: pack(opAdd(1, 0), opInc(3)),    // R1 = 0x1007, R3 = 0x0502
      0x010F: pack(ldPoke(3, 1), 0x00),       // [0x0502] = 0x1007

      // 5. Load WAW hazard test:
      //    PEEK R1, (0x0400) [0x1000] followed IMMEDIATELY by LDI4 0xB; LD R1, R0
      //    Architectural order MUST end with R1 = 0x000B (NOT 0x1000!) -> [0x0503]
      0x0110: push8Word(2, 0x04),
      0x0111: push8Word(2, 0x00),
      0x0112: pack(ldPeek(1, 2), ldImm4(0xB)),
      0x0113: pack(ldReg(1, 0), opInc(3)),    // R1 = 0x000B, R3 = 0x0503
      0x0114: pack(ldPoke(3, 1), 0x00),       // [0x0503] = 0x000B

      // 6. Back-to-back POKE -> PEEK same address coherence:
      //    POKE (0x0420), 0xBEEF ; PEEK R1, (0x0420) -> [0x0504] = 0xBEEF
      0x0115: push8Word(2, 0x04),
      0x0116: push8Word(2, 0x20),
      0x0117: push8Word(0, 0xBE),
      0x0118: push8Word(0, 0xEF),
      0x0119: pack(ldPoke(2, 0), ldPeek(1, 2)),
      0x011A: pack(opInc(3), ldPoke(3, 1)),   // R3 = 0x0504, [0x0504] = 0xBEEF

      // 7. Self-overwriting POP R2, (R2++): mem[0x0410] = 0x5A5A -> R2 MUST be 0x5A5A (not 0x0411)!
      0x011B: push8Word(2, 0x04),
      0x011C: push8Word(2, 0x10),
      0x011D: pack(ldPop(2, 2), opInc(3)),    // R2 = 0x5A5A, R3 = 0x0505
      0x011E: pack(ldPoke(3, 2), 0x00),       // [0x0505] = 0x5A5A

      // 8. Back-to-back forwarding into JMP.Z / JMP.M condition & target:
      //    R0 = 1; DEC R0 (0); JMP.Z R2, R0 -> taken to 0x0125!
      0x011F: push8Word(2, 0x01),
      0x0120: push8Word(2, 0x25),
      0x0121: pack(ldImm4(1), opDec(0)),
      0x0122: pack(opJmpZ(2, 0), ldImm4(0xF)), // Taken! Slot 1 MUST be flushed!
      0x0123: pack(ldImm4(0xE), 0x00),         // Must NOT execute!
      0x0124: pack(ldImm4(0xD), 0x00),
      // 0x0125: R0 must still be 0! Store R0 -> [0x0506], then test back-to-back POKE EPC; ERET!
      0x0125: pack(opInc(3), ldPoke(3, 0)),    // R3 = 0x0506, [0x0506] = 0x0000
      0x0126: push8Word(0, 0x00),
      0x0127: push8Word(0, 0x1E),              // addrEpc = 0x001E
      0x0128: push8Word(1, 0x01),
      0x0129: push8Word(1, 0x30),              // target = 0x0130
      0x012A: pack(ldPoke(0, 1), opEret()),    // Back-to-back POKE EPC ; ERET!
      0x012B: pack(ldImm4(0xF), 0x00),         // Must NOT execute!

      // 0x0130: Landed via EPC->ERET! Store 0xCAFE -> [0x0507] and halt at 0x0135
      0x0130: push8Word(1, 0xCA),
      0x0131: push8Word(1, 0xFE),
      0x0132: pack(opInc(3), ldPoke(3, 1)),    // R3 = 0x0507, [0x0507] = 0xCAFE
      0x0133: push8Word(2, 0x01),
      0x0134: push8Word(2, 0x35),
      0x0135: pack(opJmp(2), 0x00),
    };

    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final cpu = CpuCore(
      clk: clk,
      rstN: rstN,
      config: const CpuConfig(
        coreId: 0,
        enableCpuid: false,
        enableUart: false,
        enableCrossTraps: false,
        enableEpc: true,
        enableMathAccel: false,
        trapTableBase: 0x0100,
        memWords: 65536,
      ),
      initialMemory: mem,
    );
    await cpu.build();
    rstN.put(0);
    Simulator.registerAction(22, () => rstN.put(1));
    Simulator.setMaxSimTime(25 + 220 * 10);
    await Simulator.run();

    expect(cpu.ram.mem[0x0500], equals(0x0015), reason: 'WB->EX / WB->ID ALU RAW chain');
    expect(cpu.ram.mem[0x0501], equals(0x000A), reason: 'Back-to-back XCHG forwarding');
    expect(cpu.ram.mem[0x0502], equals(0x1007), reason: 'Stalled-EX WB->EX forward capture');
    expect(cpu.ram.mem[0x0503], equals(0x000B), reason: 'Load WAW ordering');
    expect(cpu.ram.mem[0x0504], equals(0xBEEF), reason: 'Back-to-back POKE->PEEK coherence');
    expect(cpu.ram.mem[0x0505], equals(0x5A5A), reason: 'Self-overwriting POP R2,(R2++)');
    expect(cpu.ram.mem[0x0506], equals(0x0000), reason: 'JMP.Z forwarding & slot-1 flush');
    expect(cpu.ram.mem[0x0507], equals(0xCAFE), reason: 'Back-to-back POKE EPC -> ERET forwarding');
  });

  test('Zero-bubble PUSH8 throughput reaches ~1.0 cycle/PUSH8 (vs 2.0 in legacy FSM)', () async {
    // 16 consecutive PUSH8 instructions followed by a store & halt.
    // Legacy FSM needed 16*2 = 32 cycles for the 16 PUSH8s alone (~42 total).
    // 4-stage pipeline with prefetch ring executes all 16 PUSH8s in 16 cycles (~24 total)!
    final mem = <int, int>{};
    for (var i = 0; i < 16; i++) {
      mem[0x0100 + i] = push8Word(1, 0x10 + i);
    }
    mem[0x0110] = push8Word(2, 0x05);
    mem[0x0111] = push8Word(2, 0x00);
    mem[0x0112] = pack(ldPoke(2, 1), 0x00); // [0x0500] = 0x1E1F
    mem[0x0113] = push8Word(3, 0x01);
    mem[0x0114] = push8Word(3, 0x15);
    mem[0x0115] = pack(opJmp(3), 0x00);

    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final cpu = CpuCore(
      clk: clk,
      rstN: rstN,
      config: const CpuConfig(
        coreId: 0,
        enableCpuid: false,
        enableUart: false,
        enableCrossTraps: false,
        enableMathAccel: false,
        trapTableBase: 0x0100,
        memWords: 65536,
      ),
      initialMemory: mem,
    );
    await cpu.build();
    rstN.put(0);

    var cycles = 0;
    int? doneCycle;
    clk.posedge.listen((_) {
      if (rstN.value.isValid && rstN.value.toBool()) {
        cycles++;
        if (doneCycle == null && cpu.ram.mem[0x0500] == 0x1E1F) {
          doneCycle = cycles;
        }
      }
    });

    Simulator.registerAction(22, () => rstN.put(1));
    Simulator.setMaxSimTime(25 + 60 * 10);
    await Simulator.run();

    expect(cpu.ram.mem[0x0500], equals(0x1E1F));
    expect(doneCycle, isNotNull);
    // 18 PUSH8 + 1 POKE + 4-cycle cold fill = ~25 cycles (legacy FSM would be >42 cycles!)
    expect(doneCycle!, lessThanOrEqualTo(28),
        reason: 'Expected zero-bubble ~1.0 cyc/PUSH8 (got $doneCycle cycles)');
  });

  test('ACT4 --hw-math end-to-end on CpuCore (1-DSP MathAccelerator + CPU_CAPS guard)', () async {
    final tmpDir = Directory.systemTemp.createTempSync('mr4_hw_math_rtl_');
    try {
      final a4File = File('${tmpDir.path}/hw_math_rtl.a4');
      final asmFile = File('${tmpDir.path}/hw_math_rtl.asm');
      final binFile = File('${tmpDir.path}/hw_math_rtl.bin');

      a4File.writeAsStringSync('''
u16 uart_tx @ 0x000F;
u16 out0 @ 0x1000;
u16 out1 @ 0x1001;
u16 out2 @ 0x1002;
u16 out3 @ 0x1003;
u16 out4 @ 0x1004;
u16 out5 @ 0x1005;
u16 out6 @ 0x1006;
u16 out7 @ 0x1007;

void putc(u16 c) {
    while (uart_tx != 0) {}
    uart_tx = c;
}

void main(void) {
    u16 a = 300;
    u16 b = 200;
    u16 sh = 5;
    out0 = a * b;          // 60000 (0xEA60)
    a = 54321; b = 123;
    out1 = a / b;          // 441   (0x01B9)
    out2 = a % b;          // 78    (0x004E)
    a = 1234; b = 0;
    out3 = a / b;          // 0xFFFF (div-by-zero)
    out4 = a % b;          // 1234  (0x04D2)
    a = 0x00AB;
    out5 = a << 8;         // 0xAB00
    a = 0x00FF;
    out6 = a << sh;        // 0x1FE0
    sh = 16;
    out7 = a >> sh;        // 0x0000
    putc(72); putc(87); putc(79); putc(75); putc(10); // "HWOK\\n"
    while (true) {}
}
''');

      final comp = Process.runSync('python3', [
        '../../tools/act4c.py',
        a4File.path,
        '-o',
        asmFile.path,
        '-I',
        '../../lib',
        '--hw-math',
      ]);
      expect(comp.exitCode, equals(0), reason: 'act4c failed: ${comp.stderr}');

      final assem = Process.runSync('python3', [
        '../../tools/mr4asm.py',
        '-I',
        '../../lib',
        asmFile.path,
        '-o',
        binFile.path,
      ]);
      expect(assem.exitCode, equals(0), reason: 'mr4asm failed: ${assem.stderr}');

      final bytes = binFile.readAsBytesSync();
      final mem = <int, int>{};
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        final w = (bytes[i + 1] << 8) | bytes[i];
        if (w != 0) mem[i >> 1] = w;
      }

      // Run A: CpuCore WITH 1-DSP MathAccelerator enabled
      final txEnable = <int>[];
      final clkA = SimpleClockGenerator(10).clk;
      final rstNA = Logic(name: 'rst_n_a');
      final rxA = Logic(name: 'rx_a', width: 16);
      final txStA = Logic(name: 'tx_st_a', width: 16);
      final cpuA = CpuCore(
        clk: clkA,
        rstN: rstNA,
        mmioRxData: rxA,
        mmioTxStatus: txStA,
        config: const CpuConfig(
          coreId: 0,
          enableCpuid: true,
          enableUart: true,
          enableCrossTraps: false,
          enableMathAccel: true,
          trapTableBase: 0x0100,
          memWords: 65536,
        ),
        initialMemory: Map<int, int>.from(mem),
      );
      await cpuA.build();
      rstNA.put(0);
      rxA.put(0);
      txStA.put(0);
      clkA.posedge.listen((_) {
        if (cpuA.txStrobe.value.isValid && cpuA.txStrobe.value.toBool()) {
          txEnable.add(cpuA.txData.value.toInt() & 0xFF);
        }
      });
      Simulator.registerAction(22, () => rstNA.put(1));
      Simulator.setMaxSimTime(25 + 2500 * 10);
      await Simulator.run();

      expect(String.fromCharCodes(txEnable), equals('HWOK\n'));
      expect(cpuA.ram.mem[0x1000], equals(60000));
      expect(cpuA.ram.mem[0x1001], equals(441));
      expect(cpuA.ram.mem[0x1002], equals(78));
      expect(cpuA.ram.mem[0x1003], equals(0xFFFF));
      expect(cpuA.ram.mem[0x1004], equals(1234));
      expect(cpuA.ram.mem[0x1005], equals(0xAB00));
      expect(cpuA.ram.mem[0x1006], equals(0x1FE0));
      expect(cpuA.ram.mem[0x1007], equals(0x0000));

      // Reset simulator between runs
      await Simulator.reset();

      // Run B: EXACT SAME binary on CpuCore WITHOUT MathAccelerator -> startup CPU_CAPS guard triggers!
      final txDisable = <int>[];
      final clkB = SimpleClockGenerator(10).clk;
      final rstNB = Logic(name: 'rst_n_b');
      final rxB = Logic(name: 'rx_b', width: 16);
      final txStB = Logic(name: 'tx_st_b', width: 16);
      final cpuB = CpuCore(
        clk: clkB,
        rstN: rstNB,
        mmioRxData: rxB,
        mmioTxStatus: txStB,
        config: const CpuConfig(
          coreId: 0,
          enableCpuid: true,
          enableUart: true,
          enableCrossTraps: false,
          enableMathAccel: false,
          trapTableBase: 0x0100,
          memWords: 65536,
        ),
        initialMemory: Map<int, int>.from(mem),
      );
      await cpuB.build();
      rstNB.put(0);
      rxB.put(0);
      txStB.put(0);
      clkB.posedge.listen((_) {
        if (cpuB.txStrobe.value.isValid && cpuB.txStrobe.value.toBool()) {
          txDisable.add(cpuB.txData.value.toInt() & 0xFF);
        }
      });
      Simulator.registerAction(22, () => rstNB.put(1));
      Simulator.setMaxSimTime(25 + 2500 * 10);
      await Simulator.run();

      final errOut = String.fromCharCodes(txDisable);
      expect(errOut, contains('ERR: CPU lacks HW Math Accelerator (CPU_CAPS.b3=0)'));
      expect(cpuB.ram.mem[0x1000], equals(0),
          reason: '_main body must not execute when CAP_MATH_ACCEL == 0');
    } finally {
      tmpDir.deleteSync(recursive: true);
    }
  });
}

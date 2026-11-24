// ==============================================================================
// FILE: hdl/mr4/test/math_accelerator_test.dart
// Comprehensive 1-DSP Multi-Cycle MathAccelerator Verification (All 11 Opcodes)
// ==============================================================================

import 'dart:async';
import 'package:test/test.dart';
import 'package:rohd/rohd.dart';
import 'package:microrisc4_rohd/math_accelerator.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('MathAccelerator 1-DSP Multi-Cycle Hardware Tests', () {
    test('Verifies all 11 opcodes (MUL/MULH/MULHU/MULHSU, DIV/REM/DIVU/REMU, SLL/SRL/SRA) + edge cases', () async {
      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rst_n');
      final addr = Logic(name: 'port_b_addr', width: 16);
      final wdata = Logic(name: 'port_b_wdata', width: 16);
      final we = Logic(name: 'port_b_we');
      final en = Logic(name: 'port_b_en');

      final accel = MathAccelerator(
        clk: clk,
        rstN: rstN,
        portBAddr: addr,
        portBWdata: wdata,
        portBWe: we,
        portBEn: en,
      );

      await accel.build();

      rstN.put(0);
      en.put(0);
      we.put(0);
      addr.put(0);
      wdata.put(0);

      Future<void> tick() async {
        await clk.nextPosedge;
        await Simulator.postTick.first;
      }

      unawaited(Simulator.run());

      Future<void> writeReg(int a, int v) async {
        en.put(1);
        we.put(1);
        addr.put(a);
        wdata.put(v & 0xFFFF);
        await tick();
        en.put(0);
        we.put(0);
      }

      Future<int> readReg(int a) async {
        // Verify match stays asserted even when en=0 (CpuCore _memWait2 timing!)
        en.put(0);
        we.put(0);
        addr.put(a);
        await tick();
        expect(accel.match.value.toInt(), equals(1));
        return accel.rdata.value.toInt();
      }

      Future<(int, int)> runOp(int a32, int b32, int cmd) async {
        await writeReg(0x0010, a32 & 0xFFFF);
        await writeReg(0x0011, (a32 >> 16) & 0xFFFF);
        await writeReg(0x0012, b32 & 0xFFFF);
        await writeReg(0x0013, (b32 >> 16) & 0xFFFF);
        await writeReg(0x0014, cmd);

        // Poll MATH_CMD_STAT[0] until idle
        var polls = 0;
        var stat = 0;
        while (polls < 60) {
          stat = await readReg(0x0014);
          if ((stat & 1) == 0) break;
          polls++;
        }
        expect(stat & 1, equals(0), reason: 'MathAccelerator timed out on cmd=$cmd');

        final lo = await readReg(0x0015);
        final hi = await readReg(0x0016);
        return (((hi & 0xFFFF) << 16) | (lo & 0xFFFF), stat);
      }

      Future<void> drive() async {
        await tick();
        await tick();
        rstN.put(1);
        await tick();

        // 1. MUL: 6 * 7 = 42
        var (res, stat) = await runOp(6, 7, MathAccelerator.cmdMul);
        expect(res, equals(42));
        expect(stat, equals(0));

        // 2. MUL + MULHU: 123456 * 78901 = 9,740,801,856 = 0x00000002_4498D740
        (res, stat) = await runOp(123456, 78901, MathAccelerator.cmdMul);
        expect(res, equals(0x4498D740));
        (res, stat) = await runOp(123456, 78901, MathAccelerator.cmdMulhu);
        expect(res, equals(0x00000002));

        // 3. MULHU max: 0xFFFFFFFF * 0xFFFFFFFF = 0xFFFFFFFE_00000001
        (res, stat) = await runOp(0xFFFFFFFF, 0xFFFFFFFF, MathAccelerator.cmdMul);
        expect(res, equals(0x00000001));
        (res, stat) = await runOp(0xFFFFFFFF, 0xFFFFFFFF, MathAccelerator.cmdMulhu);
        expect(res, equals(0xFFFFFFFE));

        // 4. MULH signed: (-1) * (-1) = +1 (hi = 0, lo = 1); (-100000) * 100000 = -10,000,000,000 = 0xFFFFFFFD_ABF41C00
        (res, stat) = await runOp(0xFFFFFFFF, 0xFFFFFFFF, MathAccelerator.cmdMulh);
        expect(res, equals(0x00000000));
        (res, stat) = await runOp((-100000) & 0xFFFFFFFF, 100000, MathAccelerator.cmdMulh);
        expect(res, equals(0xFFFFFFFD));
        (res, stat) = await runOp((-100000) & 0xFFFFFFFF, 100000, MathAccelerator.cmdMul);
        expect(res, equals(0xABF41C00));

        // 5. MULHSU: (-1 signed) * (0xFFFFFFFF unsigned) = -0xFFFFFFFF = 0xFFFFFFFF_00000001
        (res, stat) = await runOp(0xFFFFFFFF, 0xFFFFFFFF, MathAccelerator.cmdMulhsu);
        expect(res, equals(0xFFFFFFFF));

        // 6. DIVU / REMU: 0x12345678 / 1000 = 305419 (0x4A90B), rem = 896 (0x380)
        (res, stat) = await runOp(0x12345678, 1000, MathAccelerator.cmdDivu);
        expect(res, equals(0x12345678 ~/ 1000));
        expect(stat, equals(0));
        (res, stat) = await runOp(0x12345678, 1000, MathAccelerator.cmdRemu);
        expect(res, equals(0x12345678 % 1000));

        // 7. DIV / REM signed: -100 / 7 = -14, rem = -2; -100 / -7 = +14, rem = -2
        (res, stat) = await runOp((-100) & 0xFFFFFFFF, 7, MathAccelerator.cmdDiv);
        expect(res, equals((-14) & 0xFFFFFFFF));
        (res, stat) = await runOp((-100) & 0xFFFFFFFF, 7, MathAccelerator.cmdRem);
        expect(res, equals((-2) & 0xFFFFFFFF));
        (res, stat) = await runOp((-100) & 0xFFFFFFFF, (-7) & 0xFFFFFFFF, MathAccelerator.cmdDiv);
        expect(res, equals(14));
        (res, stat) = await runOp((-100) & 0xFFFFFFFF, (-7) & 0xFFFFFFFF, MathAccelerator.cmdRem);
        expect(res, equals((-2) & 0xFFFFFFFF));

        // 8. Signed overflow edge case: 0x80000000 / -1 = 0x80000000, rem = 0
        (res, stat) = await runOp(0x80000000, 0xFFFFFFFF, MathAccelerator.cmdDiv);
        expect(res, equals(0x80000000));
        (res, stat) = await runOp(0x80000000, 0xFFFFFFFF, MathAccelerator.cmdRem);
        expect(res, equals(0));

        // 9. Divide-by-zero flag (stat bit 1 = 1): DIVU -> 0xFFFFFFFF, REMU -> A
        (res, stat) = await runOp(0x12345678, 0, MathAccelerator.cmdDivu);
        expect(res, equals(0xFFFFFFFF));
        expect(stat & 2, equals(2));
        (res, stat) = await runOp(0x12345678, 0, MathAccelerator.cmdRemu);
        expect(res, equals(0x12345678));
        expect(stat & 2, equals(2));

        // 10. Barrel shifts: SLL, SRL, SRA
        (res, stat) = await runOp(0x00000001, 4, MathAccelerator.cmdSll);
        expect(res, equals(16));
        expect(stat, equals(0));
        (res, stat) = await runOp(0x80000010, 4, MathAccelerator.cmdSrl);
        expect(res, equals(0x08000001));
        (res, stat) = await runOp(0x80000010, 4, MathAccelerator.cmdSra);
        expect(res, equals(0xF8000001));
      }

      await drive();
      await Simulator.endSimulation();
    });
  });
}

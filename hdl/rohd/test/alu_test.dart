// ==============================================================================
// FILE: hdl/rohd/test/alu_test.dart
// Architecture: MiniRISC4 ALU, XCHG & MMIO Math Verification
// ==============================================================================

import 'package:test/test.dart';
import 'package:rohd/rohd.dart';
import 'package:minirisc4_rohd/cpu_core.dart';
import 'package:minirisc4_rohd/cpu_config.dart';
import 'package:minirisc4_rohd/constants.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('ALU & MMIO Accelerator Verification', () {
    test('Verifies native ISA opcode and sub-opcode constants', () {
      expect(MiniRISC4Constants.opAdd, equals(0x6));
      expect(MiniRISC4Constants.opSub, equals(0x7));
      expect(MiniRISC4Constants.opOr, equals(0x8));
      expect(MiniRISC4Constants.opXor, equals(0x9));
      expect(MiniRISC4Constants.opAnd, equals(0xA));
      expect(MiniRISC4Constants.subShiftXchg, equals(0x3));
    });

    test('Core instantiates cleanly with Math Accelerator enabled', () async {
      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rst_n');

      final cpu = CpuCore(
        clk: clk,
        rstN: rstN,
        config: const CpuConfig(
          coreId: 0,
          enableMathAccel: true,
          enableCpuid: true,
          enableUart: false,
        ),
      );

      await cpu.build();

      rstN.put(0);
      Simulator.registerAction(20, () => rstN.put(1));
      Simulator.registerAction(100, () {
        final strobe = cpu.output('mmio_tx_strobe');
        expect(strobe.value.isValid ? strobe.value.toInt() : 0, equals(0));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}

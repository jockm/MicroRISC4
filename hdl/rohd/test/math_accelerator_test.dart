// ==============================================================================
// FILE: hdl/rohd/test/math_accelerator_test.dart
// ==============================================================================

import 'package:test/test.dart';
import 'package:rohd/rohd.dart';
import 'package:minirisc4_rohd/math_accelerator.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('MathAccelerator Hardware Tests', () {
    test('Combinational 32-bit Multiply (MUL)', () async {
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

      // Release reset
      Simulator.registerAction(12, () => rstN.put(1));

      // Cycle 2: A_LO = 6
      Simulator.registerAction(20, () {
        en.put(1);
        we.put(1);
        addr.put(0x0010);
        wdata.put(6);
      });

      // Cycle 3: A_HI = 0
      Simulator.registerAction(30, () {
        addr.put(0x0011);
        wdata.put(0);
      });

      // Cycle 4: B_LO = 7
      Simulator.registerAction(40, () {
        addr.put(0x0012);
        wdata.put(7);
      });

      // Cycle 5: B_HI = 0
      Simulator.registerAction(50, () {
        addr.put(0x0013);
        wdata.put(0);
      });

      // Cycle 6: Trigger MUL (CMD = 0)
      Simulator.registerAction(60, () {
        addr.put(0x0014);
        wdata.put(0);
      });

      // Cycle 7: Read RES_LO (0x0015) - en=1, we=0
      Simulator.registerAction(72, () {
        en.put(1);
        we.put(0);
        addr.put(0x0015);
      });

      Simulator.registerAction(80, () {
        expect(accel.rdata.value.isValid, isTrue);
        expect(accel.rdata.value.toInt(), equals(42));
      });

      // Cycle 8: Shift test: A_LO = 1, B_LO = 4, CMD = 8 (SLL)
      Simulator.registerAction(90, () {
        en.put(1);
        we.put(1);
        addr.put(0x0010);
        wdata.put(1);
      });
      Simulator.registerAction(100, () {
        addr.put(0x0012);
        wdata.put(4);
      });
      Simulator.registerAction(110, () {
        addr.put(0x0014);
        wdata.put(8); // SLL
      });

      // Cycle 9: Read shift result
      Simulator.registerAction(122, () {
        en.put(1);
        we.put(0);
        addr.put(0x0015);
      });

      Simulator.registerAction(130, () {
        expect(accel.rdata.value.isValid, isTrue);
        expect(accel.rdata.value.toInt(), equals(16));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}

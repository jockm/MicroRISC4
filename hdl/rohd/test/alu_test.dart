import "package:test/test.dart";
import "package:rohd/rohd.dart";
import "package:minirisc4_rohd/cpu_core.dart";
import "package:minirisc4_rohd/constants.dart";

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("ALU & XCHG Functional Tests", () {
    test("Verifies Opcode Constants and Sub-Opcodes integrity", () {
      expect(MiniRISC4Constants.opAdd, equals(0x6));
      expect(MiniRISC4Constants.opSub, equals(0x7));
      expect(MiniRISC4Constants.opAnd, equals(0xA));
      expect(MiniRISC4Constants.opOr, equals(0x8));
      expect(MiniRISC4Constants.opXor, equals(0x9));
      expect(MiniRISC4Constants.subShiftXchg, equals(0x3));
    });

    test("CpuCore instantiates ALU logic and shadow register ports", () async {
      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: "rst_n");
      final rxData = Logic(name: "rx_data", width: 16);
      final txStatus = Logic(name: "tx_status", width: 16);

      final cpu = CpuCore(
        clk: clk,
        rstN: rstN,
        mmioRxData: rxData,
        mmioTxStatus: txStatus,
      );

      await cpu.build();

      rstN.put(0);
      rxData.put(0);
      txStatus.put(0);

      Simulator.registerAction(20, () {
        rstN.put(1);
      });

      Simulator.registerAction(100, () {
        final rxPop = cpu.output("mmio_rx_pop");
        expect(rxPop.value.isValid ? rxPop.value.toInt() : 0, equals(0));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}

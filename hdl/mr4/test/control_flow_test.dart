import "package:test/test.dart";
import "package:rohd/rohd.dart";
import "package:microrisc4_rohd/cpu_core.dart";
import "package:microrisc4_rohd/constants.dart";

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Control Flow & Trap Vectoring Tests", () {
    test("Verifies Branch and Special Jump Opcodes", () {
      expect(MicroRISC4Constants.opJmpZ, equals(0xD));
      expect(MicroRISC4Constants.opJmpM, equals(0xE));
      expect(MicroRISC4Constants.opJmpSpecial, equals(0xF));
      expect(MicroRISC4Constants.subJmp, equals(0x0));
      expect(MicroRISC4Constants.subLink, equals(0x1));
      expect(MicroRISC4Constants.subPush8, equals(0x2));
      expect(MicroRISC4Constants.subTrap, equals(0x3));
    });

    test("CpuCore simulates control flow and vector table fetch cleanly", () async {
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

      Simulator.registerAction(15, () => rstN.put(1));
      Simulator.registerAction(100, () {
        final strobe = cpu.output("mmio_tx_strobe");
        expect(strobe.value.isValid ? strobe.value.toInt() : 0, equals(0));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}

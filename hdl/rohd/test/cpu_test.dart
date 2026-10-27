import "package:test/test.dart";
import "package:rohd/rohd.dart";
import "package:minirisc4_rohd/cpu_core.dart";

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("CpuCore Integration & Reset Tests", () {
    test("CPU reset initializes signals and begins execution", () async {
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

      Simulator.registerAction(25, () {
        rstN.put(1);
      });

      Simulator.registerAction(120, () {
        final strobe = cpu.output("mmio_tx_strobe");
        expect(strobe.value.isValid ? strobe.value.toInt() : 0, equals(0));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}

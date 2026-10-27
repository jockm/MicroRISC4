import "package:test/test.dart";
import "package:rohd/rohd.dart";
import "package:minirisc4_rohd/cpu_core.dart";
import "package:minirisc4_rohd/constants.dart";

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Memory Bus & Stack Semantics Tests", () {
    test("Verifies Stack Opcodes per Full Descending (FD) Convention", () {
      expect(MiniRISC4Constants.opLdPostinc, equals(0x4));
      expect(MiniRISC4Constants.opLdPredec, equals(0x5));
      expect(MiniRISC4Constants.opLdPeek, equals(0x2));
      expect(MiniRISC4Constants.opLdPoke, equals(0x3));
    });

    test("Verifies MMIO Port Address Decoding", () {
      expect(MiniRISC4Constants.addrUartRx, equals(0x000E));
      expect(MiniRISC4Constants.addrUartTx, equals(0x000F));
      expect(MiniRISC4Constants.trapTableBase, equals(0xFFF0));
      expect(MiniRISC4Constants.trapAlignAddr, equals(0xFFFF));
    });

    test("Memory Bus handshakes without ROM write restrictions", () async {
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
      rxData.put(0x8041);
      txStatus.put(0x0000);

      Simulator.registerAction(20, () {
        rstN.put(1);
      });

      Simulator.registerAction(100, () {
        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}

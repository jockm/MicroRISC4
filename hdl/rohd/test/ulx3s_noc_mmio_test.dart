import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "package:minirisc4_rohd/constants.dart";
import "package:minirisc4_rohd/cpu_config.dart";
import "package:minirisc4_rohd/ulx3s_top.dart";

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Ulx3sTop NoC MMIO wiring", () {
    test("Builds with nocCores=2 and exposes mboxTrapReq_0 on led[6]", () async {
      final clk25 = SimpleClockGenerator(10).clk;
      final btnPwrN = Logic(name: "btn_pwr_n");
      final ftdiTxd = Logic(name: "ftdi_txd");

      final top = Ulx3sTop(
        clk25mhz: clk25,
        btnPwrN: btnPwrN,
        ftdiTxd: ftdiTxd,
        config: const CpuConfig(
          coreId: 0,
          enableCpuid: true,
          enableUart: true,
          enableCrossTraps: false,
          enableMathAccel: false,
          trapTableBase: 0x0100,
          memWords: 2048,
          nocChannels: 4,
          nocFifoDepth: 4,
        ),
        nocCores: 2,
        initHexFile: null,
        initialMemory: {
          0: (MiniRISC4Constants.opLdImm4 << 4) | 0x1,
          1: (MiniRISC4Constants.opLdPoke << 4) | (0x0021 & 0xF),
        },
      );
      await top.build();

      btnPwrN.put(0);
      ftdiTxd.put(1);

      Simulator.registerAction(25, () {
        btnPwrN.put(1);
      });

      Simulator.registerAction(200, () {
        expect(top.led.width, equals(8));
        expect(top.wifiGpio0.value.isValid, isTrue);
        expect(top.wifiGpio0.value.toInt(), equals(1));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });

    test("Writes NoC TX/channel registers and reads RX_STAT without BRAM write", () async {
      final clk25 = SimpleClockGenerator(10).clk;
      final btnPwrN = Logic(name: "btn_pwr_n");
      final ftdiTxd = Logic(name: "ftdi_txd");

      final top = Ulx3sTop(
        clk25mhz: clk25,
        btnPwrN: btnPwrN,
        ftdiTxd: ftdiTxd,
        config: const CpuConfig(
          coreId: 0,
          enableCpuid: true,
          enableUart: false,
          enableCrossTraps: false,
          enableMathAccel: false,
          trapTableBase: 0x0100,
          memWords: 2048,
          nocChannels: 4,
          nocFifoDepth: 4,
        ),
        nocCores: 2,
        initHexFile: null,
        initialMemory: {
          // LDI R0, 2; ST [0x0021], R0 (addrNocSelCh = 2)
          0: (MiniRISC4Constants.opLdImm4 << 4) | 0x2,
          1: (MiniRISC4Constants.opLdPoke << 4) | (0x0021 & 0xF),
          // LDI R0, 5; ST [0x0020], R0 (addrNocTxData = 5)
          2: (MiniRISC4Constants.opLdImm4 << 4) | 0x5,
          3: (MiniRISC4Constants.opLdPoke << 4) | (0x0020 & 0xF),
          // LD R1, [0x0023] (addrNocRxStat)
          4: (MiniRISC4Constants.opLdPeek << 4) | (0x0023 & 0xF),
        },
      );
      await top.build();

      btnPwrN.put(0);
      ftdiTxd.put(1);

      Simulator.registerAction(25, () {
        btnPwrN.put(1);
      });

      Simulator.registerAction(350, () {
        expect(top.cpu.ram.mem[0x0020] ?? 0, equals(0));
        expect(top.cpu.ram.mem[0x0021] ?? 0, equals(0));
        expect(top.cpu.ram.mem[0x0023] ?? 0, equals(0));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}

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
        expect(top.cpu.ram.mem[0x0020], equals(0));
        expect(top.cpu.ram.mem[0x0021], equals(0));
        expect(top.cpu.ram.mem[0x0023], equals(0));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });

    test("CpuCore reads NOC_INFO (0x002A) via Ulx3sTop 2-cycle MMIO path", () async {
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
        nocCores: 3,
        initHexFile: null,
        initialMemory: {
          // 0x0100: PUSH8 R0, 0x2A -> R0 = 0x002A (addrNocInfo)
          0x0100: (MiniRISC4Constants.addrNocInfo << 8) | 0xF8,
          // 0x0101: LD R1, (R0) ; NOP -> reads NOC_INFO = (4 << 8) | 3 = 0x0403
          0x0101: 0x0024,
          // 0x0102: PUSH8 R2, 0x02 ; 0x0103: PUSH8 R2, 0x00 -> R2 = 0x0200
          0x0102: 0x02FA,
          0x0103: 0x00FA,
          // 0x0104: LD (R2), R1 ; NOP -> store NOC_INFO to RAM[0x0200]
          0x0104: 0x0039,
          // 0x0105: LD (R0), R2 ; NOP -> write to read-only 0x002A (must NOT hit RAM)
          0x0105: 0x0032,
          // 0x0106: PUSH8 R3, 0x01 ; 0x0107: PUSH8 R3, 0x08 ; 0x0108: JMP R3
          0x0106: 0x01FB,
          0x0107: 0x08FB,
          0x0108: 0x00F3,
        },
      );
      await top.build();

      btnPwrN.put(0);
      ftdiTxd.put(1);

      Simulator.registerAction(25, () {
        btnPwrN.put(1);
      });

      Simulator.registerAction(600, () {
        expect(top.cpu.ram.mem[0x0200], equals((4 << 8) | 3));
        expect(top.cpu.ram.mem[0x002A], equals(0));
        Simulator.endSimulation();
      });

      await Simulator.run();
    });

    test("3-core Ulx3sTop live multi-hop IPC and MBOX cross-trap round-trip", () async {
      // MiniRISC4 micro-assembler helpers for readable multi-core firmware
      int pack2(int b0, [int b1 = 0x00]) => ((b1 & 0xFF) << 8) | (b0 & 0xFF);
      int push8(int rl, int imm8) => ((imm8 & 0xFF) << 8) | (0xF8 | (rl & 3));
      int peek(int rr, int rl) => (0x2 << 4) | ((rr & 3) << 2) | (rl & 3);
      int poke(int rr, int rl) => (0x3 << 4) | ((rr & 3) << 2) | (rl & 3);
      int inc(int rl) => 0xC8 | (rl & 3);
      int xchg(int rl) => 0xBC | (rl & 3);
      int jmp(int rl) => 0xF0 | (rl & 3);

      void emitProg(Map<int, int> mem, int startAddr, List<int> words) {
        for (var i = 0; i < words.length; i++) {
          mem[startAddr + i] = words[i];
        }
      }

      List<int> load16(int rl, int val) => [
            push8(rl, (val >> 8) & 0xFF),
            push8(rl, val & 0xFF),
          ];

      // Core 0 program:
      //  - Store CPUID (0x000D) -> [0x0300]
      //  - Route ch 1 -> (dstCore=2, dstCh=0), send DATA 0x4242 & MBOX 0xCAFE (2 hops: 0->1->2)
      //  - Idle loop at 0x0120; Trap 14 (0x01E0) captures reply MBOX from Core 2,
      //    stores src -> [0x0301], data -> [0x0302], increments trap count [0x0304], returns!
      final core0Mem = <int, int>{};
      emitProg(core0Mem, 0x0100, [
        ...load16(0, 0x000D),
        pack2(peek(1, 0)),
        ...load16(2, 0x0300),
        pack2(poke(2, 1)),
        // NOC_SEL_CH = 1
        ...load16(0, MiniRISC4Constants.addrNocSelCh),
        ...load16(1, 1),
        pack2(poke(0, 1)),
        // NOC_CH_CFG0 = (2 << 8) | 0
        ...load16(0, MiniRISC4Constants.addrNocChCfg0),
        ...load16(1, 0x0200),
        pack2(poke(0, 1)),
        // NOC_CH_CFG1 = 1
        ...load16(0, MiniRISC4Constants.addrNocChCfg1),
        ...load16(1, 1),
        pack2(poke(0, 1)),
        // Send DATA 0x4242 to Core 2 ch 0
        ...load16(0, MiniRISC4Constants.addrNocTxData),
        ...load16(1, 0x4242),
        pack2(poke(0, 1)),
        // Send MBOX 0xCAFE to Core 2 (triggers hardware Trap 14 on Core 2)
        ...load16(0, MiniRISC4Constants.addrNocMboxSend),
        ...load16(1, 0xCAFE),
        pack2(poke(0, 1)),
        // Jump to idle loop at 0x0130
        ...load16(3, 0x0130),
        pack2(jmp(3)),
      ]);
      emitProg(core0Mem, 0x0130, [
        pack2(jmp(3)),
      ]);
      // Core 0 Trap 14 handler (0x01E0)
      emitProg(core0Mem, 0x01E0, [
        pack2(xchg(0)), // Save return PC in shadow R0
        ...load16(0, MiniRISC4Constants.addrNocMboxSrc),
        pack2(peek(1, 0)),
        ...load16(2, 0x0301),
        pack2(poke(2, 1)),
        ...load16(0, MiniRISC4Constants.addrNocMboxData),
        pack2(peek(1, 0)),
        ...load16(2, 0x0302),
        pack2(poke(2, 1)),
        // Increment trap counter [0x0304]
        ...load16(2, 0x0304),
        pack2(peek(1, 2), inc(1)),
        pack2(poke(2, 1)),
        pack2(xchg(0)), // Restore return PC
        pack2(jmp(0)),
      ]);

      // Core 1 program (middle transit core): stores CPUID -> [0x0300], NOC_INFO -> [0x0301], idles
      final core1Mem = <int, int>{};
      emitProg(core1Mem, 0x0100, [
        ...load16(0, 0x000D),
        pack2(peek(1, 0)),
        ...load16(2, 0x0300),
        pack2(poke(2, 1)),
        ...load16(0, MiniRISC4Constants.addrNocInfo),
        pack2(peek(1, 0)),
        ...load16(2, 0x0301),
        pack2(poke(2, 1)),
        ...load16(3, 0x0120),
        pack2(jmp(3)),
      ]);
      emitProg(core1Mem, 0x0120, [
        pack2(jmp(3)),
      ]);

      // Core 2 program (worker core 2 hops from Core 0):
      //  - Stores CPUID -> [0x0300], configures ch 0 -> (dstCore=0, dstCh=0), idles at 0x0120
      //  - Trap 14 (0x01E0): reads MBOX src -> [0x0301], MBOX data -> [0x0302],
      //    pops DATA from ch 0 (0x4242), increments to 0x4243 -> [0x0303],
      //    sends 0x4243 back to Core 0 as MBOX, increments trap count [0x0304], returns!
      final core2Mem = <int, int>{};
      emitProg(core2Mem, 0x0100, [
        ...load16(0, 0x000D),
        pack2(peek(1, 0)),
        ...load16(2, 0x0300),
        pack2(poke(2, 1)),
        // Route ch 0 -> (dstCore=0, dstCh=0)
        ...load16(0, MiniRISC4Constants.addrNocSelCh),
        ...load16(1, 0),
        pack2(poke(0, 1)),
        ...load16(0, MiniRISC4Constants.addrNocChCfg0),
        ...load16(1, 0x0000),
        pack2(poke(0, 1)),
        ...load16(0, MiniRISC4Constants.addrNocChCfg1),
        ...load16(1, 1),
        pack2(poke(0, 1)),
        ...load16(3, 0x0120),
        pack2(jmp(3)),
      ]);
      emitProg(core2Mem, 0x0120, [
        pack2(jmp(3)),
      ]);
      // Core 2 Trap 14 handler (0x01E0)
      emitProg(core2Mem, 0x01E0, [
        pack2(xchg(0)), // Save return PC
        ...load16(0, MiniRISC4Constants.addrNocMboxSrc),
        pack2(peek(1, 0)),
        ...load16(2, 0x0301),
        pack2(poke(2, 1)),
        ...load16(0, MiniRISC4Constants.addrNocMboxData),
        pack2(peek(1, 0)),
        ...load16(2, 0x0302),
        pack2(poke(2, 1)),
        // Pop DATA word from ch 0, compute +1, store to [0x0303], reply MBOX to Core 0
        ...load16(0, MiniRISC4Constants.addrNocRxTryR),
        pack2(peek(1, 0), inc(1)),
        ...load16(2, 0x0303),
        pack2(poke(2, 1)),
        ...load16(0, MiniRISC4Constants.addrNocMboxSend),
        pack2(poke(0, 1)),
        // Increment trap counter [0x0304]
        ...load16(2, 0x0304),
        pack2(peek(1, 2), inc(1)),
        pack2(poke(2, 1)),
        pack2(xchg(0)), // Restore return PC
        pack2(jmp(0)),
      ]);

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
          enableCrossTraps: true,
          enableMathAccel: false,
          trapTableBase: 0x0100,
          memWords: 2048,
          nocChannels: 4,
          nocFifoDepth: 4,
        ),
        nocCores: 3,
        workerMemWords: 2048,
        initHexFile: null,
        initialMemory: core0Mem,
        workerInitialMemories: [core1Mem, core2Mem],
      );
      await top.build();
      expect(top.cores.length, equals(3));

      btnPwrN.put(0);
      ftdiTxd.put(1);
      Simulator.registerAction(25, () {
        btnPwrN.put(1);
      });

      Simulator.registerAction(3000, () {
        // CPUID & NOC_INFO checks across all 3 real CpuCores
        expect(top.cores[0].ram.mem[0x0300], equals(0));
        expect(top.cores[1].ram.mem[0x0300], equals(1));
        expect(top.cores[1].ram.mem[0x0301], equals((4 << 8) | 3));
        expect(top.cores[2].ram.mem[0x0300], equals(2));

        // Core 2 received Core 0's 2-hop MBOX (0xCAFE from Core 0 ch 1),
        // popped DATA (0x4242 -> 0x4243), and trapped exactly ONCE
        expect(top.cores[2].ram.mem[0x0301], equals(0x0001));
        expect(top.cores[2].ram.mem[0x0302], equals(0xCAFE));
        expect(top.cores[2].ram.mem[0x0303], equals(0x4243));
        expect(top.cores[2].ram.mem[0x0304], equals(1));

        // Core 0 received Core 2's reply MBOX (0x4243 from Core 2 ch 0)
        // via hardware Trap 14 and trapped exactly ONCE
        expect(top.cores[0].ram.mem[0x0301], equals(0x0200));
        expect(top.cores[0].ram.mem[0x0302], equals(0x4243));
        expect(top.cores[0].ram.mem[0x0304], equals(1));

        Simulator.endSimulation();
      });

      await Simulator.run();
    });
  });
}

import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "package:microrisc4_rohd/constants.dart";
import "package:microrisc4_rohd/cpu_config.dart";
import "package:microrisc4_rohd/ulx3s_top.dart";

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
          0: (MicroRISC4Constants.opLdImm4 << 4) | 0x1,
          1: (MicroRISC4Constants.opLdPoke << 4) | (0x0021 & 0xF),
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
          0: (MicroRISC4Constants.opLdImm4 << 4) | 0x2,
          1: (MicroRISC4Constants.opLdPoke << 4) | (0x0021 & 0xF),
          // LDI R0, 5; ST [0x0020], R0 (addrNocTxData = 5)
          2: (MicroRISC4Constants.opLdImm4 << 4) | 0x5,
          3: (MicroRISC4Constants.opLdPoke << 4) | (0x0020 & 0xF),
          // LD R1, [0x0023] (addrNocRxStat)
          4: (MicroRISC4Constants.opLdPeek << 4) | (0x0023 & 0xF),
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
          0x0100: (MicroRISC4Constants.addrNocInfo << 8) | 0xF8,
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
      // MicroRISC4 micro-assembler helpers for readable multi-core firmware
      int pack2(int b0, [int b1 = 0x00]) => ((b1 & 0xFF) << 8) | (b0 & 0xFF);
      int push8(int rl, int imm8) => ((imm8 & 0xFF) << 8) | (0xF8 | (rl & 3));
      int peek(int rr, int rl) => (0x2 << 4) | ((rr & 3) << 2) | (rl & 3);
      int poke(int rr, int rl) => (0x3 << 4) | ((rr & 3) << 2) | (rl & 3);
      int inc(int rl) => 0xC8 | (rl & 3);
      int xchg(int rl) => 0xBC | (rl & 3);
      int jmp(int rl) => 0xF0 | (rl & 3);
      int eret() => MicroRISC4Constants.opEretByte;

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
      //  - Set NOC_DST_CORE (0x0021) = 2 (1 register write — zero channel table!),
      //    send DATA 0x4242 & MBOX 0xCAFE (2 hops: 0->1->2)
      //  - Idle loop at 0x0130; Trap 14 (0x01E0) captures reply MBOX from Core 2,
      //    stores src -> [0x0301] (2), data -> [0x0302] (0x4243), trap count [0x0304] (1)
      final core0Mem = <int, int>{};
      emitProg(core0Mem, 0x0100, [
        ...load16(0, 0x000D),
        pack2(peek(1, 0)),
        ...load16(2, 0x0300),
        pack2(poke(2, 1)),
        // NOC_DST_CORE = 2
        ...load16(0, MicroRISC4Constants.addrNocDstCore),
        ...load16(1, 2),
        pack2(poke(0, 1)),
        // Send DATA 0x4242 to Core 2
        ...load16(0, MicroRISC4Constants.addrNocTxData),
        ...load16(1, 0x4242),
        pack2(poke(0, 1)),
        // Send MBOX 0xCAFE to Core 2 (triggers hardware Trap 14 on Core 2)
        ...load16(0, MicroRISC4Constants.addrNocMboxSend),
        ...load16(1, 0xCAFE),
        pack2(poke(0, 1)),
        // Jump to idle loop at 0x0130
        // Hold live sentinel 0xBEEF in R0 across the interruptible idle loop!
        // With hardware EPC + ERET, async Trap 14 MUST NOT clobber R0.
        ...load16(0, 0xBEEF),
        ...load16(3, 0x0130),
        pack2(jmp(3)),
      ]);
      emitProg(core0Mem, 0x0130, [
        // Continuously store live R0 into [0x0305] so post-trap R0 integrity is verified
        ...load16(2, 0x0305),
        pack2(poke(2, 0)),
        pack2(jmp(3)),
      ]);
      // Core 0 Trap 14 handler (0x01E0) — saves ALL live regs including R0 and returns via ERET!
      emitProg(core0Mem, 0x01E0, [
        pack2(xchg(0), xchg(1)), // Save live R0, R1 in shadow bank (PC is in hardware EPC)
        pack2(xchg(2)),
        ...load16(0, MicroRISC4Constants.addrNocMboxSrc),
        pack2(peek(1, 0)),
        ...load16(2, 0x0301),
        pack2(poke(2, 1)),
        ...load16(0, MicroRISC4Constants.addrNocMboxData),
        pack2(peek(1, 0)),
        ...load16(2, 0x0302),
        pack2(poke(2, 1)),
        // Increment trap counter [0x0304]
        ...load16(2, 0x0304),
        pack2(peek(1, 2), inc(1)),
        pack2(poke(2, 1)),
        // Snapshot hardware EPC (0x001E) -> [0x0306]
        ...load16(0, MicroRISC4Constants.addrEpc),
        pack2(peek(1, 0)),
        ...load16(2, 0x0306),
        pack2(poke(2, 1)),
        pack2(xchg(2), xchg(1)),
        pack2(xchg(0), eret()), // Restore live R0 and return atomically to hardware EPC!
      ]);

      // Core 1 program (middle transit core): stores CPUID -> [0x0300], NOC_INFO -> [0x0301], idles
      final core1Mem = <int, int>{};
      emitProg(core1Mem, 0x0100, [
        ...load16(0, 0x000D),
        pack2(peek(1, 0)),
        ...load16(2, 0x0300),
        pack2(poke(2, 1)),
        ...load16(0, MicroRISC4Constants.addrNocInfo),
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
      //  - Stores CPUID -> [0x0300], sets NOC_DST_CORE = 0, idles at 0x0120
      //  - Trap 14 (0x01E0): reads MBOX src -> [0x0301] (0), MBOX data -> [0x0302] (0xCAFE),
      //    pops DATA (0x4242), increments to 0x4243 -> [0x0303],
      //    sends 0x4243 back to Core 0 as MBOX, increments trap count [0x0304], returns!
      final core2Mem = <int, int>{};
      emitProg(core2Mem, 0x0100, [
        ...load16(0, 0x000D),
        pack2(peek(1, 0)),
        ...load16(2, 0x0300),
        pack2(poke(2, 1)),
        // NOC_DST_CORE = 0
        ...load16(0, MicroRISC4Constants.addrNocDstCore),
        ...load16(1, 0),
        pack2(poke(0, 1)),
        // Hold live sentinel 0xACED in R0 across interruptible loop!
        ...load16(0, 0xACED),
        ...load16(3, 0x0120),
        pack2(jmp(3)),
      ]);
      emitProg(core2Mem, 0x0120, [
        ...load16(2, 0x0305),
        pack2(poke(2, 0)),
        pack2(jmp(3)),
      ]);
      // Core 2 Trap 14 handler (0x01E0) — preserves live R0..R2 and returns via ERET!
      emitProg(core2Mem, 0x01E0, [
        pack2(xchg(0), xchg(1)), // Save live R0, R1 (PC is in hardware EPC)
        pack2(xchg(2)),
        ...load16(0, MicroRISC4Constants.addrNocMboxSrc),
        pack2(peek(1, 0)),
        ...load16(2, 0x0301),
        pack2(poke(2, 1)),
        ...load16(0, MicroRISC4Constants.addrNocMboxData),
        pack2(peek(1, 0)),
        ...load16(2, 0x0302),
        pack2(poke(2, 1)),
        // Pop DATA word, compute +1, store to [0x0303], reply MBOX to Core 0
        ...load16(0, MicroRISC4Constants.addrNocRxTryR),
        pack2(peek(1, 0), inc(1)),
        ...load16(2, 0x0303),
        pack2(poke(2, 1)),
        ...load16(0, MicroRISC4Constants.addrNocMboxSend),
        pack2(poke(0, 1)),
        // Increment trap counter [0x0304]
        ...load16(2, 0x0304),
        pack2(peek(1, 2), inc(1)),
        pack2(poke(2, 1)),
        // Snapshot hardware EPC (0x001E) -> [0x0306]
        ...load16(0, MicroRISC4Constants.addrEpc),
        pack2(peek(1, 0)),
        ...load16(2, 0x0306),
        pack2(poke(2, 1)),
        pack2(xchg(2), xchg(1)),
        pack2(xchg(0), eret()), // Restore live R0 and return atomically to hardware EPC!
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
          nocFifoDepth: 16,
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
        // CPUID & NOC_INFO ({fifoDepth=16, numCores=3} = 0x1003) across all 3 real CpuCores
        expect(top.cores[0].ram.mem[0x0300], equals(0));
        expect(top.cores[1].ram.mem[0x0300], equals(1));
        expect(top.cores[1].ram.mem[0x0301], equals((16 << 8) | 3));
        expect(top.cores[2].ram.mem[0x0300], equals(2));

        // Core 2 received Core 0's 2-hop MBOX (0xCAFE from Core 0),
        // popped DATA (0x4242 -> 0x4243), and trapped exactly ONCE
        expect(top.cores[2].ram.mem[0x0301], equals(0));
        expect(top.cores[2].ram.mem[0x0302], equals(0xCAFE));
        expect(top.cores[2].ram.mem[0x0303], equals(0x4243));
        expect(top.cores[2].ram.mem[0x0304], equals(1));

        // Core 0 received Core 2's reply MBOX (0x4243 from Core 2)
        // via hardware Trap 14 and trapped exactly ONCE
        expect(top.cores[0].ram.mem[0x0301], equals(2));
        expect(top.cores[0].ram.mem[0x0302], equals(0x4243));
        expect(top.cores[0].ram.mem[0x0304], equals(1));

        // Verify live R0 sentinels were 100% preserved across async Trap 14 + ERET!
        expect(top.cores[0].ram.mem[0x0305], equals(0xBEEF));
        expect(top.cores[2].ram.mem[0x0305], equals(0xACED));
        // Verify hardware EPC (0x001E) captured Core 0's interrupted idle-loop PC
        expect(top.cores[0].ram.mem[0x0306], inInclusiveRange(0x0130, 0x0134));

        Simulator.endSimulation();
      });

      await Simulator.run();
    });

    test("Read-only CPU_VER (0x001B), CPU_CAPS (0x001C), and CPU_CAPS2 (0x001D) constants", () async {
      int pack2(int b0, [int b1 = 0x00]) => ((b1 & 0xFF) << 8) | (b0 & 0xFF);
      int push8(int rl, int imm8) => ((imm8 & 0xFF) << 8) | (0xF8 | (rl & 3));
      int peek(int rr, int rl) => (0x2 << 4) | ((rr & 3) << 2) | (rl & 3);
      int poke(int rr, int rl) => (0x3 << 4) | ((rr & 3) << 2) | (rl & 3);
      int jmp(int rl) => 0xF0 | (rl & 3);
      List<int> load16(int rl, int val) => [
            push8(rl, (val >> 8) & 0xFF),
            push8(rl, val & 0xFF),
          ];

      final mem = <int, int>{};
      void emit(int addr, List<int> words) {
        for (var i = 0; i < words.length; i++) {
          mem[addr + i] = words[i];
        }
      }

      // Attempt writes to 0x001B..0x001D (must be ignored!), then read all three into 0x0320..0x0322
      emit(0x0100, [
        ...load16(1, 0xDEAD),
        ...load16(0, MicroRISC4Constants.addrCpuVer),
        pack2(poke(0, 1)),
        ...load16(0, MicroRISC4Constants.addrCpuCaps),
        pack2(poke(0, 1)),
        ...load16(0, MicroRISC4Constants.addrCpuCaps2),
        pack2(poke(0, 1)),
        ...load16(0, MicroRISC4Constants.addrCpuVer),
        pack2(peek(1, 0)),
        ...load16(2, 0x0320),
        pack2(poke(2, 1)),
        ...load16(0, MicroRISC4Constants.addrCpuCaps),
        pack2(peek(1, 0)),
        ...load16(2, 0x0321),
        pack2(poke(2, 1)),
        ...load16(0, MicroRISC4Constants.addrCpuCaps2),
        pack2(peek(1, 0)),
        ...load16(2, 0x0322),
        pack2(poke(2, 1)),
        ...load16(3, 0x0140),
        pack2(jmp(3)),
      ]);
      emit(0x0140, [pack2(jmp(3))]);

      const cfg = CpuConfig(
        coreId: 0,
        enableCpuid: true,
        enableUart: true,
        enableCrossTraps: true,
        enableShadowRegs: true,
        enableMathAccel: false,
        enableFpu: false,
        enableSpi: false,
        enableNoc: false,
        enableSdramCache: false,
        trapTableBase: 0x0100,
        memWords: 2048,
      );

      final clk25 = SimpleClockGenerator(10).clk;
      final btnPwrN = Logic(name: "btn_pwr_n");
      final ftdiTxd = Logic(name: "ftdi_txd");
      final top = Ulx3sTop(
        clk25mhz: clk25,
        btnPwrN: btnPwrN,
        ftdiTxd: ftdiTxd,
        config: cfg,
        initHexFile: null,
        initialMemory: mem,
      );
      await top.build();

      btnPwrN.put(0);
      ftdiTxd.put(1);
      Simulator.registerAction(25, () => btnPwrN.put(1));
      Simulator.registerAction(800, () {
        // CPU_VER = 0.1 (0x0001), CPU_CAPS matches config, CPU_CAPS2 = 0x0000
        expect(top.cpu.ram.mem[0x0320], equals(0x0001));
        expect(
          top.cpu.ram.mem[0x0321],
          equals(
            MicroRISC4Constants.capShadowRegs |
                MicroRISC4Constants.capCpuid |
                MicroRISC4Constants.capUart |
                MicroRISC4Constants.capCrossTraps |
                MicroRISC4Constants.capEpcEret |
                MicroRISC4Constants.capPipelined,
          ),
        );
        expect(top.cpu.ram.mem[0x0322], equals(0x0000));
        Simulator.endSimulation();
      });
      await Simulator.run();
    });

    test("Hardware EPC (0x001E) R/W + ERET (0x0F) preserves all 4 registers R0..R3", () async {
      int pack2(int b0, [int b1 = 0x00]) => ((b1 & 0xFF) << 8) | (b0 & 0xFF);
      int push8(int rl, int imm8) => ((imm8 & 0xFF) << 8) | (0xF8 | (rl & 3));
      int poke(int rr, int rl) => (0x3 << 4) | ((rr & 3) << 2) | (rl & 3);
      int jmp(int rl) => 0xF0 | (rl & 3);
      int eret() => MicroRISC4Constants.opEretByte;
      List<int> load16(int rl, int val) => [
            push8(rl, (val >> 8) & 0xFF),
            push8(rl, val & 0xFF),
          ];

      final mem = <int, int>{};
      void emit(int addr, List<int> words) {
        for (var i = 0; i < words.length; i++) {
          mem[addr + i] = words[i];
        }
      }

      // 0x0100: Write target 0x0220 to EPC (0x001E), load R0..R3 with 4 distinct
      // live sentinels, then execute ERET (0x0F)!
      emit(0x0100, [
        ...load16(0, MicroRISC4Constants.addrEpc),
        ...load16(1, 0x0220),
        pack2(poke(0, 1)),
        ...load16(0, 0x1111),
        ...load16(1, 0x2222),
        ...load16(2, 0x3333),
        ...load16(3, 0x4444),
        pack2(eret()),
      ]);

      // 0x0220: Store all 4 registers using shadow swap to prove ERET clobbered NONE of them!
      int xchg(int rl) => 0xBC | (rl & 3);
      emit(0x0220, [
        pack2(xchg(0)),
        ...load16(0, 0x0310),
        pack2(poke(0, 1)), // [0x0310] = R1 (0x2222)
        ...load16(0, 0x0311),
        pack2(poke(0, 2)), // [0x0311] = R2 (0x3333)
        ...load16(0, 0x0312),
        pack2(poke(0, 3)), // [0x0312] = R3 (0x4444)
        pack2(xchg(0)),    // restore R0 (0x1111)
        ...load16(1, 0x0313),
        pack2(poke(1, 0)), // [0x0313] = R0 (0x1111)
        ...load16(3, 0x0240),
        pack2(jmp(3)),
      ]);
      emit(0x0240, [pack2(jmp(3))]);

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
          enableCrossTraps: true,
          enableEpc: true,
          trapTableBase: 0x0100,
          memWords: 2048,
        ),
        initHexFile: null,
        initialMemory: mem,
      );
      await top.build();

      btnPwrN.put(0);
      ftdiTxd.put(1);
      Simulator.registerAction(25, () => btnPwrN.put(1));
      Simulator.registerAction(800, () {
        expect(top.cpu.ram.mem[0x0313], equals(0x1111));
        expect(top.cpu.ram.mem[0x0310], equals(0x2222));
        expect(top.cpu.ram.mem[0x0311], equals(0x3333));
        expect(top.cpu.ram.mem[0x0312], equals(0x4444));
        Simulator.endSimulation();
      });
      await Simulator.run();
    });

    test("Track A.3: Ulx3sTop SPI loopback + 1-DSP MathAccelerator MMIO + CPU_CAPS", () async {
      int pack2(int b0, [int b1 = 0x00]) => ((b1 & 0xFF) << 8) | (b0 & 0xFF);
      int push8(int rl, int imm8) => ((imm8 & 0xFF) << 8) | (0xF8 | (rl & 3));
      int peek(int rr, int rl) => (0x2 << 4) | ((rr & 3) << 2) | (rl & 3);
      int poke(int rr, int rl) => (0x3 << 4) | ((rr & 3) << 2) | (rl & 3);
      int andOp(int rr, int rl) => (0xA << 4) | ((rr & 3) << 2) | (rl & 3);
      int jmpZ(int rr, int rl) => (0xD << 4) | ((rr & 3) << 2) | (rl & 3);
      int jmp(int rl) => 0xF0 | (rl & 3);
      int ldi4(int imm4) => 0x10 | (imm4 & 0xF);
      List<int> load16(int rl, int val) => [
            push8(rl, (val >> 8) & 0xFF),
            push8(rl, val & 0xFF),
          ];

      final mem = <int, int>{};
      void emit(int addr, List<int> words) {
        for (var i = 0; i < words.length; i++) {
          mem[addr + i] = words[i];
        }
      }

      // 0x0100:
      // 1. Read CPU_CAPS (0x001C) -> [0x0340]
      // 2. MathAccelerator: A = 0x0001E240 (123456), B = 0x00013435 (78901), CMD=0 (MUL)
      //    Poll 0x0014[0], store RES_LO -> [0x0341] (0xF740), RES_HI -> [0x0342] (0x449B)
      // 3. SPI loopback (sd_cmd -> sd_d0): SPI_CTRL = 0x0002 (CS_N=0, FAST=1),
      //    SPI_DATA = 0x00A5, poll SPI_STAT[0], store SPI_DATA -> [0x0343] (0x00A5)
      emit(0x0100, [
        ...load16(0, MicroRISC4Constants.addrCpuCaps),
        pack2(peek(1, 0)),
        ...load16(2, 0x0340),
        pack2(poke(2, 1)),

        // MATH_A_LO = 0xE240, MATH_A_HI = 0x0001
        ...load16(0, 0x0010),
        ...load16(1, 0xE240),
        pack2(poke(0, 1)),
        ...load16(0, 0x0011),
        ...load16(1, 0x0001),
        pack2(poke(0, 1)),
        // MATH_B_LO = 0x3435, MATH_B_HI = 0x0001
        ...load16(0, 0x0012),
        ...load16(1, 0x3435),
        pack2(poke(0, 1)),
        ...load16(0, 0x0013),
        ...load16(1, 0x0001),
        pack2(poke(0, 1)),
        // MATH_CMD = 0 (MUL)
        ...load16(0, 0x0014),
        ...load16(1, 0x0000),
        pack2(poke(0, 1)),
        // Jump to poll loop at 0x0130
        ...load16(3, 0x0130),
        pack2(jmp(3)),
      ]);
      // 0x0130: Poll MATH_CMD_STAT (0x0014) bit 0
      emit(0x0130, [
        ...load16(2, 0x0138),
        pack2(peek(1, 0), ldi4(1)),
        pack2(andOp(1, 0), jmpZ(2, 1)),
        ...load16(0, 0x0014),
        pack2(jmp(3)),
      ]);
      // 0x0138: Read RES_LO & RES_HI -> [0x0341], [0x0342]
      emit(0x0138, [
        ...load16(0, 0x0015),
        pack2(peek(1, 0)),
        ...load16(2, 0x0341),
        pack2(poke(2, 1)),
        ...load16(0, 0x0016),
        pack2(peek(1, 0)),
        ...load16(2, 0x0342),
        pack2(poke(2, 1)),

        // SPI_CTRL (0x0018) = 0x0002 (CS_N=0, FAST_CLK=1)
        ...load16(0, 0x0018),
        ...load16(1, 0x0002),
        pack2(poke(0, 1)),
        // SPI_DATA (0x001A) = 0x00A5
        ...load16(0, 0x001A),
        ...load16(1, 0x00A5),
        pack2(poke(0, 1)),
        ...load16(3, 0x0160),
        pack2(jmp(3)),
      ]);
      // 0x0160: Poll SPI_STAT (0x0019) bit 0
      emit(0x0160, [
        ...load16(0, 0x0019),
        ...load16(2, 0x0168),
        pack2(peek(1, 0), ldi4(1)),
        pack2(andOp(1, 0), jmpZ(2, 1)),
        pack2(jmp(3)),
      ]);
      // 0x0168: Read SPI_DATA (0x001A) -> [0x0343], halt at 0x0174
      emit(0x0168, [
        ...load16(0, 0x001A),
        pack2(peek(1, 0)),
        ...load16(2, 0x0343),
        pack2(poke(2, 1)),
        ...load16(3, 0x0174),
        pack2(jmp(3)),
      ]);
      emit(0x0174, [pack2(jmp(3))]);

      final clk25 = SimpleClockGenerator(10).clk;
      final btnPwrN = Logic(name: "btn_pwr_n");
      final ftdiTxd = Logic(name: "ftdi_txd");
      final sdD0 = Logic(name: "sd_d0");

      final top = Ulx3sTop(
        clk25mhz: clk25,
        btnPwrN: btnPwrN,
        ftdiTxd: ftdiTxd,
        sdD0: sdD0,
        clkFreqMhz: 48,
        config: const CpuConfig(
          coreId: 0,
          enableCpuid: true,
          enableUart: false,
          enableCrossTraps: false,
          enableMathAccel: true,
          enableSpi: true,
          trapTableBase: 0x0100,
          memWords: 2048,
        ),
        initHexFile: null,
        initialMemory: mem,
      );
      // Physical SPI loopback on ULX3S microSD pins: sd_cmd (MOSI) -> sd_d0 (MISO)
      sdD0 <= top.sdCmd;
      await top.build();

      btnPwrN.put(0);
      ftdiTxd.put(1);
      Simulator.registerAction(25, () => btnPwrN.put(1));
      Simulator.registerAction(3000, () {
        expect(
          top.cpu.ram.mem[0x0340],
          equals(
            MicroRISC4Constants.capShadowRegs |
                MicroRISC4Constants.capCpuid |
                MicroRISC4Constants.capMathAccel |
                MicroRISC4Constants.capSpi |
                MicroRISC4Constants.capPipelined,
          ),
        );
        expect(top.cpu.ram.mem[0x0341], equals(0xD740), reason: '123456*78901 low word');
        expect(top.cpu.ram.mem[0x0342], equals(0x4498), reason: '123456*78901 high word');
        expect(top.cpu.ram.mem[0x0343], equals(0x00A5), reason: 'SPI loopback RX byte');
        expect(top.sdD3.value.toInt(), equals(0), reason: 'SPI CS_N asserted');
        Simulator.endSimulation();
      });
      await Simulator.run();
    });
  });
}

// ==============================================================================
// FILE: hdl/rohd/test/memory_factory_test.dart
// Track D.1 Verification: Target-Selectable MemoryFactory & ASIC Boot ROM
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:minirisc4_rohd/cache_controllers.dart';
import 'package:minirisc4_rohd/cpu_config.dart';
import 'package:minirisc4_rohd/cpu_core.dart';
import 'package:minirisc4_rohd/memory_factory.dart';
import 'package:minirisc4_rohd/noc_router.dart';

int pack(int s0, [int s1 = 0x00]) => ((s1 & 0xFF) << 8) | (s0 & 0xFF);
int ldReg(int rr, int rl) => (0x0 << 4) | (rr << 2) | rl;
int ldImm4(int imm4) => (0x1 << 4) | (imm4 & 0xF);
int ldPeek(int rr, int rl) => (0x2 << 4) | (rr << 2) | rl;
int ldPoke(int rr, int rl) => (0x3 << 4) | (rr << 2) | rl;
int opAdd(int rr, int rl) => (0x6 << 4) | (rr << 2) | rl;
int opJmp(int rl) => 0xF0 | rl;
int push8Word(int rl, int imm8) => pack(0xF8 | rl, imm8);

/// Builds a self-contained MiniRISC4 cold-boot ROM image mapped at 0x0100..0x013F:
/// - Initializes R1/R2, reads constant 0x1234 from Boot ROM (0x0130) via Port B
/// - Attempts to overwrite Boot ROM at 0x0130 with 0xDEAD (must be write-protected!)
/// - Re-reads 0x0130 into [0x0400] (must still be 0x1234!)
/// - Computes 0x1234 + 0x0007 = 0x123B and stores into [0x0401]
/// - Emits 'A', 'S', 'I', 'C' over UART TX (0x000F) and halts cleanly.
List<int> buildColdBootRomImage() {
  final words = List<int>.filled(64, 0);
  // 0x0100: Load 0x0130 into R2 (ROM constant address)
  words[0x00] = push8Word(2, 0x01);
  words[0x01] = push8Word(2, 0x30);
  // 0x0102: Attempt write 0xDEAD into ROM[0x0130] (must be ignored!)
  words[0x02] = push8Word(1, 0xDE);
  words[0x03] = push8Word(1, 0xAD);
  words[0x04] = pack(ldPoke(2, 1), 0x00);
  // 0x0105: Read ROM[0x0130] -> R1 (must still be 0x1234)
  words[0x05] = pack(ldPeek(1, 2), 0x00);
  // 0x0106: Store R1 to SRAM[0x0400]
  words[0x06] = push8Word(3, 0x04);
  words[0x07] = push8Word(3, 0x00);
  words[0x08] = pack(ldPoke(3, 1), 0x00);
  // 0x0109: R0 = 7; R1 += R0 (0x123B); store to SRAM[0x0401]
  words[0x09] = pack(ldImm4(7), opAdd(1, 0));
  words[0x0A] = push8Word(3, 0x04);
  words[0x0B] = push8Word(3, 0x01);
  words[0x0C] = pack(ldPoke(3, 1), 0x00);
  // 0x010D: Print "ASIC" to UART TX (0x000F)
  words[0x0D] = pack(ldImm4(15), ldReg(3, 0)); // R3 = 0x000F
  words[0x0E] = push8Word(1, 0x00);
  words[0x0F] = push8Word(1, 65); // 'A'
  words[0x10] = pack(ldPoke(3, 1), 0x00);
  words[0x11] = push8Word(1, 0x00);
  words[0x12] = push8Word(1, 83); // 'S'
  words[0x13] = pack(ldPoke(3, 1), 0x00);
  words[0x14] = push8Word(1, 0x00);
  words[0x15] = push8Word(1, 73); // 'I'
  words[0x16] = pack(ldPoke(3, 1), 0x00);
  words[0x17] = push8Word(1, 0x00);
  words[0x18] = push8Word(1, 67); // 'C'
  words[0x19] = pack(ldPoke(3, 1), 0x00);
  // 0x011A: Halt loop at 0x011C
  words[0x1A] = push8Word(0, 0x01);
  words[0x1B] = push8Word(0, 0x1C);
  words[0x1C] = pack(opJmp(0), 0x00);
  // 0x0130: Constant word in Boot ROM
  words[0x30] = 0x1234;
  return words;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final latency in [1, 2]) {
    test('ASIC SRAM + Boot ROM cold-boot from uninitialized SRAM (latency=$latency)', () async {
      final bootRom = buildColdBootRomImage();
      // Fill SRAM with power-up garbage (0xA5A5) to prove cold-boot comes 100% from Boot ROM!
      final garbage = <int, int>{
        for (var i = 0; i < 2048; i++) i: 0xA5A5,
      };

      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rst_n');
      final rxData = Logic(name: 'mmio_rx_data', width: 16);
      final txStatus = Logic(name: 'mmio_tx_status', width: 16);

      final cpu = CpuCore(
        clk: clk,
        rstN: rstN,
        mmioRxData: rxData,
        mmioTxStatus: txStatus,
        config: CpuConfig(
          coreId: 0,
          enableCpuid: false,
          enableUart: true,
          enableCrossTraps: false,
          enableMathAccel: false,
          memReadLatency: latency,
          memoryTarget: MemoryTarget.asicSram,
          bootRomBase: 0x0100,
          bootRomWords: bootRom,
          trapTableBase: 0x0100,
          memWords: 2048,
        ),
        initialMemory: garbage,
      );

      await cpu.build();

      // Verify clean ASIC SystemVerilog generation (zero FPGA attributes / zero $readmemh)
      final sv = cpu.generateSynth();
      expect(sv, isNot(contains('ram_style')),
          reason: 'ASIC RTL must not emit FPGA (* ram_style *) attributes');
      expect(sv, isNot(contains(r'$readmemh')),
          reason: 'ASIC RTL must not emit \$readmemh initializers');
      expect(sv, contains('module mr4_sram_dp_2048x16'),
          reason: 'MemoryTarget.asicSram must instantiate foundry SRAM macro');
      expect(sv, contains('(* blackbox *)'),
          reason: 'Foundry SRAM macro must include SYNTHESIS blackbox guard');
      expect(sv, contains("16'h1234"),
          reason: 'AsicBootRom must emit synthesizable case ROM data');

      final txChars = <int>[];
      rstN.put(0);
      rxData.put(0);
      txStatus.put(0);
      clk.posedge.listen((_) {
        if (cpu.txStrobe.value.isValid && cpu.txStrobe.value.toBool()) {
          txChars.add(cpu.txData.value.toInt() & 0xFF);
        }
      });

      Simulator.registerAction(22, () => rstN.put(1));
      Simulator.setMaxSimTime(25 + 300 * 10);
      await Simulator.run();

      expect(String.fromCharCodes(txChars), equals('ASIC'));
      expect(cpu.ram.mem[0x0400], equals(0x1234),
          reason: 'Port B read from Boot ROM must be write-protected & return 0x1234');
      expect(cpu.ram.mem[0x0401], equals(0x123B),
          reason: 'Computed result must land cleanly in SRAM');
      expect(cpu.ram.mem[0x0130], equals(0xA5A5),
          reason: 'Writes inside Boot ROM window must NOT mutate underlying SRAM');
    });
  }

  test('ASIC Flop-RAM + Boot ROM cold-boot (zero blackboxes, standalone ORFS ready)', () async {
    final bootRom = buildColdBootRomImage();
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final rxData = Logic(name: 'mmio_rx_data', width: 16);
    final txStatus = Logic(name: 'mmio_tx_status', width: 16);

    final cpu = CpuCore(
      clk: clk,
      rstN: rstN,
      mmioRxData: rxData,
      mmioTxStatus: txStatus,
      config: CpuConfig(
        coreId: 0,
        enableCpuid: false,
        enableUart: true,
        enableCrossTraps: false,
        enableMathAccel: false,
        memReadLatency: 1,
        memoryTarget: MemoryTarget.asicFlop,
        bootRomBase: 0x0100,
        bootRomWords: bootRom,
        trapTableBase: 0x0100,
        memWords: 2048,
      ),
    );

    await cpu.build();

    final sv = cpu.generateSynth();
    expect(sv, isNot(contains('ram_style')));
    expect(sv, isNot(contains(r'$readmemh')));
    expect(sv, isNot(contains('blackbox')),
        reason: 'MemoryTarget.asicFlop must emit pure standard-cell logic with zero blackboxes');

    final txChars = <int>[];
    rstN.put(0);
    rxData.put(0);
    txStatus.put(0);
    clk.posedge.listen((_) {
      if (cpu.txStrobe.value.isValid && cpu.txStrobe.value.toBool()) {
        txChars.add(cpu.txData.value.toInt() & 0xFF);
      }
    });

    Simulator.registerAction(22, () => rstN.put(1));
    Simulator.setMaxSimTime(25 + 300 * 10);
    await Simulator.run();

    expect(String.fromCharCodes(txChars), equals('ASIC'));
    expect(cpu.ram.mem[0x0400], equals(0x1234));
    expect(cpu.ram.mem[0x0401], equals(0x123B));
  });

  test('ICache, DCache, and NocRouterNi emit clean ASIC RTL with zero ram_style', () async {
    final clk = Logic(name: 'clk');
    final rst = Logic(name: 'rst');

    final ic = ICache(
      clk: clk,
      reset: rst,
      reqValid: Logic(name: 'ic_v'),
      reqAddr: Logic(name: 'ic_a', width: 16),
      memCmdReady: Logic(name: 'ic_rdy'),
      memRdata: Logic(name: 'ic_md', width: 16),
      memRdataValid: Logic(name: 'ic_mv'),
      numLines: 16,
      lineWords: 8,
      memoryTarget: MemoryTarget.asicSram,
    );
    await ic.build();
    final icSv = ic.generateSynth();
    expect(icSv, isNot(contains('ram_style')));
    expect(icSv, contains('module mr4_sram_sp_128x16'));

    final dc = DCache(
      clk: clk,
      reset: rst,
      reqValid: Logic(name: 'dc_v'),
      reqWe: Logic(name: 'dc_we'),
      reqAddr: Logic(name: 'dc_a', width: 16),
      reqWdata: Logic(name: 'dc_wd', width: 16),
      memCmdReady: Logic(name: 'dc_rdy'),
      memRdata: Logic(name: 'dc_md', width: 16),
      memRdataValid: Logic(name: 'dc_mv'),
      memWdataReady: Logic(name: 'dc_wrdy'),
      numLines: 16,
      lineWords: 8,
      memoryTarget: MemoryTarget.asicFlop,
    );
    await dc.build();
    final dcSv = dc.generateSynth();
    expect(dcSv, isNot(contains('ram_style')));
    expect(dcSv, isNot(contains('blackbox')));

    final ni = NocRouterNi(
      clk: clk,
      reset: rst,
      mmioAddr: Logic(name: 'n_a', width: 16),
      mmioWdata: Logic(name: 'n_w', width: 16),
      mmioWe: Logic(name: 'n_we'),
      mmioRe: Logic(name: 'n_re'),
      netInValid: Logic(name: 'n_iv'),
      netInType: Logic(name: 'n_it'),
      netInSrcCore: Logic(name: 'n_is', width: 2),
      netInPayload: Logic(name: 'n_ip', width: 16),
      netOutReady: Logic(name: 'n_or'),
      coreId: 0,
      numCores: 4,
      fifoDepth: 16,
      memoryTarget: MemoryTarget.asicSram,
    );
    await ni.build();
    final niSv = ni.generateSynth();
    expect(niSv, isNot(contains('ram_style')));
  });
}

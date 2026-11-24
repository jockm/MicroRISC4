// ==============================================================================
// FILE: hdl/rohd/test/asic_top_test.dart
// Track D.2 Verification: AsicTop (`mr4_asic_top`) Cold-Boot & RTL Cleanliness
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:minirisc4_rohd/asic_top.dart';
import 'package:minirisc4_rohd/cpu_config.dart';
import 'package:minirisc4_rohd/memory_factory.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('AsicTop cold-boots asic_boot.asm from AsicBootRom, self-tests SRAM+Math, and prints UART banner', () async {
    final tmpDir = Directory.systemTemp.createTempSync('mr4_asic_top_test_');
    try {
      final hexPath = '${tmpDir.path}/asic_boot.hex';
      final assem = Process.runSync('python3', [
        '../../tools/mr4asm.py',
        '-I',
        '../../lib',
        '../../mr4src/asm/asic_boot.asm',
        '--hex',
        '-o',
        hexPath,
      ]);
      expect(assem.exitCode, equals(0), reason: 'mr4asm failed: ${assem.stderr}');

      final romWords = MemoryFactory.loadBootRomFromHex(
        hexPath,
        baseAddr: 0x0100,
        wordCount: 512,
      );

      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rst_n');
      final uartRxd = Logic(name: 'uart_rxd');

      // Use divisor = 8 (2 cycles/oversample, 8 cycles/bit) for snappy ROHD UART sim
      final top = AsicTop(
        clk: clk,
        rstN: rstN,
        uartRxd: uartRxd,
        uartDivisor: 8,
        config: CpuConfig(
          coreId: 0,
          enableUart: true,
          enableMathAccel: true,
          enableSpi: true,
          memReadLatency: 1,
          memoryTarget: MemoryTarget.asicSram,
          bootRomBase: 0x0100,
          bootRomWords: romWords,
          clkFreqMhz: 100,
          memWords: 2048,
        ),
      );
      await top.build();

      // Verify generated ASIC RTL is 100% free of FPGA primitives & $readmemh
      final sv = top.generateSynth();
      expect(sv, contains('module mr4_asic_top'));
      expect(sv, contains('module mr4_sram_dp_2048x16'));
      expect(sv, contains('spi_sck'));
      expect(sv, isNot(contains('EHXPLLL')));
      expect(sv, isNot(contains('ODDRX1F')));
      expect(sv, isNot(contains('ram_style')));
      expect(sv, isNot(contains('syn_useioff')));
      expect(sv, isNot(contains(r'$readmemh')));
      expect(sv, isNot(contains('wifi_gpio0')));

      final txBytes = <int>[];
      rstN.put(0);
      uartRxd.put(1);

      clk.posedge.listen((_) {
        if (top.cpu.txStrobe.value.isValid && top.cpu.txStrobe.value.toBool()) {
          txBytes.add(top.cpu.txData.value.toInt() & 0xFF);
        }
      });

      Simulator.registerAction(32, () => rstN.put(1));
      Simulator.setMaxSimTime(40 + 4000 * 10);
      await Simulator.run();

      expect(String.fromCharCodes(txBytes), equals('MR4 ASIC v0.1 OK\r\n'));
      expect(top.cpu.ram.mem[0x0300], equals(0xA55A));
      expect(top.cpu.ram.mem[0x0301], equals(0x5AA5));
      expect(top.cpu.ram.mem[0x0302], equals(5535),
          reason: '1-DSP MathAccelerator self-test (123 * 45 = 5535)');
      expect(top.cpu.ram.mem[0x0303], equals(0x600D),
          reason: 'Boot-OK sentinel in SRAM');
    } finally {
      tmpDir.deleteSync(recursive: true);
    }
  });

  test('AsicTop with MemoryTarget.asicFlop emits zero blackboxes for standalone ORFS', () async {
    final rom = List<int>.filled(64, 0);
    rom[0] = 0x01F8;
    rom[1] = 0x02F8;
    rom[2] = 0x00F0;

    final top = AsicTop(
      clk: Logic(name: 'clk'),
      rstN: Logic(name: 'rst_n'),
      uartRxd: Logic(name: 'uart_rxd'),
      uartDivisor: 16,
      config: CpuConfig(
        memReadLatency: 1,
        memoryTarget: MemoryTarget.asicFlop,
        bootRomBase: 0x0100,
        bootRomWords: rom,
        memWords: 512,
      ),
    );
    await top.build();

    final sv = top.generateSynth();
    expect(sv, contains('module mr4_asic_top'));
    expect(sv, isNot(contains('blackbox')));
    expect(sv, isNot(contains('EHXPLLL')));
    expect(sv, isNot(contains('ram_style')));
    expect(sv, isNot(contains(r'$readmemh')));
  });
}

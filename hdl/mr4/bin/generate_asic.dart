// ==============================================================================
// FILE: hdl/mr4/bin/generate_asic.dart
// Dedicated ASIC SystemVerilog Generator CLI for MicroRISC4 (`mr4_asic_top`)
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:microrisc4_rohd/asic_top.dart';
import 'package:microrisc4_rohd/cpu_config.dart';
import 'package:microrisc4_rohd/memory_factory.dart';

void main(List<String> args) async {
  String? bootHexPath;
  var outDir = '../../build/asic';
  var memTargetStr = 'sram'; // sram | flop
  var memWords = 2048;
  var memLatency = 1;
  var bootRomBase = 0x0100;
  var bootRomWords = 512;
  var clkFreqMhz = 100;
  int? uartDivisor;
  var enableSpi = false;
  var enableMath = false;
  String? sramMacroName;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--boot-hex' && i + 1 < args.length) {
      bootHexPath = args[++i];
    } else if (args[i] == '--out' && i + 1 < args.length) {
      outDir = args[++i];
    } else if (args[i] == '--mem-target' && i + 1 < args.length) {
      memTargetStr = args[++i].toLowerCase();
    } else if (args[i] == '--mem-words' && i + 1 < args.length) {
      memWords = int.tryParse(args[++i]) ?? memWords;
    } else if (args[i] == '--mem-latency' && i + 1 < args.length) {
      memLatency = int.tryParse(args[++i]) ?? memLatency;
    } else if (args[i] == '--boot-rom-base' && i + 1 < args.length) {
      bootRomBase = int.tryParse(args[++i]) ?? bootRomBase;
    } else if (args[i] == '--boot-rom-words' && i + 1 < args.length) {
      bootRomWords = int.tryParse(args[++i]) ?? bootRomWords;
    } else if (args[i] == '--clk-mhz' && i + 1 < args.length) {
      clkFreqMhz = int.tryParse(args[++i]) ?? clkFreqMhz;
    } else if (args[i] == '--uart-divisor' && i + 1 < args.length) {
      uartDivisor = int.tryParse(args[++i]);
    } else if (args[i] == '--enable-spi') {
      enableSpi = true;
    } else if (args[i] == '--enable-math') {
      enableMath = true;
    } else if (args[i] == '--sram-macro' && i + 1 < args.length) {
      sramMacroName = args[++i];
    }
  }

  final MemoryTarget target;
  if (memTargetStr == 'sram') {
    target = MemoryTarget.asicSram;
  } else if (memTargetStr == 'flop') {
    target = MemoryTarget.asicFlop;
  } else {
    stderr.writeln('Error: --mem-target must be "sram" or "flop", got "$memTargetStr"');
    exit(2);
  }

  List<int>? romWords;
  if (bootHexPath != null && bootHexPath.isNotEmpty) {
    if (!File(bootHexPath).existsSync()) {
      stderr.writeln('Error: Boot ROM hex file not found: $bootHexPath');
      exit(2);
    }
    romWords = MemoryFactory.loadBootRomFromHex(
      bootHexPath,
      baseAddr: bootRomBase,
      wordCount: bootRomWords,
    );
  }

  print(
    'Building MicroRISC4 ASIC Top (mr4_asic_top) in ROHD '
    '(target=$memTargetStr, clk=${clkFreqMhz}MHz, memWords=$memWords, '
    'memLatency=$memLatency'
    '${romWords != null ? ', bootRom=0x${bootRomBase.toRadixString(16)}+${romWords.length}w' : ', bootRom=none'}'
    '${enableSpi ? ', spi=on' : ''}'
    '${enableMath ? ', math=on' : ''}'
    '${uartDivisor != null ? ', uartDiv=$uartDivisor' : ''})...',
  );

  final top = AsicTop(
    clk: Logic(name: 'clk'),
    rstN: Logic(name: 'rst_n'),
    uartRxd: Logic(name: 'uart_rxd'),
    spiMiso: enableSpi ? Logic(name: 'spi_miso') : null,
    uartDivisor: uartDivisor,
    config: CpuConfig(
      coreId: 0,
      enableCpuid: false,
      enableUart: true,
      enableCrossTraps: false,
      enableMathAccel: enableMath,
      enableSpi: enableSpi,
      enableNoc: false,
      enableSdramCache: false,
      isPipelined: true,
      memReadLatency: memLatency,
      memoryTarget: target,
      bootRomBase: bootRomBase,
      bootRomWords: romWords,
      sramMacroName: sramMacroName,
      clkFreqMhz: clkFreqMhz,
      trapTableBase: 0x0100,
      memWords: memWords,
    ),
  );

  await top.build();

  print('Synthesizing ASIC SystemVerilog...');
  final sv = top.generateSynth();

  final dir = Directory(outDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final outFile = File('${dir.path}/mr4_asic_top.sv');
  await outFile.writeAsString(sv);

  print('ASIC generation complete: ${outFile.path} (${sv.length} bytes)');
}

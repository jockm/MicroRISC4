// ==============================================================================
// FILE: hdl/mr4/bin/generate_tiny.dart
// Dedicated Tiny Tapeout SystemVerilog Generator CLI (`tt_um_mr4`, Track E.1.2)
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:microrisc4_rohd/memory_factory.dart';
import 'package:microrisc4_rohd/mr4_tiny_top.dart';

void main(List<String> args) async {
  String? bootHexPath;
  var outDir = '../../build/asic_tiny';
  var bootRomBase = 0x0100;
  var bootRomWords = 256;
  var localRamWords = 16;
  var clkFreqMhz = 50;
  int? uartDivisor;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--boot-hex' && i + 1 < args.length) {
      bootHexPath = args[++i];
    } else if (args[i] == '--out' && i + 1 < args.length) {
      outDir = args[++i];
    } else if (args[i] == '--boot-rom-base' && i + 1 < args.length) {
      bootRomBase = int.tryParse(args[++i]) ?? bootRomBase;
    } else if (args[i] == '--boot-rom-words' && i + 1 < args.length) {
      bootRomWords = int.tryParse(args[++i]) ?? bootRomWords;
    } else if (args[i] == '--local-ram-words' && i + 1 < args.length) {
      localRamWords = int.tryParse(args[++i]) ?? localRamWords;
    } else if (args[i] == '--clk-mhz' && i + 1 < args.length) {
      clkFreqMhz = int.tryParse(args[++i]) ?? clkFreqMhz;
    } else if (args[i] == '--uart-divisor' && i + 1 < args.length) {
      uartDivisor = int.tryParse(args[++i]);
    }
  }

  List<int>? romWords;
  if (bootHexPath != null && bootHexPath.isNotEmpty) {
    if (!File(bootHexPath).existsSync()) {
      stderr.writeln('Error: Tiny Boot ROM hex file not found: $bootHexPath');
      exit(2);
    }
    romWords = MemoryFactory.loadBootRomFromHex(
      bootHexPath,
      baseAddr: bootRomBase,
      wordCount: bootRomWords,
    );
  }

  print(
    'Building Tiny Tapeout MicroRISC4 (tt_um_mr4) in ROHD '
    '(clk=${clkFreqMhz}MHz, localRam=${localRamWords}w, '
    'bootRom=0x${bootRomBase.toRadixString(16)}+${romWords?.length ?? 0}w, '
    'extQspi=0x0200..0xFFFF'
    '${uartDivisor != null ? ', uartDiv=$uartDivisor' : ''})...',
  );

  final top = Mr4TinyTop(
    clk: Logic(name: 'clk'),
    rstN: Logic(name: 'rst_n'),
    ena: Logic(name: 'ena'),
    uiIn: Logic(name: 'ui_in', width: 8),
    uioIn: Logic(name: 'uio_in', width: 8),
    bootRomWords: romWords,
    bootRomBase: bootRomBase,
    localRamWords: localRamWords,
    clkFreqMhz: clkFreqMhz,
    uartDivisor: uartDivisor,
  );

  await top.build();

  print('Synthesizing Tiny Tapeout SystemVerilog...');
  final sv = top.generateSynth();

  final dir = Directory(outDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final outFile = File('${dir.path}/tt_um_mr4.sv');
  await outFile.writeAsString(sv);

  print('Tiny Tapeout generation complete: ${outFile.path} (${sv.length} bytes)');
}

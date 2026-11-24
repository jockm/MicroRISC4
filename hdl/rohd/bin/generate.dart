// ==============================================================================
// FILE: hdl/rohd/bin/generate.dart
// SystemVerilog Generator CLI for MiniRISC4 ROHD Model (ULX3S-85F)
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:minirisc4_rohd/cpu_config.dart';
import 'package:minirisc4_rohd/tdp_bram.dart';
import 'package:minirisc4_rohd/ulx3s_top.dart';

void main(List<String> args) async {
  var hexPath = 'system_image.hex';
  String? workerHexPath;
  var outDir = '.';
  var memWords = 65536;
  var workerMemWords = 2048;
  var nocCores = 0;
  var nocChannels = 1;
  var nocFifoDepth = 16;
  var sdramCache = false;
  var cacheLines = 64;
  int? sdramInitWait;
  var clkFreqMhz = 48;
  int? resetHoldBits;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--hex' && i + 1 < args.length) {
      hexPath = args[++i];
    } else if (args[i] == '--worker-hex' && i + 1 < args.length) {
      final v = args[++i];
      workerHexPath = v.isEmpty ? null : v;
    } else if (args[i] == '--out' && i + 1 < args.length) {
      outDir = args[++i];
    } else if (args[i] == '--mem-words' && i + 1 < args.length) {
      memWords = int.tryParse(args[++i]) ?? memWords;
    } else if (args[i] == '--worker-mem-words' && i + 1 < args.length) {
      workerMemWords = int.tryParse(args[++i]) ?? workerMemWords;
    } else if (args[i] == '--noc-cores' && i + 1 < args.length) {
      nocCores = int.tryParse(args[++i]) ?? nocCores;
    } else if (args[i] == '--noc-channels' && i + 1 < args.length) {
      nocChannels = int.tryParse(args[++i]) ?? nocChannels;
    } else if (args[i] == '--noc-fifo-depth' && i + 1 < args.length) {
      nocFifoDepth = int.tryParse(args[++i]) ?? nocFifoDepth;
    } else if (args[i] == '--sdram-cache') {
      sdramCache = true;
    } else if (args[i] == '--cache-lines' && i + 1 < args.length) {
      cacheLines = int.tryParse(args[++i]) ?? cacheLines;
    } else if (args[i] == '--sdram-init-wait' && i + 1 < args.length) {
      sdramInitWait = int.tryParse(args[++i]);
    } else if (args[i] == '--clk-mhz' && i + 1 < args.length) {
      clkFreqMhz = int.tryParse(args[++i]) ?? clkFreqMhz;
    } else if (args[i] == '--reset-hold-bits' && i + 1 < args.length) {
      resetHoldBits = int.tryParse(args[++i]) ?? resetHoldBits;
    }
  }
  // Keep POR & btn_pwr_n debounce ~10-15 ms across 48-96 MHz
  final effResetHoldBits = resetHoldBits ?? (clkFreqMhz >= 72 ? 20 : 19);

  print(
    'Building MiniRISC4 ULX3S-85F hardware representation in ROHD '
    '(clk=${clkFreqMhz}MHz, memWords=$memWords, nocCores=$nocCores'
    '${nocCores >= 2 ? ', workerMemWords=$workerMemWords, nocChannels=$nocChannels, nocFifoDepth=$nocFifoDepth' : ''}'
    '${sdramCache ? ', sdramCache=on, cacheLines=$cacheLines' : ''})...',
  );

  final clk25 = Logic(name: 'clk_25mhz');
  final btnPwrN = Logic(name: 'btn_pwr_n');
  final ftdiTxd = Logic(name: 'ftdi_txd');

  final cfg = CpuConfig(
    coreId: 0,
    enableCpuid: nocCores >= 2,
    enableUart: true,
    enableCrossTraps: nocCores >= 2,
    enableMathAccel: false,
    enableNoc: nocCores >= 2,
    enableSdramCache: sdramCache,
    cacheLines: cacheLines,
    nocChannels: nocChannels,
    nocFifoDepth: nocFifoDepth,
    trapTableBase: 0x0100,
    memWords: memWords,
  );

  final top = Ulx3sTop(
    clk25mhz: clk25,
    btnPwrN: btnPwrN,
    ftdiTxd: ftdiTxd,
    config: cfg,
    nocCores: nocCores,
    workerMemWords: workerMemWords,
    clkFreqMhz: clkFreqMhz,
    resetHoldBits: effResetHoldBits,
    sdramInitWaitCycles: sdramInitWait,
    initHexFile: hexPath,
    workerInitHexFile: workerHexPath,
  );

  await top.build();

  print('Synthesizing to SystemVerilog...');
  final generatedSv = top.generateSynth();

  final dir = Directory(outDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  TdpBram.writeBankHexFiles(
    hexFileName: hexPath,
    outDir: dir.path,
    depth: memWords,
  );
  if (nocCores >= 2 && workerHexPath != null) {
    TdpBram.writeBankHexFiles(
      hexFileName: workerHexPath,
      outDir: dir.path,
      depth: workerMemWords,
    );
  }
  final outFile = File('${dir.path}/ulx3s_top_rohd.sv');
  await outFile.writeAsString(generatedSv);

  print('Generation complete: ${outFile.path} (${generatedSv.length} bytes)');
}

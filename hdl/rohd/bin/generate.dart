// ==============================================================================
// FILE: hdl/rohd/bin/generate.dart
// SystemVerilog Generator CLI for MiniRISC4 ROHD Model (ULX3S-85F)
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:minirisc4_rohd/ulx3s_top.dart';

void main(List<String> args) async {
  var hexPath = 'system_image.hex';
  var outDir = '.';

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--hex' && i + 1 < args.length) {
      hexPath = args[++i];
    } else if (args[i] == '--out' && i + 1 < args.length) {
      outDir = args[++i];
    }
  }

  print('Building MiniRISC4 ULX3S-85F hardware representation in ROHD...');

  final clk25 = Logic(name: 'clk_25mhz');
  final btnPwrN = Logic(name: 'btn_pwr_n');
  final ftdiTxd = Logic(name: 'ftdi_txd');

  final top = Ulx3sTop(
    clk25mhz: clk25,
    btnPwrN: btnPwrN,
    ftdiTxd: ftdiTxd,
    initHexFile: hexPath,
  );

  await top.build();

  print('Synthesizing to SystemVerilog...');
  final generatedSv = top.generateSynth();

  final dir = Directory(outDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final outFile = File('${dir.path}/ulx3s_top_rohd.sv');
  await outFile.writeAsString(generatedSv);

  print('Generation complete: ${outFile.path} (${generatedSv.length} bytes)');
}

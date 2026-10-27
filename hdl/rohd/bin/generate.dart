// ==============================================================================
// SystemVerilog Generator CLI for MiniRISC4 ROHD Model
// ==============================================================================
import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:minirisc4_rohd/ulx3s_top.dart'; // instead of ../lib/ulx3s_top.dart

void main() async {
  print('Building MiniRISC4 hardware representation in ROHD...');

  final clk = Logic(name: 'clk_24mhz');
  final rstN = Logic(name: 'rst_n');
  final ftdiTxd = Logic(name: 'ftdi_txd');

  final top = Ulx3sTop(
    clk24mhz: clk,
    rstN: rstN,
    ftdiTxd: ftdiTxd,
  );

  await top.build();

  print('Synthesizing to standard SystemVerilog...');
  final generatedSv = top.generateSynth();

  final outFile = File('ulx3s_top_rohd.sv');
  await outFile.writeAsString(generatedSv);

  print('Generation complete: \${outFile.path} (\${generatedSv.length} bytes)');
}

// ==============================================================================
// FILE: hdl/rohd/lib/tdp_bram.dart
// Synthesizable 2-Cycle Pipelined True Dual-Port Block RAM (ECP5 DP16KD)
// ==============================================================================

import 'dart:io';
import 'dart:typed_data';
import 'package:rohd/rohd.dart';

class TdpBram extends Module with SystemVerilog {
  final int depth;
  final int dataWidth;
  final int addrWidth;
  final String? initHexFile;
  final Uint16List mem;

  static const int maxSingleBankWords = 16384;

  static String bankHexName(String hexPath, int bankIndex) {
    final dot = hexPath.lastIndexOf('.');
    if (dot > 0) {
      return '${hexPath.substring(0, dot)}_b$bankIndex${hexPath.substring(dot)}';
    }
    return '${hexPath}_b$bankIndex';
  }

  /// Parses a standard `$readmemh` file (supporting `@addr` directives) into a
  /// flat [Uint16List] of length [depth].
  static Uint16List parseHexFile(String path, int depth) {
    final words = Uint16List(depth);
    final file = File(path);
    if (!file.existsSync()) return words;
    var idx = 0;
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      if (line.startsWith('@')) {
        idx = int.parse(line.substring(1), radix: 16);
        continue;
      }
      if (idx < depth) {
        words[idx++] = int.parse(line, radix: 16) & 0xFFFF;
      }
    }
    return words;
  }

  /// Writes per-bank hex initialization files into [outDir] when [depth] uses
  /// banked `16K`-word DP16KD arrays.
  static void writeBankHexFiles({
    required String hexFileName,
    required String outDir,
    required int depth,
  }) {
    if (depth <= maxSingleBankWords || depth % maxSingleBankWords != 0) {
      return;
    }
    final srcPath = '$outDir/$hexFileName';
    if (!File(srcPath).existsSync()) return;
    final words = parseHexFile(srcPath, depth);
    final bankCount = depth ~/ maxSingleBankWords;
    for (var b = 0; b < bankCount; b++) {
      final base = b * maxSingleBankWords;
      final buf = StringBuffer();
      for (var i = 0; i < maxSingleBankWords; i++) {
        buf.writeln(words[base + i].toRadixString(16).padLeft(4, '0'));
      }
      final bankFile = File('$outDir/${bankHexName(hexFileName, b)}');
      bankFile.writeAsStringSync(buf.toString());
    }
  }

  TdpBram({
    required Logic clk,
    required Logic portAAddr,
    required Logic portAEn,
    required Logic portBAddr,
    required Logic portBWdata,
    required Logic portBWe,
    required Logic portBEn,
    this.depth = 65536,
    this.dataWidth = 16,
    this.initHexFile,
    Map<int, int>? initialMemory,
    super.name = 'tdp_bram',
  })  : addrWidth = (depth - 1).bitLength,
        mem = (initHexFile != null && File(initHexFile).existsSync())
            ? parseHexFile(initHexFile, depth)
            : Uint16List(depth) {
    if (initialMemory != null) {
      initialMemory.forEach((addr, val) {
        if (addr >= 0 && addr < depth) {
          mem[addr] = val & 0xFFFF;
        }
      });
    }

    clk = addInput('clk', clk);
    portAAddr = addInput('port_a_addr', portAAddr, width: addrWidth);
    portAEn = addInput('port_a_en', portAEn);
    portBAddr = addInput('port_b_addr', portBAddr, width: addrWidth);
    portBWdata = addInput('port_b_wdata', portBWdata, width: dataWidth);
    portBWe = addInput('port_b_we', portBWe);
    portBEn = addInput('port_b_en', portBEn);

    final portARdata = addOutput('port_a_rdata', width: dataWidth);
    final portBRdata = addOutput('port_b_rdata', width: dataWidth);

    // Combinational array read taps + genuine ROHD Sequential stages so Dart
    // simulation matches Verilog always_ff @(posedge clk) 100% cycle-for-cycle.
    final aComb = Logic(name: 'a_comb_sim', width: dataWidth);
    final bComb = Logic(name: 'b_comb_sim', width: dataWidth);
    final portARdataRawSig =
        Logic(name: 'port_a_rdata_raw_sim', width: dataWidth);
    final portBRdataRawSig =
        Logic(name: 'port_b_rdata_raw_sim', width: dataWidth);

    // Latched write-port shadow registers for applying Port B writes after clk.
    final wrFireQ = Logic(name: 'wr_fire_q_sim');
    final wrAddrQ = Logic(name: 'wr_addr_q_sim', width: addrWidth);
    final wrDataQ = Logic(name: 'wr_data_q_sim', width: dataWidth);

    void refreshReads() {
      final aAddr = portAAddr.value.isValid ? portAAddr.value.toInt() : 0;
      final bAddr = portBAddr.value.isValid ? portBAddr.value.toInt() : 0;
      aComb.put(aAddr < depth ? mem[aAddr] : 0);
      bComb.put(bAddr < depth ? mem[bAddr] : 0);
    }

    aComb.put(0);
    bComb.put(0);
    portARdataRawSig.put(0);
    portBRdataRawSig.put(0);
    portARdata.put(0);
    portBRdata.put(0);
    wrFireQ.put(0);
    wrAddrQ.put(0);
    wrDataQ.put(0);

    portAAddr.changed.listen((_) => refreshReads());
    portBAddr.changed.listen((_) => refreshReads());

    Sequential(clk, [
      If(portAEn, then: [
        portARdataRawSig < aComb,
      ]),
      portARdata < portARdataRawSig,
      If(portBEn & ~portBWe, then: [
        portBRdataRawSig < bComb,
      ]),
      portBRdata < portBRdataRawSig,
      wrFireQ < (portBEn & portBWe),
      wrAddrQ < portBAddr,
      wrDataQ < portBWdata,
    ]);

    clk.posedge.listen((_) {
      Simulator.postTick.first.then(
        (_) {
          if (wrFireQ.value.isValid && wrFireQ.value.toBool()) {
            final wAddr = wrAddrQ.value.isValid ? wrAddrQ.value.toInt() : 0;
            final wData = wrDataQ.value.isValid ? wrDataQ.value.toInt() : 0;
            if (wAddr < depth) {
              mem[wAddr] = wData & 0xFFFF;
            }
          }
          refreshReads();
        },
        onError: (_) {},
      );
    });
  }

  Logic get portARdata => output('port_a_rdata');
  Logic get portBRdata => output('port_b_rdata');

  @override
  String definitionVerilog(String definitionType) {
    final hasInit = initHexFile != null && initHexFile!.isNotEmpty;

    // For depths > 16384 words (e.g., 65536), split into 16K-word banks so each
    // bank maps cleanly to 16 x (16K x 1) DP16KD blocks with zero intra-bank
    // output muxing, followed by a registered inter-bank mux (2-cycle total).
    if (depth > maxSingleBankWords && depth % maxSingleBankWords == 0) {
      final bankCount = depth ~/ maxSingleBankWords;
      const bankAddrBits = 14;
      final bankSelWidth = (bankCount - 1).bitLength;
      final bankSelHi = addrWidth - 1;

      final bankDecls = List.generate(bankCount, (b) {
        final initStmt = hasInit
            ? '\n  initial \$readmemh("${bankHexName(initHexFile!, b)}", bank${b}_mem);'
            : '';
        return '''
  (* ram_style = "block", no_rw_check *)
  logic [${dataWidth - 1}:0] bank${b}_mem [0:${maxSingleBankWords - 1}];$initStmt
  logic [${dataWidth - 1}:0] bank${b}_a_raw;
  logic [${dataWidth - 1}:0] bank${b}_b_raw;
  (* keep = "true" *) logic [${dataWidth - 1}:0] bank${b}_a_q;
  (* keep = "true" *) logic [${dataWidth - 1}:0] bank${b}_b_q;
  logic bank${b}_we;
  assign bank${b}_we = port_b_we & (port_b_addr[$bankSelHi:$bankAddrBits] == $bankSelWidth'd$b);''';
      }).join('\n');

      final bankAReads = List.generate(
        bankCount,
        (b) => '      bank${b}_a_raw <= bank${b}_mem[port_a_addr[${bankAddrBits - 1}:0]];',
      ).join('\n');

      final bankBOps = List.generate(
        bankCount,
        (b) => '''
      if (bank${b}_we) begin
        bank${b}_mem[port_b_addr[${bankAddrBits - 1}:0]] <= port_b_wdata;
      end else begin
        bank${b}_b_raw <= bank${b}_mem[port_b_addr[${bankAddrBits - 1}:0]];
      end''',
      ).join('\n');

      final bankLocalRegs = List.generate(
        bankCount,
        (b) => '''
    bank${b}_a_q <= bank${b}_a_raw;
    bank${b}_b_q <= bank${b}_b_raw;''',
      ).join('\n');

      final String aMuxAssign;
      final String bMuxAssign;
      if (bankCount == 4) {
        aMuxAssign = '''
  assign port_a_rdata = a_bank_q2[1]
      ? (a_bank_q2[0] ? bank3_a_q : bank2_a_q)
      : (a_bank_q2[0] ? bank1_a_q : bank0_a_q);''';
        bMuxAssign = '''
  assign port_b_rdata = b_bank_q2[1]
      ? (b_bank_q2[0] ? bank3_b_q : bank2_b_q)
      : (b_bank_q2[0] ? bank1_b_q : bank0_b_q);''';
      } else {
        final bankACases = List.generate(
          bankCount,
          (b) => b == bankCount - 1
              ? '      default: port_a_rdata = bank${b}_a_q;'
              : "      $bankSelWidth'd$b: port_a_rdata = bank${b}_a_q;",
        ).join('\n');
        final bankBCases = List.generate(
          bankCount,
          (b) => b == bankCount - 1
              ? '      default: port_b_rdata = bank${b}_b_q;'
              : "      $bankSelWidth'd$b: port_b_rdata = bank${b}_b_q;",
        ).join('\n');
        aMuxAssign = '  always_comb begin\n    case (a_bank_q2)\n$bankACases\n    endcase\n  end';
        bMuxAssign = '  always_comb begin\n    case (b_bank_q2)\n$bankBCases\n    endcase\n  end';
      }

      return '''
module $definitionType (
  input  logic clk,
  input  logic [${addrWidth - 1}:0] port_a_addr,
  input  logic port_a_en,
  output logic [${dataWidth - 1}:0] port_a_rdata,
  input  logic [${addrWidth - 1}:0] port_b_addr,
  input  logic [${dataWidth - 1}:0] port_b_wdata,
  input  logic port_b_we,
  input  logic port_b_en,
  output logic [${dataWidth - 1}:0] port_b_rdata
);
$bankDecls

  logic [${bankSelWidth - 1}:0] a_bank_q1, a_bank_q2;
  logic [${bankSelWidth - 1}:0] b_bank_q1, b_bank_q2;

  always_ff @(posedge clk) begin
    if (port_a_en) begin
      a_bank_q1 <= port_a_addr[$bankSelHi:$bankAddrBits];
$bankAReads
    end
  end

  always_ff @(posedge clk) begin
    if (port_b_en) begin
      b_bank_q1 <= port_b_addr[$bankSelHi:$bankAddrBits];
$bankBOps
    end
  end

  always_ff @(posedge clk) begin
    a_bank_q2 <= a_bank_q1;
    b_bank_q2 <= b_bank_q1;
$bankLocalRegs
  end

$aMuxAssign
$bMuxAssign
endmodule
''';
    }

    final initBlock = hasInit
        ? """
  initial begin
    \$readmemh("$initHexFile", mem);
  end
"""
        : '';

    return """
module $definitionType (
  input  logic clk,
  input  logic [${addrWidth - 1}:0] port_a_addr,
  input  logic port_a_en,
  output logic [${dataWidth - 1}:0] port_a_rdata,
  input  logic [${addrWidth - 1}:0] port_b_addr,
  input  logic [${dataWidth - 1}:0] port_b_wdata,
  input  logic port_b_we,
  input  logic port_b_en,
  output logic [${dataWidth - 1}:0] port_b_rdata
);
  (* ram_style = "block", no_rw_check *)
  logic [${dataWidth - 1}:0] mem [0:${depth - 1}];
$initBlock
  logic [${dataWidth - 1}:0] port_a_rdata_raw;
  logic [${dataWidth - 1}:0] port_b_rdata_raw;

  always_ff @(posedge clk) begin
    if (port_a_en) begin
      port_a_rdata_raw <= mem[port_a_addr];
    end
    port_a_rdata <= port_a_rdata_raw;
  end

  always_ff @(posedge clk) begin
    if (port_b_en) begin
      if (port_b_we) begin
        mem[port_b_addr] <= port_b_wdata;
      end else begin
        port_b_rdata_raw <= mem[port_b_addr];
      end
    end
    port_b_rdata <= port_b_rdata_raw;
  end
endmodule
""";
  }
}

// ==============================================================================
// FILE: hdl/rohd/lib/tdp_bram.dart
// Banked 2-Cycle Pipelined True Dual-Port Block RAM (ECP5 DP16KD)
// Splits 65,536 x 16-bit space into 4 x 16K banks (128 DP16KD total) with
// registered bank select so the read mux doesn't span all 128 blocks at once.
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
        mem = Uint16List(depth) {
    if (initHexFile != null && File(initHexFile!).existsSync()) {
      final lines = File(initHexFile!).readAsLinesSync();
      var idx = 0;
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('//')) continue;
        if (line.startsWith('@')) {
          idx = int.parse(line.substring(1), radix: 16);
          continue;
        }
        if (idx < depth) {
          mem[idx++] = int.parse(line, radix: 16) & 0xFFFF;
        }
      }
    }
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

    portARdata.put(0);
    portBRdata.put(0);
    var portARdataRaw = 0;
    var portBRdataRaw = 0;

    clk.posedge.listen((_) {
      final aEn = portAEn.value.isValid && portAEn.value.toBool();
      final bEn = portBEn.value.isValid && portBEn.value.toBool();
      final bWe = portBWe.value.isValid && portBWe.value.toBool();

      final aAddr = portAAddr.value.isValid ? portAAddr.value.toInt() : 0;
      final bAddr = portBAddr.value.isValid ? portBAddr.value.toInt() : 0;
      final bWdata = portBWdata.value.isValid ? portBWdata.value.toInt() : 0;

      final prevARaw = portARdataRaw;
      final prevBRaw = portBRdataRaw;

      if (aEn && aAddr < depth) {
        portARdataRaw = mem[aAddr];
      }
      Simulator.injectAction(() => portARdata.put(prevARaw));

      if (bEn && bAddr < depth) {
        if (bWe) {
          mem[bAddr] = bWdata & 0xFFFF;
          portBRdataRaw = bWdata & 0xFFFF;
        } else {
          portBRdataRaw = mem[bAddr];
        }
      }
      Simulator.injectAction(() => portBRdata.put(prevBRaw));
    });
  }

  Logic get portARdata => output('port_a_rdata');
  Logic get portBRdata => output('port_b_rdata');

  @override
  String definitionVerilog(String definitionType) {
    final initBlock = (initHexFile != null && initHexFile!.isNotEmpty)
        ? """
  initial begin
    \$readmemh("$initHexFile", mem);
  end
"""
        : '';

    if (depth > 16384 && addrWidth >= 14) {
      final bankCount = depth ~/ 16384;
      final bankSelWidth = (bankCount - 1).bitLength;
      final bankDecls = List.generate(
        bankCount,
        (b) => """
  (* ram_style = "block" *)
  logic [${dataWidth - 1}:0] bank${b}_mem [0:16383];
  logic [${dataWidth - 1}:0] bank${b}_a_raw;
  logic [${dataWidth - 1}:0] bank${b}_b_raw;""",
      ).join('\n');

      final bankCases = List.generate(
        bankCount,
        (b) => "        2'd$b: bank${b}_mem[_init_i[13:0]] = _flat_init_mem[_init_i];",
      ).join('\n');

      final bankInit = (initHexFile != null && initHexFile!.isNotEmpty)
          ? """
  integer _init_i;
  initial begin
    \$readmemh("$initHexFile", _flat_init_mem);
    for (_init_i = 0; _init_i < $depth; _init_i = _init_i + 1) begin
      case (_init_i[15:14])
$bankCases
      endcase
    end
  end"""
          : '';

      final flatInitDecl = (initHexFile != null && initHexFile!.isNotEmpty)
          ? '  logic [${dataWidth - 1}:0] _flat_init_mem [0:${depth - 1}];'
          : '';

      final bankAlways = List.generate(
        bankCount,
        (b) => """
  always_ff @(posedge clk) begin
    if (port_a_en && (port_a_addr[${addrWidth - 1}:14] == ${bankSelWidth}'d$b)) begin
      bank${b}_a_raw <= bank${b}_mem[port_a_addr[13:0]];
    end
    if (port_b_en && (port_b_addr[${addrWidth - 1}:14] == ${bankSelWidth}'d$b)) begin
      if (port_b_we) begin
        bank${b}_mem[port_b_addr[13:0]] <= port_b_wdata;
        bank${b}_b_raw <= port_b_wdata;
      end else begin
        bank${b}_b_raw <= bank${b}_mem[port_b_addr[13:0]];
      end
    end
  end""",
      ).join('\n');

      final aMuxExpr = List.generate(
        bankCount,
        (b) => "((a_bank_q == ${bankSelWidth}'d$b) ? bank${b}_a_raw : 16'h0)",
      ).join(' | ');

      final bMuxExpr = List.generate(
        bankCount,
        (b) => "((b_bank_q == ${bankSelWidth}'d$b) ? bank${b}_b_raw : 16'h0)",
      ).join(' | ');

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
$flatInitDecl
$bankDecls
  logic [${bankSelWidth - 1}:0] a_bank_d, a_bank_q;
  logic [${bankSelWidth - 1}:0] b_bank_d, b_bank_q;
$bankInit

  assign a_bank_d = port_a_addr[${addrWidth - 1}:14];
  assign b_bank_d = port_b_addr[${addrWidth - 1}:14];

  always_ff @(posedge clk) begin
    if (port_a_en) begin
      a_bank_q <= a_bank_d;
    end
    if (port_b_en) begin
      b_bank_q <= b_bank_d;
    end
  end
$bankAlways

  always_ff @(posedge clk) begin
    port_a_rdata <= ($aMuxExpr);
    port_b_rdata <= ($bMuxExpr);
  end
endmodule
""";
    }

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
  (* ram_style = "block" *)
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
        port_b_rdata_raw <= port_b_wdata;
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

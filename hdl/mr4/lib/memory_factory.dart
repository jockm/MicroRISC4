// ==============================================================================
// FILE: hdl/mr4/lib/memory_factory.dart
// Target-Selectable Memory Abstraction & Synthesizable ASIC Boot ROM (Track D.1)
//
// Decouples CpuCore, ICache/DCache, and NocRouterNi from FPGA-only TdpBram /
// (* ram_style *) / $readmemh while preserving 100% bit-for-bit ULX3S ECP5
// behavior when MemoryTarget.fpgaEcp5 (the default) is selected.
// ==============================================================================

import 'dart:io';
import 'dart:typed_data';
import 'package:rohd/rohd.dart';
import 'cache_controllers.dart';
import 'noc_router.dart';
import 'tdp_bram.dart';

/// Target memory implementation technology for MicroRISC4 RTL generation.
enum MemoryTarget {
  /// Lattice ECP5 FPGA: banked DP16KD TdpBram, (* ram_style *), and $readmemh.
  fpgaEcp5,

  /// ASIC compiled SRAM macro wrappers (clean foundry black-box in SYNTHESIS +
  /// behavioral simulation body; zero FPGA attributes or $readmemh).
  asicSram,

  /// ASIC pure standard-cell flip-flop arrays (zero black-boxes; synthesizes
  /// standalone on any public PDK / OpenROAD flow without an SRAM compiler).
  asicFlop,
}

/// Common interface shared by [TdpBram], [AsicDualPortSram], and
/// [DualPortRamWithBootRom] so [CpuCore] and tests remain target-agnostic.
abstract interface class DualPortMemory {
  Uint16List get mem;
  Logic get portARdata;
  Logic get portBRdata;
}

/// Foundry-ready 1-cycle True Dual-Port SRAM macro wrapper
/// (`mr4_sram_dp_<depth>x<dataWidth>`).
///
/// Under `SYNTHESIS`, emits a clean `(* blackbox *)` macro declaration ready
/// for Liberty/LEF binding in OpenROAD / Yosys. Outside `SYNTHESIS`, includes
/// a cycle-accurate behavioral array for Verilator/Icarus simulation.
class AsicSramDpMacro extends Module with SystemVerilog {
  final int depth;
  final int dataWidth;
  final int addrWidth;
  final String macroName;
  final Uint16List mem;

  AsicSramDpMacro({
    required Logic clk,
    required Logic portAAddr,
    required Logic portAEn,
    required Logic portBAddr,
    required Logic portBWdata,
    required Logic portBWe,
    required Logic portBEn,
    required this.depth,
    this.dataWidth = 16,
    String? macroName,
    Map<int, int>? initialMemory,
    super.name = 'asic_sram_dp_macro',
  })  : addrWidth = (depth <= 1) ? 1 : (depth - 1).bitLength,
        macroName = macroName ?? 'mr4_sram_dp_${depth}x$dataWidth',
        mem = Uint16List(depth) {
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

    final aComb = Logic(name: 'a_comb_sim', width: dataWidth);
    final bComb = Logic(name: 'b_comb_sim', width: dataWidth);
    final wrFireQ = Logic(name: 'wr_fire_q_sim');
    final wrAddrQ = Logic(name: 'wr_addr_q_sim', width: addrWidth);
    final wrDataQ = Logic(name: 'wr_data_q_sim', width: dataWidth);

    void refreshReads() {
      final a = portAAddr.value.isValid ? portAAddr.value.toInt() : 0;
      final b = portBAddr.value.isValid ? portBAddr.value.toInt() : 0;
      aComb.put(a < depth ? mem[a] : 0);
      bComb.put(b < depth ? mem[b] : 0);
    }

    aComb.put(0);
    bComb.put(0);
    portARdata.put(0);
    portBRdata.put(0);
    wrFireQ.put(0);
    wrAddrQ.put(0);
    wrDataQ.put(0);

    portAAddr.changed.listen((_) => refreshReads());
    portBAddr.changed.listen((_) => refreshReads());

    Sequential(clk, [
      If(portAEn, then: [portARdata < aComb]),
      If(portBEn & ~portBWe, then: [portBRdata < bComb]),
      wrFireQ < (portBEn & portBWe),
      wrAddrQ < portBAddr,
      wrDataQ < portBWdata,
    ]);

    clk.posedge.listen((_) {
      Simulator.postTick.first.then(
        (_) {
          if (wrFireQ.value.isValid && wrFireQ.value.toBool()) {
            final wa = wrAddrQ.value.isValid ? wrAddrQ.value.toInt() : 0;
            final wd = wrDataQ.value.isValid ? wrDataQ.value.toInt() : 0;
            if (wa < depth) {
              mem[wa] = wd & 0xFFFF;
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
  String get definitionName => macroName;

  @override
  String definitionVerilog(String definitionType) => '''
`ifdef SYNTHESIS
(* blackbox *)
`endif
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
`ifndef SYNTHESIS
  logic [${dataWidth - 1}:0] mem [0:${depth - 1}];
  integer _init_i;
  initial begin
    for (_init_i = 0; _init_i < $depth; _init_i = _init_i + 1) begin
      mem[_init_i] = $dataWidth'd0;
    end
  end
  always_ff @(posedge clk) begin
    if (port_a_en) begin
      port_a_rdata <= mem[port_a_addr];
    end
    if (port_b_en) begin
      if (port_b_we) begin
        mem[port_b_addr] <= port_b_wdata;
      end else begin
        port_b_rdata <= mem[port_b_addr];
      end
    end
  end
`endif
endmodule
''';
}

/// Target-clean ASIC True Dual-Port SRAM supporting both 1-cycle and 2-cycle
/// read latency in either foundry macro (`useMacroBlackbox = true`) or pure
/// standard-cell flip-flop (`useMacroBlackbox = false`) mode.
class AsicDualPortSram extends Module implements DualPortMemory {
  final int depth;
  final int dataWidth;
  final int addrWidth;
  final int readLatency;
  final bool useMacroBlackbox;
  late final Uint16List _mem;

  AsicDualPortSram({
    required Logic clk,
    required Logic portAAddr,
    required Logic portAEn,
    required Logic portBAddr,
    required Logic portBWdata,
    required Logic portBWe,
    required Logic portBEn,
    this.depth = 2048,
    this.dataWidth = 16,
    this.readLatency = 1,
    this.useMacroBlackbox = true,
    String? macroName,
    Map<int, int>? initialMemory,
    super.name = 'asic_dp_sram',
  }) : addrWidth = (depth <= 1) ? 1 : (depth - 1).bitLength {
    assert(readLatency == 1 || readLatency == 2,
        'AsicDualPortSram readLatency must be 1 or 2');

    clk = addInput('clk', clk);
    portAAddr = addInput('port_a_addr', portAAddr, width: addrWidth);
    portAEn = addInput('port_a_en', portAEn);
    portBAddr = addInput('port_b_addr', portBAddr, width: addrWidth);
    portBWdata = addInput('port_b_wdata', portBWdata, width: dataWidth);
    portBWe = addInput('port_b_we', portBWe);
    portBEn = addInput('port_b_en', portBEn);

    final portARdataOut = addOutput('port_a_rdata', width: dataWidth);
    final portBRdataOut = addOutput('port_b_rdata', width: dataWidth);

    late final Logic rawA;
    late final Logic rawB;

    if (useMacroBlackbox) {
      final macro = AsicSramDpMacro(
        clk: clk,
        portAAddr: portAAddr,
        portAEn: portAEn,
        portBAddr: portBAddr,
        portBWdata: portBWdata,
        portBWe: portBWe,
        portBEn: portBEn,
        depth: depth,
        dataWidth: dataWidth,
        macroName: macroName,
        initialMemory: initialMemory,
        name: '${name}_macro',
      );
      _mem = macro.mem;
      rawA = macro.portARdata;
      rawB = macro.portBRdata;
    } else {
      final flopArray = _AsicFlopDpArray(
        clk: clk,
        portAAddr: portAAddr,
        portAEn: portAEn,
        portBAddr: portBAddr,
        portBWdata: portBWdata,
        portBWe: portBWe,
        portBEn: portBEn,
        depth: depth,
        dataWidth: dataWidth,
        initialMemory: initialMemory,
        name: '${name}_flops',
      );
      _mem = flopArray.mem;
      rawA = flopArray.portARdata;
      rawB = flopArray.portBRdata;
    }

    if (readLatency == 1) {
      portARdataOut <= rawA;
      portBRdataOut <= rawB;
    } else {
      final aPipeQ = Logic(name: 'a_pipe_q', width: dataWidth);
      final bPipeQ = Logic(name: 'b_pipe_q', width: dataWidth);
      Sequential(clk, [
        aPipeQ < rawA,
        bPipeQ < rawB,
      ]);
      portARdataOut <= aPipeQ;
      portBRdataOut <= bPipeQ;
    }
  }

  @override
  Uint16List get mem => _mem;

  @override
  Logic get portARdata => output('port_a_rdata');

  @override
  Logic get portBRdata => output('port_b_rdata');
}

/// Pure standard-cell flip-flop 1-cycle True Dual-Port RAM (zero FPGA
/// attributes, zero black-boxes) for compact standalone ASIC/ORFS builds.
class _AsicFlopDpArray extends Module with SystemVerilog {
  final int depth;
  final int dataWidth;
  final int addrWidth;
  final Uint16List mem;

  _AsicFlopDpArray({
    required Logic clk,
    required Logic portAAddr,
    required Logic portAEn,
    required Logic portBAddr,
    required Logic portBWdata,
    required Logic portBWe,
    required Logic portBEn,
    required this.depth,
    this.dataWidth = 16,
    Map<int, int>? initialMemory,
    super.name = 'asic_flop_dp_array',
  })  : addrWidth = (depth <= 1) ? 1 : (depth - 1).bitLength,
        mem = Uint16List(depth) {
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

    final aComb = Logic(name: 'a_comb_sim', width: dataWidth);
    final bComb = Logic(name: 'b_comb_sim', width: dataWidth);
    final wrFireQ = Logic(name: 'wr_fire_q_sim');
    final wrAddrQ = Logic(name: 'wr_addr_q_sim', width: addrWidth);
    final wrDataQ = Logic(name: 'wr_data_q_sim', width: dataWidth);

    void refreshReads() {
      final a = portAAddr.value.isValid ? portAAddr.value.toInt() : 0;
      final b = portBAddr.value.isValid ? portBAddr.value.toInt() : 0;
      aComb.put(a < depth ? mem[a] : 0);
      bComb.put(b < depth ? mem[b] : 0);
    }

    aComb.put(0);
    bComb.put(0);
    portARdata.put(0);
    portBRdata.put(0);
    wrFireQ.put(0);
    wrAddrQ.put(0);
    wrDataQ.put(0);

    portAAddr.changed.listen((_) => refreshReads());
    portBAddr.changed.listen((_) => refreshReads());

    Sequential(clk, [
      If(portAEn, then: [portARdata < aComb]),
      If(portBEn & ~portBWe, then: [portBRdata < bComb]),
      wrFireQ < (portBEn & portBWe),
      wrAddrQ < portBAddr,
      wrDataQ < portBWdata,
    ]);

    clk.posedge.listen((_) {
      Simulator.postTick.first.then(
        (_) {
          if (wrFireQ.value.isValid && wrFireQ.value.toBool()) {
            final wa = wrAddrQ.value.isValid ? wrAddrQ.value.toInt() : 0;
            final wd = wrDataQ.value.isValid ? wrDataQ.value.toInt() : 0;
            if (wa < depth) {
              mem[wa] = wd & 0xFFFF;
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
  String definitionVerilog(String definitionType) => '''
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
  logic [${dataWidth - 1}:0] mem [0:${depth - 1}];
`ifndef SYNTHESIS
  integer _init_i;
  initial begin
    for (_init_i = 0; _init_i < $depth; _init_i = _init_i + 1) begin
      mem[_init_i] = $dataWidth'd0;
    end
  end
`endif
  always_ff @(posedge clk) begin
    if (port_a_en) begin
      port_a_rdata <= mem[port_a_addr];
    end
    if (port_b_en) begin
      if (port_b_we) begin
        mem[port_b_addr] <= port_b_wdata;
      end else begin
        port_b_rdata <= mem[port_b_addr];
      end
    end
  end
endmodule
''';
}

/// Synthesizable ASIC Mask-ROM for cold-start instruction & constant fetch on
/// manufactured silicon (zero `$readmemh`, zero uninitialized SRAM dependency).
///
/// Emits pure standard-cell `case (addr)` read-only logic with 1- or 2-cycle
/// registered output matching the CPU's [readLatency].
class AsicBootRom extends Module with SystemVerilog {
  final int romWords;
  final int dataWidth;
  final int addrWidth;
  final int readLatency;
  final Uint16List romData;

  AsicBootRom({
    required Logic clk,
    required Logic portAAddr,
    required Logic portAEn,
    required Logic portBAddr,
    required Logic portBEn,
    required List<int> words,
    this.readLatency = 1,
    this.dataWidth = 16,
    super.name = 'asic_boot_rom',
  })  : romWords = words.isEmpty ? 2 : words.length,
        addrWidth = (words.length <= 1) ? 1 : (words.length - 1).bitLength,
        romData = Uint16List(words.isEmpty ? 2 : words.length) {
    assert(readLatency == 1 || readLatency == 2,
        'AsicBootRom readLatency must be 1 or 2');
    for (var i = 0; i < words.length; i++) {
      romData[i] = words[i] & 0xFFFF;
    }

    clk = addInput('clk', clk);
    portAAddr = addInput('port_a_addr', portAAddr, width: addrWidth);
    portAEn = addInput('port_a_en', portAEn);
    portBAddr = addInput('port_b_addr', portBAddr, width: addrWidth);
    portBEn = addInput('port_b_en', portBEn);

    final portARdata = addOutput('port_a_rdata', width: dataWidth);
    final portBRdata = addOutput('port_b_rdata', width: dataWidth);

    final aComb = Logic(name: 'rom_a_comb_sim', width: dataWidth);
    final bComb = Logic(name: 'rom_b_comb_sim', width: dataWidth);
    final aRaw = Logic(name: 'rom_a_raw_sim', width: dataWidth);
    final bRaw = Logic(name: 'rom_b_raw_sim', width: dataWidth);

    void refreshReads() {
      final a = portAAddr.value.isValid ? portAAddr.value.toInt() : 0;
      final b = portBAddr.value.isValid ? portBAddr.value.toInt() : 0;
      aComb.put(a < romData.length ? romData[a] : 0);
      bComb.put(b < romData.length ? romData[b] : 0);
    }

    aComb.put(0);
    bComb.put(0);
    aRaw.put(0);
    bRaw.put(0);
    portARdata.put(0);
    portBRdata.put(0);

    portAAddr.changed.listen((_) => refreshReads());
    portBAddr.changed.listen((_) => refreshReads());

    if (readLatency == 1) {
      Sequential(clk, [
        If(portAEn, then: [portARdata < aComb]),
        If(portBEn, then: [portBRdata < bComb]),
      ]);
    } else {
      Sequential(clk, [
        If(portAEn, then: [aRaw < aComb]),
        portARdata < aRaw,
        If(portBEn, then: [bRaw < bComb]),
        portBRdata < bRaw,
      ]);
    }
  }

  Logic get portARdata => output('port_a_rdata');
  Logic get portBRdata => output('port_b_rdata');

  @override
  String definitionVerilog(String definitionType) {
    final aCases = StringBuffer();
    final bCases = StringBuffer();
    for (var i = 0; i < romData.length; i++) {
      final w = romData[i] & 0xFFFF;
      if (w == 0) continue; // Default branch returns 0 for compact LUT synthesis
      final hexAddr = i.toRadixString(16);
      final hexVal = w.toRadixString(16).padLeft(4, '0');
      aCases.writeln("      $addrWidth'h$hexAddr: a_comb = $dataWidth'h$hexVal;");
      bCases.writeln("      $addrWidth'h$hexAddr: b_comb = $dataWidth'h$hexVal;");
    }

    final seqBlock = readLatency == 1
        ? '''
  always_ff @(posedge clk) begin
    if (port_a_en) port_a_rdata <= a_comb;
    if (port_b_en) port_b_rdata <= b_comb;
  end'''
        : '''
  logic [${dataWidth - 1}:0] a_raw, b_raw;
  always_ff @(posedge clk) begin
    if (port_a_en) a_raw <= a_comb;
    port_a_rdata <= a_raw;
    if (port_b_en) b_raw <= b_comb;
    port_b_rdata <= b_raw;
  end''';

    return '''
module $definitionType (
  input  logic clk,
  input  logic [${addrWidth - 1}:0] port_a_addr,
  input  logic port_a_en,
  output logic [${dataWidth - 1}:0] port_a_rdata,
  input  logic [${addrWidth - 1}:0] port_b_addr,
  input  logic port_b_en,
  output logic [${dataWidth - 1}:0] port_b_rdata
);
  logic [${dataWidth - 1}:0] a_comb, b_comb;
  always_comb begin
    a_comb = $dataWidth'h0000;
    case (port_a_addr)
${aCases.toString()}      default: a_comb = $dataWidth'h0000;
    endcase
  end
  always_comb begin
    b_comb = $dataWidth'h0000;
    case (port_b_addr)
${bCases.toString()}      default: b_comb = $dataWidth'h0000;
    endcase
  end
$seqBlock
endmodule
''';
  }
}

/// ASIC Dual-Port SRAM overlaid with a write-protected synthesizable
/// [AsicBootRom] at `[bootRomBase, bootRomBase + bootRomWords)`.
///
/// Allows an ASIC core to cold-boot deterministically from reset vector
/// `0x0100` (Trap Vector Table + UART/SPI bootloader or firmware) even when
/// on-chip SRAM powers up uninitialized, while keeping scratchpad
/// (`0x0000`–`0x00FF`) and upper RAM/stacks fully writable in SRAM.
class DualPortRamWithBootRom extends Module implements DualPortMemory {
  final int depth;
  final int sramDepth;
  final int bootRomBase;
  final int bootRomWords;
  final int readLatency;
  late final AsicDualPortSram sram;
  late final AsicBootRom bootRom;

  DualPortRamWithBootRom({
    required Logic clk,
    required Logic portAAddr,
    required Logic portAEn,
    required Logic portBAddr,
    required Logic portBWdata,
    required Logic portBWe,
    required Logic portBEn,
    required List<int> romWords,
    this.depth = 2048,
    int? sramDepth,
    this.bootRomBase = 0x0100,
    this.readLatency = 1,
    int dataWidth = 16,
    bool useMacroBlackbox = true,
    String? macroName,
    Map<int, int>? initialMemory,
    super.name = 'asic_ram_with_bootrom',
  })  : sramDepth = sramDepth ?? depth,
        bootRomWords = romWords.length {
    assert(romWords.isNotEmpty, 'romWords must be non-empty');
    assert(bootRomBase >= 0 && bootRomBase + romWords.length <= depth,
        'Boot ROM [$bootRomBase..${bootRomBase + romWords.length}) exceeds depth $depth');
    assert(this.sramDepth >= 2 && this.sramDepth <= depth,
        'sramDepth (${this.sramDepth}) must be within [2, $depth]');

    final addrWidth = (depth <= 1) ? 1 : (depth - 1).bitLength;
    final sramAddrWidth = (this.sramDepth <= 1) ? 1 : (this.sramDepth - 1).bitLength;
    final romAddrWidth = (romWords.length <= 1) ? 1 : (romWords.length - 1).bitLength;

    clk = addInput('clk', clk);
    portAAddr = addInput('port_a_addr', portAAddr, width: addrWidth);
    portAEn = addInput('port_a_en', portAEn);
    portBAddr = addInput('port_b_addr', portBAddr, width: addrWidth);
    portBWdata = addInput('port_b_wdata', portBWdata, width: dataWidth);
    portBWe = addInput('port_b_we', portBWe);
    portBEn = addInput('port_b_en', portBEn);

    final portARdataOut = addOutput('port_a_rdata', width: dataWidth);
    final portBRdataOut = addOutput('port_b_rdata', width: dataWidth);

    final baseConst = Const(bootRomBase, width: addrWidth);
    final endConst = Const(bootRomBase + romWords.length, width: addrWidth);

    Logic inRomRange(Logic addr) {
      final geBase = bootRomBase == 0 ? Const(1) : addr.gte(baseConst);
      final ltEnd =
          (bootRomBase + romWords.length >= depth) ? Const(1) : addr.lt(endConst);
      return geBase & ltEnd;
    }

    final inRomA = inRomRange(portAAddr);
    final inRomB = inRomRange(portBAddr);
    final romOffA = (portAAddr - baseConst).slice(romAddrWidth - 1, 0);
    final romOffB = (portBAddr - baseConst).slice(romAddrWidth - 1, 0);

    final isCompactSram = this.sramDepth < depth;
    final sramEndConst = Const(this.sramDepth, width: addrWidth);
    final inSramA = isCompactSram ? portAAddr.lt(sramEndConst) : Const(1);
    final inSramB = isCompactSram ? portBAddr.lt(sramEndConst) : Const(1);
    final sramAddrA =
        isCompactSram ? portAAddr.slice(sramAddrWidth - 1, 0) : portAAddr;
    final sramAddrB =
        isCompactSram ? portBAddr.slice(sramAddrWidth - 1, 0) : portBAddr;

    bootRom = AsicBootRom(
      clk: clk,
      portAAddr: romOffA,
      portAEn: portAEn & inRomA,
      portBAddr: romOffB,
      portBEn: portBEn & (~portBWe) & inRomB,
      words: romWords,
      readLatency: readLatency,
      dataWidth: dataWidth,
      name: '${name}_rom',
    );

    // Mask writes into the Boot ROM address window (and out-of-range addresses
    // when compact scratchpad sramDepth < depth); SRAM serves [0, sramDepth).
    sram = AsicDualPortSram(
      clk: clk,
      portAAddr: sramAddrA,
      portAEn: portAEn & (~inRomA) & inSramA,
      portBAddr: sramAddrB,
      portBWdata: portBWdata,
      portBWe: portBWe & (~inRomB) & inSramB,
      portBEn: portBEn & (~inRomB) & inSramB,
      depth: this.sramDepth,
      dataWidth: dataWidth,
      readLatency: readLatency,
      useMacroBlackbox: useMacroBlackbox,
      macroName: macroName,
      initialMemory: initialMemory,
      name: '${name}_sram',
    );

    // Align ROM-select (and optional compact SRAM valid) mux with readLatency
    final selAQ1 = Logic(name: 'rom_sel_a_q1');
    final selBQ1 = Logic(name: 'rom_sel_b_q1');
    final selAQ2 = Logic(name: 'rom_sel_a_q2');
    final selBQ2 = Logic(name: 'rom_sel_b_q2');

    if (isCompactSram) {
      final sramAQ1 = Logic(name: 'sram_sel_a_q1');
      final sramBQ1 = Logic(name: 'sram_sel_b_q1');
      final sramAQ2 = Logic(name: 'sram_sel_a_q2');
      final sramBQ2 = Logic(name: 'sram_sel_b_q2');
      if (readLatency == 1) {
        Sequential(clk, [
          If(portAEn, then: [selAQ1 < inRomA, sramAQ1 < inSramA]),
          If(portBEn & (~portBWe), then: [selBQ1 < inRomB, sramBQ1 < inSramB]),
        ]);
        portARdataOut <= mux(
          selAQ1,
          bootRom.portARdata,
          mux(sramAQ1, sram.portARdata, Const(0, width: dataWidth)),
        );
        portBRdataOut <= mux(
          selBQ1,
          bootRom.portBRdata,
          mux(sramBQ1, sram.portBRdata, Const(0, width: dataWidth)),
        );
      } else {
        Sequential(clk, [
          If(portAEn, then: [selAQ1 < inRomA, sramAQ1 < inSramA]),
          selAQ2 < selAQ1,
          sramAQ2 < sramAQ1,
          If(portBEn & (~portBWe), then: [selBQ1 < inRomB, sramBQ1 < inSramB]),
          selBQ2 < selBQ1,
          sramBQ2 < sramBQ1,
        ]);
        portARdataOut <= mux(
          selAQ2,
          bootRom.portARdata,
          mux(sramAQ2, sram.portARdata, Const(0, width: dataWidth)),
        );
        portBRdataOut <= mux(
          selBQ2,
          bootRom.portBRdata,
          mux(sramBQ2, sram.portBRdata, Const(0, width: dataWidth)),
        );
      }
    } else if (readLatency == 1) {
      Sequential(clk, [
        If(portAEn, then: [selAQ1 < inRomA]),
        If(portBEn & (~portBWe), then: [selBQ1 < inRomB]),
      ]);
      portARdataOut <= mux(selAQ1, bootRom.portARdata, sram.portARdata);
      portBRdataOut <= mux(selBQ1, bootRom.portBRdata, sram.portBRdata);
    } else {
      Sequential(clk, [
        If(portAEn, then: [selAQ1 < inRomA]),
        selAQ2 < selAQ1,
        If(portBEn & (~portBWe), then: [selBQ1 < inRomB]),
        selBQ2 < selBQ1,
      ]);
      portARdataOut <= mux(selAQ2, bootRom.portARdata, sram.portARdata);
      portBRdataOut <= mux(selBQ2, bootRom.portBRdata, sram.portBRdata);
    }
  }

  @override
  Uint16List get mem => sram.mem;

  @override
  Logic get portARdata => output('port_a_rdata');

  @override
  Logic get portBRdata => output('port_b_rdata');
}

/// Pure standard-cell 1W1R flip-flop register file for small ASIC queues/tags
/// (`iqRam`, `ICache`/`DCache` tag arrays, `NocRouterNi` RX FIFO).
/// Zero FPGA `(* ram_style = "distributed" *)` attributes.
class AsicSmallRam extends Module with SystemVerilog {
  final int addrWidth;
  final int dataWidth;
  final int memDepth;
  final List<BigInt> _mem;

  AsicSmallRam({
    required Logic clk,
    required Logic waddr,
    required Logic wdata,
    required Logic we,
    required Logic raddr,
    required this.addrWidth,
    required this.dataWidth,
    super.name = 'asic_small_ram',
  })  : memDepth = 1 << addrWidth,
        _mem = List<BigInt>.filled(1 << addrWidth, BigInt.zero) {
    clk = addInput('clk', clk);
    waddr = addInput('waddr', waddr, width: addrWidth);
    wdata = addInput('wdata', wdata, width: dataWidth);
    we = addInput('we', we);
    raddr = addInput('raddr', raddr, width: addrWidth);

    final rdata = addOutput('rdata', width: dataWidth);

    final wrFireQ = Logic(name: 'wr_fire_q_sim');
    final wrAddrQ = Logic(name: 'wr_addr_q_sim', width: addrWidth);
    final wrDataQ = Logic(name: 'wr_data_q_sim', width: dataWidth);

    void refreshRead() {
      final r = raddr.value.isValid ? raddr.value.toInt() : 0;
      rdata.put(
        r < memDepth ? LogicValue.ofBigInt(_mem[r], dataWidth) : 0,
      );
    }

    wrFireQ.put(0);
    wrAddrQ.put(0);
    wrDataQ.put(0);
    rdata.put(0);

    raddr.changed.listen((_) => refreshRead());

    Sequential(clk, [
      wrFireQ < we,
      wrAddrQ < waddr,
      wrDataQ < wdata,
    ]);

    clk.posedge.listen((_) {
      Simulator.postTick.first.then(
        (_) {
          if (wrFireQ.value.isValid && wrFireQ.value.toBool()) {
            final w = wrAddrQ.value.isValid ? wrAddrQ.value.toInt() : 0;
            final d =
                wrDataQ.value.isValid ? wrDataQ.value.toBigInt() : BigInt.zero;
            if (w < memDepth) {
              _mem[w] = d;
            }
          }
          refreshRead();
        },
        onError: (_) {},
      );
    });
  }

  Logic get rdata => output('rdata');

  @override
  String definitionVerilog(String definitionType) => '''
module $definitionType (
  input  logic clk,
  input  logic [${addrWidth - 1}:0] waddr,
  input  logic [${dataWidth - 1}:0] wdata,
  input  logic we,
  input  logic [${addrWidth - 1}:0] raddr,
  output logic [${dataWidth - 1}:0] rdata
);
  logic [${dataWidth - 1}:0] mem [0:${memDepth - 1}];
`ifndef SYNTHESIS
  integer _init_i;
  initial begin
    for (_init_i = 0; _init_i < $memDepth; _init_i = _init_i + 1) begin
      mem[_init_i] = $dataWidth'd0;
    end
  end
`endif
  always_ff @(posedge clk) begin
    if (we) begin
      mem[waddr] <= wdata;
    end
  end
  assign rdata = mem[raddr];
endmodule
''';
}

/// Foundry-ready Single-Port SRAM macro wrapper (`mr4_sram_sp_<depth>x<dataWidth>`)
/// for ASIC `ICache` / `DCache` data arrays.
class AsicSramSpMacro extends Module with SystemVerilog {
  final int depth;
  final int dataWidth;
  final int addrWidth;
  final String macroName;
  final Uint16List mem;

  AsicSramSpMacro({
    required Logic clk,
    required Logic addr,
    required Logic wdata,
    required Logic we,
    required Logic en,
    required this.depth,
    this.dataWidth = 16,
    String? macroName,
    super.name = 'asic_sram_sp_macro',
  })  : addrWidth = (depth <= 1) ? 1 : (depth - 1).bitLength,
        macroName = macroName ?? 'mr4_sram_sp_${depth}x$dataWidth',
        mem = Uint16List(depth) {
    clk = addInput('clk', clk);
    addr = addInput('addr', addr, width: addrWidth);
    wdata = addInput('wdata', wdata, width: dataWidth);
    we = addInput('we', we);
    en = addInput('en', en);

    final rdata = addOutput('rdata', width: dataWidth);

    final readComb = Logic(name: 'read_comb_sim', width: dataWidth);
    final wrFireQ = Logic(name: 'wr_fire_q_sim');
    final wrAddrQ = Logic(name: 'wr_addr_q_sim', width: addrWidth);
    final wrDataQ = Logic(name: 'wr_data_q_sim', width: dataWidth);

    void refreshRead() {
      final a = addr.value.isValid ? addr.value.toInt() : 0;
      readComb.put(a < depth ? mem[a] : 0);
    }

    readComb.put(0);
    rdata.put(0);
    wrFireQ.put(0);
    wrAddrQ.put(0);
    wrDataQ.put(0);

    addr.changed.listen((_) => refreshRead());

    Sequential(clk, [
      If(en & ~we, then: [rdata < readComb]),
      wrFireQ < (en & we),
      wrAddrQ < addr,
      wrDataQ < wdata,
    ]);

    clk.posedge.listen((_) {
      Simulator.postTick.first.then(
        (_) {
          if (wrFireQ.value.isValid && wrFireQ.value.toBool()) {
            final wa = wrAddrQ.value.isValid ? wrAddrQ.value.toInt() : 0;
            final wd = wrDataQ.value.isValid ? wrDataQ.value.toInt() : 0;
            if (wa < depth) {
              mem[wa] = wd & 0xFFFF;
            }
          }
          refreshRead();
        },
        onError: (_) {},
      );
    });
  }

  Logic get rdata => output('rdata');

  @override
  String get definitionName => macroName;

  @override
  String definitionVerilog(String definitionType) => '''
`ifdef SYNTHESIS
(* blackbox *)
`endif
module $definitionType (
  input  logic clk,
  input  logic [${addrWidth - 1}:0] addr,
  input  logic [${dataWidth - 1}:0] wdata,
  input  logic we,
  input  logic en,
  output logic [${dataWidth - 1}:0] rdata
);
`ifndef SYNTHESIS
  logic [${dataWidth - 1}:0] mem [0:${depth - 1}];
  integer _init_i;
  initial begin
    for (_init_i = 0; _init_i < $depth; _init_i = _init_i + 1) begin
      mem[_init_i] = $dataWidth'd0;
    end
  end
  always_ff @(posedge clk) begin
    if (en) begin
      if (we) begin
        mem[addr] <= wdata;
      end else begin
        rdata <= mem[addr];
      end
    end
  end
`endif
endmodule
''';
}

/// Pure standard-cell single-port flop RAM (zero FPGA attributes, zero blackbox)
/// for compact ASIC cache builds.
class AsicSinglePortFlopRam extends Module with SystemVerilog {
  final int depth;
  final int dataWidth;
  final int addrWidth;
  final Uint16List mem;

  AsicSinglePortFlopRam({
    required Logic clk,
    required Logic addr,
    required Logic wdata,
    required Logic we,
    required Logic en,
    required this.depth,
    this.dataWidth = 16,
    super.name = 'asic_sp_flop_ram',
  })  : addrWidth = (depth <= 1) ? 1 : (depth - 1).bitLength,
        mem = Uint16List(depth) {
    clk = addInput('clk', clk);
    addr = addInput('addr', addr, width: addrWidth);
    wdata = addInput('wdata', wdata, width: dataWidth);
    we = addInput('we', we);
    en = addInput('en', en);

    final rdata = addOutput('rdata', width: dataWidth);

    final readComb = Logic(name: 'read_comb_sim', width: dataWidth);
    final wrFireQ = Logic(name: 'wr_fire_q_sim');
    final wrAddrQ = Logic(name: 'wr_addr_q_sim', width: addrWidth);
    final wrDataQ = Logic(name: 'wr_data_q_sim', width: dataWidth);

    void refreshRead() {
      final a = addr.value.isValid ? addr.value.toInt() : 0;
      readComb.put(a < depth ? mem[a] : 0);
    }

    readComb.put(0);
    rdata.put(0);
    wrFireQ.put(0);
    wrAddrQ.put(0);
    wrDataQ.put(0);

    addr.changed.listen((_) => refreshRead());

    Sequential(clk, [
      If(en & ~we, then: [rdata < readComb]),
      wrFireQ < (en & we),
      wrAddrQ < addr,
      wrDataQ < wdata,
    ]);

    clk.posedge.listen((_) {
      Simulator.postTick.first.then(
        (_) {
          if (wrFireQ.value.isValid && wrFireQ.value.toBool()) {
            final wa = wrAddrQ.value.isValid ? wrAddrQ.value.toInt() : 0;
            final wd = wrDataQ.value.isValid ? wrDataQ.value.toInt() : 0;
            if (wa < depth) {
              mem[wa] = wd & 0xFFFF;
            }
          }
          refreshRead();
        },
        onError: (_) {},
      );
    });
  }

  Logic get rdata => output('rdata');

  @override
  String definitionVerilog(String definitionType) => '''
module $definitionType (
  input  logic clk,
  input  logic [${addrWidth - 1}:0] addr,
  input  logic [${dataWidth - 1}:0] wdata,
  input  logic we,
  input  logic en,
  output logic [${dataWidth - 1}:0] rdata
);
  logic [${dataWidth - 1}:0] mem [0:${depth - 1}];
`ifndef SYNTHESIS
  integer _init_i;
  initial begin
    for (_init_i = 0; _init_i < $depth; _init_i = _init_i + 1) begin
      mem[_init_i] = $dataWidth'd0;
    end
  end
`endif
  always_ff @(posedge clk) begin
    if (en) begin
      if (we) begin
        mem[addr] <= wdata;
      end else begin
        rdata <= mem[addr];
      end
    end
  end
endmodule
''';
}

/// Central target-selectable memory factory decoupling shared RTL (`CpuCore`,
/// `ICache`/`DCache`, `NocRouterNi`) from FPGA-only primitives.
class MemoryFactory {
  /// Extract a contiguous slice of Boot ROM words `[baseAddr, baseAddr + wordCount)`
  /// from an assembled `.hex` file (or return zeros if the file does not exist).
  static List<int> loadBootRomFromHex(
    String hexPath, {
    int baseAddr = 0x0100,
    required int wordCount,
  }) {
    final full = TdpBram.parseHexFile(hexPath, baseAddr + wordCount);
    return List<int>.generate(wordCount, (i) => full[baseAddr + i]);
  }

  /// Extract a contiguous slice of Boot ROM words from a sparse word map.
  static List<int> loadBootRomFromMap(
    Map<int, int> words, {
    int baseAddr = 0x0100,
    required int wordCount,
  }) {
    return List<int>.generate(
      wordCount,
      (i) => (words[baseAddr + i] ?? 0) & 0xFFFF,
    );
  }

  /// Instantiate main True Dual-Port CPU memory for [target].
  static DualPortMemory createMainRam({
    required MemoryTarget target,
    required Logic clk,
    required Logic portAAddr,
    required Logic portAEn,
    required Logic portBAddr,
    required Logic portBWdata,
    required Logic portBWe,
    required Logic portBEn,
    required int depth,
    int dataWidth = 16,
    int readLatency = 2,
    String? initHexFile,
    Map<int, int>? initialMemory,
    int bootRomBase = 0x0100,
    List<int>? bootRomWords,
    int? sramDepth,
    String? sramMacroName,
    String name = 'tdp_bram',
  }) {
    if (target == MemoryTarget.fpgaEcp5) {
      return TdpBram(
        clk: clk,
        portAAddr: portAAddr,
        portAEn: portAEn,
        portBAddr: portBAddr,
        portBWdata: portBWdata,
        portBWe: portBWe,
        portBEn: portBEn,
        depth: depth,
        dataWidth: dataWidth,
        initHexFile: initHexFile,
        initialMemory: initialMemory,
        name: name,
      );
    }

    final useMacro = target == MemoryTarget.asicSram;
    List<int>? resolvedRom = bootRomWords;
    if (resolvedRom == null &&
        initHexFile != null &&
        initHexFile.isNotEmpty &&
        File(initHexFile).existsSync()) {
      // Optional convenience: if caller provided a hex file without explicit
      // bootRomWords, keep SRAM clean unless bootRomWords is explicitly passed.
      resolvedRom = null;
    }

    if (resolvedRom != null && resolvedRom.isNotEmpty) {
      return DualPortRamWithBootRom(
        clk: clk,
        portAAddr: portAAddr,
        portAEn: portAEn,
        portBAddr: portBAddr,
        portBWdata: portBWdata,
        portBWe: portBWe,
        portBEn: portBEn,
        romWords: resolvedRom,
        depth: depth,
        sramDepth: sramDepth,
        bootRomBase: bootRomBase,
        readLatency: readLatency,
        dataWidth: dataWidth,
        useMacroBlackbox: useMacro,
        macroName: sramMacroName,
        initialMemory: initialMemory,
        name: name,
      );
    }

    return AsicDualPortSram(
      clk: clk,
      portAAddr: portAAddr,
      portAEn: portAEn,
      portBAddr: portBAddr,
      portBWdata: portBWdata,
      portBWe: portBWe,
      portBEn: portBEn,
      depth: depth,
      dataWidth: dataWidth,
      readLatency: readLatency,
      useMacroBlackbox: useMacro,
      macroName: sramMacroName,
      initialMemory: initialMemory,
      name: name,
    );
  }

  /// Instantiate small 1W1R RAM for `iqRam`, cache `tagRam`, or `NocRouterNi`
  /// RX FIFO (`NocFifoRam` on ECP5 FPGA, pure flop `AsicSmallRam` on ASIC).
  static Logic createSmallRam({
    required MemoryTarget target,
    required Logic clk,
    required Logic waddr,
    required Logic wdata,
    required Logic we,
    required Logic raddr,
    required int addrWidth,
    required int dataWidth,
    String name = 'small_ram',
  }) {
    if (target == MemoryTarget.fpgaEcp5) {
      return NocFifoRam(
        clk: clk,
        waddr: waddr,
        wdata: wdata,
        we: we,
        raddr: raddr,
        addrWidth: addrWidth,
        dataWidth: dataWidth,
        name: name,
      ).rdata;
    }
    return AsicSmallRam(
      clk: clk,
      waddr: waddr,
      wdata: wdata,
      we: we,
      raddr: raddr,
      addrWidth: addrWidth,
      dataWidth: dataWidth,
      name: name,
    ).rdata;
  }

  /// Instantiate single-port cache data array (`CacheDataBram` on ECP5 FPGA,
  /// `AsicSramSpMacro` or `AsicSinglePortFlopRam` on ASIC).
  static Logic createCacheDataRam({
    required MemoryTarget target,
    required Logic clk,
    required Logic addr,
    required Logic wdata,
    required Logic we,
    required Logic en,
    required int depth,
    int dataWidth = 16,
    String? sramMacroName,
    String name = 'cache_data_ram',
  }) {
    if (target == MemoryTarget.fpgaEcp5) {
      return CacheDataBram(
        clk: clk,
        addr: addr,
        wdata: wdata,
        we: we,
        en: en,
        depth: depth,
        dataWidth: dataWidth,
        name: name,
      ).rdata;
    }
    if (target == MemoryTarget.asicSram) {
      return AsicSramSpMacro(
        clk: clk,
        addr: addr,
        wdata: wdata,
        we: we,
        en: en,
        depth: depth,
        dataWidth: dataWidth,
        macroName: sramMacroName,
        name: name,
      ).rdata;
    }
    return AsicSinglePortFlopRam(
      clk: clk,
      addr: addr,
      wdata: wdata,
      we: we,
      en: en,
      depth: depth,
      dataWidth: dataWidth,
      name: name,
    ).rdata;
  }
}

// ==============================================================================
// FILE: hdl/mr4/bin/generate_asic_tile.dart
// Hierarchical ASIC Tile & Multi-Tile Cluster SystemVerilog Generator (Track D.4)
//
// Emits three clean artifacts under --out (default: build/asic_tile):
//   1. mr4_tile.sv     - Single reusable hardened tile macro (`mr4_tile`)
//   2. mr4_quad_top.sv - Hierarchical N-tile cluster wrapper with `(* blackbox *)`
//                        `mr4_tile` instantiations (for ORFS macro assembly)
//   3. mr4_quad_sim.sv - Full flat N-tile SystemVerilog (for Verilator/Yosys sim)
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:microrisc4_rohd/cpu_config.dart';
import 'package:microrisc4_rohd/memory_factory.dart';
import 'package:microrisc4_rohd/mr4_tile.dart';
import 'package:microrisc4_rohd/noc_router.dart';

void main(List<String> args) async {
  String? bootHexPath;
  var outDir = '../../build/asic_tile';
  var memTargetStr = 'flop'; // flop | sram
  var memWords = 1024;
  var memLatency = 1;
  var bootRomBase = 0x0100;
  var bootRomWords = 512;
  var clkFreqMhz = 100;
  var numTiles = 4;
  var nocFifoDepth = 16;
  var topName = 'mr4_quad_top';
  int? uartDivisor;
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
    } else if (args[i] == '--num-tiles' && i + 1 < args.length) {
      numTiles = int.tryParse(args[++i]) ?? numTiles;
    } else if (args[i] == '--noc-fifo-depth' && i + 1 < args.length) {
      nocFifoDepth = int.tryParse(args[++i]) ?? nocFifoDepth;
    } else if (args[i] == '--top-name' && i + 1 < args.length) {
      topName = args[++i];
    } else if (args[i] == '--uart-divisor' && i + 1 < args.length) {
      uartDivisor = int.tryParse(args[++i]);
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
    stderr.writeln(
        'Error: --mem-target must be "sram" or "flop", got "$memTargetStr"');
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

  final idWidth = NocRouterNi.idWidthForCores(numTiles);
  final tileCfg = CpuConfig(
    coreId: 0,
    enableCpuid: true,
    enableUart: true,
    enableCrossTraps: true,
    enableEpc: true,
    enableMathAccel: enableMath,
    enableSpi: false,
    enableNoc: true,
    enableSdramCache: false,
    isPipelined: true,
    memReadLatency: memLatency,
    memoryTarget: target,
    bootRomBase: bootRomBase,
    bootRomWords: romWords,
    sramMacroName: sramMacroName,
    clkFreqMhz: clkFreqMhz,
    nocChannels: 1,
    nocFifoDepth: nocFifoDepth,
    trapTableBase: 0x0100,
    memWords: memWords,
  );

  print(
    'Building MicroRISC4 Hierarchical Tile (`mr4_tile`) & $numTiles-Tile Cluster (`$topName`) '
    '(target=$memTargetStr, clk=${clkFreqMhz}MHz, memWords=$memWords, '
    'nocFifo=$nocFifoDepth, idWidth=$idWidth'
    '${romWords != null ? ', bootRom=0x${bootRomBase.toRadixString(16)}+${romWords.length}w' : ', bootRom=none'}'
    '${enableMath ? ', math=on' : ''}'
    '${uartDivisor != null ? ', uartDiv=$uartDivisor' : ''})...',
  );

  final dir = Directory(outDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }

  // 1. Standalone hardened tile macro (`mr4_tile.sv`)
  final singleTile = Mr4Tile(
    clk: Logic(name: 'clk'),
    rstN: Logic(name: 'rst_n'),
    tileId: Logic(name: 'tile_id', width: idWidth),
    uartRxd: Logic(name: 'uart_rxd'),
    ringInValid: Logic(name: 'ring_in_valid'),
    ringInType: Logic(name: 'ring_in_type'),
    ringInSrc: Logic(name: 'ring_in_src', width: idWidth),
    ringInDst: Logic(name: 'ring_in_dst', width: idWidth),
    ringInPayload: Logic(name: 'ring_in_payload', width: 16),
    ringOutReady: Logic(name: 'ring_out_ready'),
    numCores: numTiles,
    nocFifoDepth: nocFifoDepth,
    config: tileCfg,
    uartDivisor: uartDivisor,
  );
  await singleTile.build();
  final tileSv = singleTile.generateSynth();
  final tileFile = File('${dir.path}/mr4_tile.sv');
  await tileFile.writeAsString(tileSv);

  // 2. Hierarchical top-level wrapper (`mr4_quad_top.sv`) with blackbox `mr4_tile`
  final hierCluster = Mr4AsicCluster(
    clk: Logic(name: 'clk'),
    rstN: Logic(name: 'rst_n'),
    uartRxd: Logic(name: 'uart_rxd'),
    numTiles: numTiles,
    nocFifoDepth: nocFifoDepth,
    tileConfig: tileCfg,
    uartDivisor: uartDivisor,
    useTileBlackbox: true,
    name: topName,
  );
  await hierCluster.build();
  final hierSv = hierCluster.generateSynth();
  final hierFile = File('${dir.path}/$topName.sv');
  await hierFile.writeAsString(hierSv);

  // 3. Full flat simulation RTL (`mr4_quad_sim.sv`) for Verilator / Icarus sim
  final simCluster = Mr4AsicCluster(
    clk: Logic(name: 'clk'),
    rstN: Logic(name: 'rst_n'),
    uartRxd: Logic(name: 'uart_rxd'),
    numTiles: numTiles,
    nocFifoDepth: nocFifoDepth,
    tileConfig: tileCfg,
    uartDivisor: uartDivisor,
    useTileBlackbox: false,
    name: topName,
  );
  await simCluster.build();
  final simSv = simCluster.generateSynth();
  final simFile = File('${dir.path}/${topName}_sim.sv');
  await simFile.writeAsString(simSv);

  print('Tile & cluster generation complete:');
  print('  ${tileFile.path} (${tileSv.length} bytes)');
  print('  ${hierFile.path} (${hierSv.length} bytes)');
  print('  ${simFile.path} (${simSv.length} bytes)');
}

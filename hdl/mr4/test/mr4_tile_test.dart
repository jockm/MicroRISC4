// ==============================================================================
// FILE: hdl/mr4/test/mr4_tile_test.dart
// Track D.4 Verification: Reusable Hardened `Mr4Tile` & 4-Tile `Mr4AsicCluster`
//
// Verifies:
//   1. Single `Mr4Tile` worker with strapped `tile_id = 2` services an incoming
//      MBOX doorbell via Hardware Trap 14 and replies on `ring_out_*`.
//   2. Full 4-tile `Mr4AsicCluster` (`mr4_quad_top`) cold-boots ALL 4 identical
//      tiles from uninitialized `0xA5A5` RAM via shared `AsicBootRom`
//      (`asic_tile_boot.asm`), pings Tiles 1..3 over the registered neighbor
//      Lean Ring (MBOX + Trap 14 + RX FIFO reply), marks `[0x0303] = 0x600D` on
//      all 4 tiles, and prints `MR4 TILE0 OK\r\nRING PASS\r\n` on UART!
//   3. Hierarchical SystemVerilog cleanliness: `mr4_tile.sv` and black-boxed
//      `mr4_quad_top.sv` contain zero FPGA primitives or `$readmemh`.
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:microrisc4_rohd/cpu_config.dart';
import 'package:microrisc4_rohd/memory_factory.dart';
import 'package:microrisc4_rohd/mr4_tile.dart';

List<int> _assembleTileBootRom() {
  final repoRoot = Directory('../..').absolute.path;
  final tmpHex = File('${Directory.systemTemp.path}/mr4_tile_boot_test.hex');
  final res = Process.runSync(
    'python3',
    [
      '$repoRoot/tools/mr4asm.py',
      '-I',
      '$repoRoot/lib',
      '$repoRoot/mr4src/asm/asic_tile_boot.asm',
      '--hex',
      '-o',
      tmpHex.path,
    ],
  );
  if (res.exitCode != 0) {
    fail('mr4asm.py failed: ${res.stdout}\n${res.stderr}');
  }
  final words = MemoryFactory.loadBootRomFromHex(
    tmpHex.path,
    baseAddr: 0x0100,
    wordCount: 512,
  );
  if (tmpHex.existsSync()) tmpHex.deleteSync();
  return words;
}

void main() {
  final bootRomWords = _assembleTileBootRom();

  tearDown(() async {
    await Simulator.reset();
  });

  test('Single Mr4Tile with strapped tile_id=2 services MBOX Trap 14 and replies',
      () async {
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final tileId = Logic(name: 'tile_id', width: 2);
    final uartRxd = Logic(name: 'uart_rxd');
    final ringInValid = Logic(name: 'ring_in_valid');
    final ringInType = Logic(name: 'ring_in_type');
    final ringInSrc = Logic(name: 'ring_in_src', width: 2);
    final ringInDst = Logic(name: 'ring_in_dst', width: 2);
    final ringInPayload = Logic(name: 'ring_in_payload', width: 16);
    final ringOutReady = Logic(name: 'ring_out_ready');

    final tile = Mr4Tile(
      clk: clk,
      rstN: rstN,
      tileId: tileId,
      uartRxd: uartRxd,
      ringInValid: ringInValid,
      ringInType: ringInType,
      ringInSrc: ringInSrc,
      ringInDst: ringInDst,
      ringInPayload: ringInPayload,
      ringOutReady: ringOutReady,
      numCores: 4,
      nocFifoDepth: 16,
      uartDivisor: 8,
      config: CpuConfig(
        coreId: 0,
        enableCpuid: true,
        enableUart: true,
        enableCrossTraps: true,
        enableEpc: true,
        enableNoc: true,
        isPipelined: true,
        memReadLatency: 1,
        memoryTarget: MemoryTarget.asicFlop,
        bootRomBase: 0x0100,
        bootRomWords: bootRomWords,
        clkFreqMhz: 100,
        memWords: 1024,
      ),
    );
    await tile.build();

    // Poison local RAM with 0xA5A5 to verify cold-start from AsicBootRom
    for (var i = 0; i < tile.cpu.ram.mem.length; i++) {
      tile.cpu.ram.mem[i] = 0xA5A5;
    }

    rstN.put(0);
    tileId.put(2);
    uartRxd.put(1);
    ringInValid.put(0);
    ringInType.put(0);
    ringInSrc.put(0);
    ringInDst.put(0);
    ringInPayload.put(0);
    ringOutReady.put(1);

    int? replyPayload;
    int? replySrc;
    int? replyDst;
    int? replyType;

    Simulator.registerAction(50, () => rstN.put(1));

    // Inject MBOX doorbell (0x1002 from src=0 -> dst=2) once worker is looping
    Simulator.registerAction(400, () {
      ringInValid.put(1);
      ringInType.put(1); // MBOX doorbell
      ringInSrc.put(0);
      ringInDst.put(2);
      ringInPayload.put(0x1002);
    });
    Simulator.registerAction(410, () {
      ringInValid.put(0);
    });

    clk.posedge.listen((_) {
      if (tile.ringOutValid.value.isValid && tile.ringOutValid.value.toBool()) {
        replyPayload ??= tile.ringOutPayload.value.toInt();
        replySrc ??= tile.ringOutSrc.value.toInt();
        replyDst ??= tile.ringOutDst.value.toInt();
        replyType ??= tile.ringOutType.value.toInt();
      }
    });

    Simulator.setMaxSimTime(2500);
    await Simulator.run();

    expect(replyPayload, equals(0x2002),
        reason: 'Worker tile 2 must reply payload + 0x1000');
    expect(replySrc, equals(2),
        reason: 'Reply source must come from strapped tile_id=2');
    expect(replyDst, equals(0), reason: 'Reply must target sender Tile 0');
    expect(replyType, equals(0), reason: 'Reply must be RX FIFO data flit');
    expect(tile.cpu.ram.mem[0x0303], equals(0x600D),
        reason: 'Worker tile must write healthy sentinel 0x600D to [0x0303]');
  });

  test(
      '4-Tile Mr4AsicCluster cold-boots from shared Boot ROM and passes full ring round-trip',
      () async {
    const int baudDiv = 8;
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final uartRxd = Logic(name: 'uart_rxd');

    final cluster = Mr4AsicCluster(
      clk: clk,
      rstN: rstN,
      uartRxd: uartRxd,
      numTiles: 4,
      nocFifoDepth: 16,
      uartDivisor: baudDiv,
      useTileBlackbox: false,
      tileConfig: CpuConfig(
        coreId: 0,
        enableCpuid: true,
        enableUart: true,
        enableCrossTraps: true,
        enableEpc: true,
        enableNoc: true,
        isPipelined: true,
        memReadLatency: 1,
        memoryTarget: MemoryTarget.asicFlop,
        bootRomBase: 0x0100,
        bootRomWords: bootRomWords,
        clkFreqMhz: 100,
        memWords: 1024,
      ),
    );
    await cluster.build();

    // Poison every tile's RAM with garbage to prove cold boot
    for (final t in cluster.tiles) {
      for (var i = 0; i < t.cpu.ram.mem.length; i++) {
        t.cpu.ram.mem[i] = 0xA5A5;
      }
    }

    rstN.put(0);
    uartRxd.put(1);
    Simulator.registerAction(50, () => rstN.put(1));

    final txBytes = <int>[];
    clk.posedge.listen((_) {
      final t0 = cluster.tiles[0].cpu;
      if (t0.txStrobe.value.isValid && t0.txStrobe.value.toBool()) {
        txBytes.add(t0.txData.value.toInt() & 0xFF);
        if (String.fromCharCodes(txBytes).contains('RING PASS\r\n')) {
          Simulator.endSimulation();
        }
      }
    });

    Simulator.setMaxSimTime(60000);
    await Simulator.run();

    final uartOutput = String.fromCharCodes(txBytes);
    final pcs = [
      for (var i = 0; i < 4; i++)
        't$i=0x${cluster.tiles[i].debugPc.value.toInt().toRadixString(16)}'
    ].join(', ');
    expect(uartOutput, contains('MR4 TILE0 OK\r\n'), reason: 'PCs: $pcs');
    expect(uartOutput, contains('RING PASS\r\n'), reason: 'PCs: $pcs');
    for (var i = 0; i < 4; i++) {
      expect(cluster.tiles[i].cpu.ram.mem[0x0303], equals(0x600D),
          reason: 'Tile $i must have completed ring verification (0x600D); PCs: $pcs');
    }
  });

  test(
      'Hierarchical mr4_tile & blackbox mr4_quad_top SV are 100% ASIC-clean (zero FPGA primitives)',
      () async {
    final tileCfg = CpuConfig(
      coreId: 0,
      enableCpuid: true,
      enableUart: true,
      enableCrossTraps: true,
      enableEpc: true,
      enableNoc: true,
      isPipelined: true,
      memReadLatency: 1,
      memoryTarget: MemoryTarget.asicSram,
      bootRomBase: 0x0100,
      bootRomWords: bootRomWords,
      clkFreqMhz: 100,
      memWords: 2048,
    );

    final tile = Mr4Tile(
      clk: Logic(name: 'clk'),
      rstN: Logic(name: 'rst_n'),
      tileId: Logic(name: 'tile_id', width: 2),
      uartRxd: Logic(name: 'uart_rxd'),
      ringInValid: Logic(name: 'ring_in_valid'),
      ringInType: Logic(name: 'ring_in_type'),
      ringInSrc: Logic(name: 'ring_in_src', width: 2),
      ringInDst: Logic(name: 'ring_in_dst', width: 2),
      ringInPayload: Logic(name: 'ring_in_payload', width: 16),
      ringOutReady: Logic(name: 'ring_out_ready'),
      numCores: 4,
      config: tileCfg,
    );
    await tile.build();
    final tileSv = tile.generateSynth();

    expect(tileSv, contains('module mr4_tile'));
    expect(tileSv, contains('mr4_sram_dp_2048x16'));
    expect(tileSv, isNot(contains('EHXPLLL')));
    expect(tileSv, isNot(contains('ODDRX1F')));
    expect(tileSv, isNot(contains('ram_style')));
    expect(tileSv, isNot(contains('syn_useioff')));
    expect(tileSv, isNot(contains(r'$readmemh')));

    final hierTop = Mr4AsicCluster(
      clk: Logic(name: 'clk'),
      rstN: Logic(name: 'rst_n'),
      uartRxd: Logic(name: 'uart_rxd'),
      numTiles: 4,
      useTileBlackbox: true,
      name: 'mr4_quad_top',
    );
    await hierTop.build();
    final hierSv = hierTop.generateSynth();

    expect(hierSv, contains('module mr4_quad_top'));
    expect(hierSv, contains('(* blackbox *)'));
    expect(hierSv, contains('u_tile_0'));
    expect(hierSv, contains('u_tile_3'));
    expect(hierSv, isNot(contains('CpuCore')));
  });
}

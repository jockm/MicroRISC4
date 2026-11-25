// ==============================================================================
// FILE: hdl/mr4/test/mr4_tiny_top_test.dart
// Track E.1.2 Verification: Tiny Tapeout MicroRISC4 (`tt_um_mr4`) + `tiny_boot.asm`
//
// End-to-end verification of the complete `tt_um_mr4` chip over its exact
// Tiny Tapeout pinout (`ui_in`, `uo_out`, `uio_in`, `uio_out`, `uio_oe`, `ena`,
// `clk`, `rst_n`):
//   1. Verifies exact Tiny Tapeout standard port interface & zero FPGA primitives.
//   2. Cold-boots `tt_um_mr4` with real assembled `mr4src/asm/tiny_boot.asm` in
//      `AsicBootRom` + behavioral APS6404L QSPI PSRAM attached to `uio[7:0]`:
//        - Confirms `"MR4 TT\r\n"` banner on `uo_out[0]` (UART TX).
//        - Pings `'?'` on `ui_in[0]` (UART RX) -> verifies `'!'`.
//        - Uploads a real MicroRISC4 program into external QSPI PSRAM (`0x0400`)
//          using `'L'` -> verifies `'K'` ack.
//        - Peeks `[0x0400]` using `'P'` -> verifies exact word readback.
//        - Jumps to `0x0400` using `'G'` -> verifies `'G'` ack, program execution
//          directly out of QSPI PSRAM, `"OK!"` over UART TX, and PSRAM data writes
//          (`0xCAFE` at `0x0500`, `0xCAFF` at `0x0501`).
//   3. Verifies QSPI Flash XIP auto-boot (`ui_in[1] = 1`): when external QSPI
//      Flash CS0 holds magic `0x4D34` ("M4") at `0x0400` and code at `0x0401`,
//      cold-boot jumps straight into XIP Flash and emits `'F'` over UART TX!
// ==============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:microrisc4_rohd/memory_factory.dart';
import 'package:microrisc4_rohd/mr4_tiny_top.dart';
import 'qspi_mem_controller_test.dart';

/// Assemble `mr4src/asm/tiny_boot.asm` into a 256-word Boot ROM slice (`0x0100..0x01FF`).
List<int> assembleTinyBootRom() {
  final repoRoot = Directory.current.path.endsWith('/hdl/mr4')
      ? Directory.current.parent.parent.path
      : Directory.current.path;
  final outDir = Directory('$repoRoot/build/asic_tiny');
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
  final hexPath = '${outDir.path}/tiny_boot_test.hex';
  final asmPath = '$repoRoot/mr4src/asm/tiny_boot.asm';
  final res = Process.runSync(
    'python3',
    ['$repoRoot/tools/mr4asm.py', '-I', '$repoRoot/lib', asmPath, '--hex', '-o', hexPath],
  );
  if (res.exitCode != 0) {
    fail('mr4asm failed assembling tiny_boot.asm:\n${res.stdout}\n${res.stderr}');
  }
  return MemoryFactory.loadBootRomFromHex(
    hexPath,
    baseAddr: 0x0100,
    wordCount: 256,
  );
}

/// Attach behavioral QSPI PSRAM (CS1 = `uio[6]`) and optional Flash (CS0 = `uio[0]`)
/// directly to the Tiny Tapeout `uio_out` / `uio_oe` / `uio_in` pins.
void attachTinyQspiPmod({
  required Logic clk,
  required Mr4TinyTop dut,
  required Logic uioIn,
  required BehavioralQspiChip psram,
  BehavioralQspiChip? flash,
}) {
  int lastSck = 0;
  int lastCs1 = 1;
  int lastCs0 = 1;

  void driveUioIn() {
    int sd = 0;
    if (psram.driving) {
      sd = psram.driveVal & 0xF;
    } else if (flash != null && flash.driving) {
      sd = flash.driveVal & 0xF;
    }
    // Map sd[3:0] -> uio_in[5,4,2,1]
    final uioVal = ((sd & 0x1) << 1) |
        (((sd >> 1) & 0x1) << 2) |
        (((sd >> 2) & 0x1) << 4) |
        (((sd >> 3) & 0x1) << 5);
    uioIn.put(uioVal);
  }

  clk.posedge.listen((_) {
    Simulator.postTick.first.then(
      (_) {
        if (!dut.uioOut.value.isValid || !dut.uioOe.value.isValid) return;
        final outVal = dut.uioOut.value.toInt();
        final oeVal = dut.uioOe.value.toInt();

        final cs0 = outVal & 1;
        final sck = (outVal >> 3) & 1;
        final cs1 = (outVal >> 6) & 1;

        final sdOut = ((outVal >> 1) & 1) |
            (((outVal >> 2) & 1) << 1) |
            (((outVal >> 4) & 1) << 2) |
            (((outVal >> 5) & 1) << 3);
        final sdOe = ((oeVal >> 1) & 1) |
            (((oeVal >> 2) & 1) << 1) |
            (((oeVal >> 4) & 1) << 2) |
            (((oeVal >> 5) & 1) << 3);

        if (cs1 != lastCs1) {
          lastCs1 = cs1;
          psram.onCsChanged(cs1 == 0);
          driveUioIn();
        }
        if (flash != null && cs0 != lastCs0) {
          lastCs0 = cs0;
          flash.onCsChanged(cs0 == 0);
          driveUioIn();
        }
        if (sck != lastSck) {
          lastSck = sck;
          if (sck == 1) {
            psram.onSckPosedge(sdOut, sdOe);
            flash?.onSckPosedge(sdOut, sdOe);
          } else {
            psram.onSckNegedge();
            flash?.onSckNegedge();
            driveUioIn();
          }
        }
      },
      onError: (_) {},
    );
  });
}

/// Bit-level 8-N-1 UART TX capture (samples `uo_out[0]` at mid-bit).
class UartTxMonitor {
  final int bitCycles;
  final List<int> rxBytes = [];
  int _state = 0; // 0=idle, 1=start-wait, 2=data, 3=stop
  int _cnt = 0;
  int _bitIdx = 0;
  int _shift = 0;

  UartTxMonitor(this.bitCycles);

  void tick(int txd) {
    if (_state == 0) {
      if (txd == 0) {
        _state = 1;
        _cnt = (bitCycles ~/ 2) - 1;
      }
    } else if (_state == 1) {
      if (_cnt <= 0) {
        if (txd == 0) {
          _state = 2;
          _cnt = bitCycles - 1;
          _bitIdx = 0;
          _shift = 0;
        } else {
          _state = 0; // glitch
        }
      } else {
        _cnt--;
      }
    } else if (_state == 2) {
      if (_cnt <= 0) {
        _shift |= (txd & 1) << _bitIdx;
        _bitIdx++;
        if (_bitIdx == 8) {
          _state = 3;
          _cnt = bitCycles - 1;
        } else {
          _cnt = bitCycles - 1;
        }
      } else {
        _cnt--;
      }
    } else if (_state == 3) {
      if (_cnt <= 0) {
        if (txd == 1) {
          rxBytes.add(_shift);
        }
        _state = 0;
      } else {
        _cnt--;
      }
    }
  }

  String get ascii => String.fromCharCodes(rxBytes);
}

void main() {
  final bootRom = assembleTinyBootRom();

  tearDown(() async {
    await Simulator.reset();
  });

  // Fast UART divisor = 8 (4x oversample = 2 cycles) for rapid ROHD simulation
  const simDivisor = 8;

  /// Assemble a small MicroRISC4 payload at [baseAddr] using mr4asm.py.
  List<int> assemblePayload(String asmSource, int baseAddr) {
    final repoRoot = Directory.current.path.endsWith('/hdl/mr4')
        ? Directory.current.parent.parent.path
        : Directory.current.path;
    final tmpDir = Directory('$repoRoot/build/asic_tiny');
    final asmFile = File('${tmpDir.path}/payload_tmp.asm');
    final hexFile = File('${tmpDir.path}/payload_tmp.hex');
    asmFile.writeAsStringSync(asmSource);
    final res = Process.runSync(
      'python3',
      ['$repoRoot/tools/mr4asm.py', '-I', '$repoRoot/lib', asmFile.path, '--hex', '-o', hexFile.path],
    );
    if (res.exitCode != 0) {
      fail('mr4asm failed assembling payload:\n${res.stdout}\n${res.stderr}');
    }
    final words = MemoryFactory.loadBootRomFromHex(
      hexFile.path,
      baseAddr: baseAddr,
      wordCount: 128,
    );
    int end = 0;
    for (int i = 0; i < words.length; i++) {
      if (words[i] != 0) end = i + 1;
    }
    return words.sublist(0, end);
  }

  test('Mr4TinyTop (tt_um_mr4): exact Tiny Tapeout port signature & ASIC-clean SV', () async {
    final top = Mr4TinyTop(
      clk: Logic(name: 'clk'),
      rstN: Logic(name: 'rst_n'),
      ena: Logic(name: 'ena'),
      uiIn: Logic(name: 'ui_in', width: 8),
      uioIn: Logic(name: 'uio_in', width: 8),
      bootRomWords: bootRom,
      uartDivisor: 432,
    );
    await top.build();
    expect(top.definitionName, equals('tt_um_mr4'));
    expect(top.inputs.keys.toSet(),
        containsAll(['ui_in', 'uio_in', 'ena', 'clk', 'rst_n']));
    expect(top.outputs.keys.toSet(),
        containsAll(['uo_out', 'uio_out', 'uio_oe']));

    final sv = top.generateSynth();
    expect(sv, contains('module tt_um_mr4'));
    expect(sv, isNot(contains('EHXPLLL')));
    expect(sv, isNot(contains('ODDRX1F')));
    expect(sv, isNot(contains('ram_style')));
    expect(sv, isNot(contains('syn_useioff')));
    expect(sv, isNot(contains(r'$readmemh')));
  });

  test('Mr4TinyTop end-to-end: cold boot, UART banner, ping, load to QSPI PSRAM, peek & execute', () async {
    // Assemble a real MicroRISC4 payload at 0x0400 that exercises QSPI PSRAM
    // data writes/reads + UART TX ("OK!") and halts cleanly.
    final payload = assemblePayload('''
.include "common.inc"
.org 0x0400
_app:
    LOAD16  R0, 0x0500
    LOAD16  R1, 0xCAFE
    LD      (R0), R1
    LD      R2, (R0)
    INC     R2
    INC     R0
    LD      (R0), R2
    LOAD16  R1, 0x004F      ; 'O'
    PUTC    R1
    LOAD16  R1, 0x004B      ; 'K'
    PUTC    R1
    LOAD16  R1, 0x0021      ; '!'
    PUTC    R1
_halt:
    LOAD16  R0, _halt
    JMP     R0
''', 0x0400);
    expect(payload.length, greaterThan(10));

    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final ena = Logic(name: 'ena');
    final uiIn = Logic(name: 'ui_in', width: 8);
    final uioIn = Logic(name: 'uio_in', width: 8);

    final dut = Mr4TinyTop(
      clk: clk,
      rstN: rstN,
      ena: ena,
      uiIn: uiIn,
      uioIn: uioIn,
      bootRomWords: bootRom,
      uartDivisor: simDivisor,
    );
    await dut.build();

    final psram = BehavioralQspiChip(sizeBytes: 131072, writable: true);
    attachTinyQspiPmod(clk: clk, dut: dut, uioIn: uioIn, psram: psram);

    final uartMon = UartTxMonitor(simDivisor);

    // Initialize inputs (UART RX idle high on ui_in[0], boot_from_flash=0 on ui_in[1])
    rstN.put(0);
    ena.put(1);
    uiIn.put(0x01);
    uioIn.put(0);

    Future<void> stepCycle() async {
      await clk.nextPosedge;
      if (dut.uoOut.value.isValid) {
        uartMon.tick(dut.uoOut.value.toInt() & 1);
      }
    }

    Future<void> waitCycles(int n) async {
      for (int i = 0; i < n; i++) {
        await stepCycle();
      }
    }

    Future<void> sendUartByte(int b) async {
      // Start bit (0)
      uiIn.put(0x00);
      await waitCycles(simDivisor);
      // 8 data bits LSB-first
      for (int i = 0; i < 8; i++) {
        uiIn.put((b >> i) & 1);
        await waitCycles(simDivisor);
      }
      // Stop bit (1) + inter-byte guard
      uiIn.put(0x01);
      await waitCycles(simDivisor * 2);
    }

    Future<void> waitForRxCount(int target, {int maxCycles = 20000}) async {
      for (int i = 0; i < maxCycles; i++) {
        if (uartMon.rxBytes.length >= target) return;
        await stepCycle();
      }
      fail('Timed out waiting for $target UART TX bytes '
          '(got ${uartMon.rxBytes.length}: ${uartMon.rxBytes}, "${uartMon.ascii}", '
          'pc=0x${dut.cpu.debugPc.value.isValid ? dut.cpu.debugPc.value.toInt().toRadixString(16) : "X"}, '
          'psramTx=${psram.txCount})');
    }

    Simulator.setMaxSimTime(5000000);
    final simFuture = Simulator.run();

    // Release reset
    await waitCycles(6);
    rstN.put(1);

    // 1. Expect cold-boot banner "MR4 TT\r\n" (8 bytes)
    await waitForRxCount(8, maxCycles: 15000);
    expect(uartMon.ascii, equals('MR4 TT\r\n'));

    // 2. Ping '?' -> expect '!'
    await sendUartByte(0x3F); // '?'
    await waitForRxCount(9, maxCycles: 5000);
    expect(uartMon.rxBytes[8], equals(0x21)); // '!'

    // 3. Load payload into QSPI PSRAM @ 0x0400 using 'L' command
    await sendUartByte(0x4C); // 'L'
    await sendUartByte(0x00); // addr_lo = 0x00
    await sendUartByte(0x04); // addr_hi = 0x04
    await sendUartByte(payload.length & 0xFF);
    await sendUartByte((payload.length >> 8) & 0xFF);
    for (final w in payload) {
      await sendUartByte(w & 0xFF);
      await sendUartByte((w >> 8) & 0xFF);
    }
    await waitForRxCount(10, maxCycles: 10000);
    expect(uartMon.rxBytes[9], equals(0x4B)); // 'K'

    // Verify PSRAM received every single word intact!
    for (int i = 0; i < payload.length; i++) {
      expect(psram.readWordLE(0x0400 + i), equals(payload[i]),
          reason: 'PSRAM word mismatch at 0x${(0x0400 + i).toRadixString(16)}');
    }

    // 4. Peek word [0x0400] using 'P' command
    await sendUartByte(0x50); // 'P'
    await sendUartByte(0x00);
    await sendUartByte(0x04);
    await waitForRxCount(12, maxCycles: 5000);
    final peeked = uartMon.rxBytes[10] | (uartMon.rxBytes[11] << 8);
    expect(peeked, equals(payload[0]));

    // 5. Execute payload at 0x0400 using 'G' command -> expect 'G' + "OK!"
    await sendUartByte(0x47); // 'G'
    await sendUartByte(0x00);
    await sendUartByte(0x04);
    await waitForRxCount(16, maxCycles: 25000);

    final tailStr = String.fromCharCodes(uartMon.rxBytes.sublist(12, 16));
    expect(tailStr, equals('GOK!'));

    // Verify payload wrote 0xCAFE -> [0x0500] and 0xCAFF -> [0x0501] in PSRAM!
    expect(psram.readWordLE(0x0500), equals(0xCAFE));
    expect(psram.readWordLE(0x0501), equals(0xCAFF));

    await Simulator.endSimulation();
    await simFuture;
  });

  test('Mr4TinyTop QSPI Flash XIP Auto-Boot (ui_in[1]=1, magic 0x4D34 @ 0x0400)', () async {
    // Assemble a tiny Flash XIP app starting at 0x0401 that prints 'F' and halts
    final flashApp = assemblePayload('''
.include "common.inc"
.org 0x0401
_flash_app:
    LOAD16  R1, 0x0046      ; 'F'
    PUTC    R1
_fhalt:
    LOAD16  R0, _fhalt
    JMP     R0
''', 0x0401);

    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final ena = Logic(name: 'ena');
    final uiIn = Logic(name: 'ui_in', width: 8);
    final uioIn = Logic(name: 'uio_in', width: 8);

    final dut = Mr4TinyTop(
      clk: clk,
      rstN: rstN,
      ena: ena,
      uiIn: uiIn,
      uioIn: uioIn,
      bootRomWords: bootRom,
      uartDivisor: simDivisor,
    );
    await dut.build();

    final psram = BehavioralQspiChip(sizeBytes: 131072, writable: true);
    final flash = BehavioralQspiChip(sizeBytes: 131072, writable: false);
    flash.writeWordLE(0x0400, 0x4D34); // "M4" auto-boot magic
    for (int i = 0; i < flashApp.length; i++) {
      flash.writeWordLE(0x0401 + i, flashApp[i]);
    }
    attachTinyQspiPmod(clk: clk, dut: dut, uioIn: uioIn, psram: psram, flash: flash);

    final uartMon = UartTxMonitor(simDivisor);

    // ui_in[0]=1 (UART RX idle high), ui_in[1]=1 (boot_from_flash = 1 -> Flash CS0)
    rstN.put(0);
    ena.put(1);
    uiIn.put(0x03);
    uioIn.put(0);

    Simulator.setMaxSimTime(1000000);
    final simFuture = Simulator.run();

    for (int i = 0; i < 6; i++) {
      await clk.nextPosedge;
    }
    rstN.put(1);

    for (int i = 0; i < 15000 && uartMon.rxBytes.isEmpty; i++) {
      await clk.nextPosedge;
      if (dut.uoOut.value.isValid) {
        uartMon.tick(dut.uoOut.value.toInt() & 1);
      }
    }

    expect(uartMon.ascii, equals('F'));
    expect(flash.txCount, greaterThan(0));

    await Simulator.endSimulation();
    await simFuture;
  });
}

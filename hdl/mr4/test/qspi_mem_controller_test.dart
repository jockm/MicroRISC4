// ==============================================================================
// FILE: hdl/mr4/test/qspi_mem_controller_test.dart
// Track E.1.1 Verification: Compact Tiny Tapeout QSPI PSRAM / Flash Controller
//
// Includes a cycle-accurate behavioral APS6404L / W25Q QSPI slave model and
// verifies:
//   1. Direct 16-bit little-endian Quad Write (0x38) and Quad Read (0xEB)
//      across multiple PSRAM addresses.
//   2. 4-word coherent Instruction Prefetch Cache: burst miss fills 4 words,
//      next 3 sequential fetches hit in 1 cycle with ZERO QSPI activity, and a
//      DC write to the cached line invalidates it cleanly.
//   3. Flash CS0 routing (`use_flash = 1`) reads from independent Flash array
//      while keeping writes directed to PSRAM CS1.
//   4. End-to-end `CpuCore` executing a real MicroRISC4 program directly out of
//      external QSPI PSRAM (`0x0400+`) while reading/writing PSRAM data (`0x1000+`)
//      and ASIC-clean SystemVerilog check (zero FPGA primitives / $readmemh).
// ==============================================================================

import 'dart:typed_data';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:microrisc4_rohd/cpu_config.dart';
import 'package:microrisc4_rohd/cpu_core.dart';
import 'package:microrisc4_rohd/memory_factory.dart';
import 'package:microrisc4_rohd/qspi_mem_controller.dart';

/// Cycle-accurate behavioral APS6404L QSPI PSRAM / W25Q Flash slave model.
/// Supports 1-4-4 `0xEB` (Fast Read Quad I/O, 6 dummy clocks) and `0x38`
/// (Quad Input Write, 0 dummy clocks), byte-addressed little-endian.
class BehavioralQspiChip {
  final Uint8List mem;
  final bool writable;
  int txCount = 0;

  // Internal protocol tracker
  bool _selected = false;
  int _phase = 0; // 0=cmd(8), 1=addr(6), 2=dummy(6), 3=read, 4=write
  int _cnt = 0;
  int _cmd = 0;
  int _addr = 0;
  bool _hiNib = true;
  int _curByte = 0;
  int _driveVal = 0;
  bool _driving = false;

  BehavioralQspiChip({int sizeBytes = 131072, this.writable = true})
      : mem = Uint8List(sizeBytes);

  void writeWordLE(int wordAddr, int val) {
    final byteAddr = (wordAddr << 1) & (mem.length - 1);
    mem[byteAddr] = val & 0xFF;
    mem[byteAddr + 1] = (val >> 8) & 0xFF;
  }

  int readWordLE(int wordAddr) {
    final byteAddr = (wordAddr << 1) & (mem.length - 1);
    return mem[byteAddr] | (mem[byteAddr + 1] << 8);
  }

  bool get driving => _driving;
  int get driveVal => _driveVal;

  void onCsChanged(bool csLow) {
    if (csLow && !_selected) {
      _selected = true;
      _phase = 0;
      _cnt = 0;
      _cmd = 0;
      _addr = 0;
      _hiNib = true;
      _driving = false;
      txCount++;
    } else if (!csLow && _selected) {
      _selected = false;
      _driving = false;
    }
  }

  void onSckPosedge(int sdOut, int sdOe) {
    if (!_selected) return;
    if (_phase == 0) {
      // 1-bit SPI command on SD0
      expect(sdOe & 1, equals(1), reason: 'SD0 must be driven during cmd');
      _cmd = ((_cmd << 1) | (sdOut & 1)) & 0xFF;
      _cnt++;
      if (_cnt == 8) {
        _phase = 1;
        _cnt = 0;
        _addr = 0;
      }
    } else if (_phase == 1) {
      // 4-bit Quad 24-bit byte address
      expect(sdOe, equals(0xF), reason: 'SD[3:0] must be driven during addr');
      _addr = ((_addr << 4) | (sdOut & 0xF)) & 0xFFFFFF;
      _cnt++;
      if (_cnt == 6) {
        _cnt = 0;
        if (_cmd == QspiMemController.cmdQuadRead) {
          _phase = 2;
        } else if (_cmd == QspiMemController.cmdQuadWrite && writable) {
          _phase = 4;
          _hiNib = true;
        } else {
          _phase = 99; // Ignore unsupported/read-only write
        }
      }
    } else if (_phase == 2) {
      // 6 dummy cycles
      expect(sdOe, equals(0), reason: 'SD[3:0] must be Hi-Z during dummy');
      _cnt++;
      if (_cnt == 6) {
        _phase = 3;
        _hiNib = true;
      }
    } else if (_phase == 4) {
      // 4-bit Quad write
      expect(sdOe, equals(0xF), reason: 'SD[3:0] must be driven during write');
      final nib = sdOut & 0xF;
      if (_hiNib) {
        _curByte = nib << 4;
        _hiNib = false;
      } else {
        _curByte |= nib;
        mem[_addr & (mem.length - 1)] = _curByte;
        _addr = (_addr + 1) & 0xFFFFFF;
        _hiNib = true;
      }
    }
  }

  void onSckNegedge() {
    if (!_selected) {
      _driving = false;
      return;
    }
    if (_phase == 3) {
      _driving = true;
      final b = mem[_addr & (mem.length - 1)];
      if (_hiNib) {
        _driveVal = (b >> 4) & 0xF;
        _hiNib = false;
      } else {
        _driveVal = b & 0xF;
        _addr = (_addr + 1) & 0xFFFFFF;
        _hiNib = true;
      }
    } else {
      _driving = false;
    }
  }
}

void attachQspiBus({
  required QspiMemController dut,
  required Logic sdIn,
  required BehavioralQspiChip psram,
  BehavioralQspiChip? flash,
}) {
  void refreshBus() {
    if (psram.driving) {
      sdIn.put(psram.driveVal);
    } else if (flash != null && flash.driving) {
      sdIn.put(flash.driveVal);
    } else {
      sdIn.put(0);
    }
  }

  dut.qspiRamACsN.changed.listen((_) {
    if (dut.qspiRamACsN.value.isValid) {
      psram.onCsChanged(!dut.qspiRamACsN.value.toBool());
      refreshBus();
    }
  });
  if (flash != null) {
    dut.qspiFlashCsN.changed.listen((_) {
      if (dut.qspiFlashCsN.value.isValid) {
        flash.onCsChanged(!dut.qspiFlashCsN.value.toBool());
        refreshBus();
      }
    });
  }
  dut.qspiSck.posedge.listen((_) {
    final sdo = dut.qspiSdOut.value.isValid ? dut.qspiSdOut.value.toInt() : 0;
    final oe = dut.qspiSdOe.value.isValid ? dut.qspiSdOe.value.toInt() : 0;
    psram.onSckPosedge(sdo, oe);
    flash?.onSckPosedge(sdo, oe);
  });
  dut.qspiSck.negedge.listen((_) {
    psram.onSckNegedge();
    flash?.onSckNegedge();
    refreshBus();
  });
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('QspiMemController: Quad Write/Read, 4-word I-cache hits, coherence, and Flash CS0',
      () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final icValid = Logic(name: 'ic_valid');
    final icAddr = Logic(name: 'ic_addr', width: 16);
    final dcValid = Logic(name: 'dc_valid');
    final dcWe = Logic(name: 'dc_we');
    final dcAddr = Logic(name: 'dc_addr', width: 16);
    final dcWdata = Logic(name: 'dc_wdata', width: 16);
    final useFlash = Logic(name: 'use_flash');
    final sdIn = Logic(name: 'sd_in', width: 4);

    final dut = QspiMemController(
      clk: clk,
      reset: reset,
      icReqValid: icValid,
      icReqAddr: icAddr,
      dcReqValid: dcValid,
      dcReqWe: dcWe,
      dcReqAddr: dcAddr,
      dcReqWdata: dcWdata,
      qspiSdIn: sdIn,
      useFlash: useFlash,
    );
    await dut.build();

    final psram = BehavioralQspiChip(writable: true);
    final flash = BehavioralQspiChip(writable: false);
    flash.writeWordLE(0x0500, 0xCAFE);
    psram.writeWordLE(0x0400, 0x1111);
    psram.writeWordLE(0x0401, 0x2222);
    psram.writeWordLE(0x0402, 0x3333);
    psram.writeWordLE(0x0403, 0x4444);

    attachQspiBus(dut: dut, sdIn: sdIn, psram: psram, flash: flash);

    reset.put(1);
    icValid.put(0);
    icAddr.put(0);
    dcValid.put(0);
    dcWe.put(0);
    dcAddr.put(0);
    dcWdata.put(0);
    useFlash.put(0);
    sdIn.put(0);

    Future<void> tick() async {
      await clk.nextPosedge;
    }

    Future<int> dcRead(int addr, {bool fromFlash = false}) async {
      useFlash.put(fromFlash ? 1 : 0);
      dcAddr.put(addr);
      dcWe.put(0);
      dcValid.put(1);
      while (!(dut.dcReqReady.value.isValid && dut.dcReqReady.value.toBool())) {
        await tick();
      }
      await tick();
      dcValid.put(0);
      while (!(dut.dcRespValid.value.isValid && dut.dcRespValid.value.toBool())) {
        await tick();
      }
      final val = dut.dcRespData.value.toInt();
      await tick();
      return val;
    }

    Future<void> dcWrite(int addr, int data) async {
      useFlash.put(0);
      dcAddr.put(addr);
      dcWdata.put(data);
      dcWe.put(1);
      dcValid.put(1);
      while (!(dut.dcReqReady.value.isValid && dut.dcReqReady.value.toBool())) {
        await tick();
      }
      await tick();
      dcValid.put(0);
      dcWe.put(0);
      while (!(dut.dcRespValid.value.isValid && dut.dcRespValid.value.toBool())) {
        await tick();
      }
      await tick();
    }

    Future<int> icFetch(int addr) async {
      useFlash.put(0);
      icAddr.put(addr);
      icValid.put(1);
      while (!(dut.icReqReady.value.isValid && dut.icReqReady.value.toBool())) {
        await tick();
      }
      await tick();
      icValid.put(0);
      while (!(dut.icRespValid.value.isValid && dut.icRespValid.value.toBool())) {
        await tick();
      }
      final val = dut.icRespData.value.toInt();
      await tick();
      return val;
    }

    Simulator.setMaxSimTime(20000);
    final simFuture = Simulator.run();

    await tick();
    await tick();
    reset.put(0);
    await tick();

    // 1. Direct Quad Write + Quad Read back from PSRAM
    await dcWrite(0x1234, 0xBEEF);
    expect(psram.readWordLE(0x1234), equals(0xBEEF));
    expect(await dcRead(0x1234), equals(0xBEEF));

    // 2. Flash CS0 read (independent chip select)
    expect(await dcRead(0x0500, fromFlash: true), equals(0xCAFE));
    expect(flash.txCount, equals(1));

    // 3. 4-word I-cache burst miss + 3 consecutive 1-cycle hits (zero extra QSPI tx!)
    final txBeforeBurst = psram.txCount;
    expect(await icFetch(0x0400), equals(0x1111));
    expect(psram.txCount, equals(txBeforeBurst + 1));
    expect(await icFetch(0x0401), equals(0x2222));
    expect(await icFetch(0x0402), equals(0x3333));
    expect(await icFetch(0x0403), equals(0x4444));
    expect(psram.txCount, equals(txBeforeBurst + 1),
        reason: 'Sequential fetches within cached 4-word line must not touch QSPI');

    // 4. Coherent invalidation: DC write to 0x0402 invalidates cached I-line
    await dcWrite(0x0402, 0xABCD);
    final txAfterWrite = psram.txCount;
    expect(await icFetch(0x0402), equals(0xABCD));
    expect(psram.txCount, equals(txAfterWrite + 1),
        reason: 'I-fetch after coherent invalidation must refill from PSRAM');

    Simulator.endSimulation();
    await simFuture;
  });

  test('End-to-end CpuCore executes code directly from external QSPI PSRAM and verifies RTL cleanliness',
      () async {
    // Boot ROM (at 0x0100, 128w) simply jumps to external QSPI PSRAM at 0x0400!
    // 0x0100: PUSH8 R0, 0x04; PUSH8 R0, 0x00 -> 0x04F8, 0x00F8
    // 0x0102: JMP R0 (0xF0), NOP (0x00)      -> 0x00F0
    final bootRom = List<int>.filled(128, 0);
    bootRom[0] = 0x04F8;
    bootRom[1] = 0x00F8;
    bootRom[2] = 0x00F0;

    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final sdIn = Logic(name: 'sd_in', width: 4);

    // Late-bound cache feedback wires
    final icReqReady = Logic(name: 'ic_req_ready');
    final icRespValid = Logic(name: 'ic_resp_valid');
    final icRespData = Logic(name: 'ic_resp_data', width: 16);
    final dcReqReady = Logic(name: 'dc_req_ready');
    final dcRespValid = Logic(name: 'dc_resp_valid');
    final dcRespData = Logic(name: 'dc_resp_data', width: 16);

    final cpu = CpuCore(
      clk: clk,
      rstN: rstN,
      icReqReady: icReqReady,
      icRespValid: icRespValid,
      icRespData: icRespData,
      dcReqReady: dcReqReady,
      dcRespValid: dcRespValid,
      dcRespData: dcRespData,
      config: CpuConfig(
        coreId: 0,
        enableCpuid: false,
        enableUart: false,
        enableCrossTraps: false,
        enableSdramCache: true, // Enables external ic_*/dc_* bus for addr >= memWords!
        isPipelined: true,
        memReadLatency: 1,
        memoryTarget: MemoryTarget.asicFlop,
        bootRomBase: 0x0100,
        bootRomWords: bootRom,
        memWords: 512, // Local scratchpad + Boot ROM: 0x0000..0x01FF; QSPI: 0x0200..0xFFFF
      ),
    );

    final qspi = QspiMemController(
      clk: clk,
      reset: ~rstN,
      icReqValid: cpu.output('ic_req_valid'),
      icReqAddr: cpu.output('ic_req_addr'),
      dcReqValid: cpu.output('dc_req_valid'),
      dcReqWe: cpu.output('dc_req_we'),
      dcReqAddr: cpu.output('dc_req_addr'),
      dcReqWdata: cpu.output('dc_req_wdata'),
      qspiSdIn: sdIn,
    );

    icReqReady <= qspi.icReqReady;
    icRespValid <= qspi.icRespValid;
    icRespData <= qspi.icRespData;
    dcReqReady <= qspi.dcReqReady;
    dcRespValid <= qspi.dcRespValid;
    dcRespData <= qspi.dcRespData;

    await cpu.build();
    await qspi.build();

    // Check ASIC cleanliness of QspiMemController SV
    final sv = qspi.generateSynth();
    expect(sv, isNot(contains('EHXPLLL')));
    expect(sv, isNot(contains('ODDRX1F')));
    expect(sv, isNot(contains('ram_style')));
    expect(sv, isNot(contains('syn_useioff')));
    expect(sv, isNot(contains(r'$readmemh')));

    // Load a real program into external QSPI PSRAM at 0x0400:
    //   R1 = 0x1234 (PUSH8 R1, 0x12; PUSH8 R1, 0x34)
    //   R2 = 0x1000 (PUSH8 R2, 0x10; PUSH8 R2, 0x00)
    //   [R2] = R1   (LD (R2), R1 -> opcode 0x30 | (2<<2) | 1 = 0x39)
    //   R3 = [R2]   (LD R3, (R2) -> opcode 0x20 | (3<<2) | 2 = 0x2E)
    //   R3 = R3 + R1 (ADD R3, R1 -> opcode 0x60 | (3<<2) | 1 = 0x6D -> 0x2468)
    //   INC R2      (0xC2 | (2<<2)? Actually PUSH8 R2, 0x10; PUSH8 R2, 0x01 -> 0x1001)
    //   [0x1001] = R3 (LD (R2), R3 -> 0x3B)
    //   JMP 0x0407  (halt loop)
    final psram = BehavioralQspiChip(writable: true);
    psram.writeWordLE(0x0400, 0x12F9); // PUSH8 R1, 0x12
    psram.writeWordLE(0x0401, 0x34F9); // PUSH8 R1, 0x34 -> R1 = 0x1234
    psram.writeWordLE(0x0402, 0x10FA); // PUSH8 R2, 0x10
    psram.writeWordLE(0x0403, 0x00FA); // PUSH8 R2, 0x00 -> R2 = 0x1000
    psram.writeWordLE(0x0404, 0x2E39); // Slot0: LD (R2), R1 (0x39); Slot1: LD R3, (R2) (0x2E)
    psram.writeWordLE(0x0405, 0x006D); // Slot0: ADD R3, R1 (0x6D -> 0x2468); Slot1: NOP
    psram.writeWordLE(0x0406, 0x10FA); // PUSH8 R2, 0x10
    psram.writeWordLE(0x0407, 0x01FA); // PUSH8 R2, 0x01 -> R2 = 0x1001
    psram.writeWordLE(0x0408, 0x003B); // Slot0: LD (R2), R3 (0x3B); Slot1: NOP
    psram.writeWordLE(0x0409, 0x04F8); // PUSH8 R0, 0x04
    psram.writeWordLE(0x040A, 0x09F8); // PUSH8 R0, 0x09 -> R0 = 0x0409
    psram.writeWordLE(0x040B, 0x00F0); // JMP R0 (halt loop)

    attachQspiBus(dut: qspi, sdIn: sdIn, psram: psram);

    rstN.put(0);
    sdIn.put(0);
    Simulator.registerAction(40, () => rstN.put(1));

    clk.posedge.listen((_) {
      if (psram.readWordLE(0x1001) == 0x2468) {
        Simulator.endSimulation();
      }
    });

    Simulator.setMaxSimTime(20000);
    await Simulator.run();

    expect(psram.readWordLE(0x1000), equals(0x1234),
        reason: 'CpuCore must have stored 0x1234 to QSPI PSRAM [0x1000]');
    expect(psram.readWordLE(0x1001), equals(0x2468),
        reason: 'CpuCore must have loaded 0x1234 back from QSPI PSRAM, added R1 -> 0x2468, and stored to [0x1001]');
  });
}

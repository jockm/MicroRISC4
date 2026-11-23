import 'dart:async';
import 'package:test/test.dart';
import 'package:rohd/rohd.dart';
import 'package:minirisc4_rohd/sdram_controller.dart';

/// Pin-level behavioral JEDEC IS42S16160G SDRAM model (CL=2, BL=8) driven
/// directly from physical SDRAM control/address/DQ pins.
class JedecSdramSimModel {
  final Map<int, int> mem = {};
  final List<int> openRow = List.filled(4, -1);
  int lmrVal = 0;
  int initRefreshCount = 0;
  int totalRefreshCount = 0;
  bool lmrSeen = false;

  // Active write burst state
  int _wrRem = 0;
  int _wrBank = 0;
  int _wrRow = 0;
  int _wrCol = 0;

  // Active read burst state (CL=2 sampled on negedge -> 2-stage pipe -> dq valid before E+3)
  int _rdRem = 0;
  int _rdBank = 0;
  int _rdRow = 0;
  int _rdCol = 0;
  int _rdPipe0 = 0;
  int _rdPipe1 = 0;

  void attach(Logic clk, Module sdramPins, Logic sdramDqIn) {
    _attachSignals(
      clk: clk,
      csN: sdramPins.output('sdram_cs_n'),
      rasN: sdramPins.output('sdram_ras_n'),
      casN: sdramPins.output('sdram_cas_n'),
      weN: sdramPins.output('sdram_we_n'),
      ba: sdramPins.output('sdram_ba'),
      a: sdramPins.output('sdram_a'),
      dqOut: sdramPins.output('sdram_dq_out'),
      dqOe: sdramPins.output('sdram_dq_oe'),
      driveDq: (val, oe) => sdramDqIn.put(val),
    );
  }

  /// Attach directly to [Ulx3sTop] physical SDRAM pins (`sdram_csn`, `sdram_d`, etc.).
  void attachPins({
    required Logic clk,
    required Logic csN,
    required Logic rasN,
    required Logic casN,
    required Logic weN,
    required Logic ba,
    required Logic a,
    required Logic dqOut,
    required Logic dqOe,
    required LogicNet sdramDNet,
  }) {
    final tbDrive = Logic(name: 'tb_sdram_d_drv', width: 16);
    sdramDNet <= tbDrive;
    tbDrive.put(LogicValue.filled(16, LogicValue.z));
    _attachSignals(
      clk: clk,
      csN: csN,
      rasN: rasN,
      casN: casN,
      weN: weN,
      ba: ba,
      a: a,
      dqOut: dqOut,
      dqOe: dqOe,
      driveDq: (val, isReadDriving) {
        tbDrive.put(
          isReadDriving ? LogicValue.ofInt(val & 0xFFFF, 16) : LogicValue.filled(16, LogicValue.z),
        );
      },
    );
  }

  bool _rdValid0 = false;
  bool _rdValid1 = false;

  void _attachSignals({
    required Logic clk,
    required Logic csN,
    required Logic rasN,
    required Logic casN,
    required Logic weN,
    required Logic ba,
    required Logic a,
    required Logic dqOut,
    required Logic dqOe,
    required void Function(int val, bool isReadDriving) driveDq,
  }) {
    driveDq(0, false);
    // Sample SDRAM pins at negedge so all Sequential outputs from the preceding
    // posedge are 100% settled (matches real JEDEC sampling at the next posedge).
    clk.negedge.listen((_) {
      if (!csN.value.isValid || !rasN.value.isValid || !casN.value.isValid || !weN.value.isValid) {
        return;
      }
      final csNVal = csN.value.toInt();
      final rasNVal = rasN.value.toInt();
      final casNVal = casN.value.toInt();
      final weNVal = weN.value.toInt();
      final baVal = ba.value.isValid ? ba.value.toInt() : 0;
      final aVal = a.value.isValid ? a.value.toInt() : 0;
      final dqOutVal = dqOut.value.isValid ? dqOut.value.toInt() : 0;
      final dqOeVal = dqOe.value.isValid ? dqOe.value.toInt() : 0;

      // Advance CL=2 read pipeline
      final nextDq = _rdPipe1;
      final nextDrive = _rdValid1;
      final nextPipe1 = _rdPipe0;
      final nextValid1 = _rdValid0;
      var nextPipe0 = 0;
      var nextValid0 = false;
      if (_rdRem > 0) {
        final addr24 = (_rdBank << 22) | (_rdRow << 9) | (_rdCol & 0x1FF);
        nextPipe0 = mem[addr24] ?? 0;
        nextValid0 = true;
        _rdCol = (_rdCol + 1) & 0x1FF;
        _rdRem--;
      }

      // Advance ongoing write burst beats 1..N-1
      if (_wrRem > 0) {
        if (dqOeVal == 1) {
          final addr24 = (_wrBank << 22) | (_wrRow << 9) | (_wrCol & 0x1FF);
          mem[addr24] = dqOutVal & 0xFFFF;
        }
        _wrCol = (_wrCol + 1) & 0x1FF;
        _wrRem--;
      }

      // Decode JEDEC command {cs_n, ras_n, cas_n, we_n}
      final cmd = (csNVal << 3) | (rasNVal << 2) | (casNVal << 1) | weNVal;
      if (cmd == 0x0) {
        // LMR
        lmrVal = aVal;
        lmrSeen = true;
      } else if (cmd == 0x1) {
        // AUTO REFRESH
        totalRefreshCount++;
        if (!lmrSeen) initRefreshCount++;
      } else if (cmd == 0x2) {
        // PRECHARGE
        if (((aVal >> 10) & 1) == 1) {
          for (var b = 0; b < 4; b++) {
            openRow[b] = -1;
          }
        } else {
          openRow[baVal] = -1;
        }
      } else if (cmd == 0x3) {
        // ACTIVE
        openRow[baVal] = aVal & 0x1FFF;
      } else if (cmd == 0x4) {
        // WRITE (beat 0 on same clock edge!)
        final row = openRow[baVal];
        final col = aVal & 0x1FF;
        final bl = 1 << (lmrVal & 0x7);
        if (row >= 0 && dqOeVal == 1) {
          mem[(baVal << 22) | (row << 9) | col] = dqOutVal & 0xFFFF;
        }
        _wrBank = baVal;
        _wrRow = row;
        _wrCol = (col + 1) & 0x1FF;
        _wrRem = bl - 1;
      } else if (cmd == 0x5) {
        // READ
        final row = openRow[baVal];
        final col = aVal & 0x1FF;
        final bl = 1 << (lmrVal & 0x7);
        if (row >= 0) {
          nextPipe0 = mem[(baVal << 22) | (row << 9) | col] ?? 0;
          nextValid0 = true;
          _rdBank = baVal;
          _rdRow = row;
          _rdCol = (col + 1) & 0x1FF;
          _rdRem = bl - 1;
        }
      }

      _rdPipe0 = nextPipe0;
      _rdPipe1 = nextPipe1;
      _rdValid0 = nextValid0;
      _rdValid1 = nextValid1;
      driveDq(nextDq, nextDrive && dqOeVal == 0);
    });
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('SDRAM Controller JEDEC init (8x refresh + BL=8 LMR), periodic refresh, and 8-word burst write/read',
      () async {
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final cmdReq = Logic(name: 'cmd_req');
    final cmdRw = Logic(name: 'cmd_rw');
    final cmdAddr = Logic(name: 'cmd_addr', width: 24);
    final cmdBurstLen = Logic(name: 'cmd_burst_len', width: 8);
    final wdata = Logic(name: 'wdata', width: 16);
    final wdataValid = Logic(name: 'wdata_valid');
    final sdramDqIn = Logic(name: 'sdram_dq_in', width: 16);

    final ctrl = SdramController(
      clk: clk,
      rstN: rstN,
      cmdReq: cmdReq,
      cmdRw: cmdRw,
      cmdAddr: cmdAddr,
      cmdBurstLen: cmdBurstLen,
      wdata: wdata,
      wdataValid: wdataValid,
      sdramDqIn: sdramDqIn,
      clkFreqMhz: 48,
      casLatency: 2,
      burstLen: 8,
      initWaitCycles: 10,
      refreshCycles: 60, // short period to verify periodic AUTO REFRESH in test
    );
    await ctrl.build();

    final sdramModel = JedecSdramSimModel()..attach(clk, ctrl, sdramDqIn);

    rstN.put(0);
    cmdReq.put(0);
    cmdRw.put(0);
    cmdAddr.put(0);
    cmdBurstLen.put(8);
    wdata.put(0);
    wdataValid.put(0);

    Simulator.setMaxSimTime(6000);
    unawaited(Simulator.run());

    Future<void> step() async {
      await clk.nextPosedge;
      await clk.nextNegedge;
    }

    await step();
    await step();
    rstN.put(1);

    // Wait for JEDEC init to finish
    for (var i = 0; i < 120 && ctrl.output('cmd_ready').value.toInt() == 0; i++) {
      await step();
    }
    expect(ctrl.output('cmd_ready').value.toInt(), equals(1));
    expect(sdramModel.lmrSeen, isTrue);
    expect(sdramModel.lmrVal, equals(0x0023)); // CL=2, BL=8 sequential
    expect(sdramModel.initRefreshCount, equals(8));

    // Issue 8-word burst WRITE to Core 3 partition 0x031200
    const baseAddr = 0x031200;
    final txWords = List.generate(8, (i) => 0xC000 + i);
    cmdAddr.put(baseAddr);
    cmdRw.put(1);
    cmdBurstLen.put(8);
    cmdReq.put(1);
    await step();
    cmdReq.put(0);

    // Stream 8 write words via standard wdata_valid / wdata_ready handshake
    var beat = 0;
    for (var cyc = 0; cyc < 40 && beat < 8; cyc++) {
      wdata.put(txWords[beat]);
      wdataValid.put(1);
      final ready = ctrl.output('wdata_ready').value.toInt() == 1;
      await step();
      if (ready) beat++;
    }
    wdataValid.put(0);
    expect(beat, equals(8));

    // Wait for tWR + tRP -> cmd_ready == 1
    for (var i = 0; i < 40 && ctrl.output('cmd_ready').value.toInt() == 0; i++) {
      await step();
    }
    expect(ctrl.output('cmd_ready').value.toInt(), equals(1));

    // Verify physical SDRAM array holds all 8 written words at 0x031200..0x031207
    for (var i = 0; i < 8; i++) {
      expect(sdramModel.mem[baseAddr + i], equals(txWords[i]));
    }

    // Issue 8-word burst READ back from 0x031200
    cmdAddr.put(baseAddr);
    cmdRw.put(0);
    cmdBurstLen.put(8);
    cmdReq.put(1);
    await step();
    cmdReq.put(0);

    final rxWords = <int>[];
    for (var cyc = 0; cyc < 40 && rxWords.length < 8; cyc++) {
      if (ctrl.output('rdata_valid').value.toInt() == 1) {
        rxWords.add(ctrl.output('rdata').value.toInt());
      }
      await step();
    }
    expect(rxWords, equals(txWords));

    // Advance past refreshCycles to verify periodic AUTO REFRESH fires automatically
    final refBefore = sdramModel.totalRefreshCount;
    for (var i = 0; i < 80; i++) {
      await step();
    }
    expect(sdramModel.totalRefreshCount, greaterThan(refBefore));

    Simulator.endSimulation();
    await Simulator.simulationEnded;
  });
}

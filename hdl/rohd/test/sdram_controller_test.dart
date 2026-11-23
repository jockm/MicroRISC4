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
    sdramDqIn.put(0);
    // Sample SDRAM pins at negedge so all Sequential outputs from the preceding
    // posedge are 100% settled (matches real JEDEC sampling at the next posedge).
    clk.negedge.listen((_) {
      final csN = sdramPins.output('sdram_cs_n').value.toInt();
      final rasN = sdramPins.output('sdram_ras_n').value.toInt();
      final casN = sdramPins.output('sdram_cas_n').value.toInt();
      final weN = sdramPins.output('sdram_we_n').value.toInt();
      final ba = sdramPins.output('sdram_ba').value.toInt();
      final a = sdramPins.output('sdram_a').value.toInt();
      final dqOut = sdramPins.output('sdram_dq_out').value.toInt();
      final dqOe = sdramPins.output('sdram_dq_oe').value.toInt();

      // Advance CL=2 read pipeline
      final nextDq = _rdPipe1;
      final nextPipe1 = _rdPipe0;
      var nextPipe0 = 0;
      if (_rdRem > 0) {
        final addr24 = (_rdBank << 22) | (_rdRow << 9) | (_rdCol & 0x1FF);
        nextPipe0 = mem[addr24] ?? 0;
        _rdCol = (_rdCol + 1) & 0x1FF;
        _rdRem--;
      }

      // Advance ongoing write burst beats 1..N-1
      if (_wrRem > 0) {
        if (dqOe == 1) {
          final addr24 = (_wrBank << 22) | (_wrRow << 9) | (_wrCol & 0x1FF);
          mem[addr24] = dqOut & 0xFFFF;
        }
        _wrCol = (_wrCol + 1) & 0x1FF;
        _wrRem--;
      }

      // Decode JEDEC command {cs_n, ras_n, cas_n, we_n}
      final cmd = (csN << 3) | (rasN << 2) | (casN << 1) | weN;
      if (cmd == 0x0) {
        // LMR
        lmrVal = a;
        lmrSeen = true;
      } else if (cmd == 0x1) {
        // AUTO REFRESH
        totalRefreshCount++;
        if (!lmrSeen) initRefreshCount++;
      } else if (cmd == 0x2) {
        // PRECHARGE
        if (((a >> 10) & 1) == 1) {
          for (var b = 0; b < 4; b++) {
            openRow[b] = -1;
          }
        } else {
          openRow[ba] = -1;
        }
      } else if (cmd == 0x3) {
        // ACTIVE
        openRow[ba] = a & 0x1FFF;
      } else if (cmd == 0x4) {
        // WRITE (beat 0 on same clock edge!)
        final row = openRow[ba];
        final col = a & 0x1FF;
        final bl = 1 << (lmrVal & 0x7);
        if (row >= 0 && dqOe == 1) {
          mem[(ba << 22) | (row << 9) | col] = dqOut & 0xFFFF;
        }
        _wrBank = ba;
        _wrRow = row;
        _wrCol = (col + 1) & 0x1FF;
        _wrRem = bl - 1;
      } else if (cmd == 0x5) {
        // READ
        final row = openRow[ba];
        final col = a & 0x1FF;
        final bl = 1 << (lmrVal & 0x7);
        if (row >= 0) {
          nextPipe0 = mem[(ba << 22) | (row << 9) | col] ?? 0;
          _rdBank = ba;
          _rdRow = row;
          _rdCol = (col + 1) & 0x1FF;
          _rdRem = bl - 1;
        }
      }

      _rdPipe0 = nextPipe0;
      _rdPipe1 = nextPipe1;
      sdramDqIn.put(nextDq);
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

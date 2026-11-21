import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:minirisc4_rohd/constants.dart';
import 'package:minirisc4_rohd/noc_router.dart';

void main() {
  group('NocRouterNi MMIO & Priority MBOX Tests', () {
    setUp(() async {
      await Simulator.reset();
    });
    test('FIFO.TRYR returns 0x0000 when empty and reads data when non-empty', () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final mmioAddr = Logic(name: 'mmioAddr', width: MiniRISC4Constants.addrWidth);
      final mmioWdata = Logic(name: 'mmioWdata', width: MiniRISC4Constants.dataWidth);
      final mmioWe = Logic(name: 'mmioWe');
      final mmioRe = Logic(name: 'mmioRe');
      final netInValid = Logic(name: 'netInValid');
      final netInType = Logic(name: 'netInType');
      final netInSrcCore = Logic(name: 'netInSrcCore', width: 8);
      final netInSrcCh = Logic(name: 'netInSrcCh', width: 8);
      final netInDstCh = Logic(name: 'netInDstCh', width: 8);
      final netInPayload = Logic(name: 'netInPayload', width: MiniRISC4Constants.dataWidth);
      final netOutReady = Logic(name: 'netOutReady');

      final dut = NocRouterNi(
        clk: clk,
        reset: reset,
        mmioAddr: mmioAddr,
        mmioWdata: mmioWdata,
        mmioWe: mmioWe,
        mmioRe: mmioRe,
        netInValid: netInValid,
        netInType: netInType,
        netInSrcCore: netInSrcCore,
        netInSrcCh: netInSrcCh,
        netInDstCh: netInDstCh,
        netInPayload: netInPayload,
        netOutReady: netOutReady,
        coreId: 0,
        numChannels: 4,
        fifoDepth: 4,
        name: 'noc_ni_0',
      );
      await dut.build();

      reset.put(1);
      mmioAddr.put(0);
      mmioWdata.put(0);
      mmioWe.put(0);
      mmioRe.put(0);
      netInValid.put(0);
      netInType.put(0);
      netInSrcCore.put(0);
      netInSrcCh.put(0);
      netInDstCh.put(0);
      netInPayload.put(0);
      netOutReady.put(1);

      Simulator.setMaxSimTime(500);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.put(0);
      await clk.nextPosedge;

      mmioAddr.put(MiniRISC4Constants.addrNocRxTryR);
      mmioRe.put(1);
      await clk.nextPosedge;
      expect(dut.output('mmioRdata').value.toInt(), equals(0x0000));
      mmioRe.put(0);
      await clk.nextPosedge;

      mmioAddr.put(MiniRISC4Constants.addrNocSelCh);
      mmioWdata.put(1);
      mmioWe.put(1);
      netInValid.put(1);
      netInType.put(0);
      netInSrcCore.put(2);
      netInSrcCh.put(1);
      netInDstCh.put(1);
      netInPayload.put(0xCAFE);
      await clk.nextPosedge;

      mmioWe.put(0);
      netInValid.put(0);
      await clk.nextPosedge;

      mmioAddr.put(MiniRISC4Constants.addrNocRxStat);
      mmioRe.put(1);
      await clk.nextPosedge;
      expect(dut.output('mmioRdata').value.toInt() & 0x1, equals(1));
      mmioRe.put(0);
      await clk.nextPosedge;

      // Sample combinational FIFO.TRYR output while non-empty, then clock to pop
      mmioAddr.put(MiniRISC4Constants.addrNocRxTryR);
      mmioRe.put(1);
      await Simulator.tick();
      expect(dut.output('mmioRdata').value.toInt(), equals(0xCAFE));
      await clk.nextPosedge;
      mmioRe.put(0);
      await clk.nextPosedge;
      expect(dut.output('mmioRdata').value.toInt(), equals(0x0000));

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('Channel table routing & priority MBOX trap capture', () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final mmioAddr = Logic(name: 'mmioAddr', width: MiniRISC4Constants.addrWidth);
      final mmioWdata = Logic(name: 'mmioWdata', width: MiniRISC4Constants.dataWidth);
      final mmioWe = Logic(name: 'mmioWe');
      final mmioRe = Logic(name: 'mmioRe');
      final netInValid = Logic(name: 'netInValid');
      final netInType = Logic(name: 'netInType');
      final netInSrcCore = Logic(name: 'netInSrcCore', width: 8);
      final netInSrcCh = Logic(name: 'netInSrcCh', width: 8);
      final netInDstCh = Logic(name: 'netInDstCh', width: 8);
      final netInPayload = Logic(name: 'netInPayload', width: MiniRISC4Constants.dataWidth);
      final netOutReady = Logic(name: 'netOutReady');

      final dut = NocRouterNi(
        clk: clk,
        reset: reset,
        mmioAddr: mmioAddr,
        mmioWdata: mmioWdata,
        mmioWe: mmioWe,
        mmioRe: mmioRe,
        netInValid: netInValid,
        netInType: netInType,
        netInSrcCore: netInSrcCore,
        netInSrcCh: netInSrcCh,
        netInDstCh: netInDstCh,
        netInPayload: netInPayload,
        netOutReady: netOutReady,
        coreId: 1,
        numChannels: 4,
        fifoDepth: 4,
        name: 'noc_ni_1',
      );
      await dut.build();

      reset.put(1);
      mmioAddr.put(0);
      mmioWdata.put(0);
      mmioWe.put(0);
      mmioRe.put(0);
      netInValid.put(0);
      netInType.put(0);
      netInSrcCore.put(0);
      netInSrcCh.put(0);
      netInDstCh.put(0);
      netInPayload.put(0);
      netOutReady.put(0);

      Simulator.setMaxSimTime(500);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.put(0);
      await clk.nextPosedge;

      mmioAddr.put(MiniRISC4Constants.addrNocChCfg0);
      mmioWdata.put((3 << 8) | 2);
      mmioWe.put(1);
      await clk.nextPosedge;

      mmioAddr.put(MiniRISC4Constants.addrNocChCfg1);
      mmioWdata.put(1);
      await clk.nextPosedge;

      mmioWe.put(0);
      mmioAddr.put(MiniRISC4Constants.addrNocMboxSend);
      mmioWdata.put(0x9999);
      mmioWe.put(1);
      await clk.nextPosedge;

      mmioWe.put(0);
      await clk.nextPosedge;
      expect(dut.output('netOutValid').value.toInt(), equals(1));
      expect(dut.output('netOutType').value.toInt(), equals(1));
      expect(dut.output('netOutDstCore').value.toInt(), equals(3));
      expect(dut.output('netOutDstCh').value.toInt(), equals(2));
      expect(dut.output('netOutPayload').value.toInt(), equals(0x9999));

      netOutReady.put(1);
      netInValid.put(1);
      netInType.put(1);
      netInSrcCore.put(2);
      netInSrcCh.put(3);
      netInPayload.put(0x7777);
      await clk.nextPosedge;

      netInValid.put(0);
      await clk.nextPosedge;
      expect(dut.output('mboxTrapReq').value.toInt(), equals(1));

      mmioAddr.put(MiniRISC4Constants.addrNocMboxSrc);
      mmioRe.put(1);
      await clk.nextPosedge;
      expect(dut.output('mmioRdata').value.toInt(), equals(0x0203));
      mmioRe.put(0);
      await clk.nextPosedge;

      // Sample combinational MBOX_DATA before popping on a clock edge
      mmioAddr.put(MiniRISC4Constants.addrNocMboxData);
      mmioRe.put(1);
      await Simulator.tick();
      expect(dut.output('mmioRdata').value.toInt(), equals(0x7777));
      await clk.nextPosedge;
      mmioRe.put(0);

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });
  });
}

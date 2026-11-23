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

    test('Multi-word per-channel RX FIFO ordering, wrap-around, and backpressure', () async {
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
        name: 'noc_ni_rx_fifo',
      );
      await dut.build();

      reset.put(1);
      mmioAddr.put(0);
      mmioWdata.put(0);
      mmioWe.put(0);
      mmioRe.put(0);
      netInValid.put(0);
      netInType.put(0);
      netInSrcCore.put(1);
      netInSrcCh.put(0);
      netInDstCh.put(0);
      netInPayload.put(0);
      netOutReady.put(1);

      Simulator.setMaxSimTime(2000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      await step();
      await step();
      reset.put(0);
      await step();

      // Push 4 words into ch 0 and 2 words into ch 2 interleaved
      final ch0Words = [0x1111, 0x2222, 0x3333, 0x4444];
      final ch2Words = [0xA001, 0xA002];
      for (var i = 0; i < 4; i++) {
        netInValid.put(1);
        netInType.put(0);
        netInDstCh.put(0);
        netInPayload.put(ch0Words[i]);
        expect(dut.output('netInReady').value.toInt(), equals(1));
        await step();

        if (i < 2) {
          netInDstCh.put(2);
          netInPayload.put(ch2Words[i]);
          expect(dut.output('netInReady').value.toInt(), equals(1));
          await step();
        }
      }

      // Ch 0 is now full: netInReady for ch 0 must be 0, while ch 2 is still 1
      netInDstCh.put(0);
      netInPayload.put(0xDEAD);
      expect(dut.output('netInReady').value.toInt(), equals(0));
      // Attempt overflow push on full ch 0 — must be ignored without corrupting head
      await step();

      netInValid.put(0);
      netInDstCh.put(2);
      expect(dut.output('netInReady').value.toInt(), equals(1));

      // Check NOC_RX_STAT for ch 0: count=4, full=1, not_empty=1, tx_ready=1, tx_empty=1
      mmioAddr.put(MiniRISC4Constants.addrNocSelCh);
      mmioWdata.put(0);
      mmioWe.put(1);
      await step();
      mmioWe.put(0);
      mmioAddr.put(MiniRISC4Constants.addrNocRxStat);
      mmioRe.put(1);
      final stat0 = dut.output('mmioRdata').value.toInt();
      expect((stat0 >> 8) & 0xFF, equals(4));
      expect(stat0 & 0x1, equals(1)); // rx_not_empty
      expect((stat0 >> 1) & 0x1, equals(1)); // rx_full
      expect((stat0 >> 2) & 0x1, equals(1)); // tx_ready
      expect((stat0 >> 3) & 0x1, equals(1)); // tx_empty
      mmioRe.put(0);
      await step();

      // Pop 2 words from ch 0 and verify FIFO order + 1-cycle held mmioRdataQ
      mmioAddr.put(MiniRISC4Constants.addrNocRxTryR);
      for (var i = 0; i < 2; i++) {
        mmioRe.put(1);
        expect(dut.output('mmioRdata').value.toInt(), equals(ch0Words[i]));
        await step();
        // 1-cycle hold for CpuCore ST_MEM_WAIT2 after re drops to 0
        mmioRe.put(0);
        expect(dut.output('mmioRdata').value.toInt(), equals(ch0Words[i]));
        await step();
        expect(dut.output('mmioRdata').value.toInt(), equals(0x0000));
      }

      // Simultaneous push (0x5555) + pop (0x3333) on ch 0 (tests pointer wrap-around)
      netInValid.put(1);
      netInType.put(0);
      netInDstCh.put(0);
      netInPayload.put(0x5555);
      mmioAddr.put(MiniRISC4Constants.addrNocRxData);
      mmioRe.put(1);
      expect(dut.output('netInReady').value.toInt(), equals(1));
      expect(dut.output('mmioRdata').value.toInt(), equals(0x3333));
      await step();
      netInValid.put(0);
      mmioRe.put(0);
      await step();

      // Remaining words in ch 0 must be 0x4444 then 0x5555, then empty (0x0000)
      for (final expected in [0x4444, 0x5555, 0x0000]) {
        mmioAddr.put(MiniRISC4Constants.addrNocRxTryR);
        mmioRe.put(1);
        expect(dut.output('mmioRdata').value.toInt(), equals(expected));
        await step();
        mmioRe.put(0);
        await step();
      }

      // Switch to ch 2 and verify its 2 words remained intact and in order
      mmioAddr.put(MiniRISC4Constants.addrNocSelCh);
      mmioWdata.put(2);
      mmioWe.put(1);
      await step();
      mmioWe.put(0);

      for (final expected in ch2Words) {
        mmioAddr.put(MiniRISC4Constants.addrNocRxTryR);
        mmioRe.put(1);
        expect(dut.output('mmioRdata').value.toInt(), equals(expected));
        await step();
        mmioRe.put(0);
        await step();
      }

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('Multi-word TX FIFO backpressure and multi-word MBOX RX FIFO', () async {
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
        txFifoDepth: 3,
        mboxFifoDepth: 2,
        name: 'noc_ni_tx_mbox_fifo',
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
      netOutReady.put(0); // Stall TX output to test TX FIFO buffering

      Simulator.setMaxSimTime(2000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      await step();
      await step();
      reset.put(0);
      await step();

      // Configure ch 2 -> (dstCore=3, dstCh=1), verify readback & NOC_INFO (0x002A)
      mmioAddr.put(MiniRISC4Constants.addrNocInfo);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals((4 << 8) | 1));
      mmioRe.put(0);
      // Writes to read-only NOC_INFO must be ignored
      mmioWdata.put(0xFFFF);
      mmioWe.put(1);
      await step();
      mmioWe.put(0);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals((4 << 8) | 1));
      mmioRe.put(0);

      mmioAddr.put(MiniRISC4Constants.addrNocSelCh);
      mmioWdata.put(2);
      mmioWe.put(1);
      await step();
      mmioAddr.put(MiniRISC4Constants.addrNocChCfg0);
      mmioWdata.put((3 << 8) | 1);
      await step();
      mmioAddr.put(MiniRISC4Constants.addrNocChCfg1);
      mmioWdata.put(1);
      await step();
      mmioWe.put(0);

      mmioAddr.put(MiniRISC4Constants.addrNocChCfg0);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals(0x0301));
      mmioAddr.put(MiniRISC4Constants.addrNocChCfg1);
      expect(dut.output('mmioRdata').value.toInt(), equals(1));
      mmioRe.put(0);
      await step();

      // Push 3 words into TX FIFO while netOutReady=0 (2 DATA + 1 MBOX)
      mmioWe.put(1);
      mmioAddr.put(MiniRISC4Constants.addrNocTxData);
      mmioWdata.put(0x1001);
      await step();
      mmioWdata.put(0x1002);
      await step();
      mmioAddr.put(MiniRISC4Constants.addrNocMboxSend);
      mmioWdata.put(0x8888);
      await step();
      mmioWe.put(0);

      // TX FIFO (depth 3) is now full -> tx_ready (bit 2) = 0, tx_empty (bit 3) = 0
      mmioAddr.put(MiniRISC4Constants.addrNocRxStat);
      mmioRe.put(1);
      final statFull = dut.output('mmioRdata').value.toInt();
      expect((statFull >> 2) & 0x1, equals(0)); // tx_ready = 0
      expect((statFull >> 3) & 0x1, equals(0)); // tx_empty = 0
      mmioRe.put(0);

      // Extra TX write while full must be ignored
      mmioWe.put(1);
      mmioAddr.put(MiniRISC4Constants.addrNocTxData);
      mmioWdata.put(0xBAD0);
      await step();
      mmioWe.put(0);

      // Drain TX FIFO with netOutReady = 1 and check exact FIFO order & srcCh=2
      netOutReady.put(1);
      final expectedTx = [
        (0, 0x1001),
        (0, 0x1002),
        (1, 0x8888),
      ];
      for (final (expType, expPayload) in expectedTx) {
        expect(dut.output('netOutValid').value.toInt(), equals(1));
        expect(dut.output('netOutType').value.toInt(), equals(expType));
        expect(dut.output('netOutDstCore').value.toInt(), equals(3));
        expect(dut.output('netOutDstCh').value.toInt(), equals(1));
        expect(dut.output('netOutSrcCh').value.toInt(), equals(2));
        expect(dut.output('netOutPayload').value.toInt(), equals(expPayload));
        await step();
      }
      expect(dut.output('netOutValid').value.toInt(), equals(0));

      // Test MBOX RX FIFO (depth 2) + backpressure
      netInValid.put(1);
      netInType.put(1);
      netInSrcCore.put(2);
      netInSrcCh.put(1);
      netInPayload.put(0xAA01);
      expect(dut.output('netInReady').value.toInt(), equals(1));
      await step();

      netInSrcCore.put(3);
      netInSrcCh.put(2);
      netInPayload.put(0xBB02);
      expect(dut.output('netInReady').value.toInt(), equals(1));
      await step();

      // MBOX FIFO now full -> netInReady=0 for type=1, but still 1 for type=0
      netInPayload.put(0xCC03);
      expect(dut.output('netInReady').value.toInt(), equals(0));
      netInType.put(0);
      netInDstCh.put(0);
      expect(dut.output('netInReady').value.toInt(), equals(1));

      netInType.put(1);
      await step(); // Ignored because MBOX full
      netInValid.put(0);

      // Check status flags: mbox_not_empty (bit 4)=1, mbox_full (bit 5)=1, mboxTrapReq=1
      expect(dut.output('mboxTrapReq').value.toInt(), equals(1));
      mmioAddr.put(MiniRISC4Constants.addrNocRxStat);
      mmioRe.put(1);
      final mboxStat = dut.output('mmioRdata').value.toInt();
      expect((mboxStat >> 4) & 0x1, equals(1));
      expect((mboxStat >> 5) & 0x1, equals(1));
      mmioRe.put(0);

      // Pop first MBOX (0xAA01 from 0x0201) -> trap stays 1
      mmioAddr.put(MiniRISC4Constants.addrNocMboxSrc);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals(0x0201));
      mmioAddr.put(MiniRISC4Constants.addrNocMboxData);
      expect(dut.output('mmioRdata').value.toInt(), equals(0xAA01));
      await step();
      mmioRe.put(0);
      expect(dut.output('mboxTrapReq').value.toInt(), equals(1));

      // Pop second MBOX (0xBB02 from 0x0302) -> trap drops to 0, lastMboxSrc holds 0x0302
      mmioAddr.put(MiniRISC4Constants.addrNocMboxData);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals(0xBB02));
      await step();
      mmioRe.put(0);
      expect(dut.output('mboxTrapReq').value.toInt(), equals(0));

      mmioAddr.put(MiniRISC4Constants.addrNocMboxSrc);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals(0x0302));
      mmioRe.put(0);

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });
  });
}

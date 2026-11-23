import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:minirisc4_rohd/constants.dart';
import 'package:minirisc4_rohd/noc_router.dart';

void main() {
  group('NocRouterNi Direct Ring & Doorbell Tests', () {
    setUp(() async {
      await Simulator.reset();
    });

    test('RX FIFO ordering, wrap-around, 1-cycle hold, and full backpressure', () async {
      const numCores = 4;
      const fifoDepth = 4;
      final idW = NocRouterNi.idWidthForCores(numCores);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final mmioAddr = Logic(name: 'mmioAddr', width: MiniRISC4Constants.addrWidth);
      final mmioWdata = Logic(name: 'mmioWdata', width: MiniRISC4Constants.dataWidth);
      final mmioWe = Logic(name: 'mmioWe');
      final mmioRe = Logic(name: 'mmioRe');
      final netInValid = Logic(name: 'netInValid');
      final netInType = Logic(name: 'netInType');
      final netInSrcCore = Logic(name: 'netInSrcCore', width: idW);
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
        netInPayload: netInPayload,
        netOutReady: netOutReady,
        coreId: 0,
        numCores: numCores,
        fifoDepth: fifoDepth,
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
      netInSrcCore.put(2);
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

      // Empty TRYR returns 0x0000; NOC_INFO returns {fifoDepth=4, numCores=4}
      mmioAddr.put(MiniRISC4Constants.addrNocRxTryR);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals(0x0000));
      mmioAddr.put(MiniRISC4Constants.addrNocInfo);
      expect(dut.output('mmioRdata').value.toInt(), equals((fifoDepth << 8) | numCores));
      mmioRe.put(0);

      // Push 4 words into shared RX FIFO
      final words = [0x1111, 0x2222, 0x3333, 0x4444];
      for (final w in words) {
        netInValid.put(1);
        netInType.put(0);
        netInPayload.put(w);
        expect(dut.output('netInReady').value.toInt(), equals(1));
        await step();
      }

      // Full -> netInReady drops to 0, extra push ignored without corrupting head
      netInPayload.put(0xDEAD);
      expect(dut.output('netInReady').value.toInt(), equals(0));
      await step();
      netInValid.put(0);

      // Verify NOC_STAT: cnt=4, rx_not_empty=1, rx_full=1, tx_ready=1, tx_empty=1
      mmioAddr.put(MiniRISC4Constants.addrNocRxStat);
      mmioRe.put(1);
      final stat = dut.output('mmioRdata').value.toInt();
      expect((stat >> 8) & 0xFF, equals(4));
      expect(stat & 0xF, equals(0xF));
      mmioRe.put(0);
      await step();

      // Pop 2 words and verify 1-cycle mmioRdataReg hold for CpuCore ST_MEM_WAIT2
      mmioAddr.put(MiniRISC4Constants.addrNocRxTryR);
      for (var i = 0; i < 2; i++) {
        mmioRe.put(1);
        expect(dut.output('mmioRdata').value.toInt(), equals(words[i]));
        await step();
        mmioRe.put(0);
        expect(dut.output('mmioRdata').value.toInt(), equals(words[i]));
        expect(dut.output('mmioRdataReg').value.toInt(), equals(words[i]));
        await step();
        expect(dut.output('mmioRdata').value.toInt(), equals(0x0000));
      }

      // Simultaneous push (0x5555) + pop (0x3333) tests circular pointer wrap-around
      netInValid.put(1);
      netInType.put(0);
      netInPayload.put(0x5555);
      mmioAddr.put(MiniRISC4Constants.addrNocRxData);
      mmioRe.put(1);
      expect(dut.output('netInReady').value.toInt(), equals(1));
      expect(dut.output('mmioRdata').value.toInt(), equals(0x3333));
      await step();
      netInValid.put(0);
      mmioRe.put(0);
      await step();

      // Remaining words: 0x4444, 0x5555, then empty (0x0000)
      for (final expected in [0x4444, 0x5555, 0x0000]) {
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

    test('Direct dstCore addressing, TX backpressure, invalid dstCore guard, and Doorbell/MBOX', () async {
      const numCores = 4;
      final idW = NocRouterNi.idWidthForCores(numCores);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final mmioAddr = Logic(name: 'mmioAddr', width: MiniRISC4Constants.addrWidth);
      final mmioWdata = Logic(name: 'mmioWdata', width: MiniRISC4Constants.dataWidth);
      final mmioWe = Logic(name: 'mmioWe');
      final mmioRe = Logic(name: 'mmioRe');
      final netInValid = Logic(name: 'netInValid');
      final netInType = Logic(name: 'netInType');
      final netInSrcCore = Logic(name: 'netInSrcCore', width: idW);
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
        netInPayload: netInPayload,
        netOutReady: netOutReady,
        coreId: 1,
        numCores: numCores,
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
      netInPayload.put(0);
      netOutReady.put(0); // Stall output

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

      // Select dstCore = 3 and verify readback
      mmioAddr.put(MiniRISC4Constants.addrNocDstCore);
      mmioWdata.put(3);
      mmioWe.put(1);
      await step();
      mmioWe.put(0);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals(3));
      mmioRe.put(0);

      // Send doorbell/MBOX 0x9999 while netOutReady = 0
      mmioAddr.put(MiniRISC4Constants.addrNocMboxSend);
      mmioWdata.put(0x9999);
      mmioWe.put(1);
      await step();
      mmioWe.put(0);

      expect(dut.output('netOutValid').value.toInt(), equals(1));
      expect(dut.output('netOutType').value.toInt(), equals(1));
      expect(dut.output('netOutDstCore').value.toInt(), equals(3));
      expect(dut.output('netOutPayload').value.toInt(), equals(0x9999));

      // While stalled, tx_ready (bit 2) = 0, tx_empty (bit 3) = 0
      mmioAddr.put(MiniRISC4Constants.addrNocRxStat);
      mmioRe.put(1);
      final stalledStat = dut.output('mmioRdata').value.toInt();
      expect((stalledStat >> 2) & 1, equals(0));
      expect((stalledStat >> 3) & 1, equals(0));
      mmioRe.put(0);

      // Release netOutReady = 1 and simultaneously push DATA 0x1234 (1.0 word/cycle!)
      netOutReady.put(1);
      mmioAddr.put(MiniRISC4Constants.addrNocTxData);
      mmioWdata.put(0x1234);
      mmioWe.put(1);
      await step();
      mmioWe.put(0);

      expect(dut.output('netOutValid').value.toInt(), equals(1));
      expect(dut.output('netOutType').value.toInt(), equals(0));
      expect(dut.output('netOutPayload').value.toInt(), equals(0x1234));
      await step();
      expect(dut.output('netOutValid').value.toInt(), equals(0));

      // Out-of-range dstCore (99) must be guarded (TX writes ignored)
      mmioAddr.put(MiniRISC4Constants.addrNocDstCore);
      mmioWdata.put(99);
      mmioWe.put(1);
      await step();
      mmioAddr.put(MiniRISC4Constants.addrNocTxData);
      mmioWdata.put(0xDEAD);
      await step();
      mmioWe.put(0);
      expect(dut.output('netOutValid').value.toInt(), equals(0));

      // Incoming Doorbell/MBOX from core 2 sets mboxTrapReq & backpressures type=1
      netInValid.put(1);
      netInType.put(1);
      netInSrcCore.put(2);
      netInPayload.put(0x7777);
      expect(dut.output('netInReady').value.toInt(), equals(1));
      await step();
      netInValid.put(0);

      expect(dut.output('mboxTrapReq').value.toInt(), equals(1));
      // Type=1 is now backpressured (netInReady=0), while DATA type=0 is still ready (1)
      netInType.put(1);
      expect(dut.output('netInReady').value.toInt(), equals(0));
      netInType.put(0);
      expect(dut.output('netInReady').value.toInt(), equals(1));

      // MBOX_SRC returns sender core ID directly (2); MBOX_DATA pops 0x7777 & clears trap
      mmioAddr.put(MiniRISC4Constants.addrNocMboxSrc);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals(2));
      mmioAddr.put(MiniRISC4Constants.addrNocMboxData);
      expect(dut.output('mmioRdata').value.toInt(), equals(0x7777));
      await step();
      mmioRe.put(0);
      expect(dut.output('mboxTrapReq').value.toInt(), equals(0));
      // Last sender core ID retained after pop
      mmioAddr.put(MiniRISC4Constants.addrNocMboxSrc);
      mmioRe.put(1);
      expect(dut.output('mmioRdata').value.toInt(), equals(2));

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });
  });
}

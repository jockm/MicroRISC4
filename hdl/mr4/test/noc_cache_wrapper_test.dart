import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:microrisc4_rohd/constants.dart';
import 'package:microrisc4_rohd/noc_cache_wrapper.dart';
import 'package:microrisc4_rohd/noc_router.dart';

void main() {
  group('NocMultiCoreCacheWrapper Lean Elastic Ring Tests', () {
    setUp(() async {
      await Simulator.reset();
    });

    test('3-core ring request/reply + server injection parity', () async {
      const numCores = 3;
      const fifoDepth = 8;
      final idW = NocRouterNi.idWidthForCores(numCores);
      const writeReqWord = 0x8020;
      const writeVal = 0xBEEF;
      const readReqWord = 0x0010;
      const readVal = 0x55AA;
      const expectedWriteTag = 0x8020;

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final mmioAddr = List.generate(numCores, (i) => Logic(name: 'addr_$i', width: MicroRISC4Constants.addrWidth));
      final mmioWdata = List.generate(numCores, (i) => Logic(name: 'wdata_$i', width: MicroRISC4Constants.dataWidth));
      final mmioWe = List.generate(numCores, (i) => Logic(name: 'we_$i'));
      final mmioRe = List.generate(numCores, (i) => Logic(name: 're_$i'));
      final netOutReady = List.generate(numCores, (i) => Logic(name: 'ready_$i'));

      final srvV = Logic(name: 'srvV');
      final srvT = Logic(name: 'srvT');
      final srvSc = Logic(name: 'srvSc', width: idW);
      final srvDc = Logic(name: 'srvDc', width: idW);
      final srvP = Logic(name: 'srvP', width: MicroRISC4Constants.dataWidth);

      final top = NocMultiCoreCacheWrapper(
        clk: clk,
        reset: reset,
        mmioAddr: mmioAddr,
        mmioWdata: mmioWdata,
        mmioWe: mmioWe,
        mmioRe: mmioRe,
        netOutReady: netOutReady,
        srvInjectValid: srvV,
        srvInjectType: srvT,
        srvInjectSrcCore: srvSc,
        srvInjectDstCore: srvDc,
        srvInjectPayload: srvP,
        numCores: numCores,
        serverCoreId: 0,
        fifoDepth: fifoDepth,
      );
      await top.build();

      reset.put(1);
      for (var c = 0; c < numCores; c++) {
        mmioAddr[c].put(0);
        mmioWdata[c].put(0);
        mmioWe[c].put(0);
        mmioRe[c].put(0);
        netOutReady[c].put(1);
      }
      srvV.put(0);
      srvT.put(0);
      srvSc.put(0);
      srvDc.put(0);
      srvP.put(0);

      Simulator.setMaxSimTime(1200);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      await step();
      await step();
      reset.put(0);
      await step();

      // Core 1 targets Core 0 directly (1 write to NOC_DST_CORE!) and sends 2 words (2 hops: 1->2->0)
      mmioAddr[1].put(MicroRISC4Constants.addrNocDstCore);
      mmioWdata[1].put(0);
      mmioWe[1].put(1);
      await step();
      mmioAddr[1].put(MicroRISC4Constants.addrNocTxData);
      mmioWdata[1].put(writeReqWord);
      await step();
      mmioWdata[1].put(writeVal);
      await step();
      mmioWe[1].put(0);

      for (var i = 0; i < numCores + 1; i++) {
        await step();
      }

      // Server emits priority MBOX doorbell back to Core 1
      srvV.put(1);
      srvT.put(1);
      srvSc.put(0);
      srvDc.put(1);
      srvP.put(expectedWriteTag);
      await step();
      srvV.put(0);
      await step();

      expect(top.output('mboxTrapReq_1').value.toInt(), equals(1));
      mmioAddr[1].put(MicroRISC4Constants.addrNocMboxData);
      mmioRe[1].put(1);
      expect(top.output('mmioRdata_1').value.toInt(), equals(expectedWriteTag));
      await step();
      mmioRe[1].put(0);

      // Core 2 targets Core 0 directly and sends readReqWord (1 hop: 2->0)
      mmioAddr[2].put(MicroRISC4Constants.addrNocDstCore);
      mmioWdata[2].put(0);
      mmioWe[2].put(1);
      await step();
      mmioAddr[2].put(MicroRISC4Constants.addrNocTxData);
      mmioWdata[2].put(readReqWord);
      await step();
      mmioWe[2].put(0);
      for (var i = 0; i < numCores + 1; i++) {
        await step();
      }

      // Core 0 received writeReqWord, writeVal (2 hops), and readReqWord (1 hop)
      mmioAddr[0].put(MicroRISC4Constants.addrNocRxTryR);
      mmioRe[0].put(1);
      expect(top.output('mmioRdata_0').value.toInt(), equals(writeReqWord));
      await step();
      expect(top.output('mmioRdata_0').value.toInt(), equals(writeVal));
      await step();
      expect(top.output('mmioRdata_0').value.toInt(), equals(readReqWord));
      await step();
      mmioRe[0].put(0);

      // Server injects readVal back to Core 2
      srvV.put(1);
      srvT.put(0);
      srvSc.put(0);
      srvDc.put(2);
      srvP.put(readVal);
      await step();
      srvV.put(0);
      await step();

      mmioAddr[2].put(MicroRISC4Constants.addrNocRxTryR);
      mmioRe[2].put(1);
      expect(top.output('mmioRdata_2').value.toInt(), equals(readVal));
      await step();
      mmioRe[2].put(0);

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('4-core multi-hop DATA/MBOX forwarding, contention, and lossless backpressure', () async {
      const numCores = 4;
      const fifoDepth = 4;
      final idW = NocRouterNi.idWidthForCores(numCores);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final mmioAddr = List.generate(numCores, (i) => Logic(name: 'addr_$i', width: MicroRISC4Constants.addrWidth));
      final mmioWdata = List.generate(numCores, (i) => Logic(name: 'wdata_$i', width: MicroRISC4Constants.dataWidth));
      final mmioWe = List.generate(numCores, (i) => Logic(name: 'we_$i'));
      final mmioRe = List.generate(numCores, (i) => Logic(name: 're_$i'));
      final netOutReady = List.generate(numCores, (i) => Logic(name: 'ready_$i'));

      final srvV = Logic(name: 'srvV');
      final srvT = Logic(name: 'srvT');
      final srvSc = Logic(name: 'srvSc', width: idW);
      final srvDc = Logic(name: 'srvDc', width: idW);
      final srvP = Logic(name: 'srvP', width: MicroRISC4Constants.dataWidth);

      final top = NocMultiCoreCacheWrapper(
        clk: clk,
        reset: reset,
        mmioAddr: mmioAddr,
        mmioWdata: mmioWdata,
        mmioWe: mmioWe,
        mmioRe: mmioRe,
        netOutReady: netOutReady,
        srvInjectValid: srvV,
        srvInjectType: srvT,
        srvInjectSrcCore: srvSc,
        srvInjectDstCore: srvDc,
        srvInjectPayload: srvP,
        numCores: numCores,
        serverCoreId: 0,
        fifoDepth: fifoDepth,
      );
      await top.build();

      reset.put(1);
      for (var c = 0; c < numCores; c++) {
        mmioAddr[c].put(0);
        mmioWdata[c].put(0);
        mmioWe[c].put(0);
        mmioRe[c].put(0);
        netOutReady[c].put(1);
      }
      srvV.put(0);
      srvT.put(0);
      srvSc.put(0);
      srvDc.put(0);
      srvP.put(0);

      Simulator.setMaxSimTime(4000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      await step();
      await step();
      reset.put(0);
      await step();

      // Verify NOC_INFO (0x002A) == {fifoDepth=4, numCores=4} on every core
      for (var c = 0; c < numCores; c++) {
        mmioAddr[c].put(MicroRISC4Constants.addrNocInfo);
        mmioRe[c].put(1);
        expect(top.output('mmioRdata_$c').value.toInt(), equals((fifoDepth << 8) | numCores));
      }
      await step();
      for (var c = 0; c < numCores; c++) {
        mmioRe[c].put(0);
        expect(top.output('mmioRdataReg_$c').value.toInt(), equals((fifoDepth << 8) | numCores));
      }

      // Direct targets in 1 cycle:
      //   Core 0 -> Core 3 (3 hops), Core 1 -> Core 3 (2 hops, contends!),
      //   Core 2 -> Core 0 (2 hops, MBOX), Core 3 -> Core 1 (2 hops)
      mmioAddr[0].put(MicroRISC4Constants.addrNocDstCore); mmioWdata[0].put(3); mmioWe[0].put(1);
      mmioAddr[1].put(MicroRISC4Constants.addrNocDstCore); mmioWdata[1].put(3); mmioWe[1].put(1);
      mmioAddr[2].put(MicroRISC4Constants.addrNocDstCore); mmioWdata[2].put(0); mmioWe[2].put(1);
      mmioAddr[3].put(MicroRISC4Constants.addrNocDstCore); mmioWdata[3].put(1); mmioWe[3].put(1);
      await step();

      // Burst 6 DATA words into Core 3 (FIFO depth 4 -> exercises elastic ring backpressure)
      // while Core 2 sends MBOX 0xBEEF to Core 0 and Core 3 sends 0x3333 to Core 1
      var c0Sent = 0;
      var c1Sent = 0;
      var c2Sent = false;
      var c3Sent = false;
      for (var cyc = 0; cyc < 20 && (c0Sent < 3 || c1Sent < 3 || !c2Sent || !c3Sent); cyc++) {
        // Poll tx_ready bit 2 on each sender before pushing (1-entry TX flit)
        mmioAddr[0].put(MicroRISC4Constants.addrNocRxStat); mmioRe[0].put(1);
        final r0 = ((top.output('mmioRdata_0').value.toInt() >> 2) & 1) == 1;
        mmioRe[0].put(0);
        if (c0Sent < 3 && r0) {
          mmioAddr[0].put(MicroRISC4Constants.addrNocTxData);
          mmioWdata[0].put(0x0001 + c0Sent);
          mmioWe[0].put(1);
          c0Sent++;
        } else {
          mmioWe[0].put(0);
        }

        mmioAddr[1].put(MicroRISC4Constants.addrNocRxStat); mmioRe[1].put(1);
        final r1 = ((top.output('mmioRdata_1').value.toInt() >> 2) & 1) == 1;
        mmioRe[1].put(0);
        if (c1Sent < 3 && r1) {
          mmioAddr[1].put(MicroRISC4Constants.addrNocTxData);
          mmioWdata[1].put(0x1001 + c1Sent);
          mmioWe[1].put(1);
          c1Sent++;
        } else {
          mmioWe[1].put(0);
        }

        if (!c2Sent) {
          mmioAddr[2].put(MicroRISC4Constants.addrNocMboxSend);
          mmioWdata[2].put(0xBEEF);
          mmioWe[2].put(1);
          c2Sent = true;
        } else {
          mmioWe[2].put(0);
        }

        if (!c3Sent) {
          mmioAddr[3].put(MicroRISC4Constants.addrNocTxData);
          mmioWdata[3].put(0x3333);
          mmioWe[3].put(1);
          c3Sent = true;
        } else {
          mmioWe[3].put(0);
        }
        await step();
      }
      for (var c = 0; c < numCores; c++) {
        mmioWe[c].put(0);
      }

      for (var i = 0; i < 12; i++) {
        await step();
      }

      // Core 0 received Core 2's MBOX (0xBEEF) with direct srcCore = 2
      expect(top.output('mboxTrapReq_0').value.toInt(), equals(1));
      mmioAddr[0].put(MicroRISC4Constants.addrNocMboxSrc);
      mmioRe[0].put(1);
      expect(top.output('mmioRdata_0').value.toInt(), equals(2));
      mmioAddr[0].put(MicroRISC4Constants.addrNocMboxData);
      expect(top.output('mmioRdata_0').value.toInt(), equals(0xBEEF));
      await step();
      mmioRe[0].put(0);
      expect(top.output('mboxTrapReq_0').value.toInt(), equals(0));

      // Core 1 received Core 3's 2-hop DATA word (0x3333)
      mmioAddr[1].put(MicroRISC4Constants.addrNocRxTryR);
      mmioRe[1].put(1);
      expect(top.output('mmioRdata_1').value.toInt(), equals(0x3333));
      await step();
      mmioRe[1].put(0);

      // Core 3 RX FIFO must be FULL (count == 4, full bit == 1) with 2 more stalled in ring
      mmioAddr[3].put(MicroRISC4Constants.addrNocRxStat);
      mmioRe[3].put(1);
      final stat3 = top.output('mmioRdata_3').value.toInt();
      expect((stat3 >> 8) & 0xFF, equals(4));
      expect((stat3 >> 1) & 1, equals(1));
      mmioRe[3].put(0);

      // Drain all 6 words losslessly
      final received3 = <int>[];
      for (var tries = 0; tries < 24 && received3.length < 6; tries++) {
        mmioAddr[3].put(MicroRISC4Constants.addrNocRxStat);
        mmioRe[3].put(1);
        final hasWord = (top.output('mmioRdata_3').value.toInt() & 1) == 1;
        if (hasWord) {
          mmioAddr[3].put(MicroRISC4Constants.addrNocRxTryR);
          received3.add(top.output('mmioRdata_3').value.toInt());
          await step();
        } else {
          mmioRe[3].put(0);
          await step();
        }
      }
      mmioRe[3].put(0);

      expect(received3.length, equals(6));
      expect(received3.where((w) => (w & 0xF000) == 0x0000).toList(),
          equals([0x0001, 0x0002, 0x0003]));
      expect(received3.where((w) => (w & 0xF000) == 0x1000).toList(),
          equals([0x1001, 0x1002, 0x1003]));

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });
  });
}

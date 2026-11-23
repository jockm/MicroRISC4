import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:minirisc4_rohd/constants.dart';
import 'package:minirisc4_rohd/noc_cache_wrapper.dart';

void main() {
  group('NocMultiCoreCacheWrapper vs mr4sim.py parity', () {
    setUp(() async {
      await Simulator.reset();
    });

    test('Mirrors write 0x80xx MBOX tag and read data + MBOX completion', () async {
      const numCores = 3;
      const opRead = 0;
      const opWrite = 1;
      const writeOffset = 0x0020;
      const writeVal = 0xBEEF;
      const readOffset = 0x0010;
      const readVal = 0x55AA;
      final expectedWriteTag = 0x8000 | (writeOffset & 0x3FFF);
      final writeReqWord = ((opWrite & 1) << 15) | (writeOffset & 0x7FFF);
      final readReqWord = ((opRead & 1) << 15) | (readOffset & 0x7FFF);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final mmioAddr = List.generate(numCores, (i) => Logic(name: 'addr_$i', width: MiniRISC4Constants.addrWidth));
      final mmioWdata = List.generate(numCores, (i) => Logic(name: 'wdata_$i', width: MiniRISC4Constants.dataWidth));
      final mmioWe = List.generate(numCores, (i) => Logic(name: 'we_$i'));
      final mmioRe = List.generate(numCores, (i) => Logic(name: 're_$i'));
      final netOutReady = List.generate(numCores, (i) => Logic(name: 'ready_$i'));

      final srvV = Logic(name: 'srvV');
      final srvT = Logic(name: 'srvT');
      final srvSc = Logic(name: 'srvSc', width: 8);
      final srvSch = Logic(name: 'srvSch', width: 8);
      final srvDc = Logic(name: 'srvDc', width: 8);
      final srvDch = Logic(name: 'srvDch', width: 8);
      final srvP = Logic(name: 'srvP', width: MiniRISC4Constants.dataWidth);

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
        srvInjectSrcCh: srvSch,
        srvInjectDstCore: srvDc,
        srvInjectDstCh: srvDch,
        srvInjectPayload: srvP,
        numCores: numCores,
        serverCoreId: 0,
        opRead: opRead,
        opWrite: opWrite,
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
      srvSch.put(0);
      srvDc.put(0);
      srvDch.put(0);
      srvP.put(0);

      Simulator.setMaxSimTime(1000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      await step();
      await step();
      reset.put(0);
      await step();

      // Core 1 configures route ch0 -> (serverCore=0, ch0) and sends write req + data
      mmioAddr[1].put(MiniRISC4Constants.addrNocChCfg0);
      mmioWdata[1].put((0 << 8) | 0);
      mmioWe[1].put(1);
      await step();
      mmioAddr[1].put(MiniRISC4Constants.addrNocChCfg1);
      mmioWdata[1].put(1);
      await step();
      mmioAddr[1].put(MiniRISC4Constants.addrNocTxData);
      mmioWdata[1].put(writeReqWord);
      await step();
      mmioWdata[1].put(writeVal);
      await step();
      mmioWe[1].put(0);

      for (var i = 0; i < numCores + 1; i++) {
        await step();
      }

      // Server emits priority MBOX write tag 0x8020 back to Core 1 ch 1
      srvV.put(1);
      srvT.put(1);
      srvSc.put(0);
      srvSch.put(0);
      srvDc.put(1);
      srvDch.put(1);
      srvP.put(expectedWriteTag);
      await step();
      srvV.put(0);
      await step();

      expect(top.output('mboxTrapReq_1').value.toInt(), equals(1));
      mmioAddr[1].put(MiniRISC4Constants.addrNocMboxData);
      mmioRe[1].put(1);
      expect(top.output('mmioRdata_1').value.toInt(), equals(expectedWriteTag));
      await step();
      mmioRe[1].put(0);

      // Core 2 configures ch 1 -> (serverCore=0, ch0), sends read req, and receives readVal (0x55AA)
      mmioAddr[2].put(MiniRISC4Constants.addrNocSelCh);
      mmioWdata[2].put(1);
      mmioWe[2].put(1);
      await step();
      mmioAddr[2].put(MiniRISC4Constants.addrNocChCfg0);
      mmioWdata[2].put((0 << 8) | 0);
      await step();
      mmioAddr[2].put(MiniRISC4Constants.addrNocChCfg1);
      mmioWdata[2].put(1);
      await step();
      mmioAddr[2].put(MiniRISC4Constants.addrNocTxData);
      mmioWdata[2].put(readReqWord);
      await step();
      mmioWe[2].put(0);
      for (var i = 0; i < numCores + 1; i++) {
        await step();
      }

      // Server Core 0 actually received Core 1's 2-word write req (2 hops: 1->2->0)
      // and Core 2's read req (1 hop: 2->0) in RX ch 0!
      mmioAddr[0].put(MiniRISC4Constants.addrNocRxTryR);
      mmioRe[0].put(1);
      expect(top.output('mmioRdata_0').value.toInt(), equals(writeReqWord));
      await step();
      expect(top.output('mmioRdata_0').value.toInt(), equals(writeVal));
      await step();
      expect(top.output('mmioRdata_0').value.toInt(), equals(readReqWord));
      await step();
      mmioRe[0].put(0);

      // Server injects read DATA word to Core 2 ch 1
      srvV.put(1);
      srvT.put(0);
      srvSc.put(0);
      srvSch.put(0);
      srvDc.put(2);
      srvDch.put(1);
      srvP.put(readVal);
      await step();
      srvV.put(0);
      await step();

      mmioAddr[2].put(MiniRISC4Constants.addrNocRxTryR);
      mmioRe[2].put(1);
      expect(top.output('mmioRdata_2').value.toInt(), equals(readVal));
      await step();
      mmioRe[2].put(0);

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('4-core multi-hop DATA/MBOX forwarding, contention, backpressure, and invalid-core drop', () async {
      const numCores = 4;
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final mmioAddr = List.generate(numCores, (i) => Logic(name: 'addr_$i', width: MiniRISC4Constants.addrWidth));
      final mmioWdata = List.generate(numCores, (i) => Logic(name: 'wdata_$i', width: MiniRISC4Constants.dataWidth));
      final mmioWe = List.generate(numCores, (i) => Logic(name: 'we_$i'));
      final mmioRe = List.generate(numCores, (i) => Logic(name: 're_$i'));
      final netOutReady = List.generate(numCores, (i) => Logic(name: 'ready_$i'));

      final srvV = Logic(name: 'srvV');
      final srvT = Logic(name: 'srvT');
      final srvSc = Logic(name: 'srvSc', width: 8);
      final srvSch = Logic(name: 'srvSch', width: 8);
      final srvDc = Logic(name: 'srvDc', width: 8);
      final srvDch = Logic(name: 'srvDch', width: 8);
      final srvP = Logic(name: 'srvP', width: MiniRISC4Constants.dataWidth);

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
        srvInjectSrcCh: srvSch,
        srvInjectDstCore: srvDc,
        srvInjectDstCh: srvDch,
        srvInjectPayload: srvP,
        numCores: numCores,
        serverCoreId: 0,
        numChannels: 4,
        fifoDepth: 4,
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
      srvSch.put(0);
      srvDc.put(0);
      srvDch.put(0);
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

      // Configure routes:
      //   Core 0 ch 2 -> Core 3 ch 1 (3 hops: 0->1->2->3)
      //   Core 1 ch 3 -> Core 3 ch 1 (2 hops: 1->2->3, contends with Core 0!)
      //   Core 2 ch 0 -> Core 0 ch 2 (2 hops: 2->3->0, MBOX with srcCore=2, srcCh=0)
      //   Core 3 ch 1 -> Core 1 ch 0 (2 hops: 3->0->1)
      mmioAddr[0].put(MiniRISC4Constants.addrNocSelCh); mmioWdata[0].put(2); mmioWe[0].put(1);
      mmioAddr[1].put(MiniRISC4Constants.addrNocSelCh); mmioWdata[1].put(3); mmioWe[1].put(1);
      mmioAddr[2].put(MiniRISC4Constants.addrNocSelCh); mmioWdata[2].put(0); mmioWe[2].put(1);
      mmioAddr[3].put(MiniRISC4Constants.addrNocSelCh); mmioWdata[3].put(1); mmioWe[3].put(1);
      await step();

      mmioAddr[0].put(MiniRISC4Constants.addrNocChCfg0); mmioWdata[0].put((3 << 8) | 1);
      mmioAddr[1].put(MiniRISC4Constants.addrNocChCfg0); mmioWdata[1].put((3 << 8) | 1);
      mmioAddr[2].put(MiniRISC4Constants.addrNocChCfg0); mmioWdata[2].put((0 << 8) | 2);
      mmioAddr[3].put(MiniRISC4Constants.addrNocChCfg0); mmioWdata[3].put((1 << 8) | 0);
      await step();

      mmioAddr[0].put(MiniRISC4Constants.addrNocChCfg1); mmioWdata[0].put(1);
      mmioAddr[1].put(MiniRISC4Constants.addrNocChCfg1); mmioWdata[1].put(1);
      mmioAddr[2].put(MiniRISC4Constants.addrNocChCfg1); mmioWdata[2].put(1);
      mmioAddr[3].put(MiniRISC4Constants.addrNocChCfg1); mmioWdata[3].put(1);
      await step();

      // Simultaneously inject a 6-word burst destined for Core 3 ch 1 (depth 4 -> exercises ring backpressure!)
      // Core 0 sends 3 words (0x0001..0x0003) and Core 1 sends 3 words (0x1001..0x1003),
      // while Core 2 sends an MBOX (0xBEEF) to Core 0 and Core 3 sends 0x3333 to Core 1!
      for (var i = 0; i < 3; i++) {
        mmioAddr[0].put(MiniRISC4Constants.addrNocTxData);
        mmioWdata[0].put(0x0001 + i);
        mmioWe[0].put(1);

        mmioAddr[1].put(MiniRISC4Constants.addrNocTxData);
        mmioWdata[1].put(0x1001 + i);
        mmioWe[1].put(1);

        if (i == 0) {
          mmioAddr[2].put(MiniRISC4Constants.addrNocMboxSend);
          mmioWdata[2].put(0xBEEF);
          mmioWe[2].put(1);

          mmioAddr[3].put(MiniRISC4Constants.addrNocTxData);
          mmioWdata[3].put(0x3333);
          mmioWe[3].put(1);
        } else {
          mmioWe[2].put(0);
          mmioWe[3].put(0);
        }
        await step();
      }
      for (var c = 0; c < numCores; c++) {
        mmioWe[c].put(0);
      }

      // Let packets propagate around the 4-core ring (Core 3 ch 1 FIFO fills to 4;
      // the remaining 2 words must stall losslessly in hop_2_to_3!)
      for (var i = 0; i < 12; i++) {
        await step();
      }

      // Core 0 received Core 2's MBOX (0xBEEF) with preserved srcCore=2, srcCh=0!
      expect(top.output('mboxTrapReq_0').value.toInt(), equals(1));
      mmioAddr[0].put(MiniRISC4Constants.addrNocMboxSrc);
      mmioRe[0].put(1);
      expect(top.output('mmioRdata_0').value.toInt(), equals(0x0200));
      mmioAddr[0].put(MiniRISC4Constants.addrNocMboxData);
      expect(top.output('mmioRdata_0').value.toInt(), equals(0xBEEF));
      await step();
      mmioRe[0].put(0);
      expect(top.output('mboxTrapReq_0').value.toInt(), equals(0));

      // Core 1 received Core 3's 2-hop DATA word (0x3333) on ch 0
      mmioAddr[1].put(MiniRISC4Constants.addrNocSelCh);
      mmioWdata[1].put(0);
      mmioWe[1].put(1);
      await step();
      mmioWe[1].put(0);
      mmioAddr[1].put(MiniRISC4Constants.addrNocRxTryR);
      mmioRe[1].put(1);
      expect(top.output('mmioRdata_1').value.toInt(), equals(0x3333));
      await step();
      mmioRe[1].put(0);

      // Core 3 ch 1 must currently be FULL (count == 4, full bit == 1)
      mmioAddr[3].put(MiniRISC4Constants.addrNocRxStat);
      mmioRe[3].put(1);
      final stat3 = top.output('mmioRdata_3').value.toInt();
      expect((stat3 >> 8) & 0xFF, equals(4));
      expect((stat3 >> 1) & 0x1, equals(1));
      mmioRe[3].put(0);

      // Drain ALL 6 words from Core 3 ch 1 (4 from FIFO + 2 backpressured in ring hops!)
      final received3 = <int>[];
      for (var tries = 0; tries < 20 && received3.length < 6; tries++) {
        mmioAddr[3].put(MiniRISC4Constants.addrNocRxStat);
        mmioRe[3].put(1);
        final hasWord = (top.output('mmioRdata_3').value.toInt() & 0x1) == 1;
        if (hasWord) {
          mmioAddr[3].put(MiniRISC4Constants.addrNocRxTryR);
          received3.add(top.output('mmioRdata_3').value.toInt());
          await step();
        } else {
          mmioRe[3].put(0);
          await step();
        }
      }
      mmioRe[3].put(0);

      // Zero words lost! Per-sender FIFO order preserved!
      expect(received3.length, equals(6));
      expect(received3.where((w) => (w & 0xF000) == 0x0000).toList(),
          equals([0x0001, 0x0002, 0x0003]));
      expect(received3.where((w) => (w & 0xF000) == 0x1000).toList(),
          equals([0x1001, 0x1002, 0x1003]));

      // Invalid dstCore (>= numCores) must drop cleanly without wedging the ring
      mmioAddr[0].put(MiniRISC4Constants.addrNocSelCh); mmioWdata[0].put(0); mmioWe[0].put(1);
      await step();
      mmioAddr[0].put(MiniRISC4Constants.addrNocChCfg0); mmioWdata[0].put((99 << 8) | 0);
      await step();
      mmioAddr[0].put(MiniRISC4Constants.addrNocChCfg1); mmioWdata[0].put(1);
      await step();
      mmioAddr[0].put(MiniRISC4Constants.addrNocTxData); mmioWdata[0].put(0xDEAD);
      await step();
      mmioWe[0].put(0);
      for (var i = 0; i < 8; i++) {
        await step();
      }
      // Verify ring still delivers valid traffic cleanly after invalid dstCore drop
      mmioAddr[0].put(MiniRISC4Constants.addrNocSelCh); mmioWdata[0].put(2); mmioWe[0].put(1);
      await step();
      mmioAddr[0].put(MiniRISC4Constants.addrNocTxData); mmioWdata[0].put(0x7777);
      await step();
      mmioWe[0].put(0);
      for (var i = 0; i < 6; i++) {
        await step();
      }
      mmioAddr[3].put(MiniRISC4Constants.addrNocRxTryR);
      mmioRe[3].put(1);
      expect(top.output('mmioRdata_3').value.toInt(), equals(0x7777));
      await step();
      mmioRe[3].put(0);

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });
  });
}

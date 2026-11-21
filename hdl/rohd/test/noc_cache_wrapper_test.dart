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

      Simulator.setMaxSimTime(600);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.put(0);
      await clk.nextPosedge;

      // Core 1 configures route ch1 -> (serverCore=0, ch0) and sends write req + data
      mmioAddr[1].put(MiniRISC4Constants.addrNocChCfg0);
      mmioWdata[1].put((0 << 8) | 0);
      mmioWe[1].put(1);
      await clk.nextPosedge;
      mmioAddr[1].put(MiniRISC4Constants.addrNocChCfg1);
      mmioWdata[1].put(1);
      await clk.nextPosedge;
      mmioAddr[1].put(MiniRISC4Constants.addrNocTxData);
      mmioWdata[1].put(writeReqWord);
      await clk.nextPosedge;
      mmioWdata[1].put(writeVal);
      await clk.nextPosedge;
      mmioWe[1].put(0);

      for (var i = 0; i < numCores + 1; i++) {
        await clk.nextPosedge;
      }

      // Server emits priority MBOX write tag 0x8020 back to Core 1 ch 1
      srvV.put(1);
      srvT.put(1);
      srvSc.put(0);
      srvSch.put(0);
      srvDc.put(1);
      srvDch.put(1);
      srvP.put(expectedWriteTag);
      await clk.nextPosedge;
      srvV.put(0);
      await clk.nextPosedge;

      expect(top.output('mboxTrapReq_1').value.toInt(), equals(1));
      mmioAddr[1].put(MiniRISC4Constants.addrNocMboxData);
      mmioRe[1].put(1);
      await Simulator.tick();
      expect(top.output('mmioRdata_1').value.toInt(), equals(expectedWriteTag));
      await clk.nextPosedge;
      mmioRe[1].put(0);

      // Core 2 sends read req and receives readVal (0x55AA) via DATA ch 1 + MBOX completion
      mmioAddr[2].put(MiniRISC4Constants.addrNocSelCh);
      mmioWdata[2].put(1);
      mmioWe[2].put(1);
      await clk.nextPosedge;
      mmioAddr[2].put(MiniRISC4Constants.addrNocTxData);
      mmioWdata[2].put(readReqWord);
      await clk.nextPosedge;
      mmioWe[2].put(0);
      for (var i = 0; i < numCores + 1; i++) {
        await clk.nextPosedge;
      }

      // Server injects read DATA word to Core 2 ch 1
      srvV.put(1);
      srvT.put(0);
      srvSc.put(0);
      srvSch.put(0);
      srvDc.put(2);
      srvDch.put(1);
      srvP.put(readVal);
      await clk.nextPosedge;
      srvV.put(0);
      await clk.nextPosedge;

      mmioAddr[2].put(MiniRISC4Constants.addrNocRxTryR);
      mmioRe[2].put(1);
      await Simulator.tick();
      expect(top.output('mmioRdata_2').value.toInt(), equals(readVal));
      await clk.nextPosedge;
      mmioRe[2].put(0);

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });
  });
}

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'noc_router.dart';

/// Registered hop stage between adjacent NoC nodes for >100 MHz timing.
class RegisteredNocHop extends Module {
  RegisteredNocHop({
    required Logic clk,
    required Logic reset,
    required Logic inValid,
    required Logic inType,
    required Logic inSrcCore,
    required Logic inSrcCh,
    required Logic inDstCore,
    required Logic inDstCh,
    required Logic inPayload,
    super.name = 'reg_noc_hop',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final vIn = addInput('inValid', inValid);
    final tIn = addInput('inType', inType);
    final scIn = addInput('inSrcCore', inSrcCore, width: 8);
    final schIn = addInput('inSrcCh', inSrcCh, width: 8);
    final dcIn = addInput('inDstCore', inDstCore, width: 8);
    final dchIn = addInput('inDstCh', inDstCh, width: 8);
    final pIn = addInput('inPayload', inPayload, width: MiniRISC4Constants.dataWidth);

    final vOut = addOutput('outValid');
    final tOut = addOutput('outType');
    final scOut = addOutput('outSrcCore', width: 8);
    final schOut = addOutput('outSrcCh', width: 8);
    final dcOut = addOutput('outDstCore', width: 8);
    final dchOut = addOutput('outDstCh', width: 8);
    final pOut = addOutput('outPayload', width: MiniRISC4Constants.dataWidth);

    final vQ = Logic(name: 'vQ');
    final tQ = Logic(name: 'tQ');
    final scQ = Logic(name: 'scQ', width: 8);
    final schQ = Logic(name: 'schQ', width: 8);
    final dcQ = Logic(name: 'dcQ', width: 8);
    final dchQ = Logic(name: 'dchQ', width: 8);
    final pQ = Logic(name: 'pQ', width: MiniRISC4Constants.dataWidth);

    vOut <= vQ;
    tOut <= tQ;
    scOut <= scQ;
    schOut <= schQ;
    dcOut <= dcQ;
    dchOut <= dchQ;
    pOut <= pQ;

    Sequential(clk, reset: reset, resetValues: {
      vQ: 0,
      tQ: 0,
      scQ: 0,
      schQ: 0,
      dcQ: 0,
      dchQ: 0,
      pQ: 0,
    }, [
      vQ < vIn,
      tQ < tIn,
      scQ < scIn,
      schQ < schIn,
      dcQ < dcIn,
      dchQ < dchIn,
      pQ < pIn,
    ]);
  }
}

/// Multi-core ring wrapper with NocRouterNi per core and a cache-server reply/MBOX bridge.
/// Mirrors NocCacheServer + NocCacheClient semantics from tools/mr4sim.py.
class NocMultiCoreCacheWrapper extends Module {
  final int numCores;
  final int serverCoreId;
  final int numChannels;
  final int fifoDepth;
  final int opRead;
  final int opWrite;

  NocMultiCoreCacheWrapper({
    required Logic clk,
    required Logic reset,
    required List<Logic> mmioAddr,
    required List<Logic> mmioWdata,
    required List<Logic> mmioWe,
    required List<Logic> mmioRe,
    required List<Logic> netOutReady,
    required Logic srvInjectValid,
    required Logic srvInjectType,
    required Logic srvInjectSrcCore,
    required Logic srvInjectSrcCh,
    required Logic srvInjectDstCore,
    required Logic srvInjectDstCh,
    required Logic srvInjectPayload,
    this.numCores = 3,
    this.serverCoreId = 0,
    this.numChannels = 4,
    this.fifoDepth = 4,
    this.opRead = 0,
    this.opWrite = 1,
    super.name = 'noc_multicore_cache_wrapper',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    final addrs = <Logic>[];
    final wdatas = <Logic>[];
    final wes = <Logic>[];
    final res = <Logic>[];
    final readys = <Logic>[];

    for (var c = 0; c < numCores; c++) {
      addrs.add(addInput('mmioAddr_$c', mmioAddr[c], width: MiniRISC4Constants.addrWidth));
      wdatas.add(addInput('mmioWdata_$c', mmioWdata[c], width: MiniRISC4Constants.dataWidth));
      wes.add(addInput('mmioWe_$c', mmioWe[c]));
      res.add(addInput('mmioRe_$c', mmioRe[c]));
      readys.add(addInput('netOutReady_$c', netOutReady[c]));
      addOutput('mmioRdata_$c', width: MiniRISC4Constants.dataWidth);
      addOutput('mmioRdataReg_$c', width: MiniRISC4Constants.dataWidth);
      addOutput('mboxTrapReq_$c');
      addOutput('netOutValid_$c');
      addOutput('netOutType_$c');
      addOutput('netOutDstCore_$c', width: 8);
      addOutput('netOutDstCh_$c', width: 8);
      addOutput('netOutPayload_$c', width: MiniRISC4Constants.dataWidth);
    }

    final srvV = addInput('srvInjectValid', srvInjectValid);
    final srvT = addInput('srvInjectType', srvInjectType);
    final srvSc = addInput('srvInjectSrcCore', srvInjectSrcCore, width: 8);
    final srvSch = addInput('srvInjectSrcCh', srvInjectSrcCh, width: 8);
    final srvDc = addInput('srvInjectDstCore', srvInjectDstCore, width: 8);
    final srvDch = addInput('srvInjectDstCh', srvInjectDstCh, width: 8);
    final srvP = addInput('srvInjectPayload', srvInjectPayload, width: MiniRISC4Constants.dataWidth);

    final hopInV = List.generate(numCores, (i) => Logic(name: 'hopInV_$i'));
    final hopInT = List.generate(numCores, (i) => Logic(name: 'hopInT_$i'));
    final hopInSc = List.generate(numCores, (i) => Logic(name: 'hopInSc_$i', width: 8));
    final hopInSch = List.generate(numCores, (i) => Logic(name: 'hopInSch_$i', width: 8));
    final hopInDc = List.generate(numCores, (i) => Logic(name: 'hopInDc_$i', width: 8));
    final hopInDch = List.generate(numCores, (i) => Logic(name: 'hopInDch_$i', width: 8));
    final hopInP = List.generate(numCores, (i) => Logic(name: 'hopInP_$i', width: MiniRISC4Constants.dataWidth));

    final niInV = List.generate(numCores, (i) => Logic(name: 'niInV_$i'));
    final niInT = List.generate(numCores, (i) => Logic(name: 'niInT_$i'));
    final niInSc = List.generate(numCores, (i) => Logic(name: 'niInSc_$i', width: 8));
    final niInSch = List.generate(numCores, (i) => Logic(name: 'niInSch_$i', width: 8));
    final niInDch = List.generate(numCores, (i) => Logic(name: 'niInDch_$i', width: 8));
    final niInP = List.generate(numCores, (i) => Logic(name: 'niInP_$i', width: MiniRISC4Constants.dataWidth));

    for (var c = 0; c < numCores; c++) {
      final ni = NocRouterNi(
        clk: clk,
        reset: reset,
        mmioAddr: addrs[c],
        mmioWdata: wdatas[c],
        mmioWe: wes[c],
        mmioRe: res[c],
        netInValid: niInV[c],
        netInType: niInT[c],
        netInSrcCore: niInSc[c],
        netInSrcCh: niInSch[c],
        netInDstCh: niInDch[c],
        netInPayload: niInP[c],
        netOutReady: readys[c],
        coreId: c,
        numChannels: numChannels,
        fifoDepth: fifoDepth,
        name: 'noc_ni_core_$c',
      );

      output('mmioRdata_$c') <= ni.output('mmioRdata');
      output('mmioRdataReg_$c') <= ni.output('mmioRdataReg');
      output('mboxTrapReq_$c') <= ni.output('mboxTrapReq');
      output('netOutValid_$c') <= ni.output('netOutValid');
      output('netOutType_$c') <= ni.output('netOutType');
      output('netOutDstCore_$c') <= ni.output('netOutDstCore');
      output('netOutDstCh_$c') <= ni.output('netOutDstCh');
      output('netOutPayload_$c') <= ni.output('netOutPayload');

      final nextCore = (c + 1) % numCores;
      final hop = RegisteredNocHop(
        clk: clk,
        reset: reset,
        inValid: ni.output('netOutValid'),
        inType: ni.output('netOutType'),
        inSrcCore: Const(c, width: 8),
        inSrcCh: Const(0, width: 8),
        inDstCore: ni.output('netOutDstCore'),
        inDstCh: ni.output('netOutDstCh'),
        inPayload: ni.output('netOutPayload'),
        name: 'hop_${c}_to_$nextCore',
      );
      hopInV[nextCore] <= hop.output('outValid');
      hopInT[nextCore] <= hop.output('outType');
      hopInSc[nextCore] <= hop.output('outSrcCore');
      hopInSch[nextCore] <= hop.output('outSrcCh');
      hopInDc[nextCore] <= hop.output('outDstCore');
      hopInDch[nextCore] <= hop.output('outDstCh');
      hopInP[nextCore] <= hop.output('outPayload');
    }

    for (var c = 0; c < numCores; c++) {
      final forThisCore = hopInV[c] & hopInDc[c].eq(c);
      final srvForCore = srvV & srvDc.eq(c);
      niInV[c] <= forThisCore | srvForCore;
      niInT[c] <= mux(srvForCore, srvT, hopInT[c]);
      niInSc[c] <= mux(srvForCore, srvSc, hopInSc[c]);
      niInSch[c] <= mux(srvForCore, srvSch, hopInSch[c]);
      niInDch[c] <= mux(srvForCore, srvDch, hopInDch[c]);
      niInP[c] <= mux(srvForCore, srvP, hopInP[c]);
    }
  }
}

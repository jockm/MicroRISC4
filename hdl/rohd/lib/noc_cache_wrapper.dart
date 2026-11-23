import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'noc_router.dart';

/// 2-slot elastic registered hop stage (primary + skid buffer) between adjacent
/// NoC ring nodes. Both [outValid] and [inReady] are driven directly from
/// flip-flops, guaranteeing zero combinational loops around the ring, 1-cycle
/// per-hop latency, 1-packet/cycle line rate, and lossless backpressure at
/// >100 MHz. Optional lookahead route flags ([targetCoreId]/[numCores]) are
/// pre-decoded on entry to take destination comparisons off the next-hop path.
class RegisteredNocHop extends Module {
  static const int _packWidth =
      2 + 1 + 8 + 8 + 8 + 8 + MiniRISC4Constants.dataWidth;

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
    Logic? outReady,
    int? targetCoreId,
    int? numCores,
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
    final pIn =
        addInput('inPayload', inPayload, width: MiniRISC4Constants.dataWidth);
    final rOut = addInput('outReady', outReady ?? Const(1));

    final inReadyOut = addOutput('inReady');
    final vOut = addOutput('outValid');
    final tOut = addOutput('outType');
    final scOut = addOutput('outSrcCore', width: 8);
    final schOut = addOutput('outSrcCh', width: 8);
    final dcOut = addOutput('outDstCore', width: 8);
    final dchOut = addOutput('outDstCh', width: 8);
    final pOut =
        addOutput('outPayload', width: MiniRISC4Constants.dataWidth);
    final dstLocalOut = addOutput('outDstLocal');
    final dstInvalidOut = addOutput('outDstInvalid');

    final primaryValidQ = Logic(name: 'primaryValidQ');
    final primaryDataQ = Logic(name: 'primaryDataQ', width: _packWidth);
    final skidValidQ = Logic(name: 'skidValidQ');
    final skidDataQ = Logic(name: 'skidDataQ', width: _packWidth);

    final inDstLocal = targetCoreId != null
        ? dcIn.eq(Const(targetCoreId, width: 8))
        : Const(0);
    final inDstInvalid = numCores != null
        ? dcIn.gte(Const(numCores, width: 8))
        : Const(0);
    final inPack =
        [inDstInvalid, inDstLocal, tIn, scIn, schIn, dcIn, dchIn, pIn].swizzle();
    final inReady = ~skidValidQ;
    final inAccept = vIn & inReady;
    final outAccept = primaryValidQ & rOut;

    inReadyOut <= inReady;
    vOut <= primaryValidQ;
    dstInvalidOut <= primaryDataQ[50];
    dstLocalOut <= primaryDataQ[49];
    tOut <= primaryDataQ[48];
    scOut <= primaryDataQ.slice(47, 40);
    schOut <= primaryDataQ.slice(39, 32);
    dcOut <= primaryDataQ.slice(31, 24);
    dchOut <= primaryDataQ.slice(23, 16);
    pOut <= primaryDataQ.slice(15, 0);

    Sequential(clk, reset: reset, resetValues: {
      primaryValidQ: 0,
      primaryDataQ: 0,
      skidValidQ: 0,
      skidDataQ: 0,
    }, [
      If(outAccept, then: [
        If(skidValidQ, then: [
          primaryValidQ < 1,
          primaryDataQ < skidDataQ,
          skidValidQ < 0,
        ], orElse: [
          If(inAccept, then: [
            primaryValidQ < 1,
            primaryDataQ < inPack,
          ], orElse: [
            primaryValidQ < 0,
          ]),
        ]),
      ], orElse: [
        If(inAccept, then: [
          If(primaryValidQ, then: [
            skidValidQ < 1,
            skidDataQ < inPack,
          ], orElse: [
            primaryValidQ < 1,
            primaryDataQ < inPack,
          ]),
        ]),
      ]),
    ]);
  }
}

/// Multi-core ring wrapper with [NocRouterNi] per core, true multi-hop elastic
/// ring packet forwarding (transit-priority arbitration + lossless backpressure),
/// and an optional cache-server injection port mirroring `tools/mr4sim.py`.
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
    assert(numCores >= 1, 'numCores must be >= 1');
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    final addrs = <Logic>[];
    final wdatas = <Logic>[];
    final wes = <Logic>[];
    final res = <Logic>[];
    final readys = <Logic>[];

    for (var c = 0; c < numCores; c++) {
      addrs.add(addInput('mmioAddr_$c', mmioAddr[c],
          width: MiniRISC4Constants.addrWidth));
      wdatas.add(addInput('mmioWdata_$c', mmioWdata[c],
          width: MiniRISC4Constants.dataWidth));
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
      addOutput('netOutSrcCh_$c', width: 8);
      addOutput('netOutPayload_$c', width: MiniRISC4Constants.dataWidth);
    }

    final srvV = addInput('srvInjectValid', srvInjectValid);
    final srvT = addInput('srvInjectType', srvInjectType);
    final srvSc = addInput('srvInjectSrcCore', srvInjectSrcCore, width: 8);
    final srvSch = addInput('srvInjectSrcCh', srvInjectSrcCh, width: 8);
    final srvDc = addInput('srvInjectDstCore', srvInjectDstCore, width: 8);
    final srvDch = addInput('srvInjectDstCh', srvInjectDstCh, width: 8);
    final srvP = addInput('srvInjectPayload', srvInjectPayload,
        width: MiniRISC4Constants.dataWidth);

    // Ring signals arriving at node c from upstream hop (c - 1) -> c
    final hopInV = List.generate(numCores, (i) => Logic(name: 'hopInV_$i'));
    final hopInT = List.generate(numCores, (i) => Logic(name: 'hopInT_$i'));
    final hopInSc =
        List.generate(numCores, (i) => Logic(name: 'hopInSc_$i', width: 8));
    final hopInSch =
        List.generate(numCores, (i) => Logic(name: 'hopInSch_$i', width: 8));
    final hopInDc =
        List.generate(numCores, (i) => Logic(name: 'hopInDc_$i', width: 8));
    final hopInDch =
        List.generate(numCores, (i) => Logic(name: 'hopInDch_$i', width: 8));
    final hopInP = List.generate(
      numCores,
      (i) => Logic(name: 'hopInP_$i', width: MiniRISC4Constants.dataWidth),
    );
    final hopInReady =
        List.generate(numCores, (i) => Logic(name: 'hopInReady_$i'));
    final hopInDstLocal =
        List.generate(numCores, (i) => Logic(name: 'hopInDstLocal_$i'));
    final hopInDstInvalid =
        List.generate(numCores, (i) => Logic(name: 'hopInDstInvalid_$i'));

    // Ring signals leaving node c into downstream hop c -> (c + 1) % numCores
    final hopOutV = List.generate(numCores, (i) => Logic(name: 'hopOutV_$i'));
    final hopOutT = List.generate(numCores, (i) => Logic(name: 'hopOutT_$i'));
    final hopOutSc =
        List.generate(numCores, (i) => Logic(name: 'hopOutSc_$i', width: 8));
    final hopOutSch =
        List.generate(numCores, (i) => Logic(name: 'hopOutSch_$i', width: 8));
    final hopOutDc =
        List.generate(numCores, (i) => Logic(name: 'hopOutDc_$i', width: 8));
    final hopOutDch =
        List.generate(numCores, (i) => Logic(name: 'hopOutDch_$i', width: 8));
    final hopOutP = List.generate(
      numCores,
      (i) => Logic(name: 'hopOutP_$i', width: MiniRISC4Constants.dataWidth),
    );
    final hopOutReady =
        List.generate(numCores, (i) => Logic(name: 'hopOutReady_$i'));

    // Per-core NI local RX/TX handshake wires
    final niInV = List.generate(numCores, (i) => Logic(name: 'niInV_$i'));
    final niInT = List.generate(numCores, (i) => Logic(name: 'niInT_$i'));
    final niInSc =
        List.generate(numCores, (i) => Logic(name: 'niInSc_$i', width: 8));
    final niInSch =
        List.generate(numCores, (i) => Logic(name: 'niInSch_$i', width: 8));
    final niInDch =
        List.generate(numCores, (i) => Logic(name: 'niInDch_$i', width: 8));
    final niInP = List.generate(
      numCores,
      (i) => Logic(name: 'niInP_$i', width: MiniRISC4Constants.dataWidth),
    );
    final niOutReady =
        List.generate(numCores, (i) => Logic(name: 'niOutReady_$i'));

    final nis = <NocRouterNi>[];
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
        netOutReady: niOutReady[c],
        coreId: c,
        numCores: numCores,
        numChannels: numChannels,
        fifoDepth: fifoDepth,
        name: 'noc_ni_core_$c',
      );
      nis.add(ni);

      output('mmioRdata_$c') <= ni.output('mmioRdata');
      output('mmioRdataReg_$c') <= ni.output('mmioRdataReg');
      output('mboxTrapReq_$c') <= ni.output('mboxTrapReq');
      output('netOutValid_$c') <= ni.output('netOutValid');
      output('netOutType_$c') <= ni.output('netOutType');
      output('netOutDstCore_$c') <= ni.output('netOutDstCore');
      output('netOutDstCh_$c') <= ni.output('netOutDstCh');
      output('netOutSrcCh_$c') <= ni.output('netOutSrcCh');
      output('netOutPayload_$c') <= ni.output('netOutPayload');

      final nextCore = (c + 1) % numCores;
      final hop = RegisteredNocHop(
        clk: clk,
        reset: reset,
        inValid: hopOutV[c],
        inType: hopOutT[c],
        inSrcCore: hopOutSc[c],
        inSrcCh: hopOutSch[c],
        inDstCore: hopOutDc[c],
        inDstCh: hopOutDch[c],
        inPayload: hopOutP[c],
        outReady: hopInReady[nextCore],
        targetCoreId: nextCore,
        numCores: numCores,
        name: 'hop_${c}_to_$nextCore',
      );
      hopOutReady[c] <= hop.output('inReady');
      hopInV[nextCore] <= hop.output('outValid');
      hopInT[nextCore] <= hop.output('outType');
      hopInSc[nextCore] <= hop.output('outSrcCore');
      hopInSch[nextCore] <= hop.output('outSrcCh');
      hopInDc[nextCore] <= hop.output('outDstCore');
      hopInDch[nextCore] <= hop.output('outDstCh');
      hopInP[nextCore] <= hop.output('outPayload');
      hopInDstLocal[nextCore] <= hop.output('outDstLocal');
      hopInDstInvalid[nextCore] <= hop.output('outDstInvalid');
    }

    // Per-node ring stop: local ejection + transit-priority forwarding + local injection
    for (var c = 0; c < numCores; c++) {
      final ni = nis[c];
      final coreIdConst = Const(c, width: 8);
      final numCoresConst = Const(numCores, width: 8);

      final ringDstLocal = hopInDstLocal[c];
      final ringDstInvalid = hopInDstInvalid[c];
      final ringForLocal = hopInV[c] & ringDstLocal;
      final ringForForward = hopInV[c] & (~ringDstLocal) & (~ringDstInvalid);

      final srvForCore = srvV & srvDc.eq(coreIdConst);

      // Local NI RX mux (external server injection has priority; stalled ring
      // packets wait cleanly in the upstream RegisteredNocHop without loss).
      niInV[c] <= srvForCore | ringForLocal;
      niInT[c] <= mux(srvForCore, srvT, hopInT[c]);
      niInSc[c] <= mux(srvForCore, srvSc, hopInSc[c]);
      niInSch[c] <= mux(srvForCore, srvSch, hopInSch[c]);
      niInDch[c] <= mux(srvForCore, srvDch, hopInDch[c]);
      niInP[c] <= mux(srvForCore, srvP, hopInP[c]);

      // Outgoing ring hop arbitration: transit packets have strict priority
      // over new local injections to guarantee forward progress and fairness.
      final localOutV = ni.output('netOutValid');
      final localOutT = ni.output('netOutType');
      final localOutDc = ni.output('netOutDstCore');
      final localOutDch = ni.output('netOutDstCh');
      final localOutSch = ni.output('netOutSrcCh');
      final localOutP = ni.output('netOutPayload');
      final localDstValid = localOutDc.lt(numCoresConst);
      final localInjectV = localOutV & readys[c] & localDstValid;

      hopOutV[c] <= ringForForward | localInjectV;
      hopOutT[c] <= mux(ringForForward, hopInT[c], localOutT);
      hopOutSc[c] <= mux(ringForForward, hopInSc[c], coreIdConst);
      hopOutSch[c] <= mux(ringForForward, hopInSch[c], localOutSch);
      hopOutDc[c] <= mux(ringForForward, hopInDc[c], localOutDc);
      hopOutDch[c] <= mux(ringForForward, hopInDch[c], localOutDch);
      hopOutP[c] <= mux(ringForForward, hopInP[c], localOutP);

      // Local NI TX ready when external gate & downstream hop are ready and no
      // transit packet is claiming the outgoing hop this cycle.
      niOutReady[c] <= readys[c] & hopOutReady[c] & (~ringForForward);

      // Upstream hop ready:
      // - local ejection waits if server injects or local RX/MBOX FIFO is full
      // - transit forwarding waits if downstream hop skid buffer is full
      // - idle or invalid-destination packets drain immediately
      hopInReady[c] <= mux(
        ringForLocal,
        (~srvForCore) & ni.output('netInReady'),
        mux(ringForForward, hopOutReady[c], Const(1)),
      );
    }
  }
}

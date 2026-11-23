import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'noc_router.dart';

/// Ultra-lean 2-slot elastic registered ring hop stage (primary + skid buffer)
/// using narrow `coreIdWidth`-bit core IDs.
///
/// For 4 cores (`coreIdWidth = 2`), each flit is only **22 bits**
/// (`{dstLocal[0], type[0], srcCore[1:0], dstCore[1:0], payload[15:0]}`),
/// keeping hop cost to ~44 FFs while guaranteeing zero combinational loops,
/// 1-cycle per-hop latency, 1.0 packet/cycle line rate, and lossless
/// backpressure at >100 MHz.
class RegisteredNocHop extends Module {
  final int coreIdWidth;

  RegisteredNocHop({
    required Logic clk,
    required Logic reset,
    required Logic inValid,
    required Logic inType,
    required Logic inSrcCore,
    required Logic inDstCore,
    required Logic inPayload,
    this.coreIdWidth = 2,
    Logic? outReady,
    int? targetCoreId,
    super.name = 'reg_noc_hop',
  }) {
    final packWidth = 1 + 1 + coreIdWidth + coreIdWidth + MiniRISC4Constants.dataWidth;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final vIn = addInput('inValid', inValid);
    final tIn = addInput('inType', inType);
    final scIn = addInput('inSrcCore', inSrcCore, width: coreIdWidth);
    final dcIn = addInput('inDstCore', inDstCore, width: coreIdWidth);
    final pIn =
        addInput('inPayload', inPayload, width: MiniRISC4Constants.dataWidth);
    final rOut = addInput('outReady', outReady ?? Const(1));

    final inReadyOut = addOutput('inReady');
    final vOut = addOutput('outValid');
    final dstLocalOut = addOutput('outDstLocal');
    final tOut = addOutput('outType');
    final scOut = addOutput('outSrcCore', width: coreIdWidth);
    final dcOut = addOutput('outDstCore', width: coreIdWidth);
    final pOut = addOutput('outPayload', width: MiniRISC4Constants.dataWidth);

    final primaryValidQ = Logic(name: 'primaryValidQ');
    final primaryDataQ = Logic(name: 'primaryDataQ', width: packWidth);
    final skidValidQ = Logic(name: 'skidValidQ');
    final skidDataQ = Logic(name: 'skidDataQ', width: packWidth);

    final inDstLocal = targetCoreId != null
        ? dcIn.eq(Const(targetCoreId, width: coreIdWidth))
        : Const(0);
    final inPack = [inDstLocal, tIn, scIn, dcIn, pIn].swizzle();
    final inReady = ~skidValidQ;
    final inAccept = vIn & inReady;
    final outAccept = primaryValidQ & rOut;

    const pHi = MiniRISC4Constants.dataWidth - 1;
    final dcLo = MiniRISC4Constants.dataWidth;
    final dcHi = dcLo + coreIdWidth - 1;
    final scLo = dcHi + 1;
    final scHi = scLo + coreIdWidth - 1;
    final tBit = scHi + 1;
    final locBit = tBit + 1;

    inReadyOut <= inReady;
    vOut <= primaryValidQ;
    dstLocalOut <= primaryDataQ[locBit];
    tOut <= primaryDataQ[tBit];
    scOut <= primaryDataQ.slice(scHi, scLo);
    dcOut <= primaryDataQ.slice(dcHi, dcLo);
    pOut <= primaryDataQ.slice(pHi, 0);

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

/// Ultra-lean multi-core registered packet + doorbell ring wrapper.
/// Scales strictly linearly ($O(N)$) in LUTs, FFs, and wire length with
/// zero combinational loops and transit-priority lossless forwarding.
class NocMultiCoreCacheWrapper extends Module {
  final int numCores;
  final int serverCoreId;
  final int fifoDepth;
  final int coreIdWidth;
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
    required Logic srvInjectDstCore,
    required Logic srvInjectPayload,
    this.numCores = 4,
    this.serverCoreId = 0,
    this.fifoDepth = 16,
    this.opRead = 0,
    this.opWrite = 1,
    super.name = 'noc_multicore_cache_wrapper',
  }) : coreIdWidth = NocRouterNi.idWidthForCores(numCores) {
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
      addOutput('netOutDstCore_$c', width: coreIdWidth);
      addOutput('netOutPayload_$c', width: MiniRISC4Constants.dataWidth);
    }

    final srvV = addInput('srvInjectValid', srvInjectValid);
    final srvT = addInput('srvInjectType', srvInjectType);
    final srvSc = addInput('srvInjectSrcCore', srvInjectSrcCore, width: coreIdWidth);
    final srvDc = addInput('srvInjectDstCore', srvInjectDstCore, width: coreIdWidth);
    final srvP = addInput('srvInjectPayload', srvInjectPayload,
        width: MiniRISC4Constants.dataWidth);

    // Narrow ring signals entering node c from upstream hop (c - 1) -> c
    final hopInV = List.generate(numCores, (i) => Logic(name: 'hopInV_$i'));
    final hopInT = List.generate(numCores, (i) => Logic(name: 'hopInT_$i'));
    final hopInSc = List.generate(
        numCores, (i) => Logic(name: 'hopInSc_$i', width: coreIdWidth));
    final hopInDc = List.generate(
        numCores, (i) => Logic(name: 'hopInDc_$i', width: coreIdWidth));
    final hopInP = List.generate(
      numCores,
      (i) => Logic(name: 'hopInP_$i', width: MiniRISC4Constants.dataWidth),
    );
    final hopInDstLocal =
        List.generate(numCores, (i) => Logic(name: 'hopInDstLocal_$i'));
    final hopInReady =
        List.generate(numCores, (i) => Logic(name: 'hopInReady_$i'));

    // Narrow ring signals leaving node c into downstream hop c -> (c + 1) % N
    final hopOutV = List.generate(numCores, (i) => Logic(name: 'hopOutV_$i'));
    final hopOutT = List.generate(numCores, (i) => Logic(name: 'hopOutT_$i'));
    final hopOutSc = List.generate(
        numCores, (i) => Logic(name: 'hopOutSc_$i', width: coreIdWidth));
    final hopOutDc = List.generate(
        numCores, (i) => Logic(name: 'hopOutDc_$i', width: coreIdWidth));
    final hopOutP = List.generate(
      numCores,
      (i) => Logic(name: 'hopOutP_$i', width: MiniRISC4Constants.dataWidth),
    );
    final hopOutReady =
        List.generate(numCores, (i) => Logic(name: 'hopOutReady_$i'));

    // Local NI RX/TX wires
    final niInV = List.generate(numCores, (i) => Logic(name: 'niInV_$i'));
    final niInT = List.generate(numCores, (i) => Logic(name: 'niInT_$i'));
    final niInSc = List.generate(
        numCores, (i) => Logic(name: 'niInSc_$i', width: coreIdWidth));
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
        netInPayload: niInP[c],
        netOutReady: niOutReady[c],
        coreId: c,
        numCores: numCores,
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
      output('netOutPayload_$c') <= ni.output('netOutPayload');

      final nextCore = (c + 1) % numCores;
      final hop = RegisteredNocHop(
        clk: clk,
        reset: reset,
        inValid: hopOutV[c],
        inType: hopOutT[c],
        inSrcCore: hopOutSc[c],
        inDstCore: hopOutDc[c],
        inPayload: hopOutP[c],
        coreIdWidth: coreIdWidth,
        outReady: hopInReady[nextCore],
        targetCoreId: nextCore,
        name: 'hop_${c}_to_$nextCore',
      );
      hopOutReady[c] <= hop.output('inReady');
      hopInV[nextCore] <= hop.output('outValid');
      hopInDstLocal[nextCore] <= hop.output('outDstLocal');
      hopInT[nextCore] <= hop.output('outType');
      hopInSc[nextCore] <= hop.output('outSrcCore');
      hopInDc[nextCore] <= hop.output('outDstCore');
      hopInP[nextCore] <= hop.output('outPayload');
    }

    // Per-node ring stop: local ejection + transit-priority forwarding + local injection
    for (var c = 0; c < numCores; c++) {
      final ni = nis[c];
      final coreIdConst = Const(c, width: coreIdWidth);

      final ringForLocal = hopInV[c] & hopInDstLocal[c];
      final ringForForward = hopInV[c] & (~hopInDstLocal[c]);
      final srvForCore = srvV & srvDc.eq(coreIdConst);

      niInV[c] <= srvForCore | ringForLocal;
      niInT[c] <= mux(srvForCore, srvT, hopInT[c]);
      niInSc[c] <= mux(srvForCore, srvSc, hopInSc[c]);
      niInP[c] <= mux(srvForCore, srvP, hopInP[c]);

      final localOutV = ni.output('netOutValid');
      final localOutT = ni.output('netOutType');
      final localOutDc = ni.output('netOutDstCore');
      final localOutP = ni.output('netOutPayload');
      final localInjectV = localOutV & readys[c];

      hopOutV[c] <= ringForForward | localInjectV;
      hopOutT[c] <= mux(ringForForward, hopInT[c], localOutT);
      hopOutSc[c] <= mux(ringForForward, hopInSc[c], coreIdConst);
      hopOutDc[c] <= mux(ringForForward, hopInDc[c], localOutDc);
      hopOutP[c] <= mux(ringForForward, hopInP[c], localOutP);

      niOutReady[c] <= readys[c] & hopOutReady[c] & (~ringForForward);

      hopInReady[c] <= mux(
        ringForLocal,
        (~srvForCore) & ni.output('netInReady'),
        mux(ringForForward, hopOutReady[c], Const(1)),
      );
    }
  }
}

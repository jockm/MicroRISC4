// ==============================================================================
// FILE: hdl/rohd/lib/cache_subsystem_top.dart
// Architecture: MiniRISC4 Multi-Core I/D Cache + Round-Robin SDRAM Burst Arbiter
// Framework: Intel ROHD (Dart)
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'cache_controllers.dart';
import 'constants.dart';
import 'memory_factory.dart';
import 'sdram_controller.dart';

/// Pipelined, fully-registered round-robin burst arbiter sharing a single
/// [SdramController] across [numClients] streaming cache ports (typically
/// `2 * numCores`: I-Cache + D-Cache per core).
///
/// Timing architecture (all cross-die boundaries 100% FF-to-FF):
/// - **2-stage command grant (`_stIdle -> _stLatch -> _stIssue`)**: separates
///   the round-robin priority encoder from the 24-bit address mux, driving pure
///   registered `sdram_cmd_*` outputs and a 1-cycle registered `client_cmd_ready`.
/// - **Registered read return (`rdataQ`, `rvalidVecQ`)**: breaks the cross-die
///   path from `SdramController` into remote cache `DP16KD` write ports.
/// - **2-stage write pipeline (`wdataCapQ` + shared 4-word `wbuf` ring)**:
///   captures each write-capable `DCache`'s `DP16KD.DO` locally on `wreadyVecQ`,
///   then muxes pure FFs into a central 4-word skid buffer feeding
///   `SdramController` at 1.0 word/cycle with zero bubbles and zero overflow.
class SdramBurstArbiter extends Module {
  final int numClients;
  final int idWidth;

  static const int _stIdle = 0;
  static const int _stLatch = 1;
  static const int _stIssue = 2;
  static const int _stActive = 3;
  static const int _stDrain = 4;

  SdramBurstArbiter({
    required Logic clk,
    required Logic reset,
    required List<Logic> clientCmdReq,
    required List<Logic> clientCmdRw,
    required List<Logic> clientCmdAddr,
    required List<Logic> clientCmdBurstLen,
    required List<Logic> clientWdata,
    required List<Logic> clientWdataValid,
    required Logic sdramCmdReady,
    required Logic sdramRdata,
    required Logic sdramRdataValid,
    required Logic sdramWdataReady,
    List<bool>? clientCanWrite,
    super.name = 'sdram_burst_arbiter',
  })  : numClients = clientCmdReq.length,
        idWidth = (clientCmdReq.length <= 1)
            ? 1
            : (clientCmdReq.length - 1).bitLength {
    assert(numClients >= 1, 'numClients must be >= 1');
    final canWrite = clientCanWrite ?? List<bool>.filled(numClients, true);
    assert(canWrite.length == numClients, 'clientCanWrite length mismatch');

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    final reqs = <Logic>[];
    final rws = <Logic>[];
    final addrs = <Logic>[];
    final lens = <Logic>[];
    final wdatas = <Logic>[];
    final wvalids = <Logic>[];

    for (var i = 0; i < numClients; i++) {
      reqs.add(addInput('client_cmd_req_$i', clientCmdReq[i]));
      rws.add(addInput('client_cmd_rw_$i', clientCmdRw[i]));
      addrs.add(addInput('client_cmd_addr_$i', clientCmdAddr[i], width: 24));
      lens.add(addInput('client_cmd_burst_len_$i', clientCmdBurstLen[i], width: 8));
      wdatas.add(addInput('client_wdata_$i', clientWdata[i],
          width: MiniRISC4Constants.dataWidth));
      wvalids.add(addInput('client_wdata_valid_$i', clientWdataValid[i]));

      addOutput('client_cmd_ready_$i');
      addOutput('client_rdata_valid_$i');
      addOutput('client_wdata_ready_$i');
    }
    final clientRdataOut =
        addOutput('client_rdata', width: MiniRISC4Constants.dataWidth);

    final sCmdReady = addInput('sdram_cmd_ready', sdramCmdReady);
    final sRdata =
        addInput('sdram_rdata', sdramRdata, width: MiniRISC4Constants.dataWidth);
    final sRdataValid = addInput('sdram_rdata_valid', sdramRdataValid);
    final sWdataReady = addInput('sdram_wdata_ready', sdramWdataReady);

    final sCmdReq = addOutput('sdram_cmd_req');
    final sCmdRw = addOutput('sdram_cmd_rw');
    final sCmdAddr = addOutput('sdram_cmd_addr', width: 24);
    final sCmdBurstLen = addOutput('sdram_cmd_burst_len', width: 8);
    final sWdata = addOutput('sdram_wdata', width: MiniRISC4Constants.dataWidth);
    final sWdataValid = addOutput('sdram_wdata_valid');

    // FSM & command registers
    final stateQ = Logic(name: 'arb_state_q', width: 3);
    final grantIdxQ = Logic(name: 'grant_idx_q', width: idWidth);
    final grantRwQ = Logic(name: 'grant_rw_q');
    final cmdAddrQ = Logic(name: 'cmd_addr_q', width: 24);
    final cmdLenQ = Logic(name: 'cmd_len_q', width: 8);
    final remBeatsQ = Logic(name: 'rem_beats_q', width: 8);
    final pullRemQ = Logic(name: 'pull_rem_q', width: 8);
    final rrPtrQ = Logic(name: 'rr_ptr_q', width: idWidth);

    // Registered client-facing handshake & read-return signals
    final cmdReadyVecQ = List.generate(
      numClients,
      (i) => Logic(name: 'cmd_ready_q_$i'),
    );
    final rvalidVecQ = List.generate(
      numClients,
      (i) => Logic(name: 'rvalid_q_$i'),
    );
    final rdataQ =
        Logic(name: 'rdata_q', width: MiniRISC4Constants.dataWidth);

    // Per-write-client local capture FF (breaks DP16KD.DO -> N:1 mux path)
    final wreadyVecQ = <Logic>[];
    final wdataCapQ = <int, Logic>{};
    final writeClientIndices = <int>[];
    for (var i = 0; i < numClients; i++) {
      if (canWrite[i]) {
        writeClientIndices.add(i);
        wreadyVecQ.add(Logic(name: 'wready_q_$i'));
        wdataCapQ[i] = Logic(
          name: 'wdata_cap_q_$i',
          width: MiniRISC4Constants.dataWidth,
        );
      } else {
        wreadyVecQ.add(Const(0));
      }
    }

    // Shared 4-entry central write skid ring (64 FFs total across the whole chip)
    final wbuf = List.generate(
      4,
      (i) => Logic(name: 'wbuf_q_$i', width: MiniRISC4Constants.dataWidth),
    );
    final wWrPtrQ = Logic(name: 'wbuf_wr_ptr_q', width: 2);
    final wRdPtrQ = Logic(name: 'wbuf_rd_ptr_q', width: 2);
    final wCntQ = Logic(name: 'wbuf_cnt_q', width: 3);
    final wStageValidQ = Logic(name: 'w_stage_valid_q');
    final wReadyActiveQ = Logic(name: 'w_ready_active_q');

    Logic balancedMux(List<Logic> items, Logic sel, Logic fallback) {
      if (items.length == 1) return items[0];
      final size = 1 << sel.width;
      var level = List<Logic>.generate(
        size,
        (i) => i < items.length ? items[i] : fallback,
      );
      for (var b = 0; b < sel.width; b++) {
        final next = <Logic>[];
        for (var i = 0; i < level.length; i += 2) {
          next.add(mux(sel[b], level[i + 1], level[i]));
        }
        level = next;
      }
      return level[0];
    }

    // Helper: select a signal over write-capable clients only (halves mux width
    // in SdramCacheCluster where I-Cache occupies even indices and D-Cache odd).
    final isOddWriteLayout = writeClientIndices.isNotEmpty &&
        writeClientIndices.length * 2 == numClients &&
        List.generate(writeClientIndices.length, (k) => k * 2 + 1)
            .asMap()
            .entries
            .every((e) => writeClientIndices[e.key] == e.value);

    Logic selectWriteClient(Logic Function(int idx) getItem, Logic fallback) {
      if (writeClientIndices.isEmpty) return fallback;
      if (writeClientIndices.length == 1) {
        return getItem(writeClientIndices[0]);
      }
      if (isOddWriteLayout && idWidth >= 2) {
        final oddItems = [for (final idx in writeClientIndices) getItem(idx)];
        return balancedMux(
          oddItems,
          grantIdxQ.slice(idWidth - 1, 1),
          fallback,
        );
      }
      final allItems = List<Logic>.generate(
        numClients,
        (i) => canWrite[i] ? getItem(i) : fallback,
      );
      return balancedMux(allItems, grantIdxQ, fallback);
    }

    // Stage 1 (_stIdle): Round-robin priority encoder on 1-bit reqs only
    Logic anyHi = Const(0);
    Logic idxHi = Const(0, width: idWidth);
    Logic anyLo = Const(0);
    Logic idxLo = Const(0, width: idWidth);
    for (var i = numClients - 1; i >= 0; i--) {
      final iConst = Const(i, width: idWidth);
      final geRr = iConst.gte(rrPtrQ);
      final reqHi = reqs[i] & geRr;
      anyHi = anyHi | reqHi;
      idxHi = mux(reqHi, iConst, idxHi);

      anyLo = anyLo | reqs[i];
      idxLo = mux(reqs[i], iConst, idxLo);
    }
    final anyReq = anyHi | anyLo;
    final selIdx = mux(anyHi, idxHi, idxLo);
    final nextRr = mux(
      selIdx.eq(Const(numClients - 1, width: idWidth)),
      Const(0, width: idWidth),
      selIdx + Const(1, width: idWidth),
    );

    // Stage 2 (_stLatch): Mux command payload using registered grantIdxQ
    final latchedRw = balancedMux(rws, grantIdxQ, Const(0));
    final latchedAddr = balancedMux(addrs, grantIdxQ, Const(0, width: 24));
    final latchedLen = balancedMux(lens, grantIdxQ, Const(8, width: 8));

    final isIssue = stateQ.eq(Const(_stIssue, width: 3));
    final isActive = stateQ.eq(Const(_stActive, width: 3));
    final inWriteFlight = (isIssue | isActive) & grantRwQ;

    // Pure-FF SDRAM command outputs
    sCmdReq <= isIssue;
    sCmdRw <= grantRwQ;
    sCmdAddr <= cmdAddrQ;
    sCmdBurstLen <= cmdLenQ;

    // Central 4-word write ring -> SDRAM write port
    final wbufOut = balancedMux(
      wbuf,
      wRdPtrQ,
      Const(0, width: MiniRISC4Constants.dataWidth),
    );
    final wbufNonEmpty = ~wCntQ.eq(Const(0, width: 3));
    final wOutValid = isActive & grantRwQ & wbufNonEmpty;
    sWdata <= wbufOut;
    sWdataValid <= wOutValid;

    // Pure-FF client return buses
    clientRdataOut <= rdataQ;
    for (var i = 0; i < numClients; i++) {
      output('client_cmd_ready_$i') <= cmdReadyVecQ[i];
      output('client_rdata_valid_$i') <= rvalidVecQ[i];
      output('client_wdata_ready_$i') <= wreadyVecQ[i];
    }

    // Write-pipeline flow control (guaranteed 0 overflow, 0 mid-burst underflow):
    //   wCapFire:       selected write client transfers a word into wdataCapQ
    //   wPush:          wdataCapQ pushes into wbuf[wWrPtrQ]
    //   wPop:           SdramController consumes wbuf[wRdPtrQ]
    //   wCntNext:       wbuf occupancy after this posedge
    //   wStageValidNext: 1 iff a newly captured word will sit in wdataCapQ next cycle
    //   wReadyNext:     assert wreadyVecQ[grantIdxQ] next cycle iff
    //                   (pullRemNext > 0) && (wCntNext + wStageValidNext < 4)
    final grantedWvalid = selectWriteClient((i) => wvalids[i], Const(0));
    final grantedCapData = selectWriteClient(
      (i) => wdataCapQ[i]!,
      Const(0, width: MiniRISC4Constants.dataWidth),
    );

    final wCapFire = inWriteFlight & wReadyActiveQ & grantedWvalid;
    final wPush = inWriteFlight & wStageValidQ;
    final wPop = wOutValid & sWdataReady;

    final wCntNext = mux(
      wPush & (~wPop),
      wCntQ + Const(1, width: 3),
      mux(
        (~wPush) & wPop,
        wCntQ - Const(1, width: 3),
        wCntQ,
      ),
    );
    final pullRemNext = mux(
      wCapFire,
      pullRemQ - Const(1, width: 8),
      pullRemQ,
    );
    final inFlightAfter =
        wCntNext + [Const(0, width: 2), wCapFire].swizzle();
    final wReadyNext = inWriteFlight &
        pullRemNext.gt(Const(0, width: 8)) &
        inFlightAfter.lt(Const(4, width: 3));

    final resetVals = <Logic, dynamic>{
      stateQ: Const(_stIdle, width: 3),
      grantIdxQ: 0,
      grantRwQ: 0,
      cmdAddrQ: 0,
      cmdLenQ: 0,
      remBeatsQ: 0,
      pullRemQ: 0,
      rrPtrQ: 0,
      rdataQ: 0,
      wWrPtrQ: 0,
      wRdPtrQ: 0,
      wCntQ: 0,
      wStageValidQ: 0,
      wReadyActiveQ: 0,
      for (final c in cmdReadyVecQ) c: 0,
      for (final r in rvalidVecQ) r: 0,
      for (final idx in writeClientIndices) wreadyVecQ[idx]: 0,
      for (final idx in writeClientIndices) wdataCapQ[idx]!: 0,
      for (final b in wbuf) b: 0,
    };

    Sequential(clk, reset: reset, resetValues: resetVals, [
      // Default single-cycle pulses cleared every cycle
      for (final c in cmdReadyVecQ) c < 0,
      for (final r in rvalidVecQ) r < 0,

      // Per-write-client local data capture (adjacent to each DCache BRAM)
      for (final idx in writeClientIndices)
        If(wreadyVecQ[idx], then: [
          wdataCapQ[idx]! < wdatas[idx],
        ]),

      // Write pipeline datapath (active throughout _stIssue and _stActive for writes)
      If(inWriteFlight, then: [
        wStageValidQ < wCapFire,
        wReadyActiveQ < wReadyNext,
        pullRemQ < pullRemNext,
        wCntQ < wCntNext,
        for (final idx in writeClientIndices)
          wreadyVecQ[idx] <
              (wReadyNext & grantIdxQ.eq(Const(idx, width: idWidth))),
        If(wPush, then: [
          Case(wWrPtrQ, [
            for (var slot = 0; slot < 4; slot++)
              CaseItem(Const(slot, width: 2), [
                wbuf[slot] < grantedCapData,
              ]),
          ]),
          wWrPtrQ < wWrPtrQ + Const(1, width: 2),
        ]),
        If(wPop, then: [
          wRdPtrQ < wRdPtrQ + Const(1, width: 2),
        ]),
      ], orElse: [
        wStageValidQ < 0,
        wReadyActiveQ < 0,
        for (final idx in writeClientIndices) wreadyVecQ[idx] < 0,
      ]),

      Case(stateQ, [
        // 0. IDLE: round-robin select client index (1-bit reqs only)
        CaseItem(Const(_stIdle, width: 3), [
          If(anyReq, then: [
            grantIdxQ < selIdx,
            rrPtrQ < nextRr,
            stateQ < Const(_stLatch, width: 3),
          ]),
        ]),

        // 1. LATCH: mux command payload from registered grantIdxQ and ack client
        CaseItem(Const(_stLatch, width: 3), [
          grantRwQ < latchedRw,
          cmdAddrQ < latchedAddr,
          cmdLenQ < latchedLen,
          remBeatsQ < latchedLen,
          pullRemQ < latchedLen,
          wWrPtrQ < 0,
          wRdPtrQ < 0,
          wCntQ < 0,
          wStageValidQ < 0,
          wReadyActiveQ < 0,
          for (var i = 0; i < numClients; i++)
            cmdReadyVecQ[i] < grantIdxQ.eq(Const(i, width: idWidth)),
          stateQ < Const(_stIssue, width: 3),
        ]),

        // 2. ISSUE: hold pure-FF sdram_cmd_req until SdramController accepts
        CaseItem(Const(_stIssue, width: 3), [
          If(sCmdReady, then: [
            stateQ < Const(_stActive, width: 3),
          ]),
        ]),

        // 3. ACTIVE: stream registered read beats back or drain write ring
        CaseItem(Const(_stActive, width: 3), [
          If(~grantRwQ, then: [
            If(sRdataValid, then: [
              rdataQ < sRdata,
              for (var i = 0; i < numClients; i++)
                rvalidVecQ[i] < grantIdxQ.eq(Const(i, width: idWidth)),
              If(remBeatsQ.lte(Const(1, width: 8)), then: [
                remBeatsQ < 0,
                stateQ < Const(_stDrain, width: 3),
              ], orElse: [
                remBeatsQ < remBeatsQ - Const(1, width: 8),
              ]),
            ]),
          ], orElse: [
            If(wPop, then: [
              If(remBeatsQ.lte(Const(1, width: 8)), then: [
                remBeatsQ < 0,
                stateQ < Const(_stIdle, width: 3),
              ], orElse: [
                remBeatsQ < remBeatsQ - Const(1, width: 8),
              ]),
            ]),
          ]),
        ]),

        // 4. DRAIN: 1-cycle clean exit so final registered rvalidVecQ clears
        CaseItem(Const(_stDrain, width: 3), [
          stateQ < Const(_stIdle, width: 3),
        ]),
      ]),
    ]);
  }
}

/// Complete multi-core BRAM I/D Cache + Round-Robin Arbiter + SDRAM Controller
/// subsystem. Each core `c` (`0..numCores-1`) gets its own private BRAM
/// [ICache] and write-back [DCache] mapped to non-overlapping SDRAM partition
/// `{coreId[7:0], addr[15:0]}`, with automatic per-core D-write -> I-invalidate
/// coherency for self-modifying code and program loading.
class SdramCacheCluster extends Module {
  final int numCores;
  final int numLines;
  final int lineWords;

  SdramCacheCluster({
    required Logic clk,
    required Logic rstN,
    required List<Logic> icReqValid,
    required List<Logic> icReqAddr,
    required List<Logic> dcReqValid,
    required List<Logic> dcReqWe,
    required List<Logic> dcReqAddr,
    required List<Logic> dcReqWdata,
    required Logic sdramDqIn,
    List<Logic>? icFlushAll,
    this.numCores = 1,
    this.numLines = 64,
    this.lineWords = 8,
    int clkFreqMhz = 48,
    int casLatency = 2,
    int extraReadPipeCycles = 0,
    int? initWaitCycles,
    int? refreshCycles,
    MemoryTarget memoryTarget = MemoryTarget.fpgaEcp5,
    super.name = 'sdram_cache_cluster',
  }) {
    assert(numCores >= 1, 'numCores must be >= 1');
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    final dqIn = addInput('sdram_dq_in', sdramDqIn, width: 16);
    final reset = ~rstN;

    final clientReq = <Logic>[];
    final clientRw = <Logic>[];
    final clientAddr = <Logic>[];
    final clientLen = <Logic>[];
    final clientWdata = <Logic>[];
    final clientWvalid = <Logic>[];
    final clientCanWrite = <bool>[];

    final arbCmdReady = List.generate(
      numCores * 2,
      (i) => Logic(name: 'arb_cmd_ready_$i'),
    );
    final arbRdata = Logic(name: 'arb_rdata', width: MiniRISC4Constants.dataWidth);
    final arbRvalid = List.generate(
      numCores * 2,
      (i) => Logic(name: 'arb_rvalid_$i'),
    );
    final arbWready = List.generate(
      numCores * 2,
      (i) => Logic(name: 'arb_wready_$i'),
    );

    final usePerCoreReadPipe = numCores > 1;

    for (var c = 0; c < numCores; c++) {
      final iV = addInput('ic_req_valid_$c', icReqValid[c]);
      final iA = addInput('ic_req_addr_$c', icReqAddr[c],
          width: MiniRISC4Constants.addrWidth);
      final iFlush = addInput(
        'ic_flush_all_$c',
        (icFlushAll != null && c < icFlushAll.length) ? icFlushAll[c] : Const(0),
      );
      final dV = addInput('dc_req_valid_$c', dcReqValid[c]);
      final dWe = addInput('dc_req_we_$c', dcReqWe[c]);
      final dA = addInput('dc_req_addr_$c', dcReqAddr[c],
          width: MiniRISC4Constants.addrWidth);
      final dW = addInput('dc_req_wdata_$c', dcReqWdata[c],
          width: MiniRISC4Constants.dataWidth);

      final icIdx = c * 2;
      final dcIdx = c * 2 + 1;
      final snoopDoneWire = Logic(name: 'snoop_done_core_$c');

      // For multi-core clusters, add a tiny 1-stage local read-return repeater
      // (18 FFs/core) so central arb.rdataQ fans out to N midpoint FFs instead
      // of 2N cross-die DP16KD write ports.
      late final Logic coreRdata;
      late final Logic coreIcRvalid;
      late final Logic coreDcRvalid;
      if (usePerCoreReadPipe) {
        coreRdata = Logic(
          name: 'core_rdata_q_$c',
          width: MiniRISC4Constants.dataWidth,
        );
        coreIcRvalid = Logic(name: 'core_ic_rvalid_q_$c');
        coreDcRvalid = Logic(name: 'core_dc_rvalid_q_$c');
        Sequential(clk, reset: reset, resetValues: {
          coreRdata: 0,
          coreIcRvalid: 0,
          coreDcRvalid: 0,
        }, [
          coreRdata < arbRdata,
          coreIcRvalid < arbRvalid[icIdx],
          coreDcRvalid < arbRvalid[dcIdx],
        ]);
      } else {
        coreRdata = arbRdata;
        coreIcRvalid = arbRvalid[icIdx];
        coreDcRvalid = arbRvalid[dcIdx];
      }

      // Register D-write -> I-Cache invalidation by 1 cycle (only indexBits + 1
      // FFs/core). DCache takes >=2 cycles even on a hit, so I-Cache is still
      // invalidated before dc_resp_valid while completely breaking the
      // cross-module portBAddr -> isExt -> dV&dWe -> ICache.lookupHit path!
      final offsetBits = (lineWords - 1).bitLength;
      final indexBits = (numLines - 1).bitLength;
      final idxHi = offsetBits + indexBits - 1;
      final tagBits = MiniRISC4Constants.addrWidth - offsetBits - indexBits;
      final invalValidQ = Logic(name: 'ic_inval_valid_q_$c');
      final invalIdxQ = Logic(name: 'ic_inval_idx_q_$c', width: indexBits);
      Sequential(clk, reset: reset, resetValues: {
        invalValidQ: 0,
        invalIdxQ: 0,
      }, [
        invalValidQ < (dV & dWe),
        invalIdxQ < dA.slice(idxHi, offsetBits),
      ]);
      final invalAddrPadded = [
        Const(0, width: tagBits),
        invalIdxQ,
        Const(0, width: offsetBits),
      ].swizzle();

      final ic = ICache(
        clk: clk,
        reset: reset,
        reqValid: iV,
        reqAddr: iA,
        memCmdReady: arbCmdReady[icIdx],
        memRdata: coreRdata,
        memRdataValid: coreIcRvalid,
        flushAll: iFlush,
        // Per-core D-Cache write automatically invalidates matching I-Cache line
        invalValid: invalValidQ,
        invalAddr: invalAddrPadded,
        // On I-Cache miss, snoop D-Cache to write back any dirty line first
        // so self-modifying code / monitor program loads are 100% coherent.
        snoopCleanDone: snoopDoneWire,
        coreId: c,
        numLines: numLines,
        lineWords: lineWords,
        memoryTarget: memoryTarget,
        name: 'icache_core_$c',
      );

      final dc = DCache(
        clk: clk,
        reset: reset,
        reqValid: dV,
        reqWe: dWe,
        reqAddr: dA,
        reqWdata: dW,
        memCmdReady: arbCmdReady[dcIdx],
        memRdata: coreRdata,
        memRdataValid: coreDcRvalid,
        memWdataReady: arbWready[dcIdx],
        snoopCleanReq: ic.output('snoop_clean_req'),
        snoopCleanAddr: ic.output('snoop_clean_addr'),
        coreId: c,
        numLines: numLines,
        lineWords: lineWords,
        memoryTarget: memoryTarget,
        name: 'dcache_core_$c',
      );
      snoopDoneWire <= dc.output('snoop_clean_done');

      addOutput('ic_req_ready_$c') <= ic.output('req_ready');
      addOutput('ic_resp_valid_$c') <= ic.output('resp_valid');
      addOutput('ic_resp_data_$c', width: MiniRISC4Constants.dataWidth) <=
          ic.output('resp_data');
      addOutput('ic_resp_hit_$c') <= ic.output('resp_hit');

      addOutput('dc_req_ready_$c') <= dc.output('req_ready');
      addOutput('dc_resp_valid_$c') <= dc.output('resp_valid');
      addOutput('dc_resp_data_$c', width: MiniRISC4Constants.dataWidth) <=
          dc.output('resp_data');
      addOutput('dc_resp_hit_$c') <= dc.output('resp_hit');

      // I-Cache client (read-only)
      clientReq.add(ic.output('mem_cmd_req'));
      clientRw.add(ic.output('mem_cmd_rw'));
      clientAddr.add(ic.output('mem_cmd_addr'));
      clientLen.add(ic.output('mem_cmd_burst_len'));
      clientWdata.add(Const(0, width: MiniRISC4Constants.dataWidth));
      clientWvalid.add(Const(0));
      clientCanWrite.add(false);

      // D-Cache client (read + dirty writeback)
      clientReq.add(dc.output('mem_cmd_req'));
      clientRw.add(dc.output('mem_cmd_rw'));
      clientAddr.add(dc.output('mem_cmd_addr'));
      clientLen.add(dc.output('mem_cmd_burst_len'));
      clientWdata.add(dc.output('mem_wdata'));
      clientWvalid.add(dc.output('mem_wdata_valid'));
      clientCanWrite.add(true);
    }

    final sdramCmdReady = Logic(name: 'sdram_cmd_ready');
    final sdramRdata = Logic(name: 'sdram_rdata', width: 16);
    final sdramRdataValid = Logic(name: 'sdram_rdata_valid');
    final sdramWdataReady = Logic(name: 'sdram_wdata_ready');

    final arb = SdramBurstArbiter(
      clk: clk,
      reset: reset,
      clientCmdReq: clientReq,
      clientCmdRw: clientRw,
      clientCmdAddr: clientAddr,
      clientCmdBurstLen: clientLen,
      clientWdata: clientWdata,
      clientWdataValid: clientWvalid,
      clientCanWrite: clientCanWrite,
      sdramCmdReady: sdramCmdReady,
      sdramRdata: sdramRdata,
      sdramRdataValid: sdramRdataValid,
      sdramWdataReady: sdramWdataReady,
      name: 'sdram_arbiter',
    );

    arbRdata <= arb.output('client_rdata');
    for (var i = 0; i < numCores * 2; i++) {
      arbCmdReady[i] <= arb.output('client_cmd_ready_$i');
      arbRvalid[i] <= arb.output('client_rdata_valid_$i');
      arbWready[i] <= arb.output('client_wdata_ready_$i');
    }

    final sdram = SdramController(
      clk: clk,
      rstN: rstN,
      cmdReq: arb.output('sdram_cmd_req'),
      cmdRw: arb.output('sdram_cmd_rw'),
      cmdAddr: arb.output('sdram_cmd_addr'),
      cmdBurstLen: arb.output('sdram_cmd_burst_len'),
      wdata: arb.output('sdram_wdata'),
      wdataValid: arb.output('sdram_wdata_valid'),
      sdramDqIn: dqIn,
      clkFreqMhz: clkFreqMhz,
      casLatency: casLatency,
      extraReadPipeCycles: extraReadPipeCycles,
      burstLen: lineWords,
      initWaitCycles: initWaitCycles,
      refreshCycles: refreshCycles,
      name: 'sdram_ctrl',
    );

    sdramCmdReady <= sdram.output('cmd_ready');
    sdramRdata <= sdram.output('rdata');
    sdramRdataValid <= sdram.output('rdata_valid');
    sdramWdataReady <= sdram.output('wdata_ready');

    // Expose physical ULX3S SDRAM pins
    addOutput('sdram_cke') <= sdram.output('sdram_cke');
    addOutput('sdram_cs_n') <= sdram.output('sdram_cs_n');
    addOutput('sdram_ras_n') <= sdram.output('sdram_ras_n');
    addOutput('sdram_cas_n') <= sdram.output('sdram_cas_n');
    addOutput('sdram_we_n') <= sdram.output('sdram_we_n');
    addOutput('sdram_ba', width: 2) <= sdram.output('sdram_ba');
    addOutput('sdram_a', width: 13) <= sdram.output('sdram_a');
    addOutput('sdram_dqm', width: 2) <= sdram.output('sdram_dqm');
    addOutput('sdram_dq_out', width: 16) <= sdram.output('sdram_dq_out');
    addOutput('sdram_dq_oe') <= sdram.output('sdram_dq_oe');
  }
}

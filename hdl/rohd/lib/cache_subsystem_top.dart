// ==============================================================================
// FILE: hdl/rohd/lib/cache_subsystem_top.dart
// Architecture: MiniRISC4 Multi-Core I/D Cache + Round-Robin SDRAM Burst Arbiter
// Framework: Intel ROHD (Dart)
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'cache_controllers.dart';
import 'constants.dart';
import 'sdram_controller.dart';

/// Round-robin burst arbiter sharing a single [SdramController] across
/// [numClients] streaming cache ports (typically `2 * numCores`: I-Cache +
/// D-Cache per core). Locks the grant for an entire burst, then rotates the
/// round-robin pointer so no core can starve.
class SdramBurstArbiter extends Module {
  final int numClients;
  final int idWidth;

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
    super.name = 'sdram_burst_arbiter',
  })  : numClients = clientCmdReq.length,
        idWidth = (clientCmdReq.length <= 1)
            ? 1
            : (clientCmdReq.length - 1).bitLength {
    assert(numClients >= 1, 'numClients must be >= 1');

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

    final busyQ = Logic(name: 'arb_busy_q');
    final grantIdxQ = Logic(name: 'grant_idx_q', width: idWidth);
    final grantRwQ = Logic(name: 'grant_rw_q');
    final remBeatsQ = Logic(name: 'rem_beats_q', width: 8);
    final rrPtrQ = Logic(name: 'rr_ptr_q', width: idWidth);

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

    // Round-robin priority selection: first check clients >= rrPtrQ, else wrap
    // around from 0..rrPtrQ-1.
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

    final selRw = balancedMux(rws, selIdx, Const(0));
    final selAddr = balancedMux(addrs, selIdx, Const(0, width: 24));
    final selLen = balancedMux(lens, selIdx, Const(8, width: 8));

    final isIdle = ~busyQ;
    final grantFire = isIdle & anyReq & sCmdReady;

    // SDRAM command port
    sCmdReq <= isIdle & anyReq;
    sCmdRw <= selRw;
    sCmdAddr <= selAddr;
    sCmdBurstLen <= selLen;

    // SDRAM write data port (driven by currently granted write client)
    final grantedWdata =
        balancedMux(wdatas, grantIdxQ, Const(0, width: MiniRISC4Constants.dataWidth));
    final grantedWvalid = balancedMux(wvalids, grantIdxQ, Const(0));
    sWdata <= grantedWdata;
    sWdataValid <= busyQ & grantRwQ & grantedWvalid;

    // Client return buses
    clientRdataOut <= sRdata;
    for (var i = 0; i < numClients; i++) {
      final iConst = Const(i, width: idWidth);
      output('client_cmd_ready_$i') <= grantFire & selIdx.eq(iConst);
      output('client_rdata_valid_$i') <=
          busyQ & (~grantRwQ) & sRdataValid & grantIdxQ.eq(iConst);
      output('client_wdata_ready_$i') <=
          busyQ & grantRwQ & sWdataReady & grantIdxQ.eq(iConst);
    }

    final beatTransfer =
        busyQ & mux(grantRwQ, grantedWvalid & sWdataReady, sRdataValid);
    final nextRr = mux(
      selIdx.eq(Const(numClients - 1, width: idWidth)),
      Const(0, width: idWidth),
      selIdx + Const(1, width: idWidth),
    );

    Sequential(clk, reset: reset, resetValues: {
      busyQ: 0,
      grantIdxQ: 0,
      grantRwQ: 0,
      remBeatsQ: 0,
      rrPtrQ: 0,
    }, [
      If(grantFire, then: [
        busyQ < 1,
        grantIdxQ < selIdx,
        grantRwQ < selRw,
        remBeatsQ < selLen,
        rrPtrQ < nextRr,
      ], orElse: [
        If(beatTransfer, then: [
          If(remBeatsQ.lte(1), then: [
            busyQ < 0,
            remBeatsQ < 0,
          ], orElse: [
            remBeatsQ < remBeatsQ - Const(1, width: 8),
          ]),
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
    int? initWaitCycles,
    int? refreshCycles,
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

      final ic = ICache(
        clk: clk,
        reset: reset,
        reqValid: iV,
        reqAddr: iA,
        memCmdReady: arbCmdReady[icIdx],
        memRdata: arbRdata,
        memRdataValid: arbRvalid[icIdx],
        flushAll: iFlush,
        // Per-core D-Cache write automatically invalidates matching I-Cache line
        invalValid: dV & dWe,
        invalAddr: dA,
        // On I-Cache miss, snoop D-Cache to write back any dirty line first
        // so self-modifying code / monitor program loads are 100% coherent.
        snoopCleanDone: snoopDoneWire,
        coreId: c,
        numLines: numLines,
        lineWords: lineWords,
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
        memRdata: arbRdata,
        memRdataValid: arbRvalid[dcIdx],
        memWdataReady: arbWready[dcIdx],
        snoopCleanReq: ic.output('snoop_clean_req'),
        snoopCleanAddr: ic.output('snoop_clean_addr'),
        coreId: c,
        numLines: numLines,
        lineWords: lineWords,
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

      // D-Cache client (read + dirty writeback)
      clientReq.add(dc.output('mem_cmd_req'));
      clientRw.add(dc.output('mem_cmd_rw'));
      clientAddr.add(dc.output('mem_cmd_addr'));
      clientLen.add(dc.output('mem_cmd_burst_len'));
      clientWdata.add(dc.output('mem_wdata'));
      clientWvalid.add(dc.output('mem_wdata_valid'));
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

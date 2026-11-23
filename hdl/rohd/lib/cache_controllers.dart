// ==============================================================================
// FILE: hdl/rohd/lib/cache_controllers.dart
// Synthesizable Direct-Mapped BRAM I-Cache & Write-Back D-Cache Controllers
// Backing Store: Private Per-Core 64K-Word SDRAM Partition ({coreId[7:0], addr[15:0]})
// ==============================================================================

import 'dart:typed_data';
import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'noc_router.dart';

/// Synthesizable single-port synchronous Block RAM (`DP16KD` on ECP5, compiled
/// single-port SRAM macro on ASIC) with cycle-exact ROHD Dart simulation.
class CacheDataBram extends Module with SystemVerilog {
  final int depth;
  final int dataWidth;
  final int addrWidth;
  final Uint16List mem;

  CacheDataBram({
    required Logic clk,
    required Logic addr,
    required Logic wdata,
    required Logic we,
    required Logic en,
    this.depth = 512,
    this.dataWidth = 16,
    super.name = 'cache_data_bram',
  })  : addrWidth = (depth <= 1) ? 1 : (depth - 1).bitLength,
        mem = Uint16List(depth) {
    clk = addInput('clk', clk);
    addr = addInput('addr', addr, width: addrWidth);
    wdata = addInput('wdata', wdata, width: dataWidth);
    we = addInput('we', we);
    en = addInput('en', en);

    final rdata = addOutput('rdata', width: dataWidth);

    final readComb = Logic(name: 'read_comb_sim', width: dataWidth);
    final wrFireQ = Logic(name: 'wr_fire_q_sim');
    final wrAddrQ = Logic(name: 'wr_addr_q_sim', width: addrWidth);
    final wrDataQ = Logic(name: 'wr_data_q_sim', width: dataWidth);

    void refreshRead() {
      final a = addr.value.isValid ? addr.value.toInt() : 0;
      readComb.put(a < depth ? mem[a] : 0);
    }

    readComb.put(0);
    rdata.put(0);
    wrFireQ.put(0);
    wrAddrQ.put(0);
    wrDataQ.put(0);

    addr.changed.listen((_) => refreshRead());

    Sequential(clk, [
      If(en & ~we, then: [
        rdata < readComb,
      ]),
      wrFireQ < (en & we),
      wrAddrQ < addr,
      wrDataQ < wdata,
    ]);

    clk.posedge.listen((_) {
      Simulator.postTick.first.then(
        (_) {
          if (wrFireQ.value.isValid && wrFireQ.value.toBool()) {
            final wa = wrAddrQ.value.isValid ? wrAddrQ.value.toInt() : 0;
            final wd = wrDataQ.value.isValid ? wrDataQ.value.toInt() : 0;
            if (wa < depth) {
              mem[wa] = wd & 0xFFFF;
            }
          }
          refreshRead();
        },
        onError: (_) {},
      );
    });
  }

  Logic get rdata => output('rdata');

  @override
  String definitionVerilog(String definitionType) => '''
module $definitionType (
  input  logic clk,
  input  logic [${addrWidth - 1}:0] addr,
  input  logic [${dataWidth - 1}:0] wdata,
  input  logic we,
  input  logic en,
  output logic [${dataWidth - 1}:0] rdata
);
  (* ram_style = "block", no_rw_check *)
  logic [${dataWidth - 1}:0] mem [0:${depth - 1}];
`ifndef SYNTHESIS
  integer _init_i;
  initial begin
    for (_init_i = 0; _init_i < $depth; _init_i = _init_i + 1) begin
      mem[_init_i] = $dataWidth'd0;
    end
  end
`endif
  always_ff @(posedge clk) begin
    if (en) begin
      if (we) begin
        mem[addr] <= wdata;
      end else begin
        rdata <= mem[addr];
      end
    end
  end
endmodule
''';
}

/// Direct-mapped BRAM Instruction Cache (`1 DP16KD` for up to 1024 words).
///
/// - Each core owns a non-overlapping 64K-word SDRAM partition at
///   `{coreId[7:0], addr[15:0]}` (24-bit SDRAM word address).
/// - Hit latency: **2 cycles** (matches `CpuCore` 2-cycle BRAM timing,
///   registered tag compare + registered data output for `>100 MHz`).
/// - Miss refill: streaming burst read (`lineWords` words, default 8) from the
///   SDRAM/arbiter interface.
/// - Coherency hooks: 1-cycle `flushAll` and single-line `invalValid`/`invalAddr`
///   (for self-modifying code / monitor `c` + `g` / program loading).
class ICache extends Module {
  final int coreId;
  final int numLines;
  final int lineWords;
  final int offsetBits;
  final int indexBits;
  final int tagBits;

  static const int _stIdle = 0;
  static const int _stLookup = 1;
  static const int _stRefillReq = 2;
  static const int _stRefillData = 3;

  ICache({
    required Logic clk,
    required Logic reset,
    required Logic reqValid,
    required Logic reqAddr,
    required Logic memCmdReady,
    required Logic memRdata,
    required Logic memRdataValid,
    Logic? flushAll,
    Logic? invalValid,
    Logic? invalAddr,
    this.coreId = 0,
    this.numLines = 64,
    this.lineWords = 8,
    super.name = 'icache',
  })  : offsetBits = (lineWords - 1).bitLength,
        indexBits = (numLines - 1).bitLength,
        tagBits = MiniRISC4Constants.addrWidth -
            (lineWords - 1).bitLength -
            (numLines - 1).bitLength {
    assert((numLines & (numLines - 1)) == 0 && numLines >= 4,
        'numLines must be a power of 2 >= 4');
    assert((lineWords & (lineWords - 1)) == 0 && lineWords >= 2,
        'lineWords must be a power of 2 >= 2');

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    reqValid = addInput('req_valid', reqValid);
    reqAddr = addInput('req_addr', reqAddr, width: MiniRISC4Constants.addrWidth);
    memCmdReady = addInput('mem_cmd_ready', memCmdReady);
    memRdata = addInput('mem_rdata', memRdata, width: MiniRISC4Constants.dataWidth);
    memRdataValid = addInput('mem_rdata_valid', memRdataValid);
    flushAll = addInput('flush_all', flushAll ?? Const(0));
    invalValid = addInput('inval_valid', invalValid ?? Const(0));
    invalAddr = addInput(
      'inval_addr',
      invalAddr ?? Const(0, width: MiniRISC4Constants.addrWidth),
      width: MiniRISC4Constants.addrWidth,
    );

    final reqReady = addOutput('req_ready');
    final respValid = addOutput('resp_valid');
    final respData = addOutput('resp_data', width: MiniRISC4Constants.dataWidth);
    final respHit = addOutput('resp_hit');

    final memCmdReq = addOutput('mem_cmd_req');
    final memCmdRw = addOutput('mem_cmd_rw');
    final memCmdAddr = addOutput('mem_cmd_addr', width: 24);
    final memCmdBurstLen = addOutput('mem_cmd_burst_len', width: 8);

    final stateQ = Logic(name: 'state_q', width: 2);
    final reqAddrQ = Logic(name: 'req_addr_q', width: MiniRISC4Constants.addrWidth);
    final hitQ = Logic(name: 'hit_q');
    final fillBeatQ = Logic(name: 'fill_beat_q', width: offsetBits);
    final fillWordQ = Logic(name: 'fill_word_q', width: MiniRISC4Constants.dataWidth);
    final respValidQ = Logic(name: 'resp_valid_q');
    final respDataQ = Logic(name: 'resp_data_q', width: MiniRISC4Constants.dataWidth);
    final respHitQ = Logic(name: 'resp_hit_q');

    // Per-line valid bits (instant 1-cycle reset & flush)
    final validVec = List.generate(numLines, (i) => Logic(name: 'valid_q_$i'));

    final idxLo = offsetBits;
    final idxHi = offsetBits + indexBits - 1;
    final tagLo = idxHi + 1;

    final inOffset = reqAddr.slice(offsetBits - 1, 0);
    final inIndex = reqAddr.slice(idxHi, idxLo);
    final inTag = reqAddr.slice(MiniRISC4Constants.addrWidth - 1, tagLo);

    final qOffset = reqAddrQ.slice(offsetBits - 1, 0);
    final qIndex = reqAddrQ.slice(idxHi, idxLo);
    final qTag = reqAddrQ.slice(MiniRISC4Constants.addrWidth - 1, tagLo);

    final invIndex = invalAddr.slice(idxHi, idxLo);

    // Balanced valid bit lookup
    Logic muxBit(List<Logic> bits, Logic sel) {
      var level = List<Logic>.from(bits);
      for (var b = 0; b < sel.width; b++) {
        final next = <Logic>[];
        for (var i = 0; i < level.length; i += 2) {
          next.add(mux(sel[b], level[i + 1], level[i]));
        }
        level = next;
      }
      return level[0];
    }

    final isIdle = stateQ.eq(Const(_stIdle, width: 2));
    final isRefillReq = stateQ.eq(Const(_stRefillReq, width: 2));
    final isRefillData = stateQ.eq(Const(_stRefillData, width: 2));

    final lastBeat = fillBeatQ.eq(Const(lineWords - 1, width: offsetBits));
    final refillDone = isRefillData & memRdataValid & lastBeat;

    // Tag storage in tiny distributed RAM (only 4-8 DPR16X4 slices)
    final tagRam = NocFifoRam(
      clk: clk,
      waddr: qIndex,
      wdata: qTag,
      we: refillDone,
      raddr: inIndex,
      addrWidth: indexBits,
      dataWidth: tagBits,
      name: '${name}_tag_ram',
    );

    final inLineValid = muxBit(validVec, inIndex);
    final inHit = inLineValid & tagRam.rdata.eq(inTag) & (~flushAll);

    // Data storage in 1 single DP16KD Block RAM
    final bramAddr = mux(
      isRefillData,
      [qIndex, fillBeatQ].swizzle(),
      [inIndex, inOffset].swizzle(),
    );
    final bramWe = isRefillData & memRdataValid;
    final bramEn = (isIdle & reqValid) | bramWe;
    final dataBram = CacheDataBram(
      clk: clk,
      addr: bramAddr,
      wdata: memRdata,
      we: bramWe,
      en: bramEn,
      depth: numLines * lineWords,
      dataWidth: MiniRISC4Constants.dataWidth,
      name: '${name}_data_bram',
    );

    // Outputs
    reqReady <= isIdle;
    respValid <= respValidQ;
    respData <= respDataQ;
    respHit <= respHitQ;

    memCmdReq <= isRefillReq;
    memCmdRw <= Const(0);
    memCmdAddr <= [
      Const(coreId & 0xFF, width: 8),
      qTag,
      qIndex,
      Const(0, width: offsetBits),
    ].swizzle();
    memCmdBurstLen <= Const(lineWords, width: 8);

    final resetVals = <Logic, dynamic>{
      stateQ: _stIdle,
      reqAddrQ: 0,
      hitQ: 0,
      fillBeatQ: 0,
      fillWordQ: 0,
      respValidQ: 0,
      respDataQ: 0,
      respHitQ: 0,
      for (final v in validVec) v: 0,
    };

    final seqOps = <Conditional>[
      respValidQ < 0,
      respHitQ < 0,
      // Valid bit maintenance (flushAll > line invalidate > refill completion)
      If(flushAll, then: [
        for (final v in validVec) v < 0,
      ], orElse: [
        for (var i = 0; i < numLines; i++)
          If(invalValid & invIndex.eq(Const(i, width: indexBits)), then: [
            validVec[i] < 0,
          ], orElse: [
            If(refillDone & qIndex.eq(Const(i, width: indexBits)), then: [
              validVec[i] < 1,
            ]),
          ]),
      ]),
      Case(stateQ, [
        CaseItem(Const(_stIdle, width: 2), [
          If(reqValid, then: [
            reqAddrQ < reqAddr,
            hitQ < inHit,
            stateQ < Const(_stLookup, width: 2),
          ]),
        ]),
        CaseItem(Const(_stLookup, width: 2), [
          If(hitQ, then: [
            respValidQ < 1,
            respDataQ < dataBram.rdata,
            respHitQ < 1,
            stateQ < Const(_stIdle, width: 2),
          ], orElse: [
            fillBeatQ < 0,
            stateQ < Const(_stRefillReq, width: 2),
          ]),
        ]),
        CaseItem(Const(_stRefillReq, width: 2), [
          If(memCmdReady, then: [
            fillBeatQ < 0,
            stateQ < Const(_stRefillData, width: 2),
          ]),
        ]),
        CaseItem(Const(_stRefillData, width: 2), [
          If(memRdataValid, then: [
            If(fillBeatQ.eq(qOffset), then: [
              fillWordQ < memRdata,
            ]),
            If(lastBeat, then: [
              respValidQ < 1,
              respDataQ < mux(fillBeatQ.eq(qOffset), memRdata, fillWordQ),
              respHitQ < 0,
              stateQ < Const(_stIdle, width: 2),
            ], orElse: [
              fillBeatQ < fillBeatQ + Const(1, width: offsetBits),
            ]),
          ]),
        ]),
      ]),
    ];

    Sequential(clk, reset: reset, resetValues: resetVals, seqOps);
  }
}

/// Direct-mapped write-back, write-allocate BRAM Data Cache (`1 DP16KD` for up
/// to 1024 words).
///
/// - Each core owns a non-overlapping 64K-word SDRAM partition at
///   `{coreId[7:0], addr[15:0]}` (24-bit SDRAM word address).
/// - Read/Write hit latency: **2 cycles** (registered tag check + registered
///   data output, matching `CpuCore` Port B timing at `>100 MHz`).
/// - Miss handling:
///   - Clean miss: 8-word burst refill from SDRAM (on write miss, incoming
///     `reqWdata` is merged on-the-fly during the matching refill beat!).
///   - Dirty miss: 8-word burst writeback of the evicted dirty line directly
///     from `CacheDataBram` (zero extra writeback buffer RAM, 1.0 word/cycle
///     ready/valid streaming), followed immediately by burst refill.
class DCache extends Module {
  final int coreId;
  final int numLines;
  final int lineWords;
  final int offsetBits;
  final int indexBits;
  final int tagBits;

  static const int _stIdle = 0;
  static const int _stLookup = 1;
  static const int _stWbPrime = 2;
  static const int _stWbReq = 3;
  static const int _stWbData = 4;
  static const int _stRefillReq = 5;
  static const int _stRefillData = 6;

  DCache({
    required Logic clk,
    required Logic reset,
    required Logic reqValid,
    required Logic reqWe,
    required Logic reqAddr,
    required Logic reqWdata,
    required Logic memCmdReady,
    required Logic memRdata,
    required Logic memRdataValid,
    required Logic memWdataReady,
    this.coreId = 0,
    this.numLines = 64,
    this.lineWords = 8,
    super.name = 'dcache',
  })  : offsetBits = (lineWords - 1).bitLength,
        indexBits = (numLines - 1).bitLength,
        tagBits = MiniRISC4Constants.addrWidth -
            (lineWords - 1).bitLength -
            (numLines - 1).bitLength {
    assert((numLines & (numLines - 1)) == 0 && numLines >= 4,
        'numLines must be a power of 2 >= 4');
    assert((lineWords & (lineWords - 1)) == 0 && lineWords >= 2,
        'lineWords must be a power of 2 >= 2');

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    reqValid = addInput('req_valid', reqValid);
    reqWe = addInput('req_we', reqWe);
    reqAddr = addInput('req_addr', reqAddr, width: MiniRISC4Constants.addrWidth);
    reqWdata = addInput('req_wdata', reqWdata, width: MiniRISC4Constants.dataWidth);
    memCmdReady = addInput('mem_cmd_ready', memCmdReady);
    memRdata = addInput('mem_rdata', memRdata, width: MiniRISC4Constants.dataWidth);
    memRdataValid = addInput('mem_rdata_valid', memRdataValid);
    memWdataReady = addInput('mem_wdata_ready', memWdataReady);

    final reqReady = addOutput('req_ready');
    final respValid = addOutput('resp_valid');
    final respData = addOutput('resp_data', width: MiniRISC4Constants.dataWidth);
    final respHit = addOutput('resp_hit');

    final memCmdReq = addOutput('mem_cmd_req');
    final memCmdRw = addOutput('mem_cmd_rw');
    final memCmdAddr = addOutput('mem_cmd_addr', width: 24);
    final memCmdBurstLen = addOutput('mem_cmd_burst_len', width: 8);
    final memWdata = addOutput('mem_wdata', width: MiniRISC4Constants.dataWidth);
    final memWdataValid = addOutput('mem_wdata_valid');

    final stateQ = Logic(name: 'state_q', width: 3);
    final reqAddrQ = Logic(name: 'req_addr_q', width: MiniRISC4Constants.addrWidth);
    final reqWeQ = Logic(name: 'req_we_q');
    final reqWdataQ =
        Logic(name: 'req_wdata_q', width: MiniRISC4Constants.dataWidth);
    final hitQ = Logic(name: 'hit_q');
    final evictDirtyQ = Logic(name: 'evict_dirty_q');
    final evictTagQ = Logic(name: 'evict_tag_q', width: tagBits);
    final beatQ = Logic(name: 'beat_q', width: offsetBits);
    final fillWordQ =
        Logic(name: 'fill_word_q', width: MiniRISC4Constants.dataWidth);
    final respValidQ = Logic(name: 'resp_valid_q');
    final respDataQ =
        Logic(name: 'resp_data_q', width: MiniRISC4Constants.dataWidth);
    final respHitQ = Logic(name: 'resp_hit_q');

    // Per-line valid & dirty bits (1-cycle reset)
    final validVec = List.generate(numLines, (i) => Logic(name: 'valid_q_$i'));
    final dirtyVec = List.generate(numLines, (i) => Logic(name: 'dirty_q_$i'));

    final idxLo = offsetBits;
    final idxHi = offsetBits + indexBits - 1;
    final tagLo = idxHi + 1;

    final inOffset = reqAddr.slice(offsetBits - 1, 0);
    final inIndex = reqAddr.slice(idxHi, idxLo);
    final inTag = reqAddr.slice(MiniRISC4Constants.addrWidth - 1, tagLo);

    final qOffset = reqAddrQ.slice(offsetBits - 1, 0);
    final qIndex = reqAddrQ.slice(idxHi, idxLo);
    final qTag = reqAddrQ.slice(MiniRISC4Constants.addrWidth - 1, tagLo);

    Logic muxBit(List<Logic> bits, Logic sel) {
      var level = List<Logic>.from(bits);
      for (var b = 0; b < sel.width; b++) {
        final next = <Logic>[];
        for (var i = 0; i < level.length; i += 2) {
          next.add(mux(sel[b], level[i + 1], level[i]));
        }
        level = next;
      }
      return level[0];
    }

    final isIdle = stateQ.eq(Const(_stIdle, width: 3));
    final isLookup = stateQ.eq(Const(_stLookup, width: 3));
    final isWbPrime = stateQ.eq(Const(_stWbPrime, width: 3));
    final isWbReq = stateQ.eq(Const(_stWbReq, width: 3));
    final isWbData = stateQ.eq(Const(_stWbData, width: 3));
    final isRefillReq = stateQ.eq(Const(_stRefillReq, width: 3));
    final isRefillData = stateQ.eq(Const(_stRefillData, width: 3));

    final lastBeat = beatQ.eq(Const(lineWords - 1, width: offsetBits));
    final wbFire = isWbData & memWdataReady;
    final refillDone = isRefillData & memRdataValid & lastBeat;
    final writeHitFire = isLookup & hitQ & reqWeQ;

    // Tag storage in tiny distributed RAM (only 4-8 DPR16X4 slices)
    final tagRam = NocFifoRam(
      clk: clk,
      waddr: qIndex,
      wdata: qTag,
      we: refillDone,
      raddr: inIndex,
      addrWidth: indexBits,
      dataWidth: tagBits,
      name: '${name}_tag_ram',
    );

    final inLineValid = muxBit(validVec, inIndex);
    final inLineDirty = muxBit(dirtyVec, inIndex);
    final inHit = inLineValid & tagRam.rdata.eq(inTag);

    // Data BRAM address/write mux:
    // - Idle lookup: read [inIndex, inOffset]
    // - Write hit: write reqWdataQ to [qIndex, qOffset]
    // - Writeback prime/req/data: stream [qIndex, wbNextBeat] at 1 word/cycle
    // - Refill: write (reqWeQ & beat==qOffset ? reqWdataQ : memRdata) to [qIndex, beatQ]
    final wbNextBeat = mux(
      isWbPrime | isWbReq,
      Const(0, width: offsetBits),
      mux(wbFire, beatQ + Const(1, width: offsetBits), beatQ),
    );
    final bramAddr = mux(
      writeHitFire,
      [qIndex, qOffset].swizzle(),
      mux(
        isRefillData,
        [qIndex, beatQ].swizzle(),
        mux(
          isWbPrime | isWbReq | isWbData,
          [qIndex, wbNextBeat].swizzle(),
          [inIndex, inOffset].swizzle(),
        ),
      ),
    );
    final refillWordMerge =
        mux(reqWeQ & beatQ.eq(qOffset), reqWdataQ, memRdata);
    final bramWdata = mux(writeHitFire, reqWdataQ, refillWordMerge);
    final bramWe = writeHitFire | (isRefillData & memRdataValid);
    final bramEn =
        (isIdle & reqValid) | bramWe | isWbPrime | isWbReq | isWbData;

    final dataBram = CacheDataBram(
      clk: clk,
      addr: bramAddr,
      wdata: bramWdata,
      we: bramWe,
      en: bramEn,
      depth: numLines * lineWords,
      dataWidth: MiniRISC4Constants.dataWidth,
      name: '${name}_data_bram',
    );

    // Outputs
    reqReady <= isIdle;
    respValid <= respValidQ;
    respData <= respDataQ;
    respHit <= respHitQ;

    memCmdReq <= isWbReq | isRefillReq;
    memCmdRw <= isWbReq;
    memCmdAddr <= [
      Const(coreId & 0xFF, width: 8),
      mux(isWbReq, evictTagQ, qTag),
      qIndex,
      Const(0, width: offsetBits),
    ].swizzle();
    memCmdBurstLen <= Const(lineWords, width: 8);
    memWdata <= dataBram.rdata;
    memWdataValid <= isWbData;

    final resetVals = <Logic, dynamic>{
      stateQ: _stIdle,
      reqAddrQ: 0,
      reqWeQ: 0,
      reqWdataQ: 0,
      hitQ: 0,
      evictDirtyQ: 0,
      evictTagQ: 0,
      beatQ: 0,
      fillWordQ: 0,
      respValidQ: 0,
      respDataQ: 0,
      respHitQ: 0,
      for (final v in validVec) v: 0,
      for (final d in dirtyVec) d: 0,
    };

    final seqOps = <Conditional>[
      respValidQ < 0,
      respHitQ < 0,
      // Valid & dirty bit maintenance
      for (var i = 0; i < numLines; i++) ...[
        If(refillDone & qIndex.eq(Const(i, width: indexBits)), then: [
          validVec[i] < 1,
          dirtyVec[i] < reqWeQ,
        ], orElse: [
          If(writeHitFire & qIndex.eq(Const(i, width: indexBits)), then: [
            dirtyVec[i] < 1,
          ]),
        ]),
      ],
      Case(stateQ, [
        CaseItem(Const(_stIdle, width: 3), [
          If(reqValid, then: [
            reqAddrQ < reqAddr,
            reqWeQ < reqWe,
            reqWdataQ < reqWdata,
            hitQ < inHit,
            evictDirtyQ < (inLineValid & inLineDirty),
            evictTagQ < tagRam.rdata,
            stateQ < Const(_stLookup, width: 3),
          ]),
        ]),
        CaseItem(Const(_stLookup, width: 3), [
          If(hitQ, then: [
            respValidQ < 1,
            respDataQ < mux(reqWeQ, reqWdataQ, dataBram.rdata),
            respHitQ < 1,
            stateQ < Const(_stIdle, width: 3),
          ], orElse: [
            beatQ < 0,
            If(evictDirtyQ, then: [
              stateQ < Const(_stWbPrime, width: 3),
            ], orElse: [
              stateQ < Const(_stRefillReq, width: 3),
            ]),
          ]),
        ]),
        // Prime CacheDataBram with word 0 of the dirty line before issuing WB cmd
        CaseItem(Const(_stWbPrime, width: 3), [
          beatQ < 0,
          stateQ < Const(_stWbReq, width: 3),
        ]),
        CaseItem(Const(_stWbReq, width: 3), [
          If(memCmdReady, then: [
            beatQ < 0,
            stateQ < Const(_stWbData, width: 3),
          ]),
        ]),
        CaseItem(Const(_stWbData, width: 3), [
          If(memWdataReady, then: [
            If(lastBeat, then: [
              beatQ < 0,
              stateQ < Const(_stRefillReq, width: 3),
            ], orElse: [
              beatQ < beatQ + Const(1, width: offsetBits),
            ]),
          ]),
        ]),
        CaseItem(Const(_stRefillReq, width: 3), [
          If(memCmdReady, then: [
            beatQ < 0,
            stateQ < Const(_stRefillData, width: 3),
          ]),
        ]),
        CaseItem(Const(_stRefillData, width: 3), [
          If(memRdataValid, then: [
            If(beatQ.eq(qOffset), then: [
              fillWordQ < memRdata,
            ]),
            If(lastBeat, then: [
              respValidQ < 1,
              respDataQ <
                  mux(
                    reqWeQ,
                    reqWdataQ,
                    mux(beatQ.eq(qOffset), memRdata, fillWordQ),
                  ),
              respHitQ < 0,
              stateQ < Const(_stIdle, width: 3),
            ], orElse: [
              beatQ < beatQ + Const(1, width: offsetBits),
            ]),
          ]),
        ]),
      ]),
    ];

    Sequential(clk, reset: reset, resetValues: resetVals, seqOps);
  }
}

import 'package:rohd/rohd.dart';
import 'constants.dart';

/// Synthesizable 1-write / 1-read synchronous-write, asynchronous-read RAM
/// backing multi-word NoC FIFOs. Infers ECP5 TRELLIS_DPR16X4 distributed RAM
/// on FPGA and a standard 1W1R register file on ASIC.
class NocFifoRam extends Module with SystemVerilog {
  final int addrWidth;
  final int dataWidth;
  final int memDepth;
  final List<BigInt> _mem;

  NocFifoRam({
    required Logic clk,
    required Logic waddr,
    required Logic wdata,
    required Logic we,
    required Logic raddr,
    required this.addrWidth,
    required this.dataWidth,
    super.name = 'noc_fifo_ram',
  })  : memDepth = 1 << addrWidth,
        _mem = List<BigInt>.filled(1 << addrWidth, BigInt.zero) {
    clk = addInput('clk', clk);
    waddr = addInput('waddr', waddr, width: addrWidth);
    wdata = addInput('wdata', wdata, width: dataWidth);
    we = addInput('we', we);
    raddr = addInput('raddr', raddr, width: addrWidth);

    final rdata = addOutput('rdata', width: dataWidth);

    // Latched write shadows updated via ROHD Sequential so Dart simulation
    // matches always_ff @(posedge clk) + combinational read cycle-for-cycle.
    final wrFireQ = Logic(name: 'wr_fire_q_sim');
    final wrAddrQ = Logic(name: 'wr_addr_q_sim', width: addrWidth);
    final wrDataQ = Logic(name: 'wr_data_q_sim', width: dataWidth);

    void refreshRead() {
      final r = raddr.value.isValid ? raddr.value.toInt() : 0;
      rdata.put(
        r < memDepth ? LogicValue.ofBigInt(_mem[r], dataWidth) : 0,
      );
    }

    wrFireQ.put(0);
    wrAddrQ.put(0);
    wrDataQ.put(0);
    rdata.put(0);

    raddr.changed.listen((_) => refreshRead());

    Sequential(clk, [
      wrFireQ < we,
      wrAddrQ < waddr,
      wrDataQ < wdata,
    ]);

    clk.posedge.listen((_) {
      Simulator.postTick.first.then(
        (_) {
          if (wrFireQ.value.isValid && wrFireQ.value.toBool()) {
            final w = wrAddrQ.value.isValid ? wrAddrQ.value.toInt() : 0;
            final d =
                wrDataQ.value.isValid ? wrDataQ.value.toBigInt() : BigInt.zero;
            if (w < memDepth) {
              _mem[w] = d;
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
  input  logic [${addrWidth - 1}:0] waddr,
  input  logic [${dataWidth - 1}:0] wdata,
  input  logic we,
  input  logic [${addrWidth - 1}:0] raddr,
  output logic [${dataWidth - 1}:0] rdata
);
  (* ram_style = "distributed" *)
  logic [${dataWidth - 1}:0] mem [0:${memDepth - 1}];
`ifndef SYNTHESIS
  integer _init_i;
  initial begin
    for (_init_i = 0; _init_i < $memDepth; _init_i = _init_i + 1) begin
      mem[_init_i] = $dataWidth'd0;
    end
  end
`endif
  always_ff @(posedge clk) begin
    if (we) begin
      mem[waddr] <= wdata;
    end
  end
  assign rdata = mem[raddr];
endmodule
''';
}

/// Per-core NoC Network Interface (`0x0020`–`0x002A`) with multi-word
/// per-channel RX FIFOs, multi-word TX FIFO, multi-word priority MBOX queue,
/// topology discovery (`NOC_INFO` at `0x002A`), and full/empty backpressure
/// signaling (`netInReady` / `netOutReady`).
class NocRouterNi extends Module {
  final int coreId;
  final int numCores;
  final int numChannels;
  final int fifoDepth;
  final int txFifoDepth;
  final int mboxFifoDepth;

  NocRouterNi({
    required Logic clk,
    required Logic reset,
    required Logic mmioAddr,
    required Logic mmioWdata,
    required Logic mmioWe,
    required Logic mmioRe,
    required Logic netInValid,
    required Logic netInType,
    required Logic netInSrcCore,
    required Logic netInSrcCh,
    required Logic netInDstCh,
    required Logic netInPayload,
    required Logic netOutReady,
    this.coreId = 0,
    this.numCores = 1,
    this.numChannels = 4,
    this.fifoDepth = 4,
    int? txFifoDepth,
    int? mboxFifoDepth,
    super.name = 'noc_router_ni',
  })  : txFifoDepth = txFifoDepth ?? (fifoDepth <= 8 ? fifoDepth : 8),
        mboxFifoDepth = mboxFifoDepth ?? (fifoDepth <= 4 ? fifoDepth : 4) {
    assert(numCores >= 1, 'numCores must be >= 1');
    assert(numChannels >= 1, 'numChannels must be >= 1');
    assert(fifoDepth >= 1, 'fifoDepth must be >= 1');
    assert(this.txFifoDepth >= 1, 'txFifoDepth must be >= 1');
    assert(this.mboxFifoDepth >= 1, 'mboxFifoDepth must be >= 1');

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final addr =
        addInput('mmioAddr', mmioAddr, width: MiniRISC4Constants.addrWidth);
    final wdata =
        addInput('mmioWdata', mmioWdata, width: MiniRISC4Constants.dataWidth);
    final we = addInput('mmioWe', mmioWe);
    final re = addInput('mmioRe', mmioRe);
    final inValid = addInput('netInValid', netInValid);
    final inType = addInput('netInType', netInType);
    final inSrcCore = addInput('netInSrcCore', netInSrcCore, width: 8);
    final inSrcCh = addInput('netInSrcCh', netInSrcCh, width: 8);
    final inDstCh = addInput('netInDstCh', netInDstCh, width: 8);
    final inPayload = addInput('netInPayload', netInPayload,
        width: MiniRISC4Constants.dataWidth);
    final outReady = addInput('netOutReady', netOutReady);

    final rdataOut =
        addOutput('mmioRdata', width: MiniRISC4Constants.dataWidth);
    final rdataRegOut =
        addOutput('mmioRdataReg', width: MiniRISC4Constants.dataWidth);
    final inReadyOut = addOutput('netInReady');
    final outValid = addOutput('netOutValid');
    final outType = addOutput('netOutType');
    final outDstCore = addOutput('netOutDstCore', width: 8);
    final outDstCh = addOutput('netOutDstCh', width: 8);
    final outSrcCh = addOutput('netOutSrcCh', width: 8);
    final outPayload =
        addOutput('netOutPayload', width: MiniRISC4Constants.dataWidth);
    final trapReq = addOutput('mboxTrapReq');

    final chWidth = (numChannels <= 1) ? 1 : (numChannels - 1).bitLength;
    final rxPtrWidth = (fifoDepth <= 1) ? 1 : (fifoDepth - 1).bitLength;
    final rxCntWidth = fifoDepth.bitLength;
    final txPtrWidth =
        (this.txFifoDepth <= 1) ? 1 : (this.txFifoDepth - 1).bitLength;
    final txCntWidth = this.txFifoDepth.bitLength;
    final mboxPtrWidth =
        (this.mboxFifoDepth <= 1) ? 1 : (this.mboxFifoDepth - 1).bitLength;
    final mboxCntWidth = this.mboxFifoDepth.bitLength;

    final selChQ = Logic(name: 'selChQ', width: chWidth);
    final chDstCoreQ = List.generate(
      numChannels,
      (i) => Logic(name: 'chDstCoreQ_$i', width: 8),
    );
    final chDstChQ = List.generate(
      numChannels,
      (i) => Logic(name: 'chDstChQ_$i', width: 8),
    );
    final chValidQ = List.generate(
      numChannels,
      (i) => Logic(name: 'chValidQ_$i'),
    );

    // Per-channel RX FIFO pointers and occupancy counters
    final rxRdPtrQ = List.generate(
      numChannels,
      (i) => Logic(name: 'rxRdPtrQ_$i', width: rxPtrWidth),
    );
    final rxWrPtrQ = List.generate(
      numChannels,
      (i) => Logic(name: 'rxWrPtrQ_$i', width: rxPtrWidth),
    );
    final rxCntQ = List.generate(
      numChannels,
      (i) => Logic(name: 'rxCntQ_$i', width: rxCntWidth),
    );

    // TX FIFO pointers and counter
    final txRdPtrQ = Logic(name: 'txRdPtrQ', width: txPtrWidth);
    final txWrPtrQ = Logic(name: 'txWrPtrQ', width: txPtrWidth);
    final txCntQ = Logic(name: 'txCntQ', width: txCntWidth);

    // Priority MBOX RX FIFO pointers, counter, and last-popped source cache
    final mboxRdPtrQ = Logic(name: 'mboxRdPtrQ', width: mboxPtrWidth);
    final mboxWrPtrQ = Logic(name: 'mboxWrPtrQ', width: mboxPtrWidth);
    final mboxCntQ = Logic(name: 'mboxCntQ', width: mboxCntWidth);
    final lastMboxSrcQ =
        Logic(name: 'lastMboxSrcQ', width: MiniRISC4Constants.dataWidth);

    // 1-cycle held MMIO read register so 2-cycle CpuCore Port B reads
    // (ST_MEM_WAIT -> ST_MEM_WAIT2) capture popped FIFO/MBOX words cleanly,
    // plus a cached read pointer for the active channel so rxRam.raddr is
    // driven directly from flip-flops (no 8:1 mux before distributed RAM).
    final mmioRdataQ =
        Logic(name: 'mmioRdataQ', width: MiniRISC4Constants.dataWidth);
    final activeRxRdPtrQ = Logic(name: 'activeRxRdPtrQ', width: rxPtrWidth);

    // Balanced binary-tree mux helper for >100 MHz timing
    Logic balancedMux(List<Logic> items, Logic sel, Logic fallback) {
      if (items.length == 1) {
        return items[0];
      }
      final treeSize = 1 << sel.width;
      var level = List<Logic>.generate(
        treeSize,
        (i) => i < items.length ? items[i] : fallback,
      );
      for (var bit = 0; bit < sel.width; bit++) {
        final next = <Logic>[];
        for (var i = 0; i < level.length; i += 2) {
          next.add(mux(sel[bit], level[i + 1], level[i]));
        }
        level = next;
      }
      return level[0];
    }

    Logic incWrap(Logic ptr, int depth, int width) {
      if (depth <= 1) {
        return Const(0, width: width);
      }
      final isPow2 = (depth & (depth - 1)) == 0;
      final nextPtr = ptr + Const(1, width: width);
      if (isPow2) {
        return nextPtr;
      }
      return mux(
        ptr.eq(Const(depth - 1, width: width)),
        Const(0, width: width),
        nextPtr,
      );
    }

    // Per-channel full flags (strictly registered -> zero combinational loop)
    final rxFullVec = List<Logic>.generate(
      numChannels,
      (i) => rxCntQ[i].gte(Const(fifoDepth, width: rxCntWidth)),
    );

    // Selected-channel status & route lookup
    final activeRxCnt = balancedMux(
      rxCntQ,
      selChQ,
      Const(0, width: rxCntWidth),
    );
    final nextSelChIdx = (numChannels <= 1)
        ? Const(0, width: 1)
        : wdata.slice(chWidth - 1, 0);
    final nextSelRxRdPtr = balancedMux(
      rxRdPtrQ,
      nextSelChIdx,
      Const(0, width: rxPtrWidth),
    );
    final activeDstCore = balancedMux(
      chDstCoreQ,
      selChQ,
      Const(coreId, width: 8),
    );
    final activeDstCh = balancedMux(
      chDstChQ,
      selChQ,
      selChQ.zeroExtend(8),
    );
    final activeChValid = balancedMux(chValidQ, selChQ, Const(0));

    // Incoming network DATA channel decode & backpressure
    final inChValid = inDstCh.lt(Const(numChannels, width: 8));
    final inChIdx = (numChannels <= 1)
        ? Const(0, width: 1)
        : inDstCh.slice(chWidth - 1, 0);
    final inChWrPtr = balancedMux(
      rxWrPtrQ,
      inChIdx,
      Const(0, width: rxPtrWidth),
    );
    final inChFull = balancedMux(rxFullVec, inChIdx, Const(1));

    // FIFO occupancy & backpressure flags
    final rxNotEmpty = ~activeRxCnt.eq(0);
    final rxFull = activeRxCnt.gte(Const(fifoDepth, width: rxCntWidth));

    final txEmpty = txCntQ.eq(0);
    final txFull = txCntQ.gte(Const(this.txFifoDepth, width: txCntWidth));
    final txReady = ~txFull;

    final mboxEmpty = mboxCntQ.eq(0);
    final mboxNotEmpty = ~mboxEmpty;
    final mboxFull =
        mboxCntQ.gte(Const(this.mboxFifoDepth, width: mboxCntWidth));

    final rxCanAccept = inChValid & (~inChFull);
    final mboxCanAccept = ~mboxFull;
    inReadyOut <= mux(inType, mboxCanAccept, rxCanAccept);

    // Shared 1W1R distributed RAM for all channels' RX FIFOs
    final inIsMbox = inValid & inType;
    final inIsData = inValid & (~inType);
    final rxPushAny = inIsData & rxCanAccept;
    final rxRamWaddr = (numChannels <= 1)
        ? inChWrPtr
        : [inChIdx, inChWrPtr].swizzle();
    final rxRamRaddr = (numChannels <= 1)
        ? activeRxRdPtrQ
        : [selChQ, activeRxRdPtrQ].swizzle();
    final rxRam = NocFifoRam(
      clk: clk,
      waddr: rxRamWaddr,
      wdata: inPayload,
      we: rxPushAny,
      raddr: rxRamRaddr,
      addrWidth: (numChannels <= 1) ? rxPtrWidth : (chWidth + rxPtrWidth),
      dataWidth: MiniRISC4Constants.dataWidth,
      name: '${name}_rx_ram',
    );
    final activeRxData = rxRam.rdata;

    // MMIO address decode
    final isTxData = addr.eq(
        Const(MiniRISC4Constants.addrNocTxData, width: MiniRISC4Constants.addrWidth));
    final isSelCh = addr.eq(
        Const(MiniRISC4Constants.addrNocSelCh, width: MiniRISC4Constants.addrWidth));
    final isRxData = addr.eq(
        Const(MiniRISC4Constants.addrNocRxData, width: MiniRISC4Constants.addrWidth));
    final isRxTryR = addr.eq(
        Const(MiniRISC4Constants.addrNocRxTryR, width: MiniRISC4Constants.addrWidth));
    final isMboxSend = addr.eq(
        Const(MiniRISC4Constants.addrNocMboxSend, width: MiniRISC4Constants.addrWidth));
    final isMboxData = addr.eq(
        Const(MiniRISC4Constants.addrNocMboxData, width: MiniRISC4Constants.addrWidth));
    final isChCfg0 = addr.eq(
        Const(MiniRISC4Constants.addrNocChCfg0, width: MiniRISC4Constants.addrWidth));
    final isChCfg1 = addr.eq(
        Const(MiniRISC4Constants.addrNocChCfg1, width: MiniRISC4Constants.addrWidth));

    final isRxPop = re & (isRxData | isRxTryR) & rxNotEmpty;
    final isMboxPop = re & isMboxData & mboxNotEmpty;
    final isTxWrite = we & isTxData & txReady;
    final isMboxWrite = we & isMboxSend & txReady;
    final txPush = isTxWrite | isMboxWrite;
    final txPop = (~txEmpty) & outReady;
    final mboxPush = inIsMbox & mboxCanAccept;

    // Effective TX route (unconfigured channel loops back to local core/channel)
    final effDstCore = mux(activeChValid, activeDstCore, Const(coreId, width: 8));
    final effDstCh = mux(activeChValid, activeDstCh, selChQ.zeroExtend(8));

    // Multi-word TX FIFO RAM: {type[0], dstCore[7:0], dstCh[7:0], srcCh[7:0], payload[15:0]} = 41 bits
    final txEntryWdata = [
      isMboxWrite,
      effDstCore,
      effDstCh,
      selChQ.zeroExtend(8),
      wdata,
    ].swizzle();
    final txRam = NocFifoRam(
      clk: clk,
      waddr: txWrPtrQ,
      wdata: txEntryWdata,
      we: txPush,
      raddr: txRdPtrQ,
      addrWidth: txPtrWidth,
      dataWidth: 41,
      name: '${name}_tx_ram',
    );

    // Multi-word MBOX RX FIFO RAM: {srcCore[7:0], srcCh[7:0], payload[15:0]} = 32 bits
    final mboxEntryWdata = [inSrcCore, inSrcCh, inPayload].swizzle();
    final mboxRam = NocFifoRam(
      clk: clk,
      waddr: mboxWrPtrQ,
      wdata: mboxEntryWdata,
      we: mboxPush,
      raddr: mboxRdPtrQ,
      addrWidth: mboxPtrWidth,
      dataWidth: 32,
      name: '${name}_mbox_ram',
    );
    final mboxHeadData = mboxRam.rdata.slice(15, 0);
    final mboxHeadSrc = mboxRam.rdata.slice(31, 16);

    // Status and MMIO read values
    // NOC_RX_STAT layout:
    //   [0]    rx_not_empty
    //   [1]    rx_full
    //   [2]    tx_ready (~tx_full)
    //   [3]    tx_empty
    //   [4]    mbox_not_empty
    //   [5]    mbox_full
    //   [7:6]  reserved (0)
    //   [15:8] activeRxCnt (saturated/zero-extended to 8 bits)
    final activeRxCnt8 = rxCntWidth >= 8
        ? activeRxCnt.slice(7, 0)
        : activeRxCnt.zeroExtend(8);
    final rxStatVal = [
      activeRxCnt8,
      Const(0, width: 2),
      mboxFull,
      mboxNotEmpty,
      txEmpty,
      txReady,
      rxFull,
      rxNotEmpty,
    ].swizzle();
    final tryRVal =
        mux(rxNotEmpty, activeRxData, Const(0, width: MiniRISC4Constants.dataWidth));
    final mboxDataVal = mux(
        mboxNotEmpty, mboxHeadData, Const(0, width: MiniRISC4Constants.dataWidth));
    final mboxSrcVal = mux(mboxNotEmpty, mboxHeadSrc, lastMboxSrcQ);

    final readMux = Logic(name: 'readMux', width: MiniRISC4Constants.dataWidth);
    Combinational([
      readMux < Const(0, width: MiniRISC4Constants.dataWidth),
      Case(addr, [
        CaseItem(
          Const(MiniRISC4Constants.addrNocSelCh, width: MiniRISC4Constants.addrWidth),
          [readMux < selChQ.zeroExtend(MiniRISC4Constants.dataWidth)],
        ),
        CaseItem(
          Const(MiniRISC4Constants.addrNocRxData, width: MiniRISC4Constants.addrWidth),
          [readMux < tryRVal],
        ),
        CaseItem(
          Const(MiniRISC4Constants.addrNocRxStat, width: MiniRISC4Constants.addrWidth),
          [readMux < rxStatVal],
        ),
        CaseItem(
          Const(MiniRISC4Constants.addrNocRxTryR, width: MiniRISC4Constants.addrWidth),
          [readMux < tryRVal],
        ),
        CaseItem(
          Const(MiniRISC4Constants.addrNocMboxData, width: MiniRISC4Constants.addrWidth),
          [readMux < mboxDataVal],
        ),
        CaseItem(
          Const(MiniRISC4Constants.addrNocMboxSrc, width: MiniRISC4Constants.addrWidth),
          [readMux < mboxSrcVal],
        ),
        CaseItem(
          Const(MiniRISC4Constants.addrNocChCfg0, width: MiniRISC4Constants.addrWidth),
          [readMux < [activeDstCore, activeDstCh].swizzle()],
        ),
        CaseItem(
          Const(MiniRISC4Constants.addrNocChCfg1, width: MiniRISC4Constants.addrWidth),
          [readMux < activeChValid.zeroExtend(MiniRISC4Constants.dataWidth)],
        ),
        CaseItem(
          Const(MiniRISC4Constants.addrNocInfo, width: MiniRISC4Constants.addrWidth),
          [
            readMux <
                Const(
                  ((numChannels & 0xFF) << 8) | (numCores & 0xFF),
                  width: MiniRISC4Constants.dataWidth,
                ),
          ],
        ),
      ]),
    ]);

    rdataOut <= mux(re, readMux, mmioRdataQ);
    rdataRegOut <= mmioRdataQ;
    outValid <= ~txEmpty;
    outType <= txRam.rdata[40];
    outDstCore <= txRam.rdata.slice(39, 32);
    outDstCh <= txRam.rdata.slice(31, 24);
    outSrcCh <= txRam.rdata.slice(23, 16);
    outPayload <= txRam.rdata.slice(15, 0);
    trapReq <= mboxNotEmpty;

    final resetVals = <Logic, dynamic>{
      selChQ: 0,
      txRdPtrQ: 0,
      txWrPtrQ: 0,
      txCntQ: 0,
      mboxRdPtrQ: 0,
      mboxWrPtrQ: 0,
      mboxCntQ: 0,
      lastMboxSrcQ: 0,
      mmioRdataQ: 0,
      activeRxRdPtrQ: 0,
      for (var i = 0; i < numChannels; i++) ...{
        chDstCoreQ[i]: coreId,
        chDstChQ[i]: i,
        chValidQ[i]: 0,
        rxRdPtrQ[i]: 0,
        rxWrPtrQ[i]: 0,
        rxCntQ[i]: 0,
      },
    };

    final seqOps = <Conditional>[
      mmioRdataQ < mux(re, readMux, Const(0, width: MiniRISC4Constants.dataWidth)),
      If(we & isSelCh, then: [
        if (numChannels <= 1)
          selChQ < 0
        else
          selChQ < wdata.slice(chWidth - 1, 0),
        activeRxRdPtrQ < nextSelRxRdPtr,
      ], orElse: [
        If(isRxPop, then: [
          activeRxRdPtrQ < incWrap(activeRxRdPtrQ, fifoDepth, rxPtrWidth),
        ]),
      ]),
      // TX FIFO pointer & count updates
      If(txPush, then: [
        txWrPtrQ < incWrap(txWrPtrQ, this.txFifoDepth, txPtrWidth),
      ]),
      If(txPop, then: [
        txRdPtrQ < incWrap(txRdPtrQ, this.txFifoDepth, txPtrWidth),
      ]),
      If(txPush & (~txPop), then: [
        txCntQ < txCntQ + Const(1, width: txCntWidth),
      ], orElse: [
        If((~txPush) & txPop, then: [
          txCntQ < txCntQ - Const(1, width: txCntWidth),
        ]),
      ]),
      // MBOX RX FIFO pointer & count updates
      If(mboxPush, then: [
        mboxWrPtrQ < incWrap(mboxWrPtrQ, this.mboxFifoDepth, mboxPtrWidth),
      ]),
      If(isMboxPop, then: [
        mboxRdPtrQ < incWrap(mboxRdPtrQ, this.mboxFifoDepth, mboxPtrWidth),
        lastMboxSrcQ < mboxHeadSrc,
      ]),
      If(mboxPush & (~isMboxPop), then: [
        mboxCntQ < mboxCntQ + Const(1, width: mboxCntWidth),
      ], orElse: [
        If((~mboxPush) & isMboxPop, then: [
          mboxCntQ < mboxCntQ - Const(1, width: mboxCntWidth),
        ]),
      ]),
    ];

    for (var i = 0; i < numChannels; i++) {
      final selIsI = (numChannels <= 1) ? Const(1) : selChQ.eq(i);
      final inIsI = (numChannels <= 1) ? Const(1) : inChIdx.eq(i);
      final doPush = rxPushAny & inIsI;
      final doPop = isRxPop & selIsI;

      seqOps.addAll([
        If(we & isChCfg0 & selIsI, then: [
          chDstCoreQ[i] < wdata.slice(15, 8),
          chDstChQ[i] < wdata.slice(7, 0),
        ]),
        If(we & isChCfg1 & selIsI, then: [
          chValidQ[i] < wdata[0],
        ]),
        If(doPush, then: [
          rxWrPtrQ[i] < incWrap(rxWrPtrQ[i], fifoDepth, rxPtrWidth),
        ]),
        If(doPop, then: [
          rxRdPtrQ[i] < incWrap(rxRdPtrQ[i], fifoDepth, rxPtrWidth),
        ]),
        If(doPush & (~doPop), then: [
          rxCntQ[i] < rxCntQ[i] + Const(1, width: rxCntWidth),
        ], orElse: [
          If((~doPush) & doPop, then: [
            rxCntQ[i] < rxCntQ[i] - Const(1, width: rxCntWidth),
          ]),
        ]),
      ]);
    }

    Sequential(clk, reset: reset, resetValues: resetVals, seqOps);
  }
}

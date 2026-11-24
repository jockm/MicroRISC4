import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'memory_factory.dart';

/// Synthesizable 1-write / 1-read synchronous-write, asynchronous-read RAM
/// backing the per-core RX FIFO. Infers 4x ECP5 TRELLIS_DPR16X4 slices for a
/// 16x16 RX FIFO on FPGA and a compact 1W1R register file on ASIC.
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

/// Ultra-lean direct-addressed per-core NoC Network Interface (`0x0020`–`0x002A`).
///
/// Designed for high core density and >100 MHz ECP5 / GHz ASIC scaling:
/// - **1 shared multi-word RX FIFO** (e.g. 16x16 = 4 `TRELLIS_DPR16X4` slices)
/// - **1-entry registered TX flit** (1.0 word/cycle peak TX throughput, 0 RAM)
/// - **1-entry registered Doorbell/MBOX** (fires hardware Trap 14, 0 RAM)
/// - **Direct target core register (`NOC_DST_CORE` at `0x0021`)** — zero channel tables
/// - **Narrow `coreIdWidth`-bit ring IDs** and registered `netInReady` backpressure
class NocRouterNi extends Module {
  final int coreId;
  final int numCores;
  final int fifoDepth;
  final int coreIdWidth;
  final MemoryTarget memoryTarget;

  static int idWidthForCores(int numCores) =>
      (numCores <= 1) ? 1 : (numCores - 1).bitLength;

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
    required Logic netInPayload,
    required Logic netOutReady,
    this.coreId = 0,
    this.numCores = 1,
    this.fifoDepth = 16,
    this.memoryTarget = MemoryTarget.fpgaEcp5,
    super.name = 'noc_router_ni',
  }) : coreIdWidth = idWidthForCores(numCores) {
    assert(numCores >= 1, 'numCores must be >= 1');
    assert(fifoDepth >= 2, 'fifoDepth must be >= 2');

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final addr =
        addInput('mmioAddr', mmioAddr, width: MicroRISC4Constants.addrWidth);
    final wdata =
        addInput('mmioWdata', mmioWdata, width: MicroRISC4Constants.dataWidth);
    final we = addInput('mmioWe', mmioWe);
    final re = addInput('mmioRe', mmioRe);
    final inValid = addInput('netInValid', netInValid);
    final inType = addInput('netInType', netInType);
    final inSrcCore = addInput('netInSrcCore', netInSrcCore, width: coreIdWidth);
    final inPayload = addInput('netInPayload', netInPayload,
        width: MicroRISC4Constants.dataWidth);
    final outReady = addInput('netOutReady', netOutReady);

    final rdataOut =
        addOutput('mmioRdata', width: MicroRISC4Constants.dataWidth);
    final rdataRegOut =
        addOutput('mmioRdataReg', width: MicroRISC4Constants.dataWidth);
    final inReadyOut = addOutput('netInReady');
    final outValid = addOutput('netOutValid');
    final outType = addOutput('netOutType');
    final outDstCore = addOutput('netOutDstCore', width: coreIdWidth);
    final outPayload =
        addOutput('netOutPayload', width: MicroRISC4Constants.dataWidth);
    final trapReq = addOutput('mboxTrapReq');

    final rxPtrWidth = (fifoDepth - 1).bitLength;
    final rxCntWidth = fifoDepth.bitLength;

    // Direct destination core register + bounds-valid guard
    final dstCoreQ = Logic(name: 'dstCoreQ', width: coreIdWidth);
    final dstValidQ = Logic(name: 'dstValidQ');

    // Shared multi-word RX FIFO pointers & occupancy counter
    final rxRdPtrQ = Logic(name: 'rxRdPtrQ', width: rxPtrWidth);
    final rxWrPtrQ = Logic(name: 'rxWrPtrQ', width: rxPtrWidth);
    final rxCntQ = Logic(name: 'rxCntQ', width: rxCntWidth);

    // 1-entry registered TX flit (1.0 word/cycle when outReady=1)
    final txValidQ = Logic(name: 'txValidQ');
    final txTypeQ = Logic(name: 'txTypeQ');
    final txDstCoreQ = Logic(name: 'txDstCoreQ', width: coreIdWidth);
    final txPayloadQ =
        Logic(name: 'txPayloadQ', width: MicroRISC4Constants.dataWidth);

    // 1-entry registered Doorbell / Priority MBOX
    final mboxValidQ = Logic(name: 'mboxValidQ');
    final mboxDataQ =
        Logic(name: 'mboxDataQ', width: MicroRISC4Constants.dataWidth);
    final mboxSrcQ = Logic(name: 'mboxSrcQ', width: coreIdWidth);

    // 1-cycle held MMIO read register for 2-cycle CpuCore Port B reads
    final mmioRdataQ =
        Logic(name: 'mmioRdataQ', width: MicroRISC4Constants.dataWidth);

    Logic incWrap(Logic ptr, int depth, int width) {
      final isPow2 = (depth & (depth - 1)) == 0;
      final nextPtr = ptr + Const(1, width: width);
      if (isPow2) return nextPtr;
      return mux(
        ptr.eq(Const(depth - 1, width: width)),
        Const(0, width: width),
        nextPtr,
      );
    }

    // Registered occupancy & backpressure flags
    final rxNotEmpty = ~rxCntQ.eq(0);
    final rxFull = rxCntQ.gte(Const(fifoDepth, width: rxCntWidth));
    final txReady = (~txValidQ) | outReady;
    final txEmpty = ~txValidQ;
    final mboxCanAccept = ~mboxValidQ;
    final rxCanAccept = ~rxFull;

    // Strictly registered backpressure (zero combinational loop into ring)
    inReadyOut <= mux(inType, mboxCanAccept, rxCanAccept);

    // Shared RX FIFO storage (1W1R distributed RAM on ECP5, pure flop regfile on ASIC)
    final rxPush = inValid & (~inType) & rxCanAccept;
    final rxRamRdata = MemoryFactory.createSmallRam(
      target: memoryTarget,
      clk: clk,
      waddr: rxWrPtrQ,
      wdata: inPayload,
      we: rxPush,
      raddr: rxRdPtrQ,
      addrWidth: rxPtrWidth,
      dataWidth: MicroRISC4Constants.dataWidth,
      name: '${name}_rx_ram',
    );

    // Fast 4-bit MMIO offset decode (caller gates we/re to 0x0020..0x002A)
    final off = addr.slice(3, 0);
    final isTxData = off.eq(Const(0x0, width: 4));
    final isDstCore = off.eq(Const(0x1, width: 4));
    final isRxData = off.eq(Const(0x2, width: 4));
    final isRxTryR = off.eq(Const(0x4, width: 4));
    final isMboxSend = off.eq(Const(0x5, width: 4));
    final isMboxData = off.eq(Const(0x6, width: 4));

    final rxPop = re & (isRxData | isRxTryR) & rxNotEmpty;
    final mboxPop = re & isMboxData & mboxValidQ;
    final mboxPush = inValid & inType & mboxCanAccept;

    final txWriteData = we & isTxData & txReady & dstValidQ;
    final txWriteMbox = we & isMboxSend & txReady & dstValidQ;
    final txPush = txWriteData | txWriteMbox;
    final txDrain = txValidQ & outReady;

    // NOC_STAT (0x0023):
    //   [0]    rx_not_empty
    //   [1]    rx_full
    //   [2]    tx_ready
    //   [3]    tx_empty
    //   [4]    mbox_valid
    //   [7:5]  0
    //   [15:8] rx_count
    final rxCnt8 =
        rxCntWidth >= 8 ? rxCntQ.slice(7, 0) : rxCntQ.zeroExtend(8);
    final rxStatVal = [
      rxCnt8,
      Const(0, width: 3),
      mboxValidQ,
      txEmpty,
      txReady,
      rxFull,
      rxNotEmpty,
    ].swizzle();
    final rxPopVal =
        mux(rxNotEmpty, rxRamRdata, Const(0, width: MicroRISC4Constants.dataWidth));
    final mboxDataVal =
        mux(mboxValidQ, mboxDataQ, Const(0, width: MicroRISC4Constants.dataWidth));
    final nocInfoVal = ((fifoDepth & 0xFF) << 8) | (numCores & 0xFF);

    final readMux = Logic(name: 'readMux', width: MicroRISC4Constants.dataWidth);
    Combinational([
      readMux < Const(0, width: MicroRISC4Constants.dataWidth),
      Case(off, [
        CaseItem(Const(0x1, width: 4), [
          readMux < dstCoreQ.zeroExtend(MicroRISC4Constants.dataWidth),
        ]),
        CaseItem(Const(0x2, width: 4), [readMux < rxPopVal]),
        CaseItem(Const(0x3, width: 4), [readMux < rxStatVal]),
        CaseItem(Const(0x4, width: 4), [readMux < rxPopVal]),
        CaseItem(Const(0x6, width: 4), [readMux < mboxDataVal]),
        CaseItem(Const(0x7, width: 4), [
          readMux < mboxSrcQ.zeroExtend(MicroRISC4Constants.dataWidth),
        ]),
        CaseItem(Const(0xA, width: 4), [
          readMux < Const(nocInfoVal, width: MicroRISC4Constants.dataWidth),
        ]),
      ]),
    ]);

    rdataOut <= mux(re, readMux, mmioRdataQ);
    rdataRegOut <= mmioRdataQ;
    outValid <= txValidQ;
    outType <= txTypeQ;
    outDstCore <= txDstCoreQ;
    outPayload <= txPayloadQ;
    trapReq <= mboxValidQ;

    final wdataDstValid = wdata.lt(Const(numCores, width: MicroRISC4Constants.dataWidth));

    Sequential(clk, reset: reset, resetValues: {
      dstCoreQ: coreId & ((1 << coreIdWidth) - 1),
      dstValidQ: 1,
      rxRdPtrQ: 0,
      rxWrPtrQ: 0,
      rxCntQ: 0,
      txValidQ: 0,
      txTypeQ: 0,
      txDstCoreQ: 0,
      txPayloadQ: 0,
      mboxValidQ: 0,
      mboxDataQ: 0,
      mboxSrcQ: 0,
      mmioRdataQ: 0,
    }, [
      mmioRdataQ < mux(re, readMux, Const(0, width: MicroRISC4Constants.dataWidth)),
      // Target destination core selection (0x0021)
      If(we & isDstCore, then: [
        dstCoreQ < wdata.slice(coreIdWidth - 1, 0),
        dstValidQ < wdataDstValid,
      ]),
      // Shared RX FIFO pointers & occupancy
      If(rxPush, then: [
        rxWrPtrQ < incWrap(rxWrPtrQ, fifoDepth, rxPtrWidth),
      ]),
      If(rxPop, then: [
        rxRdPtrQ < incWrap(rxRdPtrQ, fifoDepth, rxPtrWidth),
      ]),
      If(rxPush & (~rxPop), then: [
        rxCntQ < rxCntQ + Const(1, width: rxCntWidth),
      ], orElse: [
        If((~rxPush) & rxPop, then: [
          rxCntQ < rxCntQ - Const(1, width: rxCntWidth),
        ]),
      ]),
      // 1-entry TX flit register (simultaneous drain + push supported)
      If(txPush, then: [
        txValidQ < 1,
        txTypeQ < txWriteMbox,
        txDstCoreQ < dstCoreQ,
        txPayloadQ < wdata,
      ], orElse: [
        If(txDrain, then: [
          txValidQ < 0,
        ]),
      ]),
      // 1-entry Doorbell / Priority MBOX register
      If(mboxPush, then: [
        mboxValidQ < 1,
        mboxDataQ < inPayload,
        mboxSrcQ < inSrcCore,
      ], orElse: [
        If(mboxPop, then: [
          mboxValidQ < 0,
        ]),
      ]),
    ]);
  }
}

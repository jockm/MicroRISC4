import 'package:rohd/rohd.dart';
import 'constants.dart';

class NocRouterNi extends Module {
  final int coreId;
  final int numChannels;
  final int fifoDepth;

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
    this.numChannels = 4,
    this.fifoDepth = 4,
    super.name = 'noc_router_ni',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final addr = addInput('mmioAddr', mmioAddr, width: MiniRISC4Constants.addrWidth);
    final wdata = addInput('mmioWdata', mmioWdata, width: MiniRISC4Constants.dataWidth);
    final we = addInput('mmioWe', mmioWe);
    final re = addInput('mmioRe', mmioRe);
    final inValid = addInput('netInValid', netInValid);
    final inType = addInput('netInType', netInType);
    final inSrcCore = addInput('netInSrcCore', netInSrcCore, width: 8);
    final inSrcCh = addInput('netInSrcCh', netInSrcCh, width: 8);
    final inDstCh = addInput('netInDstCh', netInDstCh, width: 8);
    final inPayload = addInput('netInPayload', netInPayload, width: MiniRISC4Constants.dataWidth);
    final outReady = addInput('netOutReady', netOutReady);

    final rdataOut = addOutput('mmioRdata', width: MiniRISC4Constants.dataWidth);
    final outValid = addOutput('netOutValid');
    final outType = addOutput('netOutType');
    final outDstCore = addOutput('netOutDstCore', width: 8);
    final outDstCh = addOutput('netOutDstCh', width: 8);
    final outPayload = addOutput('netOutPayload', width: MiniRISC4Constants.dataWidth);
    final trapReq = addOutput('mboxTrapReq');

    final chWidth = (numChannels <= 1) ? 1 : (numChannels - 1).bitLength;
    final selChQ = Logic(name: 'selChQ', width: chWidth);
    final chDstCoreQ = List.generate(numChannels, (i) => Logic(name: 'chDstCoreQ_\$i', width: 8));
    final chDstChQ = List.generate(numChannels, (i) => Logic(name: 'chDstChQ_\$i', width: 8));
    final chValidQ = List.generate(numChannels, (i) => Logic(name: 'chValidQ_\$i'));
    final rxDataQ = List.generate(numChannels, (i) => Logic(name: 'rxDataQ_\$i', width: MiniRISC4Constants.dataWidth));
    final rxCntQ = List.generate(numChannels, (i) => Logic(name: 'rxCntQ_\$i', width: 8));

    final mboxDataQ = Logic(name: 'mboxDataQ', width: MiniRISC4Constants.dataWidth);
    final mboxValidQ = Logic(name: 'mboxValidQ');
    final mboxSrcQ = Logic(name: 'mboxSrcQ', width: MiniRISC4Constants.dataWidth);
    final mboxTrapQ = Logic(name: 'mboxTrapQ');

    final outValidQ = Logic(name: 'outValidQ');
    final outTypeQ = Logic(name: 'outTypeQ');
    final outDstCoreQ = Logic(name: 'outDstCoreQ', width: 8);
    final outDstChQ = Logic(name: 'outDstChQ', width: 8);
    final outPayloadQ = Logic(name: 'outPayloadQ', width: MiniRISC4Constants.dataWidth);

    Logic selCh(List<Logic> items, Logic fallback) {
      var cur = fallback;
      for (var i = numChannels - 1; i >= 0; i--) {
        cur = mux(selChQ.eq(i), items[i], cur);
      }
      return cur;
    }

    final activeRxCnt = selCh(rxCntQ, Const(0, width: 8));
    final activeRxData = selCh(rxDataQ, Const(0, width: MiniRISC4Constants.dataWidth));
    final activeDstCore = selCh(chDstCoreQ, Const(coreId, width: 8));
    final activeDstCh = selCh(chDstChQ, selChQ.zeroExtend(8));
    final activeChValid = selCh(chValidQ, Const(0));

    final rxNotEmpty = ~activeRxCnt.eq(0);
    final rxFull = activeRxCnt.gte(Const(fifoDepth, width: 8));
    final txReady = ~outValidQ | outReady;
    final rxStatVal = [activeRxCnt, Const(0, width: 5), txReady, rxFull, rxNotEmpty].swizzle();
    final tryRVal = mux(rxNotEmpty, activeRxData, Const(0, width: MiniRISC4Constants.dataWidth));
    final mboxDataVal = mux(mboxValidQ, mboxDataQ, Const(0, width: MiniRISC4Constants.dataWidth));

    final readMux = Logic(name: 'readMux', width: MiniRISC4Constants.dataWidth);
    Combinational([
      readMux < Const(0, width: MiniRISC4Constants.dataWidth),
      Case(addr, [
        CaseItem(Const(MiniRISC4Constants.addrNocSelCh, width: MiniRISC4Constants.addrWidth), [
          readMux < selChQ.zeroExtend(MiniRISC4Constants.dataWidth),
        ]),
        CaseItem(Const(MiniRISC4Constants.addrNocRxData, width: MiniRISC4Constants.addrWidth), [
          readMux < tryRVal,
        ]),
        CaseItem(Const(MiniRISC4Constants.addrNocRxStat, width: MiniRISC4Constants.addrWidth), [
          readMux < rxStatVal,
        ]),
        CaseItem(Const(MiniRISC4Constants.addrNocRxTryR, width: MiniRISC4Constants.addrWidth), [
          readMux < tryRVal,
        ]),
        CaseItem(Const(MiniRISC4Constants.addrNocMboxData, width: MiniRISC4Constants.addrWidth), [
          readMux < mboxDataVal,
        ]),
        CaseItem(Const(MiniRISC4Constants.addrNocMboxSrc, width: MiniRISC4Constants.addrWidth), [
          readMux < mboxSrcQ,
        ]),
      ]),
    ]);

    rdataOut <= mux(re, readMux, Const(0, width: MiniRISC4Constants.dataWidth));
    outValid <= outValidQ;
    outType <= outTypeQ;
    outDstCore <= outDstCoreQ;
    outDstCh <= outDstChQ;
    outPayload <= outPayloadQ;
    trapReq <= mboxTrapQ;

    final isTxData = addr.eq(Const(MiniRISC4Constants.addrNocTxData, width: MiniRISC4Constants.addrWidth));
    final isSelCh = addr.eq(Const(MiniRISC4Constants.addrNocSelCh, width: MiniRISC4Constants.addrWidth));
    final isRxData = addr.eq(Const(MiniRISC4Constants.addrNocRxData, width: MiniRISC4Constants.addrWidth));
    final isRxTryR = addr.eq(Const(MiniRISC4Constants.addrNocRxTryR, width: MiniRISC4Constants.addrWidth));
    final isMboxSend = addr.eq(Const(MiniRISC4Constants.addrNocMboxSend, width: MiniRISC4Constants.addrWidth));
    final isMboxData = addr.eq(Const(MiniRISC4Constants.addrNocMboxData, width: MiniRISC4Constants.addrWidth));
    final isChCfg0 = addr.eq(Const(MiniRISC4Constants.addrNocChCfg0, width: MiniRISC4Constants.addrWidth));
    final isChCfg1 = addr.eq(Const(MiniRISC4Constants.addrNocChCfg1, width: MiniRISC4Constants.addrWidth));

    final isRxPop = re & (isRxData | isRxTryR) & rxNotEmpty;
    final isMboxPop = re & isMboxData & mboxValidQ;
    final inIsMbox = inValid & inType;
    final inIsData = inValid & (~inType);
    final isTxWrite = we & isTxData & txReady;
    final isMboxWrite = we & isMboxSend & txReady;

    final effDstCore = mux(activeChValid, activeDstCore, Const(coreId, width: 8));
    final effDstCh = mux(activeChValid, activeDstCh, selChQ.zeroExtend(8));

    final nextRxData = List<Logic>.generate(numChannels, (i) {
      final doPush = inIsData & inDstCh.eq(i) & (~rxCntQ[i].gte(Const(fifoDepth, width: 8)));
      final doPop = isRxPop & selChQ.eq(i);
      return mux(
        doPush,
        inPayload,
        mux(doPop, Const(0, width: MiniRISC4Constants.dataWidth), rxDataQ[i]),
      );
    });

    final nextRxCnt = List<Logic>.generate(numChannels, (i) {
      final doPush = inIsData & inDstCh.eq(i) & (~rxCntQ[i].gte(Const(fifoDepth, width: 8)));
      final doPop = isRxPop & selChQ.eq(i);
      return mux(
        doPush & (~doPop),
        rxCntQ[i] + Const(1, width: 8),
        mux((~doPush) & doPop, rxCntQ[i] - Const(1, width: 8), rxCntQ[i]),
      );
    });

    final resetVals = <Logic, dynamic>{
      selChQ: 0,
      mboxDataQ: 0,
      mboxValidQ: 0,
      mboxSrcQ: 0,
      mboxTrapQ: 0,
      outValidQ: 0,
      outTypeQ: 0,
      outDstCoreQ: 0,
      outDstChQ: 0,
      outPayloadQ: 0,
      for (var i = 0; i < numChannels; i++) ...{
        chDstCoreQ[i]: coreId,
        chDstChQ[i]: i,
        chValidQ[i]: 0,
        rxDataQ[i]: 0,
        rxCntQ[i]: 0,
      },
    };

    Sequential(clk, reset: reset, resetValues: resetVals, [
      If(outValidQ & outReady, then: [outValidQ < 0]),
      If(we & isSelCh, then: [selChQ < wdata.slice(chWidth - 1, 0)]),
      for (var i = 0; i < numChannels; i++) ...[
        If(we & isChCfg0 & selChQ.eq(i), then: [
          chDstCoreQ[i] < wdata.slice(15, 8),
          chDstChQ[i] < wdata.slice(7, 0),
        ]),
        If(we & isChCfg1 & selChQ.eq(i), then: [
          chValidQ[i] < wdata[0],
        ]),
        rxDataQ[i] < nextRxData[i],
        rxCntQ[i] < nextRxCnt[i],
      ],
      If(
        isMboxWrite,
        then: [
          outValidQ < 1,
          outTypeQ < 1,
          outDstCoreQ < effDstCore,
          outDstChQ < effDstCh,
          outPayloadQ < wdata,
        ],
        orElse: [
          If(isTxWrite, then: [
            outValidQ < 1,
            outTypeQ < 0,
            outDstCoreQ < effDstCore,
            outDstChQ < effDstCh,
            outPayloadQ < wdata,
          ]),
        ],
      ),
      If(
        inIsMbox,
        then: [
          mboxDataQ < inPayload,
          mboxValidQ < 1,
          mboxSrcQ < [inSrcCore, inSrcCh].swizzle(),
          mboxTrapQ < 1,
        ],
        orElse: [
          If(isMboxPop, then: [
            mboxValidQ < 0,
            mboxTrapQ < 0,
          ]),
        ],
      ),
    ]);
  }
}

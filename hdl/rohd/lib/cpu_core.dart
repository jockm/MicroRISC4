// ==============================================================================
// FILE: hdl/rohd/lib/cpu_core.dart
// MiniRISC4 16-Bit CPU Core Architecture
// Intel ROHD Implementation (Direct Stride Vector Table + Synchronous TDP BRAM)
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'math_accelerator.dart';
import 'spi_master.dart';
import 'tdp_bram.dart';

class CpuCore extends Module {
  final CpuConfig config;
  late final TdpBram ram;

  static const int _stReset = 0;
  static const int _stFetch = 1;
  static const int _stExec = 2;
  static const int _stMemWait = 3;
  static const int _stMemRd = 4;
  static const int _stFetchLatch = 5;
  static const int _stFetchWait = 6;
  static const int _stMemWait2 = 7;

  CpuCore({
    required Logic clk,
    required Logic rstN,
    Logic? mmioRxData,
    Logic? mmioTxStatus,
    Logic? extTrapReq,
    Logic? extTrapNum,
    Logic? spiMiso,
    Logic? nocRdata,
    Logic? icReqReady,
    Logic? icRespValid,
    Logic? icRespData,
    Logic? dcReqReady,
    Logic? dcRespValid,
    Logic? dcRespData,
    this.config = const CpuConfig(),
    String? initHexFile,
    Map<int, int>? initialMemory,
    super.name = 'cpu_core',
  }) {
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);

    // Conditional Peripheral Inputs
    final Logic rxData;
    final Logic txStatus;
    if (config.enableUart) {
      rxData = addInput('mmio_rx_data', mmioRxData ?? Const(0, width: 16),
          width: 16);
      txStatus = addInput('mmio_tx_status', mmioTxStatus ?? Const(0, width: 16),
          width: 16);
    } else {
      rxData = Const(0, width: 16);
      txStatus = Const(0, width: 16);
    }

    final Logic crossTrapReq;
    final Logic crossTrapNum;
    if (config.enableCrossTraps) {
      crossTrapReq = addInput('ext_trap_req', extTrapReq ?? Const(0));
      crossTrapNum =
          addInput('ext_trap_num', extTrapNum ?? Const(0, width: 4), width: 4);
    } else {
      crossTrapReq = Const(0);
      crossTrapNum = Const(0, width: 4);
    }

    final Logic spiMisoIn;
    if (config.enableSpi) {
      spiMisoIn = addInput('spi_miso', spiMiso ?? Const(1));
    } else {
      spiMisoIn = Const(1);
    }

    final Logic nocRdataIn;
    if (config.enableNoc) {
      nocRdataIn = addInput('mmio_noc_rdata', nocRdata ?? Const(0, width: 16),
          width: 16);
    } else {
      nocRdataIn = Const(0, width: 16);
    }

    final useExtCache = config.enableSdramCache && config.memWords < 65536;
    final Logic icReqReadyIn;
    final Logic icRespValidIn;
    final Logic icRespDataIn;
    final Logic dcReqReadyIn;
    final Logic dcRespValidIn;
    final Logic dcRespDataIn;
    final Logic? icReqValidOut;
    final Logic? icReqAddrOut;
    final Logic? dcReqValidOut;
    final Logic? dcReqWeOut;
    final Logic? dcReqAddrOut;
    final Logic? dcReqWdataOut;
    if (useExtCache) {
      icReqReadyIn = addInput('ic_req_ready', icReqReady ?? Const(1));
      icRespValidIn = addInput('ic_resp_valid', icRespValid ?? Const(0));
      icRespDataIn = addInput(
          'ic_resp_data', icRespData ?? Const(0, width: 16),
          width: 16);
      dcReqReadyIn = addInput('dc_req_ready', dcReqReady ?? Const(1));
      dcRespValidIn = addInput('dc_resp_valid', dcRespValid ?? Const(0));
      dcRespDataIn = addInput(
          'dc_resp_data', dcRespData ?? Const(0, width: 16),
          width: 16);
      icReqValidOut = addOutput('ic_req_valid');
      icReqAddrOut = addOutput('ic_req_addr', width: 16);
      dcReqValidOut = addOutput('dc_req_valid');
      dcReqWeOut = addOutput('dc_req_we');
      dcReqAddrOut = addOutput('dc_req_addr', width: 16);
      dcReqWdataOut = addOutput('dc_req_wdata', width: 16);
    } else {
      icReqReadyIn = Const(1);
      icRespValidIn = Const(0);
      icRespDataIn = Const(0, width: 16);
      dcReqReadyIn = Const(1);
      dcRespValidIn = Const(0);
      dcRespDataIn = Const(0, width: 16);
      icReqValidOut = null;
      icReqAddrOut = null;
      dcReqValidOut = null;
      dcReqWeOut = null;
      dcReqAddrOut = null;
      dcReqWdataOut = null;
    }

    final spiSck = config.enableSpi ? addOutput('spi_sck') : null;
    final spiMosi = config.enableSpi ? addOutput('spi_mosi') : null;
    final spiCsN = config.enableSpi ? addOutput('spi_cs_n') : null;

    // Module Outputs
    final rxPop = addOutput('mmio_rx_pop');
    final txData = addOutput('mmio_tx_data', width: 8);
    final txStrobe = addOutput('mmio_tx_strobe');
    final extTrapAckOut = addOutput('ext_trap_ack');
    final debugPc = addOutput('debug_pc', width: 16);

    // Architectural & Shadow Registers
    final pc = Logic(name: 'pc', width: 16);
    final r = List.generate(4, (i) => Logic(name: 'r$i', width: 16));
    final shadowR =
        List.generate(4, (i) => Logic(name: 'shadow_r$i', width: 16));
    final instReg = Logic(name: 'inst_reg', width: 16);
    final nextInstReg = Logic(name: 'next_inst_reg', width: 16);
    final slot = Logic(name: 'slot', width: 1);
    final destReg = Logic(name: 'dest_reg', width: 2);
    final state = Logic(name: 'state', width: 3);

    debugPc <= pc;

    // Dual-Port Memory Interface Signals
    final portAAddr = Logic(name: 'port_a_addr', width: 16);
    final portAEn = Logic(name: 'port_a_en');
    final portARdata = Logic(name: 'port_a_rdata', width: 16);

    final portBAddr = Logic(name: 'port_b_addr', width: 16);
    final portBWdata = Logic(name: 'port_b_wdata', width: 16);
    final portBWe = Logic(name: 'port_b_we');
    final portBEn = Logic(name: 'port_b_en');
    final portBRdata = Logic(name: 'port_b_rdata', width: 16);

    // Expose Port B bus for external peripherals / multi-core glue
    final portBAddrOut = addOutput('port_b_addr_out', width: 16);
    final portBWdataOut = addOutput('port_b_wdata_out', width: 16);
    final portBWeOut = addOutput('port_b_we_out');
    final portBEnOut = addOutput('port_b_en_out');
    portBAddrOut <= portBAddr;
    portBWdataOut <= portBWdata;
    portBWeOut <= portBWe;
    portBEnOut <= portBEn;

    // Low MMIO Decodes (shared upper-10-bit zero check keeps decode to 2 LUT4 levels)
    final isMmioPage = portBAddr.slice(15, 6).eq(Const(0, width: 10));
    final mmioOff = portBAddr.slice(5, 0);
    final isMmioCpuid =
        config.enableCpuid ? (isMmioPage & mmioOff.eq(Const(0x0D, width: 6))) : Const(0);
    final isMmioRx = config.enableUart
        ? (isMmioPage & mmioOff.eq(Const(MiniRISC4Constants.addrUartRx, width: 6)))
        : Const(0);
    final isMmioTx = config.enableUart
        ? (isMmioPage & mmioOff.eq(Const(MiniRISC4Constants.addrUartTx, width: 6)))
        : Const(0);

    // Math Accelerator Conditional Instantiation
    Logic? mathRdata;
    Logic? mathMatch;
    if (config.enableMathAccel) {
      final mathUnit = MathAccelerator(
        clk: clk,
        rstN: rstN,
        portBAddr: portBAddr,
        portBWdata: portBWdata,
        portBWe: portBWe,
        portBEn: portBEn,
      );
      mathRdata = mathUnit.rdata;
      mathMatch = mathUnit.match;
    }

    final isMathMatch =
        (config.enableMathAccel && mathMatch != null) ? mathMatch : Const(0);
    Logic? spiRdata;
    Logic? spiMatch;
    if (config.enableSpi) {
      final spiUnit = SpiMaster(
        clk: clk,
        rstN: rstN,
        portBAddr: portBAddr,
        portBWdata: portBWdata,
        portBWe: portBWe,
        portBEn: portBEn,
        spiMiso: spiMisoIn,
      );
      spiRdata = spiUnit.rdata;
      spiMatch = spiUnit.match;
      spiSck! <= spiUnit.spiSck;
      spiMosi! <= spiUnit.spiMosi;
      spiCsN! <= spiUnit.spiCsN;
    }

    final isSpiMatch =
        (config.enableSpi && spiMatch != null) ? spiMatch : Const(0);
    final isNocMatch = config.enableNoc
        ? (isMmioPage &
            mmioOff.gte(Const(MiniRISC4Constants.addrNocTxData, width: 6)) &
            mmioOff.lte(Const(MiniRISC4Constants.addrNocInfo, width: 6)))
        : Const(0);
    final isMmio = isMmioCpuid |
        isMmioRx |
        isMmioTx |
        isMathMatch |
        isSpiMatch |
        isNocMatch;

    // Mask RAM writes when targeting MMIO or external SDRAM-cached addresses
    final addrHigh = config.addrWidth - 1;
    final isExtPortB = useExtCache
        ? ~portBAddr.slice(15, config.addrWidth).eq(
            Const(0, width: 16 - config.addrWidth))
        : Const(0);
    final ramBWe = portBWe & ~isMmio & ~isExtPortB;

    // Instantiate Synthesizable True Dual-Port BRAM
    ram = TdpBram(
      clk: clk,
      portAAddr: portAAddr.slice(addrHigh, 0),
      portAEn: portAEn,
      portBAddr: portBAddr.slice(addrHigh, 0),
      portBWdata: portBWdata,
      portBWe: ramBWe,
      portBEn: portBEn,
      depth: config.memWords,
      dataWidth: 16,
      initHexFile: initHexFile,
      initialMemory: initialMemory,
      name: '${name}_ram',
    );
    portARdata <= ram.portARdata;
    portBRdata <= ram.portBRdata;

    // Direct Stride Vector Table Constants (0x0100, stride 16 words)
    final trapTableBaseConst = Const(config.trapTableBase, width: 16);
    final trapAlignFaultConst =
        Const(config.trapTableBase + (15 << 4), width: 16);

    // Pre-muxed peripheral/MMIO read bus (strictly excludes wide BRAM output)
    final mmioOnlyData = mux(
      isMmioCpuid,
      Const(config.coreId, width: 16),
      mux(
        isMmioRx,
        rxData,
        mux(
          isMmioTx,
          txStatus,
          mux(
            isMathMatch,
            mathRdata ?? Const(0, width: 16),
            mux(
              isSpiMatch,
              spiRdata ?? Const(0, width: 16),
              mux(
                isNocMatch,
                nocRdataIn,
                Const(0, width: 16),
              ),
            ),
          ),
        ),
      ),
    );
    final mmioRdataReg = Logic(name: 'mmio_rdata_reg', width: 16);
    final isMmioRdReg = Logic(name: 'is_mmio_rd_reg');
    final decOpQ = Logic(name: 'dec_op_q', width: 4);
    final decRrQ = Logic(name: 'dec_rr_q', width: 2);
    final decRlQ = Logic(name: 'dec_rl_q', width: 2);
    final decImm4Q = Logic(name: 'dec_imm4_q', width: 4);
    final decUseRegLAsAddAQ = Logic(name: 'dec_use_regl_add_a_q');
    final decUseOneAsAddBQ = Logic(name: 'dec_use_one_add_b_q');
    final decArithSubQ = Logic(name: 'dec_arith_sub_q');
    final illegalSlot1 = Logic(name: 'dec_illegal_slot1_q');
    final extWrPendingQ = Logic(name: 'ext_wr_pending_q');

    // Staged read-data selection: keeps wide BRAM read path out of the MMIO mux tree
    final effectivePortBData = mux(isMmioRdReg, mmioRdataReg, portBRdata);

    // Pulse UART RX Pop on the exact cycle ST_MEM_WAIT2 latches a valid rxData
    rxPop <= (state.eq(Const(_stMemWait2, width: 3)) & isMmioRx & rxData[15]);

    // ALU Helpers
    Logic rotl1(Logic v) => [v.slice(14, 0), v[15]].swizzle();
    Logic rotr1(Logic v) => [v[0], v.slice(15, 1)].swizzle();
    Logic asr1(Logic v) => [v[15], v.slice(15, 1)].swizzle();

    // Balanced 4:1 register-file read muxes (single PFUMX slice per bit)
    Logic getReg(Logic idx) => mux(
          idx[1],
          mux(idx[0], r[3], r[2]),
          mux(idx[0], r[1], r[0]),
        );
    Logic getShadowReg(Logic idx) => mux(
          idx[1],
          mux(idx[0], shadowR[3], shadowR[2]),
          mux(idx[0], shadowR[1], shadowR[0]),
        );

    final resetActive = ~rstN;
    final pcPlus1 = pc + 1;
    final portAAddrPlus1 = portAAddr + 1;

    // Shared ST_EXEC operand decode & single unified 16-bit add/sub ALU
    final regR = getReg(decRrQ);
    final regL = getReg(decRlQ);

    final isOpLdReg = decOpQ.eq(Const(MiniRISC4Constants.opLdReg, width: 4));
    final isOpLdImm4 = decOpQ.eq(Const(MiniRISC4Constants.opLdImm4, width: 4));
    final isOpLdPostinc =
        decOpQ.eq(Const(MiniRISC4Constants.opLdPostinc, width: 4));
    final isOpLdPredec =
        decOpQ.eq(Const(MiniRISC4Constants.opLdPredec, width: 4));
    final isOpAdd = decOpQ.eq(Const(MiniRISC4Constants.opAdd, width: 4));
    final isOpSub = decOpQ.eq(Const(MiniRISC4Constants.opSub, width: 4));
    final isOpOr = decOpQ.eq(Const(MiniRISC4Constants.opOr, width: 4));
    final isOpXor = decOpQ.eq(Const(MiniRISC4Constants.opXor, width: 4));
    final isOpAnd = decOpQ.eq(Const(MiniRISC4Constants.opAnd, width: 4));
    final isOpShift = decOpQ.eq(Const(MiniRISC4Constants.opShift, width: 4));
    final isOpRotIncDec =
        decOpQ.eq(Const(MiniRISC4Constants.opRotIncDec, width: 4));
    final isOpSpecial =
        decOpQ.eq(Const(MiniRISC4Constants.opJmpSpecial, width: 4));

    final isSubXchg =
        isOpShift & decRrQ.eq(Const(MiniRISC4Constants.subShiftXchg, width: 2));
    final isSubInc =
        isOpRotIncDec & decRrQ.eq(Const(MiniRISC4Constants.subInc, width: 2));
    final isSubDec =
        isOpRotIncDec & decRrQ.eq(Const(MiniRISC4Constants.subDec, width: 2));
    final isSubLink =
        isOpSpecial & decRrQ.eq(Const(MiniRISC4Constants.subLink, width: 2));
    final isSubPush8 =
        isOpSpecial & decRrQ.eq(Const(MiniRISC4Constants.subPush8, width: 2));
    final isSubTrap =
        isOpSpecial & decRrQ.eq(Const(MiniRISC4Constants.subTrap, width: 2));

    // Single shared 16-bit add/sub carry chain (ADD, SUB, INC, DEC, PostInc, PreDec)
    // Control bits are pre-decoded into FFs at instruction latch time so the
    // CCU2C carry chain has zero decode LUTs ahead of it.
    final addA = mux(decUseRegLAsAddAQ, regL, regR);
    final addB = mux(decUseOneAsAddBQ, Const(1, width: 16), regL);
    final addBInv = mux(decArithSubQ, ~addB, addB);
    final arithSum17 =
        [addA, decArithSubQ].swizzle() + [addBInv, decArithSubQ].swizzle();
    final arithRes = arithSum17.slice(16, 1);

    // External SDRAM-cached address detectors (slice check -> zero CCU2C carry chains)
    Logic isExtAddr(Logic addr) => ~addr
        .slice(15, config.addrWidth)
        .eq(Const(0, width: 16 - config.addrWidth));
    final isExtPc = useExtCache ? isExtAddr(pc) : Const(0);
    final isExtNextPc = useExtCache ? isExtAddr(pcPlus1) : Const(0);
    final isExtPoke = useExtCache ? isExtAddr(regR) : Const(0);
    final isExtPredec = useExtCache ? isExtAddr(arithRes) : Const(0);

    if (useExtCache) {
      icReqValidOut! <= state.eq(Const(_stFetch, width: 3)) & isExtPc;
      icReqAddrOut! <= pc;
      dcReqValidOut! <= state.eq(Const(_stMemWait, width: 3)) & isExtPortB;
      dcReqWeOut! <= portBWe;
      dcReqAddrOut! <= portBAddr;
      dcReqWdataOut! <= portBWdata;
    }

    // Fast (non-adder) writeback paths computed in parallel with arithRes
    final shiftRes = mux(
      decRrQ[1],
      mux(
        decRrQ[0],
        config.enableShadowRegs ? getShadowReg(decRlQ) : regL,
        asr1(regL),
      ),
      mux(
        decRrQ[0],
        [Const(0, width: 1), regL.slice(15, 1)].swizzle(),
        [regL.slice(14, 0), Const(0, width: 1)].swizzle(),
      ),
    );
    final rotRes = mux(decRrQ[0], rotr1(regL), rotl1(regL));
    final bitwiseRes = mux(
      decOpQ[1],
      regR & regL,
      mux(decOpQ[0], regR ^ regL, regR | regL),
    );
    final immOrPushOrLink = mux(
      isOpLdImm4,
      [Const(0, width: 12), decImm4Q].swizzle(),
      mux(
        isSubPush8,
        [regL.slice(7, 0), instReg.slice(15, 8)].swizzle(),
        mux(isOpLdReg, regL, pcPlus1),
      ),
    );
    final execFastWbData = mux(
      isOpShift,
      shiftRes,
      mux(
        isOpRotIncDec,
        rotRes,
        mux(isOpOr | isOpXor | isOpAnd, bitwiseRes, immOrPushOrLink),
      ),
    );

    // Unified single register-file writeback with late-select after CCU2C
    final crossTrapTake = config.enableCrossTraps
        ? (crossTrapReq & state.eq(Const(_stExec, width: 3)))
        : Const(0);
    extTrapAckOut <= crossTrapTake;
    final inExec = state.eq(Const(_stExec, width: 3)) & ~crossTrapTake;
    final inMemRd = state.eq(Const(_stMemRd, width: 3));

    final execIsArith = ~illegalSlot1 &
        (isOpLdPostinc |
            isOpLdPredec |
            isOpAdd |
            isOpSub |
            isSubInc |
            isSubDec);
    final execNormalWbEn = isOpLdReg |
        isOpLdImm4 |
        isOpLdPostinc |
        isOpLdPredec |
        isOpAdd |
        isOpSub |
        isOpOr |
        isOpXor |
        isOpAnd |
        (config.enableShadowRegs ? isOpShift : (isOpShift & ~isSubXchg)) |
        isOpRotIncDec |
        isSubLink |
        isSubPush8 |
        isSubTrap;
    final execWbEn = illegalSlot1 | execNormalWbEn;

    final execWbForceR0 = illegalSlot1 | isOpLdImm4 | isSubLink | isSubTrap;
    final execWbUseRl =
        isOpLdPostinc | isOpShift | isOpRotIncDec | isSubPush8;
    final execWbIdx = mux(
      execWbForceR0,
      Const(0, width: 2),
      mux(execWbUseRl, decRlQ, decRrQ),
    );

    final wbEn = crossTrapTake | inMemRd | (inExec & execWbEn);
    final wbIdx = mux(
      crossTrapTake,
      Const(0, width: 2),
      mux(inMemRd, destReg, execWbIdx),
    );
    final crossTrapLinkPc =
        mux(slot.eq(MiniRISC4Constants.slotByte0), pc, pcPlus1);
    final wbFastData = mux(
      crossTrapTake,
      crossTrapLinkPc,
      mux(
        inMemRd,
        effectivePortBData,
        mux(illegalSlot1, pcPlus1, execFastWbData),
      ),
    );
    final wbUseArith = inExec & execIsArith;
    final wbData = mux(wbUseArith, arithRes, wbFastData);

    // Execution FSM
    Sequential(clk, reset: resetActive, resetValues: {
      state: Const(_stReset, width: 3),
      pc: trapTableBaseConst,
      slot: Const(MiniRISC4Constants.slotByte0, width: 1),
      instReg: Const(0, width: 16),
      nextInstReg: Const(0, width: 16),
      destReg: Const(0, width: 2),
      portAAddr: trapTableBaseConst,
      portAEn: Const(1, width: 1),
      portBAddr: Const(0, width: 16),
      portBWdata: Const(0, width: 16),
      portBWe: Const(0, width: 1),
      portBEn: Const(0, width: 1),
      mmioRdataReg: Const(0, width: 16),
      isMmioRdReg: Const(0, width: 1),
      decOpQ: Const(0, width: 4),
      decRrQ: Const(0, width: 2),
      decRlQ: Const(0, width: 2),
      decImm4Q: Const(0, width: 4),
      decUseRegLAsAddAQ: Const(0, width: 1),
      decUseOneAsAddBQ: Const(0, width: 1),
      decArithSubQ: Const(0, width: 1),
      illegalSlot1: Const(0, width: 1),
      if (useExtCache) extWrPendingQ: Const(0, width: 1),
      txData: Const(0, width: 8),
      txStrobe: Const(0, width: 1),
      for (final reg in r) reg: Const(0, width: 16),
      for (final sreg in shadowR) sreg: Const(0, width: 16),
    }, [
      txStrobe < 0,
      If(wbEn, then: [
        ..._writeReg(r, wbIdx, wbData),
      ]),
      if (config.enableShadowRegs)
        If(inExec & ~illegalSlot1 & isSubXchg, then: [
          ..._writeReg(shadowR, decRlQ, regL),
        ]),
      If(
          crossTrapTake,
          then: [
            portBEn < 0,
            portBWe < 0,
            _branchTo(
              trapTableBaseConst +
                  [Const(0, width: 8), crossTrapNum, Const(0, width: 4)]
                      .swizzle(),
              pc,
              portAAddr,
              portAEn,
              slot,
              state,
            ),
          ],
          orElse: [
            Case(state, [
              // ST_RESET: Kick off synchronous fetch of reset entry (0x0100)
              CaseItem(Const(_stReset, width: 3), [
                pc < trapTableBaseConst,
                portAAddr < trapTableBaseConst,
                portAEn < 1,
                portBEn < 0,
                portBWe < 0,
                slot < MiniRISC4Constants.slotByte0,
                state < Const(_stFetch, width: 3),
              ]),

              // ST_FETCH: Cycle 1 of 2-cycle BRAM read for pc (or I-Cache req if external)
              CaseItem(Const(_stFetch, width: 3), [
                if (useExtCache)
                  If(isExtPc, then: [
                    portAEn < 0,
                    portBEn < 0,
                    portBWe < 0,
                    slot < MiniRISC4Constants.slotByte0,
                    If(icReqReadyIn, then: [
                      state < Const(_stFetchWait, width: 3),
                    ]),
                  ], orElse: [
                    portAAddr < pcPlus1,
                    portAEn < 1,
                    portBEn < 0,
                    portBWe < 0,
                    slot < MiniRISC4Constants.slotByte0,
                    state < Const(_stFetchWait, width: 3),
                  ])
                else ...[
                  portAAddr < pcPlus1,
                  portAEn < 1,
                  portBEn < 0,
                  portBWe < 0,
                  slot < MiniRISC4Constants.slotByte0,
                  state < Const(_stFetchWait, width: 3),
                ],
              ]),

              // ST_FETCH_WAIT: Cycle 2 of BRAM read (or wait for I-Cache resp if external)
              CaseItem(Const(_stFetchWait, width: 3), [
                if (useExtCache)
                  If(isExtPc, then: [
                    portAEn < 0,
                    portBEn < 0,
                    portBWe < 0,
                    slot < MiniRISC4Constants.slotByte0,
                    If(icRespValidIn, then: [
                      instReg < icRespDataIn,
                      ..._latchExecByte(
                        icRespDataIn.slice(7, 0),
                        decOpQ,
                        decRrQ,
                        decRlQ,
                        decImm4Q,
                        decUseRegLAsAddAQ,
                        decUseOneAsAddBQ,
                        decArithSubQ,
                        illegalSlot1,
                        isSlot1: false,
                      ),
                      state < Const(_stExec, width: 3),
                    ]),
                  ], orElse: [
                    portAEn < 0,
                    portBEn < 0,
                    portBWe < 0,
                    slot < MiniRISC4Constants.slotByte0,
                    state < Const(_stFetchLatch, width: 3),
                  ])
                else ...[
                  portAEn < 0,
                  portBEn < 0,
                  portBWe < 0,
                  slot < MiniRISC4Constants.slotByte0,
                  state < Const(_stFetchLatch, width: 3),
                ],
              ]),

              // ST_FETCH_LATCH: Latch mem[pc] into instReg; portARdata advances to mem[pc+1];
              // schedule pc+2 on Port A for zero-bubble sequential execution.
              CaseItem(Const(_stFetchLatch, width: 3), [
                instReg < portARdata,
                ..._latchExecByte(
                  portARdata.slice(7, 0),
                  decOpQ,
                  decRrQ,
                  decRlQ,
                  decImm4Q,
                  decUseRegLAsAddAQ,
                  decUseOneAsAddBQ,
                  decArithSubQ,
                  illegalSlot1,
                  isSlot1: false,
                ),
                portAAddr < portAAddrPlus1,
                portAEn < 1,
                portBEn < 0,
                portBWe < 0,
                slot < MiniRISC4Constants.slotByte0,
                state < Const(_stExec, width: 3),
              ]),

              // ST_EXEC: Instruction decode and execute (1 cycle per slot sequentially)
              CaseItem(
                Const(_stExec, width: 3),
                () {
                  Conditional advance() => _advanceFromExec(
                        slot,
                        instReg,
                        nextInstReg,
                        portAAddr,
                        portAAddrPlus1,
                        portAEn,
                        state,
                        pc,
                        pcPlus1,
                        decOpQ,
                        decRrQ,
                        decRlQ,
                        decImm4Q,
                        decUseRegLAsAddAQ,
                        decUseOneAsAddBQ,
                        decArithSubQ,
                        illegalSlot1,
                        useExtCache: useExtCache,
                        isExtPc: isExtPc,
                        isExtNextPc: isExtNextPc,
                      );
                  return [
                portBEn < 0,
                portBWe < 0,
                portBWdata < regL,
                If(slot.eq(MiniRISC4Constants.slotByte0), then: [
                  nextInstReg < portARdata,
                ]),
                If(illegalSlot1, then: [
                  _branchTo(
                      trapAlignFaultConst, pc, portAAddr, portAEn, slot, state),
                ], orElse: [
                  Case(decOpQ, [
                    // 0x2: LD Rr, (Rl) - Peek
                    CaseItem(Const(MiniRISC4Constants.opLdPeek, width: 4), [
                      portAEn < 0,
                      portBAddr < regL,
                      portBWe < 0,
                      portBEn < 1,
                      destReg < decRrQ,
                      state < Const(_stMemWait, width: 3),
                    ]),

                    // 0x3: LD (Rr), Rl - Poke
                    CaseItem(Const(MiniRISC4Constants.opLdPoke, width: 4), [
                      portBAddr < regR,
                      portBWe < 1,
                      portBEn < 1,
                      if (config.enableUart)
                        If(regR.eq(MiniRISC4Constants.addrUartTx), then: [
                          txData < regL.slice(7, 0),
                          txStrobe < 1,
                        ]),
                      if (useExtCache)
                        If(isExtPoke, then: [
                          portAEn < 0,
                          extWrPendingQ < 1,
                          state < Const(_stMemWait, width: 3),
                        ], orElse: [
                          advance(),
                        ])
                      else
                        advance(),
                    ]),

                    // 0x4: LD Rr, (Rl++) - Pop (Full Descending)
                    CaseItem(Const(MiniRISC4Constants.opLdPostinc, width: 4), [
                      portAEn < 0,
                      portBAddr < regL,
                      portBWe < 0,
                      portBEn < 1,
                      destReg < decRrQ,
                      state < Const(_stMemWait, width: 3),
                    ]),

                    // 0x5: LD (--Rr), Rl - Push (Full Descending)
                    CaseItem(Const(MiniRISC4Constants.opLdPredec, width: 4), [
                      portBAddr < arithRes,
                      portBWe < 1,
                      portBEn < 1,
                      if (config.enableUart)
                        If(regR.eq(Const(0x0010, width: 16)),
                            then: [
                              txData < regL.slice(7, 0),
                              txStrobe < 1,
                            ]),
                      if (useExtCache)
                        If(isExtPredec, then: [
                          portAEn < 0,
                          extWrPendingQ < 1,
                          state < Const(_stMemWait, width: 3),
                        ], orElse: [
                          advance(),
                        ])
                      else
                        advance(),
                    ]),

                    // 0xD: JMP.Z
                    CaseItem(Const(MiniRISC4Constants.opJmpZ, width: 4), [
                      If(regL.eq(0), then: [
                        _branchTo(
                            regR, pc, portAAddr, portAEn, slot, state),
                      ], orElse: [
                        advance(),
                      ]),
                    ]),

                    // 0xE: JMP.M
                    CaseItem(Const(MiniRISC4Constants.opJmpM, width: 4), [
                      If(regL[15].eq(1), then: [
                        _branchTo(
                            regR, pc, portAAddr, portAEn, slot, state),
                      ], orElse: [
                        advance(),
                      ]),
                    ]),

                    // 0xF: SPECIAL (JMP, LINK, PUSH8, TRAP)
                    CaseItem(Const(MiniRISC4Constants.opJmpSpecial, width: 4), [
                      Case(decRrQ, [
                        CaseItem(Const(MiniRISC4Constants.subJmp, width: 2), [
                          _branchTo(
                              regL, pc, portAAddr, portAEn, slot, state),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subLink, width: 2), [
                          _branchTo(
                              regL, pc, portAAddr, portAEn, slot, state),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subPush8, width: 2), [
                          pc < pcPlus1,
                          slot < MiniRISC4Constants.slotByte0,
                          if (useExtCache)
                            If(isExtPc | isExtNextPc, then: [
                              portAAddr < pcPlus1,
                              portAEn < 1,
                              state < Const(_stFetch, width: 3),
                            ], orElse: [
                              portAEn < 0,
                              state < Const(_stFetchLatch, width: 3),
                            ])
                          else ...[
                            portAEn < 0,
                            state < Const(_stFetchLatch, width: 3),
                          ],
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subTrap, width: 2), [
                          _branchTo(
                            trapTableBaseConst +
                                [
                                  Const(0, width: 8),
                                  regL.slice(3, 0),
                                  Const(0, width: 4)
                                ].swizzle(),
                            pc,
                            portAAddr,
                            portAEn,
                            slot,
                            state,
                          ),
                        ]),
                      ]),
                    ]),
                  ], defaultItem: [
                    // 0x0 LD, 0x1 LDI4, 0x6..0xC ALU/SHIFT/ROT/XCHG/INC/DEC
                    advance(),
                  ]),
                ]),
                  ];
                }(),
              ),

              // ST_MEM_WAIT: Cycle 1 of Port B BRAM read (or D-Cache req handshake)
              CaseItem(Const(_stMemWait, width: 3), [
                portAEn < 0,
                if (useExtCache)
                  If(isExtPortB, then: [
                    If(dcReqReadyIn, then: [
                      portBEn < 0,
                      portBWe < 0,
                      state < Const(_stMemWait2, width: 3),
                    ]),
                  ], orElse: [
                    portBEn < 0,
                    portBWe < 0,
                    state < Const(_stMemWait2, width: 3),
                  ])
                else ...[
                  portBEn < 0,
                  portBWe < 0,
                  state < Const(_stMemWait2, width: 3),
                ],
              ]),

              // ST_MEM_WAIT2: Cycle 2 of Port B BRAM read (or wait for D-Cache resp)
              CaseItem(Const(_stMemWait2, width: 3), [
                portBEn < 0,
                portBWe < 0,
                if (useExtCache)
                  If(isExtPortB, then: [
                    If(dcRespValidIn, then: [
                      If(extWrPendingQ, then: [
                        extWrPendingQ < 0,
                        _advanceFromExec(
                          slot,
                          instReg,
                          nextInstReg,
                          portAAddr,
                          portAAddrPlus1,
                          portAEn,
                          state,
                          pc,
                          pcPlus1,
                          decOpQ,
                          decRrQ,
                          decRlQ,
                          decImm4Q,
                          decUseRegLAsAddAQ,
                          decUseOneAsAddBQ,
                          decArithSubQ,
                          illegalSlot1,
                          useExtCache: useExtCache,
                          isExtPc: isExtPc,
                          isExtNextPc: isExtNextPc,
                        ),
                      ], orElse: [
                        mmioRdataReg < dcRespDataIn,
                        isMmioRdReg < 1,
                        state < Const(_stMemRd, width: 3),
                      ]),
                    ]),
                  ], orElse: [
                    mmioRdataReg < mmioOnlyData,
                    isMmioRdReg < isMmio,
                    state < Const(_stMemRd, width: 3),
                  ])
                else ...[
                  mmioRdataReg < mmioOnlyData,
                  isMmioRdReg < isMmio,
                  state < Const(_stMemRd, width: 3),
                ],
              ]),

              // ST_MEM_RD: Advance after unified writeback latches Port B / MMIO data
              CaseItem(Const(_stMemRd, width: 3), [
                portBEn < 0,
                portBWe < 0,
                _advanceFromExec(
                  slot,
                  instReg,
                  nextInstReg,
                  portAAddr,
                  portAAddrPlus1,
                  portAEn,
                  state,
                  pc,
                  pcPlus1,
                  decOpQ,
                  decRrQ,
                  decRlQ,
                  decImm4Q,
                  decUseRegLAsAddAQ,
                  decUseOneAsAddBQ,
                  decArithSubQ,
                  illegalSlot1,
                  useExtCache: useExtCache,
                  isExtPc: isExtPc,
                  isExtNextPc: isExtNextPc,
                ),
              ]),
            ], defaultItem: [
              state < Const(_stReset, width: 3),
            ]),
          ]),
    ]);
  }

  static List<Conditional> _latchExecByte(
    Logic byteVal,
    Logic decOpQ,
    Logic decRrQ,
    Logic decRlQ,
    Logic decImm4Q,
    Logic decUseRegLAsAddAQ,
    Logic decUseOneAsAddBQ,
    Logic decArithSubQ,
    Logic decIllegalSlot1Q, {
    required bool isSlot1,
  }) {
    final op = byteVal.slice(7, 4);
    final rr = byteVal.slice(3, 2);
    final isPostinc = op.eq(Const(MiniRISC4Constants.opLdPostinc, width: 4));
    final isPredec = op.eq(Const(MiniRISC4Constants.opLdPredec, width: 4));
    final isSub = op.eq(Const(MiniRISC4Constants.opSub, width: 4));
    final isRotIncDec = op.eq(Const(MiniRISC4Constants.opRotIncDec, width: 4));
    final isDec =
        isRotIncDec & rr.eq(Const(MiniRISC4Constants.subDec, width: 2));
    final isIllegalSlot1 = isSlot1
        ? (op.eq(Const(MiniRISC4Constants.opJmpSpecial, width: 4)) &
            (rr[1] | rr[0]))
        : Const(0, width: 1);
    return [
      decOpQ < op,
      decRrQ < rr,
      decRlQ < byteVal.slice(1, 0),
      decImm4Q < byteVal.slice(3, 0),
      decUseRegLAsAddAQ < (isPostinc | isRotIncDec),
      decUseOneAsAddBQ < (isPostinc | isPredec | isRotIncDec),
      decArithSubQ < (isSub | isPredec | isDec),
      decIllegalSlot1Q < isIllegalSlot1,
    ];
  }

  static List<Conditional> _writeReg(
    List<Logic> r,
    Logic regIdx,
    Logic value,
  ) {
    final idx0 = regIdx[0];
    final idx1 = regIdx[1];
    final sel0 = ~idx1 & ~idx0;
    final sel1 = ~idx1 & idx0;
    final sel2 = idx1 & ~idx0;
    final sel3 = idx1 & idx0;
    final sels = [sel0, sel1, sel2, sel3];
    return [
      for (int i = 0; i < r.length; i++)
        If(sels[i], then: [r[i] < value]),
    ];
  }

  /// Advance from ST_EXEC / ST_MEM_RD: Slot 0 moves to Slot 1 while preserving
  /// instReg[15:8]; Slot 1 promotes prefetched nextInstReg into instReg and
  /// stays in ST_EXEC(slot 0) with zero fetch bubble (1 cycle/slot).
  static Conditional _advanceFromExec(
    Logic slot,
    Logic instReg,
    Logic nextInstReg,
    Logic portAAddr,
    Logic portAAddrPlus1,
    Logic portAEn,
    Logic state,
    Logic pc,
    Logic pcPlus1,
    Logic decOpQ,
    Logic decRrQ,
    Logic decRlQ,
    Logic decImm4Q,
    Logic decUseRegLAsAddAQ,
    Logic decUseOneAsAddBQ,
    Logic decArithSubQ,
    Logic decIllegalSlot1Q, {
    bool useExtCache = false,
    Logic? isExtPc,
    Logic? isExtNextPc,
  }) {
    final slot1LocalAdvance = <Conditional>[
      pc < pcPlus1,
      instReg < nextInstReg,
      ..._latchExecByte(
        nextInstReg.slice(7, 0),
        decOpQ,
        decRrQ,
        decRlQ,
        decImm4Q,
        decUseRegLAsAddAQ,
        decUseOneAsAddBQ,
        decArithSubQ,
        decIllegalSlot1Q,
        isSlot1: false,
      ),
      portAAddr < portAAddrPlus1,
      portAEn < 1,
      slot < MiniRISC4Constants.slotByte0,
      state < Const(_stExec, width: 3),
    ];

    return If(slot.eq(MiniRISC4Constants.slotByte0), then: [
      slot < MiniRISC4Constants.slotByte1,
      portAEn < 0,
      state < Const(_stExec, width: 3),
      ..._latchExecByte(
        instReg.slice(15, 8),
        decOpQ,
        decRrQ,
        decRlQ,
        decImm4Q,
        decUseRegLAsAddAQ,
        decUseOneAsAddBQ,
        decArithSubQ,
        decIllegalSlot1Q,
        isSlot1: true,
      ),
    ], orElse: [
      if (useExtCache && isExtPc != null && isExtNextPc != null)
        If(isExtPc | isExtNextPc, then: [
          pc < pcPlus1,
          portAAddr < pcPlus1,
          portAEn < 1,
          slot < MiniRISC4Constants.slotByte0,
          state < Const(_stFetch, width: 3),
        ], orElse: slot1LocalAdvance)
      else
        ...slot1LocalAdvance,
    ]);
  }


  /// Branch to targetAddr through ST_FETCH so synchronous Port A BRAM settles.
  static Conditional _branchTo(Logic targetAddr, Logic pc, Logic portAAddr,
      Logic portAEn, Logic slot, Logic state) {
    return If(Const(1, width: 1), then: [
      pc < targetAddr,
      portAAddr < targetAddr,
      portAEn < 1,
      slot < MiniRISC4Constants.slotByte0,
      state < Const(_stFetch, width: 3),
    ]);
  }

  Logic get rxPop => output('mmio_rx_pop');
  Logic get txData => output('mmio_tx_data');
  Logic get txStrobe => output('mmio_tx_strobe');
  Logic get extTrapAck => output('ext_trap_ack');
  Logic get debugPc => output('debug_pc');
  Logic get portBAddr => output('port_b_addr_out');
  Logic get portBWdata => output('port_b_wdata_out');
  Logic get portBWe => output('port_b_we_out');
  Logic get portBEn => output('port_b_en_out');
}

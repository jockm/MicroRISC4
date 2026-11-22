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

    final spiSck = config.enableSpi ? addOutput('spi_sck') : null;
    final spiMosi = config.enableSpi ? addOutput('spi_mosi') : null;
    final spiCsN = config.enableSpi ? addOutput('spi_cs_n') : null;

    // Module Outputs
    final rxPop = addOutput('mmio_rx_pop');
    final txData = addOutput('mmio_tx_data', width: 8);
    final txStrobe = addOutput('mmio_tx_strobe');
    final debugPc = addOutput('debug_pc', width: 16);

    // Architectural & Shadow Registers
    final pc = Logic(name: 'pc', width: 16);
    final r = List.generate(4, (i) => Logic(name: 'r$i', width: 16));
    final shadowR =
        List.generate(4, (i) => Logic(name: 'shadow_r$i', width: 16));
    final instReg = Logic(name: 'inst_reg', width: 16);
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
    final aRdataQ = Logic(name: 'a_rdata_q', width: 16);
    final bRdataQ = Logic(name: 'b_rdata_q', width: 16);
    final aBankStage = Logic(name: 'a_bank_stage', width: 16);
    final bBankStage = Logic(name: 'b_bank_stage', width: 16);

    // Expose Port B bus for external peripherals / multi-core glue
    final portBAddrOut = addOutput('port_b_addr_out', width: 16);
    final portBWdataOut = addOutput('port_b_wdata_out', width: 16);
    final portBWeOut = addOutput('port_b_we_out');
    final portBEnOut = addOutput('port_b_en_out');
    portBAddrOut <= portBAddr;
    portBWdataOut <= portBWdata;
    portBWeOut <= portBWe;
    portBEnOut <= portBEn;

    // Low MMIO Decodes
    final isMmioCpuid =
        config.enableCpuid ? portBAddr.eq(Const(0x000D, width: 16)) : Const(0);
    final isMmioRx = config.enableUart
        ? portBAddr.eq(MiniRISC4Constants.addrUartRx)
        : Const(0);
    final isMmioTx = config.enableUart
        ? portBAddr.eq(MiniRISC4Constants.addrUartTx)
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
    final isMmio = isMmioCpuid | isMmioRx | isMmioTx | isMathMatch | isSpiMatch;

    // Mask RAM writes when targeting MMIO addresses
    final ramBWe = portBEn & portBWe & ~isMmio;

    // Instantiate Synthesizable True Dual-Port BRAM
    final addrHigh = config.addrWidth - 1;
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

    // Instruction Decode Logic
    final curInst = mux(slot.eq(MiniRISC4Constants.slotByte0),
        instReg.slice(7, 0), instReg.slice(15, 8));
    final op = curInst.slice(7, 4);
    final rr = curInst.slice(3, 2);
    final rl = curInst.slice(1, 0);
    final imm4 = curInst.slice(3, 0);

    final isLink = op.eq(MiniRISC4Constants.opJmpSpecial) &
        rr.eq(MiniRISC4Constants.subLink);
    final isPush8 = op.eq(MiniRISC4Constants.opJmpSpecial) &
        rr.eq(MiniRISC4Constants.subPush8);
    final isTrap = op.eq(MiniRISC4Constants.opJmpSpecial) &
        rr.eq(MiniRISC4Constants.subTrap);
    final illegalSlot1 =
        slot.eq(MiniRISC4Constants.slotByte1) & (isLink | isPush8 | isTrap);

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
              Const(0, width: 16),
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

    // Staged read-data selection: keeps wide BRAM read path out of the MMIO mux tree
    final effectivePortBData = mux(isMmioRdReg, mmioRdataReg, portBRdata);

    // Pulse UART RX Pop only on the exact cycle stMemRd latches rxData
    rxPop <= (state.eq(Const(_stMemRd, width: 3)) & isMmioRx);

    // ALU Helpers
    Logic rotl1(Logic v) => [v.slice(14, 0), v[15]].swizzle();
    Logic rotr1(Logic v) => [v[0], v.slice(15, 1)].swizzle();
    Logic asr1(Logic v) => [v[15], v.slice(15, 1)].swizzle();

    Logic getReg(Logic idx) => mux(
          idx.eq(0),
          r[0],
          mux(idx.eq(1), r[1], mux(idx.eq(2), r[2], r[3])),
        );

    final resetActive = ~rstN;

    // Execution FSM
    Sequential(clk, reset: resetActive, resetValues: {
      state: Const(_stReset, width: 3),
      aRdataQ: Const(0, width: 16),
      bRdataQ: Const(0, width: 16),
      aBankStage: Const(0, width: 16),
      bBankStage: Const(0, width: 16),
      pc: trapTableBaseConst,
      slot: Const(MiniRISC4Constants.slotByte0, width: 1),
      instReg: Const(0, width: 16),
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
      txData: Const(0, width: 8),
      txStrobe: Const(0, width: 1),
      for (final reg in r) reg: Const(0, width: 16),
      for (final sreg in shadowR) sreg: Const(0, width: 16),
    }, [
      txStrobe < 0,
      If(
          config.enableCrossTraps
              ? (crossTrapReq & state.eq(Const(_stExec, width: 3)))
              : Const(0),
          then: [
            r[0] < mux(slot.eq(MiniRISC4Constants.slotByte0), pc, pc + 1),
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
            aBankStage < portARdata,
            bBankStage < portBRdata,
            aRdataQ < aBankStage,
            bRdataQ < bBankStage,
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

              // ST_FETCH: Cycle 1 of 2-cycle BRAM read for pc
              CaseItem(Const(_stFetch, width: 3), [
                portAAddr < pc,
                portAEn < 1,
                portBEn < 0,
                portBWe < 0,
                slot < MiniRISC4Constants.slotByte0,
                state < Const(_stFetchWait, width: 3),
              ]),

              // ST_FETCH_WAIT: Cycle 2 of BRAM read (advance into staged bank/capture pipeline)
              CaseItem(Const(_stFetchWait, width: 3), [
                portAEn < 1,
                portBEn < 0,
                portBWe < 0,
                slot < MiniRISC4Constants.slotByte0,
                state < Const(_stMemWait2, width: 3),
              ]),

              // ST_FETCH_LATCH: Latch settled mem[pc] into instReg and start prefetch of pc+1
              CaseItem(Const(_stFetchLatch, width: 3), [
                instReg < aRdataQ,
                ..._latchExecByte(
                  aRdataQ.slice(7, 0),
                  decOpQ,
                  decRrQ,
                  decRlQ,
                  decImm4Q,
                ),
                portAAddr < pc + 1,
                portAEn < 1,
                portBEn < 0,
                portBWe < 0,
                slot < MiniRISC4Constants.slotByte0,
                state < Const(_stExec, width: 3),
              ]),

              // ST_EXEC: Instruction decode and execute
              CaseItem(
                Const(_stExec, width: 3),
                () {
                  final regR = getReg(decRrQ);
                  final regL = getReg(decRlQ);
                  final regLInc = regL + 1;
                  final regRDec = regR - 1;
                  return [If(Const(1, width: 1), then: [
                portBEn < 0,
                portBWe < 0,
                If(illegalSlot1, then: [
                  r[0] < pc + 1,
                  _branchTo(
                      trapAlignFaultConst, pc, portAAddr, portAEn, slot, state),
                ], orElse: [
                  Case(decOpQ, [
                    // 0x0: LD Rr, Rl
                    CaseItem(Const(MiniRISC4Constants.opLdReg, width: 4), [
                      ..._writeReg(r, decRrQ, regL),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0x1: LD R0, decImm4Q
                    CaseItem(Const(MiniRISC4Constants.opLdImm4, width: 4), [
                      r[0] < [Const(0, width: 12), decImm4Q].swizzle(),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0x2: LD Rr, (Rl) - Peek
                    CaseItem(Const(MiniRISC4Constants.opLdPeek, width: 4), [
                      If(slot.eq(MiniRISC4Constants.slotByte1), then: [
                        instReg < portARdata,
                      ]),
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
                      portBWdata < regL,
                      portBWe < 1,
                      portBEn < 1,
                      if (config.enableUart)
                        If(regR.eq(MiniRISC4Constants.addrUartTx), then: [
                          txData < regL.slice(7, 0),
                          txStrobe < 1,
                        ]),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0x4: LD Rr, (Rl++) - Pop (Full Descending)
                    CaseItem(Const(MiniRISC4Constants.opLdPostinc, width: 4), [
                      If(slot.eq(MiniRISC4Constants.slotByte1), then: [
                        instReg < portARdata,
                      ]),
                      portAEn < 0,
                      portBAddr < regL,
                      portBWe < 0,
                      portBEn < 1,
                      destReg < decRrQ,
                      ..._writeReg(r, decRlQ, regLInc),
                      state < Const(_stMemWait, width: 3),
                    ]),

                    // 0x5: LD (--Rr), Rl - Push (Full Descending)
                    CaseItem(Const(MiniRISC4Constants.opLdPredec, width: 4), [
                      ..._writeReg(r, decRrQ, regRDec),
                      portBAddr < regRDec,
                      portBWdata < regL,
                      portBWe < 1,
                      portBEn < 1,
                      if (config.enableUart)
                        If(regR.eq(Const(0x0010, width: 16)),
                            then: [
                              txData < regL.slice(7, 0),
                              txStrobe < 1,
                            ]),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0x6: ADD
                    CaseItem(Const(MiniRISC4Constants.opAdd, width: 4), [
                      ..._writeReg(r, decRrQ, regR + regL),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0x7: SUB
                    CaseItem(Const(MiniRISC4Constants.opSub, width: 4), [
                      ..._writeReg(r, decRrQ, regR - regL),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0x8: OR
                    CaseItem(Const(MiniRISC4Constants.opOr, width: 4), [
                      ..._writeReg(r, decRrQ, regR | regL),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0x9: XOR
                    CaseItem(Const(MiniRISC4Constants.opXor, width: 4), [
                      ..._writeReg(r, decRrQ, regR ^ regL),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0xA: Native AND
                    CaseItem(Const(MiniRISC4Constants.opAnd, width: 4), [
                      ..._writeReg(r, decRrQ, regR & regL),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0xB: SHIFT & XCHG
                    CaseItem(Const(MiniRISC4Constants.opShift, width: 4), [
                      Case(decRrQ, [
                        CaseItem(
                            Const(MiniRISC4Constants.subShiftL, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(decRlQ.eq(i), then: [
                              r[i] <
                                  [r[i].slice(14, 0), Const(0, width: 1)]
                                      .swizzle()
                            ]),
                        ]),
                        CaseItem(
                            Const(MiniRISC4Constants.subShiftR, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(decRlQ.eq(i), then: [
                              r[i] <
                                  [Const(0, width: 1), r[i].slice(15, 1)]
                                      .swizzle()
                            ]),
                        ]),
                        CaseItem(
                            Const(MiniRISC4Constants.subShiftAr, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(decRlQ.eq(i), then: [r[i] < asr1(r[i])]),
                        ]),
                        CaseItem(
                            Const(MiniRISC4Constants.subShiftXchg, width: 2), [
                          if (config.enableShadowRegs)
                            for (int i = 0; i < 4; i++)
                              If(decRlQ.eq(i), then: [
                                r[i] < shadowR[i],
                                shadowR[i] < r[i],
                              ]),
                        ]),
                      ]),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0xC: ROT / INC / DEC
                    CaseItem(Const(MiniRISC4Constants.opRotIncDec, width: 4), [
                      Case(decRrQ, [
                        CaseItem(Const(MiniRISC4Constants.subRotL, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(decRlQ.eq(i), then: [r[i] < rotl1(r[i])]),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subRotR, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(decRlQ.eq(i), then: [r[i] < rotr1(r[i])]),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subInc, width: 2), [
                          ..._writeReg(r, decRlQ, regLInc),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subDec, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(decRlQ.eq(i), then: [r[i] < r[i] - 1]),
                        ]),
                      ]),
                      _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                    ]),

                    // 0xD: JMP.Z
                    CaseItem(Const(MiniRISC4Constants.opJmpZ, width: 4), [
                      If(regL.eq(0), then: [
                        _branchTo(
                            regR, pc, portAAddr, portAEn, slot, state),
                      ], orElse: [
                        _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
                      ]),
                    ]),

                    // 0xE: JMP.M
                    CaseItem(Const(MiniRISC4Constants.opJmpM, width: 4), [
                      If(regL[15].eq(1), then: [
                        _branchTo(
                            regR, pc, portAAddr, portAEn, slot, state),
                      ], orElse: [
                        _advanceFromExec(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
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
                          r[0] < pc + 1,
                          _branchTo(
                              regL, pc, portAAddr, portAEn, slot, state),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subPush8, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(decRlQ.eq(i), then: [
                              r[i] <
                                  [r[i].slice(7, 0), instReg.slice(15, 8)]
                                      .swizzle(),
                            ]),
                          _branchTo(
                              pc + 1, pc, portAAddr, portAEn, slot, state),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subTrap, width: 2), [
                          r[0] < pc + 1,
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
                  ]),
                ]),
                    ]),
                  ];
                }(),
              ),

              // ST_MEM_WAIT: Cycle 1 of Port B BRAM read (raw/bank stage)
              CaseItem(Const(_stMemWait, width: 3), [
                portAEn < 0,
                portBEn < 0,
                portBWe < 0,
                state < Const(_stMemWait2, width: 3),
              ]),

              // ST_MEM_WAIT2: Stage MMIO read bus & complete 2-stage bank/capture settling
              CaseItem(Const(_stMemWait2, width: 3), [
                portBEn < 0,
                portBWe < 0,
                mmioRdataReg < mmioOnlyData,
                isMmioRdReg < isMmio,
                If(portAEn.eq(1), then: [
                  state < Const(_stFetchLatch, width: 3),
                ], orElse: [
                  state < Const(_stMemRd, width: 3),
                ]),
              ]),

              // ST_MEM_RD: Latch settled Port B / staged MMIO read data into destReg
              CaseItem(Const(_stMemRd, width: 3), [
                portBEn < 0,
                portBWe < 0,
                ..._writeReg(
                    r, destReg, mux(isMmioRdReg, mmioRdataReg, portBRdata)),
                _advanceFromMemRd(slot, instReg, portARdata, portAAddr, portAEn, state, pc, decOpQ, decRrQ, decRlQ, decImm4Q),
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
  ) {
    return [
      decOpQ < byteVal.slice(7, 4),
      decRrQ < byteVal.slice(3, 2),
      decRlQ < byteVal.slice(1, 0),
      decImm4Q < byteVal.slice(3, 0),
    ];
  }

  static List<Conditional> _writeReg(
    List<Logic> r,
    Logic regIdx,
    Logic value,
  ) {
    return [
      for (int i = 0; i < r.length; i++)
        If(regIdx.eq(i), then: [r[i] < value]),
    ];
  }

  /// Advance from ST_EXEC: Slot 0 moves to Slot 1 while preserving instReg[15:8]
  /// for Slot 1 decode; Slot 1 advances PC and fetches the next instruction word.
  static Conditional _advanceFromExec(
    Logic slot,
    Logic instReg,
    Logic portARdata,
    Logic portAAddr,
    Logic portAEn,
    Logic state,
    Logic pc,
    Logic decOpQ,
    Logic decRrQ,
    Logic decRlQ,
    Logic decImm4Q,
  ) {
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
      ),
    ], orElse: [
      pc < pc + 1,
      portAAddr < pc + 1,
      portAEn < 1,
      slot < MiniRISC4Constants.slotByte0,
      state < Const(_stFetch, width: 3),
    ]);
  }

  /// Advance from ST_MEM_RD: Slot 0 moves to Slot 1; Slot 1 advances PC
  /// and fetches the next instruction word.
  static Conditional _advanceFromMemRd(
    Logic slot,
    Logic instReg,
    Logic portARdata,
    Logic portAAddr,
    Logic portAEn,
    Logic state,
    Logic pc,
    Logic decOpQ,
    Logic decRrQ,
    Logic decRlQ,
    Logic decImm4Q,
  ) {
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
      ),
    ], orElse: [
      pc < pc + 1,
      portAAddr < pc + 1,
      portAEn < 1,
      slot < MiniRISC4Constants.slotByte0,
      state < Const(_stFetch, width: 3),
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
  Logic get debugPc => output('debug_pc');
  Logic get portBAddr => output('port_b_addr_out');
  Logic get portBWdata => output('port_b_wdata_out');
  Logic get portBWe => output('port_b_we_out');
  Logic get portBEn => output('port_b_en_out');
}

// ==============================================================================
// FILE: hdl/rohd/lib/cpu_core.dart
// MiniRISC4 16-Bit CPU Core Architecture
// Intel ROHD Implementation
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'math_accelerator.dart';

/// Complete MiniRISC4 CPU core module with instruction execution FSM, ALU,
/// architectural register file, hardware shadow registers, and memory bus ports.
class CpuCore extends Module {
  final CpuConfig config;

  CpuCore({
    required Logic clk,
    required Logic rstN,
    Logic? mmioRxData,
    Logic? mmioTxStatus,
    Logic? extTrapReq,
    Logic? extTrapNum,
    this.config = const CpuConfig(),
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

    // Module Outputs
    final rxPop = addOutput('mmio_rx_pop');
    final txData = addOutput('mmio_tx_data', width: 8);
    final txStrobe = addOutput('mmio_tx_strobe');

    // Architectural Registers & Shadow Registers
    final pc = Logic(name: 'pc', width: 16);
    final r = List.generate(4, (i) => Logic(name: 'r$i', width: 16));
    final shadowR =
        List.generate(4, (i) => Logic(name: 'shadow_r$i', width: 16));
    final instReg = Logic(name: 'inst_reg', width: 16);
    final slot = Logic(name: 'slot', width: 1);
    final destReg = Logic(name: 'dest_reg', width: 2);
    final state = Logic(name: 'state', width: 3);

    // Dual-Port Memory Interface Signals
    final portAAddr = Logic(name: 'port_a_addr', width: 16);
    final portAEn = Logic(name: 'port_a_en');
    final portARdata = Logic(name: 'port_a_rdata', width: 16);

    final portBAddr = Logic(name: 'port_b_addr', width: 16);
    final portBWdata = Logic(name: 'port_b_wdata', width: 16);
    final portBWe = Logic(name: 'port_b_we');
    final portBEn = Logic(name: 'port_b_en');
    final portBRdata = Logic(name: 'port_b_rdata', width: 16);

    // Internal default connections
    portARdata <= Const(0, width: 16);
    portBRdata <= Const(0, width: 16);

    // Instruction Decode Logic
    final curInst = mux(slot.eq(MiniRISC4Constants.slotByte0),
        portARdata.slice(7, 0), instReg.slice(7, 0));
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

    // Direct Stride Vector Table Constants
    final trapTableBaseConst = Const(config.trapTableBase, width: 16);
    final trapAlignFaultConst =
        Const(config.trapTableBase + (15 << 4), width: 16);

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

    // Composite MMIO Read Multiplexing
    final effectivePortBData = mux(
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
            portBRdata,
          ),
        ),
      ),
    );

    // Combinational UART RX Pop
    rxPop <= (portBEn & ~portBWe & isMmioRx);

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
      state: Const(MiniRISC4Constants.stReset, width: 3),
      pc: Const(0, width: 16),
      slot: Const(MiniRISC4Constants.slotByte0, width: 1),
      instReg: Const(0, width: 16),
      destReg: Const(0, width: 2),
      portAAddr: Const(0, width: 16),
      portAEn: Const(0, width: 1),
      portBAddr: trapTableBaseConst,
      portBWdata: Const(0, width: 16),
      portBWe: Const(0, width: 1),
      portBEn: Const(1, width: 1),
      txData: Const(0, width: 8),
      txStrobe: Const(0, width: 1),
      for (final reg in r) reg: Const(0, width: 16),
      for (final sreg in shadowR) sreg: Const(0, width: 16),
    }, [
      txStrobe < 0,
      If(
          Const(config.enableCrossTraps ? 1 : 0) &
              crossTrapReq &
              state.eq(Const(MiniRISC4Constants.stExec, width: 3)),
          then: [
            r[0] < mux(slot.eq(MiniRISC4Constants.slotByte0), pc, pc + 1),
            portBAddr <
                trapTableBaseConst +
                    [Const(0, width: 8), crossTrapNum, Const(0, width: 4)]
                        .swizzle(),
            portBWe < 0,
            portBEn < 1,
            state < Const(MiniRISC4Constants.stTrapRd, width: 3),
          ],
          orElse: [
            Case(state, [
              // ST_RESET: Fetch reset vector
              CaseItem(Const(MiniRISC4Constants.stReset, width: 3), [
                portBEn < 0,
                pc < effectivePortBData,
                portAAddr < effectivePortBData,
                portAEn < 1,
                slot < MiniRISC4Constants.slotByte0,
                state < Const(MiniRISC4Constants.stExec, width: 3),
              ]),

              // ST_FETCH: Instruction word fetch from PC
              CaseItem(Const(MiniRISC4Constants.stFetch, width: 3), [
                portAAddr < pc,
                portAEn < 1,
                slot < MiniRISC4Constants.slotByte0,
                state < Const(MiniRISC4Constants.stExec, width: 3),
              ]),

              // ST_EXEC: Instruction decode and execute
              CaseItem(Const(MiniRISC4Constants.stExec, width: 3), [
                If(slot.eq(MiniRISC4Constants.slotByte0), then: [
                  instReg < portARdata,
                ]),
                portBEn < 0,
                portBWe < 0,
                If(illegalSlot1, then: [
                  r[0] < pc + 1,
                  portBAddr < trapAlignFaultConst,
                  portBWe < 0,
                  portBEn < 1,
                  state < Const(MiniRISC4Constants.stTrapRd, width: 3),
                ], orElse: [
                  Case(op, [
                    // 0x0: LD Rr, Rl
                    CaseItem(Const(MiniRISC4Constants.opLdReg, width: 4), [
                      for (int i = 0; i < 4; i++)
                        If(rr.eq(i), then: [r[i] < getReg(rl)]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0x1: LD R0, imm4
                    CaseItem(Const(MiniRISC4Constants.opLdImm4, width: 4), [
                      r[0] < [Const(0, width: 12), imm4].swizzle(),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0x2: LD Rr, (Rl) - Peek
                    CaseItem(Const(MiniRISC4Constants.opLdPeek, width: 4), [
                      portBAddr < getReg(rl),
                      portBWe < 0,
                      portBEn < 1,
                      destReg < rr,
                      state < Const(MiniRISC4Constants.stMemRd, width: 3),
                    ]),

                    // 0x3: LD (Rr), Rl - Poke
                    CaseItem(Const(MiniRISC4Constants.opLdPoke, width: 4), [
                      portBAddr < getReg(rr),
                      portBWdata < getReg(rl),
                      portBWe < 1,
                      portBEn < 1,
                      if (config.enableUart)
                        If(getReg(rr).eq(MiniRISC4Constants.addrUartTx), then: [
                          txData < getReg(rl).slice(7, 0),
                          txStrobe < 1,
                        ]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0x4: LD Rr, (Rl++) - Pop (Full Descending)
                    CaseItem(Const(MiniRISC4Constants.opLdPostinc, width: 4), [
                      portBAddr < getReg(rl),
                      portBWe < 0,
                      portBEn < 1,
                      destReg < rr,
                      for (int i = 0; i < 4; i++)
                        If(rl.eq(i), then: [r[i] < r[i] + 1]),
                      state < Const(MiniRISC4Constants.stMemRd, width: 3),
                    ]),

                    // 0x5: LD (--Rr), Rl - Push (Full Descending)
                    CaseItem(Const(MiniRISC4Constants.opLdPredec, width: 4), [
                      for (int i = 0; i < 4; i++)
                        If(rr.eq(i), then: [
                          r[i] < r[i] - 1,
                          portBAddr < r[i] - 1,
                        ]),
                      portBWdata < getReg(rl),
                      portBWe < 1,
                      portBEn < 1,
                      if (config.enableUart)
                        If((getReg(rr) - 1).eq(MiniRISC4Constants.addrUartTx),
                            then: [
                              txData < getReg(rl).slice(7, 0),
                              txStrobe < 1,
                            ]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0x6: ADD
                    CaseItem(Const(MiniRISC4Constants.opAdd, width: 4), [
                      for (int i = 0; i < 4; i++)
                        If(rr.eq(i), then: [r[i] < r[i] + getReg(rl)]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0x7: SUB
                    CaseItem(Const(MiniRISC4Constants.opSub, width: 4), [
                      for (int i = 0; i < 4; i++)
                        If(rr.eq(i), then: [r[i] < r[i] - getReg(rl)]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0x8: OR
                    CaseItem(Const(MiniRISC4Constants.opOr, width: 4), [
                      for (int i = 0; i < 4; i++)
                        If(rr.eq(i), then: [r[i] < r[i] | getReg(rl)]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0x9: XOR
                    CaseItem(Const(MiniRISC4Constants.opXor, width: 4), [
                      for (int i = 0; i < 4; i++)
                        If(rr.eq(i), then: [r[i] < r[i] ^ getReg(rl)]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0xA: Native AND
                    CaseItem(Const(MiniRISC4Constants.opAnd, width: 4), [
                      for (int i = 0; i < 4; i++)
                        If(rr.eq(i), then: [r[i] < r[i] & getReg(rl)]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0xB: SHIFT & XCHG
                    CaseItem(Const(MiniRISC4Constants.opShift, width: 4), [
                      Case(rr, [
                        CaseItem(
                            Const(MiniRISC4Constants.subShiftL, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(rl.eq(i), then: [
                              r[i] <
                                  [r[i].slice(14, 0), Const(0, width: 1)]
                                      .swizzle()
                            ]),
                        ]),
                        CaseItem(
                            Const(MiniRISC4Constants.subShiftR, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(rl.eq(i), then: [
                              r[i] <
                                  [Const(0, width: 1), r[i].slice(15, 1)]
                                      .swizzle()
                            ]),
                        ]),
                        CaseItem(
                            Const(MiniRISC4Constants.subShiftAr, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(rl.eq(i), then: [r[i] < asr1(r[i])]),
                        ]),
                        CaseItem(
                            Const(MiniRISC4Constants.subShiftXchg, width: 2), [
                          if (config.enableShadowRegs)
                            for (int i = 0; i < 4; i++)
                              If(rl.eq(i), then: [
                                r[i] < shadowR[i],
                                shadowR[i] < r[i],
                              ]),
                        ]),
                      ]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0xC: ROT / INC / DEC
                    CaseItem(Const(MiniRISC4Constants.opRotIncDec, width: 4), [
                      Case(rr, [
                        CaseItem(Const(MiniRISC4Constants.subRotL, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(rl.eq(i), then: [r[i] < rotl1(r[i])]),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subRotR, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(rl.eq(i), then: [r[i] < rotr1(r[i])]),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subInc, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(rl.eq(i), then: [r[i] < r[i] + 1]),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subDec, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(rl.eq(i), then: [r[i] < r[i] - 1]),
                        ]),
                      ]),
                      _advanceSlotOrFetch(
                          slot, instReg, portAAddr, portAEn, state, pc),
                    ]),

                    // 0xD: JMP.Z
                    CaseItem(Const(MiniRISC4Constants.opJmpZ, width: 4), [
                      If(getReg(rl).eq(0), then: [
                        _branchTo(
                            getReg(rr), pc, portAAddr, portAEn, slot, state),
                      ], orElse: [
                        _advanceSlotOrFetch(
                            slot, instReg, portAAddr, portAEn, state, pc),
                      ]),
                    ]),

                    // 0xE: JMP.M
                    CaseItem(Const(MiniRISC4Constants.opJmpM, width: 4), [
                      If(getReg(rl)[15].eq(1), then: [
                        _branchTo(
                            getReg(rr), pc, portAAddr, portAEn, slot, state),
                      ], orElse: [
                        _advanceSlotOrFetch(
                            slot, instReg, portAAddr, portAEn, state, pc),
                      ]),
                    ]),

                    // 0xF: SPECIAL (JMP, LINK, PUSH8, TRAP)
                    CaseItem(Const(MiniRISC4Constants.opJmpSpecial, width: 4), [
                      Case(rr, [
                        CaseItem(Const(MiniRISC4Constants.subJmp, width: 2), [
                          _branchTo(
                              getReg(rl), pc, portAAddr, portAEn, slot, state),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subLink, width: 2), [
                          r[0] < pc + 1,
                          _branchTo(
                              getReg(rl), pc, portAAddr, portAEn, slot, state),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subPush8, width: 2), [
                          for (int i = 0; i < 4; i++)
                            If(rl.eq(i), then: [
                              r[i] <
                                  [r[i].slice(7, 0), portARdata.slice(15, 8)]
                                      .swizzle(),
                            ]),
                          _branchTo(
                              pc + 1, pc, portAAddr, portAEn, slot, state),
                        ]),
                        CaseItem(Const(MiniRISC4Constants.subTrap, width: 2), [
                          r[0] < pc + 1,
                          portBAddr <
                              trapTableBaseConst +
                                  [
                                    Const(0, width: 8),
                                    (getReg(rl) & Const(0x000F, width: 16))
                                        .slice(3, 0),
                                    Const(0, width: 4)
                                  ].swizzle(),
                          portBWe < 0,
                          portBEn < 1,
                          state < Const(MiniRISC4Constants.stTrapRd, width: 3),
                        ]),
                      ]),
                    ]),
                  ]),
                ]),
              ]),

              // ST_MEM_RD: Latch memory read data into destination register
              CaseItem(Const(MiniRISC4Constants.stMemRd, width: 3), [
                portBEn < 0,
                for (int i = 0; i < 4; i++)
                  If(destReg.eq(i), then: [r[i] < effectivePortBData]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),

              // ST_TRAP_RD: Latch trap handler vector into PC and fetch target
              CaseItem(Const(MiniRISC4Constants.stTrapRd, width: 3), [
                portBEn < 0,
                pc < effectivePortBData,
                state < Const(MiniRISC4Constants.stFetch, width: 3),
              ]),
            ], defaultItem: [
              state < Const(MiniRISC4Constants.stReset, width: 3),
            ]),
          ]),
    ]);
  }

  static Conditional _advanceSlotOrFetch(Logic slot, Logic instReg,
      Logic portAAddr, Logic portAEn, Logic state, Logic pc) {
    return If(slot.eq(MiniRISC4Constants.slotByte0), then: [
      slot < MiniRISC4Constants.slotByte1,
      instReg < [Const(0, width: 8), instReg.slice(15, 8)].swizzle(),
      portAAddr < pc + 1,
      portAEn < 1,
      state < Const(MiniRISC4Constants.stExec, width: 3),
    ], orElse: [
      pc < pc + 1,
      slot < MiniRISC4Constants.slotByte0,
      portAEn < 0,
      state < Const(MiniRISC4Constants.stExec, width: 3),
    ]);
  }

  static Conditional _branchTo(Logic targetAddr, Logic pc, Logic portAAddr,
      Logic portAEn, Logic slot, Logic state) {
    return If(Const(1, width: 1), then: [
      pc < targetAddr,
      portAAddr < targetAddr,
      portAEn < 1,
      slot < MiniRISC4Constants.slotByte0,
      state < Const(MiniRISC4Constants.stExec, width: 3),
    ]);
  }

  Logic get rxPop => output('mmio_rx_pop');
  Logic get txData => output('mmio_tx_data');
  Logic get txStrobe => output('mmio_tx_strobe');
}

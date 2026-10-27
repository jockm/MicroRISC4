// ==============================================================================
// MiniRISC4 16-Bit CPU Core Architecture
// Intel ROHD Implementation
//
// Key Features:
// - Word-addressed 16-bit Von Neumann architecture (64K words = 128 KB).
// - Dual-instruction packing: two 8-bit instruction slots per 16-bit memory word.
// - 4 architectural registers (R0-R3) + 4 hardware shadow registers (shadow_r[0..3]).
// - Single-cycle XCHG Rr swapping register with shadow counterpart (101111rr).
// - Native hardware AND instruction (Opcode 0xA).
// - Full Descending stack convention:
//     * Pop:  LD Rr, (Rl++) -> Opcode 0x4 (Post-increment load)
//     * Push: LD (--Rr), Rl -> Opcode 0x5 (Pre-decrement store)
// - Word-aligned instructions: LINK, PUSH8, TRAP (Slot 1 fault vectors to TRAP 15).
// - Direct MMIO interface for UART at 0x000E (RX) and 0x000F (TX).
// ==============================================================================
import 'package:rohd/rohd.dart';
import 'constants.dart';

/// Complete MiniRISC4 CPU core module with instruction execution FSM, ALU,
/// architectural register file, hardware shadow registers, and memory bus ports.
class CpuCore extends Module {
  CpuCore({
    required Logic clk,
    required Logic rstN,
    required Logic mmioRxData,
    required Logic mmioTxStatus,
    super.name = 'cpu_core',
  }) {
    // Top-level module ports
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    final rxData = addInput('mmio_rx_data', mmioRxData, width: 16);
    final txStatus = addInput('mmio_tx_status', mmioTxStatus, width: 16);

    final rxPop = addOutput('mmio_rx_pop');
    final txData = addOutput('mmio_tx_data', width: 8);
    final txStrobe = addOutput('mmio_tx_strobe');

    // Architecture Registers & Shadow Registers
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

    // Default driver on internal read buses to avoid 1'bx when unattached
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

    final isMmioRx = portBAddr.eq(MiniRISC4Constants.addrUartRx);
    final isMmioTx = portBAddr.eq(MiniRISC4Constants.addrUartTx);

    // Direct read muxing: MMIO overrides memory bus on Port B read
    final effectivePortBData = mux(
      isMmioRx,
      rxData,
      mux(isMmioTx, txStatus, portBRdata),
    );

    // Combinational pop strobe on read
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
      portBAddr: Const(MiniRISC4Constants.trapTableBase, width: 16),
      portBWdata: Const(0, width: 16),
      portBWe: Const(0, width: 1),
      portBEn: Const(0, width: 1),
      txData: Const(0, width: 8),
      txStrobe: Const(0, width: 1),
      for (final reg in r) reg: Const(0, width: 16),
      for (final sreg in shadowR) sreg: Const(0, width: 16),
    }, [
      txStrobe < 0,
      Case(state, [
        CaseItem(Const(MiniRISC4Constants.stReset, width: 3), [
          portBEn < 0,
          pc < effectivePortBData,
          portAAddr < effectivePortBData,
          portAEn < 1,
          slot < MiniRISC4Constants.slotByte0,
          state < Const(MiniRISC4Constants.stExec, width: 3),
        ]),
        CaseItem(Const(MiniRISC4Constants.stFetch, width: 3), [
          portAAddr < pc,
          portAEn < 1,
          slot < MiniRISC4Constants.slotByte0,
          state < Const(MiniRISC4Constants.stExec, width: 3),
        ]),
        CaseItem(Const(MiniRISC4Constants.stExec, width: 3), [
          If(slot.eq(MiniRISC4Constants.slotByte0), then: [
            instReg < portARdata,
          ]),
          portBEn < 0,
          portBWe < 0,
          If(illegalSlot1, then: [
            r[0] < pc + 1,
            portBAddr < Const(MiniRISC4Constants.trapAlignAddr, width: 16),
            portBWe < 0,
            portBEn < 1,
            state < Const(MiniRISC4Constants.stTrapRd, width: 3),
          ], orElse: [
            Case(op, [
              CaseItem(Const(MiniRISC4Constants.opLdReg, width: 4), [
                for (int i = 0; i < 4; i++)
                  If(rr.eq(i), then: [r[i] < getReg(rl)]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opLdImm4, width: 4), [
                r[0] < [Const(0, width: 12), imm4].swizzle(),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opLdPeek, width: 4), [
                portBAddr < getReg(rl),
                portBWe < 0,
                portBEn < 1,
                destReg < rr,
                state < Const(MiniRISC4Constants.stMemRd, width: 3),
              ]),
              CaseItem(Const(MiniRISC4Constants.opLdPoke, width: 4), [
                portBAddr < getReg(rr),
                portBWdata < getReg(rl),
                portBWe < 1,
                portBEn < 1,
                If(getReg(rr).eq(MiniRISC4Constants.addrUartTx), then: [
                  txData < getReg(rl).slice(7, 0),
                  txStrobe < 1,
                ]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opLdPostinc, width: 4), [
                portBAddr < getReg(rl),
                portBWe < 0,
                portBEn < 1,
                destReg < rr,
                for (int i = 0; i < 4; i++)
                  If(rl.eq(i), then: [r[i] < r[i] + 1]),
                state < Const(MiniRISC4Constants.stMemRd, width: 3),
              ]),
              CaseItem(Const(MiniRISC4Constants.opLdPredec, width: 4), [
                for (int i = 0; i < 4; i++)
                  If(rr.eq(i), then: [
                    r[i] < r[i] - 1,
                    portBAddr < r[i] - 1,
                  ]),
                portBWdata < getReg(rl),
                portBWe < 1,
                portBEn < 1,
                If((getReg(rr) - 1).eq(MiniRISC4Constants.addrUartTx), then: [
                  txData < getReg(rl).slice(7, 0),
                  txStrobe < 1,
                ]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opAdd, width: 4), [
                for (int i = 0; i < 4; i++)
                  If(rr.eq(i), then: [r[i] < r[i] + getReg(rl)]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opSub, width: 4), [
                for (int i = 0; i < 4; i++)
                  If(rr.eq(i), then: [r[i] < r[i] - getReg(rl)]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opOr, width: 4), [
                for (int i = 0; i < 4; i++)
                  If(rr.eq(i), then: [r[i] < r[i] | getReg(rl)]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opXor, width: 4), [
                for (int i = 0; i < 4; i++)
                  If(rr.eq(i), then: [r[i] < r[i] ^ getReg(rl)]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opAnd, width: 4), [
                for (int i = 0; i < 4; i++)
                  If(rr.eq(i), then: [r[i] < r[i] & getReg(rl)]),
                _advanceSlotOrFetch(
                    slot, instReg, portAAddr, portAEn, state, pc),
              ]),
              CaseItem(Const(MiniRISC4Constants.opShift, width: 4), [
                Case(rr, [
                  CaseItem(Const(MiniRISC4Constants.subShiftL, width: 2), [
                    for (int i = 0; i < 4; i++)
                      If(rl.eq(i), then: [
                        r[i] < [r[i].slice(14, 0), Const(0, width: 1)].swizzle()
                      ]),
                  ]),
                  CaseItem(Const(MiniRISC4Constants.subShiftR, width: 2), [
                    for (int i = 0; i < 4; i++)
                      If(rl.eq(i), then: [
                        r[i] < [Const(0, width: 1), r[i].slice(15, 1)].swizzle()
                      ]),
                  ]),
                  CaseItem(Const(MiniRISC4Constants.subShiftAr, width: 2), [
                    for (int i = 0; i < 4; i++)
                      If(rl.eq(i), then: [r[i] < asr1(r[i])]),
                  ]),
                  CaseItem(Const(MiniRISC4Constants.subShiftXchg, width: 2), [
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
              CaseItem(Const(MiniRISC4Constants.opJmpZ, width: 4), [
                If(getReg(rl).eq(0), then: [
                  _branchTo(getReg(rr), pc, portAAddr, portAEn, slot, state),
                ], orElse: [
                  _advanceSlotOrFetch(
                      slot, instReg, portAAddr, portAEn, state, pc),
                ]),
              ]),
              CaseItem(Const(MiniRISC4Constants.opJmpM, width: 4), [
                If(getReg(rl)[15].eq(1), then: [
                  _branchTo(getReg(rr), pc, portAAddr, portAEn, slot, state),
                ], orElse: [
                  _advanceSlotOrFetch(
                      slot, instReg, portAAddr, portAEn, state, pc),
                ]),
              ]),
              CaseItem(Const(MiniRISC4Constants.opJmpSpecial, width: 4), [
                Case(rr, [
                  CaseItem(Const(MiniRISC4Constants.subJmp, width: 2), [
                    _branchTo(getReg(rl), pc, portAAddr, portAEn, slot, state),
                  ]),
                  CaseItem(Const(MiniRISC4Constants.subLink, width: 2), [
                    r[0] < pc + 1,
                    _branchTo(getReg(rl), pc, portAAddr, portAEn, slot, state),
                  ]),
                  CaseItem(Const(MiniRISC4Constants.subPush8, width: 2), [
                    for (int i = 0; i < 4; i++)
                      If(rl.eq(i), then: [
                        r[i] <
                            [r[i].slice(7, 0), portARdata.slice(15, 8)]
                                .swizzle(),
                      ]),
                    _branchTo(pc + 1, pc, portAAddr, portAEn, slot, state),
                  ]),
                  CaseItem(Const(MiniRISC4Constants.subTrap, width: 2), [
                    portBAddr <
                        Const(MiniRISC4Constants.trapTableBase, width: 16) +
                            (getReg(rl) & Const(0x000F, width: 16)),
                    r[0] < pc + 1,
                    portBWe < 0,
                    portBEn < 1,
                    state < Const(MiniRISC4Constants.stTrapRd, width: 3),
                  ]),
                ]),
              ]),
            ]),
          ]),
        ]),
        CaseItem(Const(MiniRISC4Constants.stMemRd, width: 3), [
          portBEn < 0,
          for (int i = 0; i < 4; i++)
            If(destReg.eq(i), then: [r[i] < effectivePortBData]),
          _advanceSlotOrFetch(slot, instReg, portAAddr, portAEn, state, pc),
        ]),
        CaseItem(Const(MiniRISC4Constants.stTrapRd, width: 3), [
          portBEn < 0,
          pc < effectivePortBData,
          state < Const(MiniRISC4Constants.stFetch, width: 3),
        ]),
      ], defaultItem: [
        state < Const(MiniRISC4Constants.stReset, width: 3),
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

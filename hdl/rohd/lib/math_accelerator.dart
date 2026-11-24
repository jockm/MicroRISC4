// ==============================================================================
// FILE: hdl/rohd/lib/math_accelerator.dart
// Lean 1-DSP (18x18) Multi-Cycle 32-Bit Math & Barrel Shift Accelerator
// MMIO Range: 0x0010 - 0x0016 (optional per-core coprocessor, 0 MHz Fmax cost)
// ==============================================================================

import 'package:rohd/rohd.dart';

/// Synthesizable registered 17x17 -> 34-bit signed multiplier.
/// Infers a single Lattice ECP5 MULT18X18D DSP slice with built-in output
/// register (>180 MHz) and a clean single 17x17 signed multiplier on ASIC.
class SignedMul17x17 extends Module with SystemVerilog {
  SignedMul17x17({
    required Logic clk,
    required Logic a,
    required Logic b,
    super.name = 'signed_mul_17x17',
  }) {
    clk = addInput('clk', clk);
    a = addInput('a', a, width: 17);
    b = addInput('b', b, width: 17);
    final p = addOutput('p', width: 34);

    // Cycle-accurate Dart simulation matching always_ff @(posedge clk) p <= a * b;
    // Latch pre-edge inputs through ROHD Sequential so non-blocking edge order
    // is 100% deterministic (identical to TdpBram / NocFifoRam).
    final aQ = Logic(name: 'a_q_sim', width: 17)..put(0);
    final bQ = Logic(name: 'b_q_sim', width: 17)..put(0);
    final pSim = Logic(name: 'p_sim', width: 34)..put(0);
    p <= pSim;

    BigInt toSigned17(Logic sig) {
      if (!sig.value.isValid) return BigInt.zero;
      final v = sig.value.toBigInt();
      return (v & (BigInt.one << 16)) != BigInt.zero
          ? v - (BigInt.one << 17)
          : v;
    }

    final mask34 = (BigInt.one << 34) - BigInt.one;
    void updateProd() {
      final prod = (toSigned17(aQ) * toSigned17(bQ)) & mask34;
      pSim.put(LogicValue.ofBigInt(prod, 34));
    }

    Sequential(clk, [
      aQ < a,
      bQ < b,
    ]);
    aQ.changed.listen((_) => updateProd());
    bQ.changed.listen((_) => updateProd());
  }

  Logic get p => output('p');

  @override
  String definitionVerilog(String definitionType) => '''
module $definitionType (
  input  logic clk,
  input  logic signed [16:0] a,
  input  logic signed [16:0] b,
  output logic signed [33:0] p
);
  always_ff @(posedge clk) begin
    p <= a * b;
  end
endmodule
''';
}

/// Optional per-core 32-bit Integer Math & Barrel-Shift Coprocessor (0x0010-0x0016):
///   0x0010 MATH_A_LO     (R/W): Operand A[15:0]
///   0x0011 MATH_A_HI     (R/W): Operand A[31:16]
///   0x0012 MATH_B_LO     (R/W): Operand B[15:0] / shift amount B[4:0]
///   0x0013 MATH_B_HI     (R/W): Operand B[31:16]
///   0x0014 MATH_CMD_STAT (R/W): Write opcode trigger; Read {14'b0, divByZero, busy}
///   0x0015 MATH_RES_LO   (R)  : Result[15:0]
///   0x0016 MATH_RES_HI   (R)  : Result[31:16]
///
/// Supported Opcodes (MATH_CMD_STAT[3:0]):
///   0x0 MUL    (6 cycles)  : (A * B)[31:0]
///   0x1 MULH   (6 cycles)  : (A_s * B_s)[63:32]
///   0x2 MULHU  (6 cycles)  : (A_u * B_u)[63:32]
///   0x3 MULHSU (6 cycles)  : (A_s * B_u)[63:32]
///   0x4 DIVU   (34 cycles) : A_u / B_u (div-by-0 -> 0xFFFFFFFF, flag bit 1)
///   0x5 REMU   (34 cycles) : A_u % B_u (div-by-0 -> A, flag bit 1)
///   0x6 DIV    (34 cycles) : A_s / B_s (trunc toward 0; -2^31/-1 -> -2^31)
///   0x7 REM    (34 cycles) : A_s % B_s (sign matches dividend A)
///   0x8 SLL    (1 cycle)   : A << B[4:0]
///   0x9 SRL    (1 cycle)   : A >>> B[4:0] (logical)
///   0xA SRA    (1 cycle)   : A >> B[4:0]  (arithmetic)
class MathAccelerator extends Module {
  final int baseAddr;

  static const int cmdMul = 0x0;
  static const int cmdMulh = 0x1;
  static const int cmdMulhu = 0x2;
  static const int cmdMulhsu = 0x3;
  static const int cmdDivu = 0x4;
  static const int cmdRemu = 0x5;
  static const int cmdDiv = 0x6;
  static const int cmdRem = 0x7;
  static const int cmdSll = 0x8;
  static const int cmdSrl = 0x9;
  static const int cmdSra = 0xA;

  // Multi-cycle FSM states
  static const int _stIdle = 0;
  static const int _stMul0 = 1;
  static const int _stMul1 = 2;
  static const int _stMul2 = 3;
  static const int _stMul3 = 4;
  static const int _stMul4 = 5;
  static const int _stDivRun = 6;
  static const int _stDivFinish = 7;

  MathAccelerator({
    required Logic clk,
    required Logic rstN,
    required Logic portBAddr,
    required Logic portBWdata,
    required Logic portBWe,
    required Logic portBEn,
    this.baseAddr = 0x0010,
    super.name = 'math_accelerator',
  }) {
    assert((baseAddr & 0xF) == 0, 'MathAccelerator baseAddr must be 16-word aligned');

    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    final addr = addInput('port_b_addr', portBAddr, width: 16);
    final wdata = addInput('port_b_wdata', portBWdata, width: 16);
    final we = addInput('port_b_we', portBWe);
    final en = addInput('port_b_en', portBEn);

    final rdata = addOutput('rdata', width: 16);
    final busy = addOutput('busy');
    final match = addOutput('match');

    // Fast 2-LUT4 address decode (strictly independent of portBEn so 2-cycle
    // CpuCore Port B reads sample match=1 cleanly in _memWait2!).
    final isPage = addr.slice(15, 4).eq(Const(baseAddr >> 4, width: 12));
    final off = addr.slice(3, 0);
    match <= isPage & off.lte(Const(6, width: 4));

    // Architectural Operand & Result Registers
    final opALo = Logic(name: 'op_a_lo', width: 16);
    final opAHi = Logic(name: 'op_a_hi', width: 16);
    final opBLo = Logic(name: 'op_b_lo', width: 16);
    final opBHi = Logic(name: 'op_b_hi', width: 16);
    final resLo = Logic(name: 'res_lo', width: 16);
    final resHi = Logic(name: 'res_hi', width: 16);

    // FSM & Shared Multi-Cycle Datapath Registers
    final stateQ = Logic(name: 'state_q', width: 3);
    final busyQ = Logic(name: 'busy_q');
    final divByZeroQ = Logic(name: 'div_by_zero_q');
    final cmdQ = Logic(name: 'cmd_q', width: 4);
    final accLoQ = Logic(name: 'acc_lo_q', width: 32);
    final accHiQ = Logic(name: 'acc_hi_q', width: 32);
    final divBQ = Logic(name: 'div_b_q', width: 32);
    final divCntQ = Logic(name: 'div_cnt_q', width: 5);
    final quotNegQ = Logic(name: 'quot_neg_q');
    final remNegQ = Logic(name: 'rem_neg_q');

    // Registered inputs to single 17x17 signed DSP multiplier
    final mulXQ = Logic(name: 'mul_x_q', width: 17);
    final mulYQ = Logic(name: 'mul_y_q', width: 17);
    final mulUnit = SignedMul17x17(
      clk: clk,
      a: mulXQ,
      b: mulYQ,
      name: '${name}_dsp',
    );
    final mulProd = mulUnit.p;

    busy <= busyQ;

    // 32-bit operand views & limb sign-extensions for 1-DSP 32x32 multiply
    final opA32 = [opAHi, opALo].swizzle();
    final opB32 = [opBHi, opBLo].swizzle();
    final cmdIn = wdata.slice(3, 0);

    final aLo17 = [Const(0, width: 1), opALo].swizzle();
    final bLo17 = [Const(0, width: 1), opBLo].swizzle();
    final aSignedQ =
        cmdQ.eq(Const(cmdMulh, width: 4)) | cmdQ.eq(Const(cmdMulhsu, width: 4));
    final bSignedQ = cmdQ.eq(Const(cmdMulh, width: 4));
    final aHi17 = [aSignedQ & opAHi[15], opAHi].swizzle();
    final bHi17 = [bSignedQ & opBHi[15], opBHi].swizzle();

    // 48-bit partial-product accumulation into {accHiQ[31:0], accLoQ[31:16]}
    final accUpper48 = [accHiQ, accLoQ.slice(31, 16)].swizzle();
    final prodSext48 = mulProd.signExtend(48);
    final accUpper48Next = accUpper48 + prodSext48;
    final finalMulHi32 = accHiQ + mulProd.slice(31, 0);

    // 32-bit restoring divider step: shift left {accHiQ, accLoQ} & trial subtract divBQ
    final shiftedRem = [accHiQ.slice(30, 0), accLoQ[31]].swizzle();
    final trialDiff33 =
        [Const(0, width: 1), shiftedRem].swizzle() -
        [Const(0, width: 1), divBQ].swizzle();
    final divGe = ~trialDiff33[32];
    final nextRem = mux(divGe, trialDiff33.slice(31, 0), shiftedRem);
    final nextQuot = [accLoQ.slice(30, 0), divGe].swizzle();

    // Signed absolute-value & sign-restoration helpers
    final negA32 = Const(0, width: 32) - opA32;
    final negB32 = Const(0, width: 32) - opB32;
    final isCmdSignedDiv = cmdIn[1];
    final absA32 = mux(isCmdSignedDiv & opA32[31], negA32, opA32);
    final absB32 = mux(isCmdSignedDiv & opB32[31], negB32, opB32);
    final bIsZero = opBLo.eq(Const(0, width: 16)) & opBHi.eq(Const(0, width: 16));

    final negQuot32 = Const(0, width: 32) - accLoQ;
    final negRem32 = Const(0, width: 32) - accHiQ;
    final finalQuot32 = mux(quotNegQ, negQuot32, accLoQ);
    final finalRem32 = mux(remNegQ, negRem32, accHiQ);
    final finalDivRes32 = mux(cmdQ[0], finalRem32, finalQuot32);

    // 32-bit Barrel Shifter (1-cycle registered on CMD write)
    final shamt = opBLo.slice(4, 0);
    final sllRes = opA32 << shamt;
    final srlRes = opA32 >>> shamt;
    // Arithmetic right shift: replicate sign bit opA32[31] across shifted-in bits
    Logic sraStage(Logic v, int shift, Logic sel) {
      final shifted = [
        Const(0, width: shift) |
            mux(v[31], Const((1 << shift) - 1, width: shift),
                Const(0, width: shift)),
        v.slice(31, shift),
      ].swizzle();
      return mux(sel, shifted, v);
    }
    var sraRes = opA32;
    sraRes = sraStage(sraRes, 1, shamt[0]);
    sraRes = sraStage(sraRes, 2, shamt[1]);
    sraRes = sraStage(sraRes, 4, shamt[2]);
    sraRes = sraStage(sraRes, 8, shamt[3]);
    sraRes = sraStage(sraRes, 16, shamt[4]);

    final shiftRes32 = mux(
      cmdIn[1],
      sraRes,
      mux(cmdIn[0], srlRes, sllRes),
    );

    final wrValid = en & we & isPage;
    final statusWord = [Const(0, width: 14), divByZeroQ, busyQ].swizzle();

    Sequential(clk, reset: ~rstN, resetValues: {
      opALo: Const(0, width: 16),
      opAHi: Const(0, width: 16),
      opBLo: Const(0, width: 16),
      opBHi: Const(0, width: 16),
      resLo: Const(0, width: 16),
      resHi: Const(0, width: 16),
      stateQ: Const(_stIdle, width: 3),
      busyQ: Const(0, width: 1),
      divByZeroQ: Const(0, width: 1),
      cmdQ: Const(0, width: 4),
      accLoQ: Const(0, width: 32),
      accHiQ: Const(0, width: 32),
      divBQ: Const(0, width: 32),
      divCntQ: Const(0, width: 5),
      quotNegQ: Const(0, width: 1),
      remNegQ: Const(0, width: 1),
      mulXQ: Const(0, width: 17),
      mulYQ: Const(0, width: 17),
    }, [
      // Operand writes (allowed whenever idle, or anytime before CMD trigger)
      If(wrValid, then: [
        Case(off, [
          CaseItem(Const(0, width: 4), [opALo < wdata]),
          CaseItem(Const(1, width: 4), [opAHi < wdata]),
          CaseItem(Const(2, width: 4), [opBLo < wdata]),
          CaseItem(Const(3, width: 4), [opBHi < wdata]),
        ]),
      ]),

      // Multi-Cycle Execution FSM
      Case(stateQ, [
        CaseItem(Const(_stIdle, width: 3), [
          If(wrValid & off.eq(Const(4, width: 4)), then: [
            cmdQ < cmdIn,
            divByZeroQ < 0,
            If(cmdIn.slice(3, 2).eq(Const(0, width: 2)), then: [
              // 0x0..0x3: 32x32 Multiply (MUL / MULH / MULHU / MULHSU) via 1 DSP
              mulXQ < aLo17,
              mulYQ < bLo17,
              busyQ < 1,
              stateQ < Const(_stMul0, width: 3),
            ], orElse: [
              If(cmdIn.slice(3, 2).eq(Const(1, width: 2)), then: [
                // 0x4..0x7: 32-bit Divide / Remainder (DIVU / REMU / DIV / REM)
                If(bIsZero, then: [
                  divByZeroQ < 1,
                  resLo < mux(cmdIn[0], opALo, Const(0xFFFF, width: 16)),
                  resHi < mux(cmdIn[0], opAHi, Const(0xFFFF, width: 16)),
                  busyQ < 0,
                ], orElse: [
                  accLoQ < absA32,
                  accHiQ < Const(0, width: 32),
                  divBQ < absB32,
                  divCntQ < Const(31, width: 5),
                  quotNegQ < (isCmdSignedDiv & (opA32[31] ^ opB32[31])),
                  remNegQ < (isCmdSignedDiv & opA32[31]),
                  busyQ < 1,
                  stateQ < Const(_stDivRun, width: 3),
                ]),
              ], orElse: [
                // 0x8..0xA: 32-bit Barrel Shifts (SLL / SRL / SRA) — 1 cycle!
                resLo < shiftRes32.slice(15, 0),
                resHi < shiftRes32.slice(31, 16),
                busyQ < 0,
              ]),
            ]),
          ]),
        ]),

        // MUL0: DSP computing p0 = aLo * bLo; feed p1 = aLo * bHi
        CaseItem(Const(_stMul0, width: 3), [
          mulXQ < aLo17,
          mulYQ < bHi17,
          stateQ < Const(_stMul1, width: 3),
        ]),

        // MUL1: Capture p0 (unsigned 32-bit); feed p2 = aHi * bLo
        CaseItem(Const(_stMul1, width: 3), [
          accLoQ < mulProd.slice(31, 0),
          accHiQ < Const(0, width: 32),
          mulXQ < aHi17,
          mulYQ < bLo17,
          stateQ < Const(_stMul2, width: 3),
        ]),

        // MUL2: Accumulate p1 << 16; feed p3 = aHi * bHi
        CaseItem(Const(_stMul2, width: 3), [
          accLoQ < [accUpper48Next.slice(15, 0), accLoQ.slice(15, 0)].swizzle(),
          accHiQ < accUpper48Next.slice(47, 16),
          mulXQ < aHi17,
          mulYQ < bHi17,
          stateQ < Const(_stMul3, width: 3),
        ]),

        // MUL3: Accumulate p2 << 16
        CaseItem(Const(_stMul3, width: 3), [
          accLoQ < [accUpper48Next.slice(15, 0), accLoQ.slice(15, 0)].swizzle(),
          accHiQ < accUpper48Next.slice(47, 16),
          stateQ < Const(_stMul4, width: 3),
        ]),

        // MUL4: Accumulate p3 << 32 and commit 32-bit result (low for MUL, high for MULH*)
        CaseItem(Const(_stMul4, width: 3), [
          If(cmdQ.eq(Const(cmdMul, width: 4)), then: [
            resLo < accLoQ.slice(15, 0),
            resHi < accLoQ.slice(31, 16),
          ], orElse: [
            resLo < finalMulHi32.slice(15, 0),
            resHi < finalMulHi32.slice(31, 16),
          ]),
          busyQ < 0,
          stateQ < Const(_stIdle, width: 3),
        ]),

        // DIV_RUN: 32-cycle restoring unsigned division
        CaseItem(Const(_stDivRun, width: 3), [
          accHiQ < nextRem,
          accLoQ < nextQuot,
          If(divCntQ.eq(Const(0, width: 5)), then: [
            stateQ < Const(_stDivFinish, width: 3),
          ], orElse: [
            divCntQ < divCntQ - Const(1, width: 5),
          ]),
        ]),

        // DIV_FINISH: Apply signed result negation and commit resLo/resHi
        CaseItem(Const(_stDivFinish, width: 3), [
          resLo < finalDivRes32.slice(15, 0),
          resHi < finalDivRes32.slice(31, 16),
          busyQ < 0,
          stateQ < Const(_stIdle, width: 3),
        ]),
      ]),
    ]);

    // Combinational Read MUX (sampled by CpuCore in _memWait2)
    Combinational([
      Case(off, [
        CaseItem(Const(0, width: 4), [rdata < opALo]),
        CaseItem(Const(1, width: 4), [rdata < opAHi]),
        CaseItem(Const(2, width: 4), [rdata < opBLo]),
        CaseItem(Const(3, width: 4), [rdata < opBHi]),
        CaseItem(Const(4, width: 4), [rdata < statusWord]),
        CaseItem(Const(5, width: 4), [rdata < resLo]),
        CaseItem(Const(6, width: 4), [rdata < resHi]),
      ], defaultItem: [
        rdata < Const(0, width: 16),
      ]),
    ]);
  }

  Logic get rdata => output('rdata');
  Logic get match => output('match');
  Logic get busy => output('busy');
}

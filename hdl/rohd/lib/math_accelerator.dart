// ==============================================================================
// FILE: hdl/rohd/lib/math_accelerator.dart
// ==============================================================================

import 'package:rohd/rohd.dart';

class MathAccelerator extends Module {
  final int baseAddr;

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
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    final addr = addInput('port_b_addr', portBAddr, width: 16);
    final wdata = addInput('port_b_wdata', portBWdata, width: 16);
    final we = addInput('port_b_we', portBWe);
    final en = addInput('port_b_en', portBEn);

    final rdata = addOutput('rdata', width: 16);
    final busy = addOutput('busy');
    final match = addOutput('match');

    final opALo = Logic(name: 'op_a_lo', width: 16);
    final opAHi = Logic(name: 'op_a_hi', width: 16);
    final opBLo = Logic(name: 'op_b_lo', width: 16);
    final opBHi = Logic(name: 'op_b_hi', width: 16);
    final resLo = Logic(name: 'res_lo', width: 16);
    final resHi = Logic(name: 'res_hi', width: 16);

    match <=
        en &
            (addr.gte(Const(baseAddr, width: 16))) &
            (addr.lte(Const(baseAddr + 6, width: 16)));
    busy <= Const(0);

    final opA32 = [opAHi, opALo].swizzle();
    final opB32 = [opBHi, opBLo].swizzle();
    final shamt = opB32.slice(4, 0);

    // Multipliers
    final prodUnsigned = opA32.zeroExtend(64) * opB32.zeroExtend(64);
    final prodSigned = opA32.signExtend(64) * opB32.signExtend(64);

    // Barrel Shifters
    final sllRes = opA32 << shamt;
    final srlRes = opA32 >>> shamt;

    Sequential(clk, reset: ~rstN, resetValues: {
      opALo: 0,
      opAHi: 0,
      opBLo: 0,
      opBHi: 0,
      resLo: 0,
      resHi: 0,
    }, [
      If(en & we, then: [
        Case(addr, [
          CaseItem(Const(baseAddr + 0, width: 16), [opALo < wdata]),
          CaseItem(Const(baseAddr + 1, width: 16), [opAHi < wdata]),
          CaseItem(Const(baseAddr + 2, width: 16), [opBLo < wdata]),
          CaseItem(Const(baseAddr + 3, width: 16), [opBHi < wdata]),
          CaseItem(Const(baseAddr + 4, width: 16), [
            Case(wdata.slice(3, 0), [
              // 0: MUL
              CaseItem(Const(0, width: 4), [
                resLo < prodUnsigned.slice(15, 0),
                resHi < prodUnsigned.slice(31, 16),
              ]),
              // 1: MULH
              CaseItem(Const(1, width: 4), [
                resLo < prodSigned.slice(47, 32),
                resHi < prodSigned.slice(63, 48),
              ]),
              // 2: MULHU
              CaseItem(Const(2, width: 4), [
                resLo < prodUnsigned.slice(47, 32),
                resHi < prodUnsigned.slice(63, 48),
              ]),
              // 8: SLL
              CaseItem(Const(8, width: 4), [
                resLo < sllRes.slice(15, 0),
                resHi < sllRes.slice(31, 16),
              ]),
              // 9: SRL
              CaseItem(Const(9, width: 4), [
                resLo < srlRes.slice(15, 0),
                resHi < srlRes.slice(31, 16),
              ]),
            ]),
          ]),
        ]),
      ]),
    ]);

    Combinational([
      Case(addr, [
        CaseItem(Const(baseAddr + 0, width: 16), [rdata < opALo]),
        CaseItem(Const(baseAddr + 1, width: 16), [rdata < opAHi]),
        CaseItem(Const(baseAddr + 2, width: 16), [rdata < opBLo]),
        CaseItem(Const(baseAddr + 3, width: 16), [rdata < opBHi]),
        CaseItem(Const(baseAddr + 4, width: 16), [rdata < Const(0, width: 16)]),
        CaseItem(Const(baseAddr + 5, width: 16), [rdata < resLo]),
        CaseItem(Const(baseAddr + 6, width: 16), [rdata < resHi]),
      ], defaultItem: [
        rdata < Const(0, width: 16),
      ]),
    ]);
  }

  Logic get rdata => output('rdata');
  Logic get match => output('match');
  Logic get busy => output('busy');
}

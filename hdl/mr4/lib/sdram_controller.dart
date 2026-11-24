// ==============================================================================
// FILE: hdl/mr4/lib/sdram_controller.dart
// Architecture: MicroRISC4 JEDEC SDRAM PHY & Burst Controller (ULX3S IS42S16160G)
// Framework: Intel ROHD (Dart)
// ==============================================================================

import 'package:rohd/rohd.dart';

/// 16-bit rising-edge IOB input capture register (`(* syn_useioff = 1 *)`).
///
/// Packs all 16 SDRAM DQ input flip-flops directly into the ECP5 PIO IOLOGIC
/// pads (`0.0 ns` fabric input routing delay across all pins `sdram_d[15:0]`),
/// capturing `DOUT[0..7]` cleanly on `posedge E3..E10` with uniform setup &
/// hold margin on every single bit regardless of die placement.
class PosedgeIobReg16 extends Module with SystemVerilog {
  PosedgeIobReg16({
    required Logic clk,
    required Logic d,
    super.name = 'sdram_dq_iob_reg',
  }) {
    clk = addInput('clk', clk);
    d = addInput('d', d, width: 16);
    final q = addOutput('q', width: 16);
    Sequential(clk, [q < d]);
  }

  Logic get q => output('q');

  @override
  String definitionVerilog(String definitionType) => '''
module $definitionType (
  input  logic clk,
  input  logic [15:0] d,
  output logic [15:0] q
);
  (* syn_useioff = 1 *)
  logic [15:0] q_iob;
  always_ff @(posedge clk) begin
    q_iob <= d;
  end
  assign q = q_iob;
endmodule
''';
}

/// Synthesizable JEDEC SDRAM controller targeting the ULX3S-85F 32 MB
/// `IS42S16160G` (16M x 16-bit: 4 banks x 8192 rows x 512 cols).
///
/// Features:
/// - JEDEC power-on init (configurable wait + PRECHARGE ALL + 8x AUTO REFRESH + LMR)
/// - Programmed sequential burst length (`burstLen`: 1, 2, 4, or 8 words) & CAS latency
/// - Periodic `tREFI` AUTO REFRESH scheduler (`refPendingQ`) preempting idle cycles
/// - Clean ready/valid burst read (`rdata`/`rdata_valid`) and burst write
///   (`wdata`/`wdata_valid`/`wdata_ready`) with proper `tRCD`, `tWR`, `tRP`, `tRFC`
class SdramController extends Module {
  final int clkFreqMhz;
  final int casLatency;
  final int burstLen;
  final int initWaitCycles;
  final int refreshCycles;
  final bool useIobInputReg;
  final int extraReadPipeCycles;

  static const int _stWait = 0;
  static const int _stInitPre = 1;
  static const int _stInitRef = 2;
  static const int _stLmr = 3;
  static const int _stIdle = 4;
  static const int _stRef = 5;
  static const int _stAct = 6;
  static const int _stRd = 7;
  static const int _stWrStart = 8;
  static const int _stWr = 9;
  static const int _stWrRec = 10;
  static const int _stPchg = 11;

  static int _burstCode(int len) {
    switch (len) {
      case 1:
        return 0;
      case 2:
        return 1;
      case 4:
        return 2;
      case 8:
        return 3;
      default:
        throw ArgumentError('SDRAM burstLen must be 1, 2, 4, or 8 (got $len)');
    }
  }

  SdramController({
    required Logic clk,
    required Logic rstN,
    required Logic cmdReq,
    required Logic cmdRw,
    required Logic cmdAddr,
    required Logic cmdBurstLen,
    required Logic wdata,
    required Logic wdataValid,
    required Logic sdramDqIn,
    this.clkFreqMhz = 48,
    this.casLatency = 2,
    this.burstLen = 8,
    this.useIobInputReg = true,
    this.extraReadPipeCycles = 0,
    int? initWaitCycles,
    int? refreshCycles,
    super.name = 'sdram_controller',
  })  : initWaitCycles = initWaitCycles ?? (clkFreqMhz * 120),
        refreshCycles = refreshCycles ?? ((clkFreqMhz * 75) ~/ 10) {
    assert(casLatency == 2 || casLatency == 3, 'casLatency must be 2 or 3');
    final lmrVal = ((casLatency & 0x7) << 4) | _burstCode(burstLen);

    // Timing cycles derived from clkFreqMhz (IS42S16160G-7TL datasheet minimums)
    int nsToCycles(int ns, int minCycles) {
      final c = ((ns * clkFreqMhz) + 999) ~/ 1000;
      return c < minCycles ? minCycles : c;
    }

    final tRp = nsToCycles(20, 2);
    final tRcd = nsToCycles(20, 2);
    final tRfc = nsToCycles(66, 4);
    final tWr = nsToCycles(15, 2);

    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    cmdReq = addInput('cmd_req', cmdReq);
    cmdRw = addInput('cmd_rw', cmdRw);
    cmdAddr = addInput('cmd_addr', cmdAddr, width: 24);
    cmdBurstLen = addInput('cmd_burst_len', cmdBurstLen, width: 8);
    wdata = addInput('wdata', wdata, width: 16);
    wdataValid = addInput('wdata_valid', wdataValid);
    sdramDqIn = addInput('sdram_dq_in', sdramDqIn, width: 16);
    final sampledDqIn = useIobInputReg
        ? PosedgeIobReg16(clk: clk, d: sdramDqIn, name: '${name}_dq_iob').q
        : sdramDqIn;
    // JEDEC CL timing with phase-shifted sdram_clk:
    // - At 48 MHz (180° inverted sdram_clk, extraReadPipeCycles=0):
    //     P0: READ; S0: SDRAM latches READ; S1+tAC drives D0 valid before P2;
    //     IOB reg captures D0 at P2 and SdramController latches rdata at P3 (effCasWait = CL = 2).
    // - At 60–96 MHz (270°–306° PLL CLKOS2 sdram_clk, extraReadPipeCycles=1):
    //     t_ODDR + t_AC (~7–8 ns) pushes D0 arrival past P2, cleanly centered
    //     for P3 IOB capture and P4 rdata latch (effCasWait = CL + 1 = 3).
    final effCasWait =
        (useIobInputReg ? casLatency : (casLatency - 1)) + extraReadPipeCycles;

    final cmdReady = addOutput('cmd_ready');
    final busy = addOutput('busy');
    final wdataReady = addOutput('wdata_ready');
    final rdata = addOutput('rdata', width: 16);
    final rdataValid = addOutput('rdata_valid');

    // Physical SDRAM Outputs
    final sdramCke = addOutput('sdram_cke');
    final sdramCsN = addOutput('sdram_cs_n');
    final sdramRasN = addOutput('sdram_ras_n');
    final sdramCasN = addOutput('sdram_cas_n');
    final sdramWeN = addOutput('sdram_we_n');
    final sdramBa = addOutput('sdram_ba', width: 2);
    final sdramA = addOutput('sdram_a', width: 13);
    final sdramDqm = addOutput('sdram_dqm', width: 2);
    final sdramDqOut = addOutput('sdram_dq_out', width: 16);
    final sdramDqOe = addOutput('sdram_dq_oe');

    sdramCke <= Const(1);
    sdramDqm <= Const(0, width: 2);

    final reset = ~rstN;

    final state = Logic(name: 'state', width: 4);
    final effInitWait = this.initWaitCycles;
    final effRefresh = this.refreshCycles;
    final timerWidth = effInitWait > 16 ? effInitWait.bitLength : 16;
    final timer = Logic(name: 'timer', width: timerWidth);
    final initRefCnt = Logic(name: 'init_ref_cnt', width: 3);
    final burstCnt = Logic(name: 'burst_cnt', width: 8);
    final casTimer = Logic(name: 'cas_timer', width: 4);

    // Periodic AUTO REFRESH timer
    final refCntWidth = effRefresh > 1 ? (effRefresh - 1).bitLength : 1;
    final refTimer = Logic(name: 'ref_timer', width: refCntWidth);
    final refPendingQ = Logic(name: 'ref_pending_q');

    final reqRw = Logic(name: 'req_rw');
    final reqBank = Logic(name: 'req_bank', width: 2);
    final reqRow = Logic(name: 'req_row', width: 13);
    final reqCol = Logic(name: 'req_col', width: 9);
    final reqBurstLen = Logic(name: 'req_burst_len', width: 8);

    final isIdle = state.eq(Const(_stIdle, width: 4));
    final isWrStart = state.eq(Const(_stWrStart, width: 4));
    final isWr = state.eq(Const(_stWr, width: 4));

    // Clean combinational handshakes straight from registered FSM state
    cmdReady <= isIdle & (~refPendingQ);
    busy <= ~isIdle;
    wdataReady <= isWrStart | isWr;

    final inInit = state.lt(Const(_stIdle, width: 4));
    final refTick = (~inInit) & refTimer.eq(Const(0, width: refCntWidth));

    Sequential(clk, reset: reset, resetValues: {
      state: Const(_stWait, width: 4),
      timer: Const(effInitWait, width: timerWidth),
      initRefCnt: Const(7, width: 3), // 8 AUTO REFRESH cycles during init
      burstCnt: Const(0, width: 8),
      casTimer: Const(0, width: 4),
      refTimer: Const(effRefresh - 1, width: refCntWidth),
      refPendingQ: Const(0),
      reqRw: Const(0),
      reqBank: Const(0, width: 2),
      reqRow: Const(0, width: 13),
      reqCol: Const(0, width: 9),
      reqBurstLen: Const(burstLen, width: 8),
      rdata: Const(0, width: 16),
      rdataValid: Const(0),
      sdramDqOe: Const(0),
      sdramDqOut: Const(0, width: 16),
      sdramCsN: Const(0),
      sdramRasN: Const(1),
      sdramCasN: Const(1),
      sdramWeN: Const(1),
      sdramBa: Const(0, width: 2),
      sdramA: Const(0, width: 13),
    }, [
      // Default NOP on SDRAM command pins every cycle
      sdramCsN < 0,
      sdramRasN < 1,
      sdramCasN < 1,
      sdramWeN < 1,
      rdataValid < 0,

      // Periodic refresh countdown (active once init finishes)
      If(~inInit, then: [
        If(refTick, then: [
          refTimer < Const(effRefresh - 1, width: refCntWidth),
          refPendingQ < 1,
        ], orElse: [
          refTimer < refTimer - Const(1, width: refCntWidth),
        ]),
      ]),

      Case(state, [
        // 0. Power-on wait -> PRECHARGE ALL
        CaseItem(Const(_stWait, width: 4), [
          If(timer.eq(0), then: [
            sdramRasN < 0,
            sdramWeN < 0, // PRECHARGE ALL
            sdramA < Const(1 << 10, width: 13),
            timer < Const(tRp - 1, width: timerWidth),
            state < Const(_stInitPre, width: 4),
          ], orElse: [
            timer < timer - Const(1, width: timerWidth),
          ]),
        ]),

        // 1. Precharge delay -> first AUTO REFRESH
        CaseItem(Const(_stInitPre, width: 4), [
          If(timer.eq(0), then: [
            sdramRasN < 0,
            sdramCasN < 0, // AUTO REFRESH
            timer < Const(tRfc - 1, width: timerWidth),
            state < Const(_stInitRef, width: 4),
          ], orElse: [
            timer < timer - Const(1, width: timerWidth),
          ]),
        ]),

        // 2. 8x AUTO REFRESH -> Load Mode Register (LMR)
        CaseItem(Const(_stInitRef, width: 4), [
          If(timer.eq(0), then: [
            If(initRefCnt.gt(0), then: [
              sdramRasN < 0,
              sdramCasN < 0, // AUTO REFRESH
              initRefCnt < initRefCnt - Const(1, width: 3),
              timer < Const(tRfc - 1, width: timerWidth),
            ], orElse: [
              sdramRasN < 0,
              sdramCasN < 0,
              sdramWeN < 0, // LMR
              sdramBa < Const(0, width: 2),
              sdramA < Const(lmrVal, width: 13),
              timer < Const(2, width: timerWidth),
              state < Const(_stLmr, width: 4),
            ]),
          ], orElse: [
            timer < timer - Const(1, width: timerWidth),
          ]),
        ]),

        // 3. LMR tMRD delay -> IDLE
        CaseItem(Const(_stLmr, width: 4), [
          If(timer.eq(0), then: [
            state < Const(_stIdle, width: 4),
          ], orElse: [
            timer < timer - Const(1, width: timerWidth),
          ]),
        ]),

        // 4. IDLE: service pending AUTO REFRESH first, otherwise accept cmdReq
        CaseItem(Const(_stIdle, width: 4), [
          sdramDqOe < 0,
          If(refPendingQ, then: [
            sdramRasN < 0,
            sdramCasN < 0, // AUTO REFRESH
            refPendingQ < 0,
            timer < Const(tRfc - 1, width: timerWidth),
            state < Const(_stRef, width: 4),
          ], orElse: [
            If(cmdReq, then: [
              reqRw < cmdRw,
              reqBank < cmdAddr.slice(23, 22),
              reqRow < cmdAddr.slice(21, 9),
              reqCol < cmdAddr.slice(8, 0),
              reqBurstLen <
                  mux(cmdBurstLen.eq(0), Const(burstLen, width: 8), cmdBurstLen),
              sdramRasN < 0, // ACTIVE
              sdramBa < cmdAddr.slice(23, 22),
              sdramA < cmdAddr.slice(21, 9),
              timer < Const(tRcd - 1, width: timerWidth),
              state < Const(_stAct, width: 4),
            ]),
          ]),
        ]),

        // 5. Periodic AUTO REFRESH tRFC wait -> IDLE
        CaseItem(Const(_stRef, width: 4), [
          If(timer.eq(0), then: [
            state < Const(_stIdle, width: 4),
          ], orElse: [
            timer < timer - Const(1, width: timerWidth),
          ]),
        ]),

        // 6. ACTIVE tRCD delay -> READ or WRITE burst start
        CaseItem(Const(_stAct, width: 4), [
          If(timer.eq(0), then: [
            burstCnt < reqBurstLen,
            If(~reqRw, then: [
              sdramCasN < 0, // READ
              sdramBa < reqBank,
              sdramA < [Const(0, width: 4), reqCol].swizzle(),
              casTimer < Const(effCasWait, width: 4),
              state < Const(_stRd, width: 4),
            ], orElse: [
              state < Const(_stWrStart, width: 4),
            ]),
          ], orElse: [
            timer < timer - Const(1, width: timerWidth),
          ]),
        ]),

        // 7. Read burst (wait CAS latency, then capture reqBurstLen words)
        CaseItem(Const(_stRd, width: 4), [
          If(casTimer.gt(0), then: [
            casTimer < casTimer - Const(1, width: 4),
          ], orElse: [
            rdata < sampledDqIn,
            rdataValid < 1,
            burstCnt < burstCnt - Const(1, width: 8),
            If(burstCnt.lte(1), then: [
              sdramRasN < 0,
              sdramWeN < 0, // PRECHARGE ALL
              sdramA < Const(1 << 10, width: 13),
              timer < Const(tRp - 1, width: timerWidth),
              state < Const(_stPchg, width: 4),
            ]),
          ]),
        ]),

        // 8. Write beat 0: issue WRITE command on exact cycle wdataValid=1
        CaseItem(Const(_stWrStart, width: 4), [
          If(wdataValid, then: [
            sdramCasN < 0,
            sdramWeN < 0, // WRITE
            sdramBa < reqBank,
            sdramA < [Const(0, width: 4), reqCol].swizzle(),
            sdramDqOe < 1,
            sdramDqOut < wdata,
            burstCnt < burstCnt - Const(1, width: 8),
            If(burstCnt.lte(1), then: [
              timer < Const(tWr - 1, width: timerWidth),
              state < Const(_stWrRec, width: 4),
            ], orElse: [
              state < Const(_stWr, width: 4),
            ]),
          ]),
        ]),

        // 9. Write beats 1..N-1 (1 word/cycle sequential burst)
        CaseItem(Const(_stWr, width: 4), [
          sdramDqOe < 1,
          sdramDqOut < wdata,
          burstCnt < burstCnt - Const(1, width: 8),
          If(burstCnt.lte(1), then: [
            timer < Const(tWr - 1, width: timerWidth),
            state < Const(_stWrRec, width: 4),
          ]),
        ]),

        // 10. Write recovery tWR -> PRECHARGE ALL
        CaseItem(Const(_stWrRec, width: 4), [
          sdramDqOe < 0,
          If(timer.eq(0), then: [
            sdramRasN < 0,
            sdramWeN < 0, // PRECHARGE ALL
            sdramA < Const(1 << 10, width: 13),
            timer < Const(tRp - 1, width: timerWidth),
            state < Const(_stPchg, width: 4),
          ], orElse: [
            timer < timer - Const(1, width: timerWidth),
          ]),
        ]),

        // 11. Precharge tRP -> IDLE
        CaseItem(Const(_stPchg, width: 4), [
          sdramDqOe < 0,
          If(timer.eq(0), then: [
            state < Const(_stIdle, width: 4),
          ], orElse: [
            timer < timer - Const(1, width: timerWidth),
          ]),
        ]),
      ]),
    ]);
  }
}

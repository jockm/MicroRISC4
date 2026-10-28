// ==============================================================================
// FILE: hdl/rohd/lib/sdram_controller.dart
// Architecture: MiniRISC4 SDRAM PHY & Burst Controller
// Framework: Intel ROHD (Dart)
// ==============================================================================

import 'package:rohd/rohd.dart';

class SdramController extends Module {
  final int clkFreqMhz;
  final int casLatency;

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
    this.clkFreqMhz = 25,
    this.casLatency = 2,
    super.name = 'sdram_controller',
  }) {
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    cmdReq = addInput('cmd_req', cmdReq);
    cmdRw = addInput('cmd_rw', cmdRw);
    cmdAddr = addInput('cmd_addr', cmdAddr, width: 24);
    cmdBurstLen = addInput('cmd_burst_len', cmdBurstLen, width: 8);
    wdata = addInput('wdata', wdata, width: 16);
    wdataValid = addInput('wdata_valid', wdataValid);
    sdramDqIn = addInput('sdram_dq_in', sdramDqIn, width: 16);

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

    // Active-high reset for ROHD Sequential
    final reset = ~rstN;

    // Internal Registers
    final state = Logic(name: 'state', width: 4);
    final timer = Logic(name: 'timer', width: 16);
    final burstCnt = Logic(name: 'burst_cnt', width: 8);
    final casTimer = Logic(name: 'cas_timer', width: 4);

    final reqRw = Logic(name: 'req_rw');
    final reqBank = Logic(name: 'req_bank', width: 2);
    final reqRow = Logic(name: 'req_row', width: 13);
    final reqCol = Logic(name: 'req_col', width: 9);

    // States
    const stWait = 0;
    const stPre = 1;
    const stRef0 = 2;
    const stRef1 = 3;
    const stLmr = 4;
    const stIdle = 5;
    const stAct = 6;
    const stRd = 7;
    const stWr = 8;
    const stPchg = 9;

    Sequential(clk, reset: reset, resetValues: {
      state: Const(stWait, width: 4),
      timer: Const(10, width: 16),
      burstCnt: Const(0, width: 8),
      casTimer: Const(0, width: 4),
      reqRw: Const(0),
      reqBank: Const(0, width: 2),
      reqRow: Const(0, width: 13),
      reqCol: Const(0, width: 9),
      cmdReady: Const(0),
      busy: Const(1),
      wdataReady: Const(0),
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
      // Default deassertions every cycle
      sdramCsN < 0,
      sdramRasN < 1,
      sdramCasN < 1,
      sdramWeN < 1, // NOP default
      rdataValid < 0,
      wdataReady < 0,

      Case(state, [
        // 1. Wait initial cycles, then Precharge All
        CaseItem(Const(stWait, width: 4), [
          If(timer.eq(0), then: [
            sdramRasN < 0,
            sdramWeN < 0, // PRECHARGE ALL
            sdramA < Const(1 << 10, width: 13),
            timer < Const(2, width: 16),
            state < Const(stPre, width: 4),
          ], orElse: [
            timer < timer - 1,
          ]),
        ]),

        // 2. Precharge delay -> Refresh 0
        CaseItem(Const(stPre, width: 4), [
          If(timer.eq(0), then: [
            sdramRasN < 0,
            sdramCasN < 0, // REFRESH 0
            timer < Const(4, width: 16),
            state < Const(stRef0, width: 4),
          ], orElse: [
            timer < timer - 1,
          ]),
        ]),

        // 3. Refresh 0 delay -> Refresh 1
        CaseItem(Const(stRef0, width: 4), [
          If(timer.eq(0), then: [
            sdramRasN < 0,
            sdramCasN < 0, // REFRESH 1
            timer < Const(4, width: 16),
            state < Const(stRef1, width: 4),
          ], orElse: [
            timer < timer - 1,
          ]),
        ]),

        // 4. Refresh 1 delay -> Load Mode Register
        CaseItem(Const(stRef1, width: 4), [
          If(timer.eq(0), then: [
            sdramRasN < 0,
            sdramCasN < 0,
            sdramWeN < 0, // LMR
            sdramBa < Const(0, width: 2),
            sdramA < Const(casLatency == 2 ? 0x0020 : 0x0030, width: 13),
            timer < Const(2, width: 16),
            state < Const(stLmr, width: 4),
          ], orElse: [
            timer < timer - 1,
          ]),
        ]),

        // 5. LMR delay -> Enter IDLE
        CaseItem(Const(stLmr, width: 4), [
          If(timer.eq(0), then: [
            state < Const(stIdle, width: 4),
            cmdReady < 1,
            busy < 0,
          ], orElse: [
            timer < timer - 1,
          ]),
        ]),

        // 6. Idle: await command
        CaseItem(Const(stIdle, width: 4), [
          sdramDqOe < 0,
          If(cmdReq, then: [
            cmdReady < 0,
            busy < 1,
            reqRw < cmdRw,
            reqBank < cmdAddr.slice(23, 22),
            reqRow < cmdAddr.slice(21, 9),
            reqCol < cmdAddr.slice(8, 0),
            sdramRasN < 0, // ACTIVE
            sdramBa < cmdAddr.slice(23, 22),
            sdramA < cmdAddr.slice(21, 9),
            timer < Const(2, width: 16),
            state < Const(stAct, width: 4),
          ], orElse: [
            cmdReady < 1,
            busy < 0,
          ]),
        ]),

        // 7. ACTIVE delay -> Issue READ or WRITE command
        CaseItem(Const(stAct, width: 4), [
          If(timer.eq(0), then: [
            burstCnt < cmdBurstLen,
            If(~reqRw, then: [
              sdramCasN < 0, // READ
              sdramBa < reqBank,
              sdramA < [Const(0, width: 4), reqCol].swizzle(),
              casTimer < Const(casLatency, width: 4),
              state < Const(stRd, width: 4),
            ], orElse: [
              sdramCasN < 0,
              sdramWeN < 0, // WRITE
              sdramBa < reqBank,
              sdramA < [Const(0, width: 4), reqCol].swizzle(),
              sdramDqOe < 1,
              sdramDqOut < wdata,
              wdataReady < 1,
              burstCnt < cmdBurstLen - 1,
              state < Const(stWr, width: 4),
            ]),
          ], orElse: [
            timer < timer - 1,
          ]),
        ]),

        // 8. Read burst
        CaseItem(Const(stRd, width: 4), [
          If(casTimer.gt(0), then: [
            casTimer < casTimer - 1,
          ], orElse: [
            rdata < sdramDqIn,
            rdataValid < 1,
            burstCnt < burstCnt - 1,
            If(burstCnt.lte(1), then: [
              sdramRasN < 0,
              sdramWeN < 0, // PRECHARGE
              timer < Const(2, width: 16),
              state < Const(stPchg, width: 4),
            ]),
          ]),
        ]),

        // 9. Write burst
        CaseItem(Const(stWr, width: 4), [
          If(burstCnt.eq(0), then: [
            sdramDqOe < 0,
            sdramRasN < 0,
            sdramWeN < 0, // PRECHARGE
            timer < Const(2, width: 16),
            state < Const(stPchg, width: 4),
          ], orElse: [
            sdramDqOe < 1,
            sdramDqOut < wdata,
            wdataReady < 1,
            burstCnt < burstCnt - 1,
          ]),
        ]),

        // 10. Precharge delay -> Back to IDLE
        CaseItem(Const(stPchg, width: 4), [
          sdramDqOe < 0,
          If(timer.eq(0), then: [
            state < Const(stIdle, width: 4),
            cmdReady < 1,
            busy < 0,
          ], orElse: [
            timer < timer - 1,
          ]),
        ]),
      ]),
    ]);
  }
}

// ==============================================================================
// FILE: hdl/mr4/lib/qspi_mem_controller.dart
// Compact Tiny Tapeout QSPI PSRAM / Flash External Memory Controller (Track E.1.1)
//
// Targets the standard Tiny Tapeout QSPI PMOD pinout (`uio[7:0]`):
//   uio[0] = qspi_flash_cs_n (CS0: QSPI Flash, active low)
//   uio[1] = qspi_sd[0]      (SD0 / MOSI, bidirectional)
//   uio[2] = qspi_sd[1]      (SD1 / MISO, bidirectional)
//   uio[3] = qspi_sck        (SCK, Mode 0, clk / 2)
//   uio[4] = qspi_sd[2]      (SD2, bidirectional)
//   uio[5] = qspi_sd[3]      (SD3, bidirectional)
//   uio[6] = qspi_ram_a_cs_n (CS1: APS6404L 8 MB PSRAM A, active low)
//   uio[7] = qspi_ram_b_cs_n (CS2: PSRAM B, tied high)
//
// Protocol (1-4-4 SPI-command / Quad-addr+data, works right out of reset):
//   - 0xEB Fast Read Quad I/O : 8-clk 1-bit cmd -> 6-clk 4-bit 24b byte addr
//                               -> 6-clk Hi-Z dummy -> 4-bit little-endian data
//   - 0x38 Quad Input Write   : 8-clk 1-bit cmd -> 6-clk 4-bit 24b byte addr
//                               -> 4-bit little-endian data (0 dummy clocks)
//   - 1-cycle CS-high deselect (`ST_FINISH`) enforces APS6404L tCPH cleanly.
//
// Performance & Area (~400 stdcells, zero FPGA primitives):
//   - Bridges directly to `CpuCore` native `ic_*` / `dc_*` external memory ports.
//   - Includes a coherent 1-line (4-word / 64-bit) Instruction Prefetch Buffer:
//     sequential IF hits return in 1 cycle; misses burst all 4 words in one 0xEB
//     transaction; DC writes to the cached tag invalidate the line immediately.
// ==============================================================================

import 'package:rohd/rohd.dart';

class QspiMemController extends Module {
  static const int _stIdle = 0;
  static const int _stCmd = 1;
  static const int _stAddr = 2;
  static const int _stDummy = 3;
  static const int _stRead = 4;
  static const int _stWrite = 5;
  static const int _stFinish = 6;

  static const int cmdQuadRead = 0xEB;
  static const int cmdQuadWrite = 0x38;

  QspiMemController({
    required Logic clk,
    required Logic reset,
    required Logic icReqValid,
    required Logic icReqAddr,
    required Logic dcReqValid,
    required Logic dcReqWe,
    required Logic dcReqAddr,
    required Logic dcReqWdata,
    required Logic qspiSdIn,
    Logic? useFlash,
    super.name = 'qspi_mem_controller',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    // CpuCore Instruction & Data External Memory Ports
    final icValid = addInput('ic_req_valid', icReqValid);
    final icAddr = addInput('ic_req_addr', icReqAddr, width: 16);
    final dcValid = addInput('dc_req_valid', dcReqValid);
    final dcWe = addInput('dc_req_we', dcReqWe);
    final dcAddr = addInput('dc_req_addr', dcReqAddr, width: 16);
    final dcWdata = addInput('dc_req_wdata', dcReqWdata, width: 16);
    final flashSel = addInput('use_flash', useFlash ?? Const(0));

    // QSPI Bidirectional Data Inputs (from uio_in[5,4,2,1])
    final sdIn = addInput('qspi_sd_in', qspiSdIn, width: 4);

    // CpuCore Responses
    final icReadyOut = addOutput('ic_req_ready');
    final icRespValidOut = addOutput('ic_resp_valid');
    final icRespDataOut = addOutput('ic_resp_data', width: 16);
    final dcReadyOut = addOutput('dc_req_ready');
    final dcRespValidOut = addOutput('dc_resp_valid');
    final dcRespDataOut = addOutput('dc_resp_data', width: 16);

    // QSPI Physical Pins (Tiny Tapeout QSPI PMOD mapping)
    final sckOut = addOutput('qspi_sck');
    final flashCsNOut = addOutput('qspi_flash_cs_n');
    final ramACsNOut = addOutput('qspi_ram_a_cs_n');
    final ramBCsNOut = addOutput('qspi_ram_b_cs_n');
    final sdOut = addOutput('qspi_sd_out', width: 4);
    final sdOeOut = addOutput('qspi_sd_oe', width: 4);

    // FSM & QSPI shift registers
    final stQ = Logic(name: 'st_q', width: 3);
    final sckQ = Logic(name: 'sck_q');
    final csActiveQ = Logic(name: 'cs_active_q');
    final activeIsFlashQ = Logic(name: 'active_is_flash_q');
    final activeIsIcQ = Logic(name: 'active_is_ic_q');
    final activeIsWriteQ = Logic(name: 'active_is_write_q');
    final cntQ = Logic(name: 'cnt_q', width: 4);

    final reqAddrQ = Logic(name: 'req_addr_q', width: 16);
    final reqWdataQ = Logic(name: 'req_wdata_q', width: 16);
    final cmdShiftQ = Logic(name: 'cmd_shift_q', width: 8);
    final addrShiftQ = Logic(name: 'addr_shift_q', width: 24);
    final rxWordQ = Logic(name: 'rx_word_q', width: 16);

    // 1-line (4-word / 64-bit) coherent Instruction Prefetch Cache
    final icLineValidQ = Logic(name: 'ic_line_valid_q');
    final icLineTagQ = Logic(name: 'ic_line_tag_q', width: 14);
    final icWordsQ = List.generate(
      4,
      (i) => Logic(name: 'ic_word_${i}_q', width: 16),
    );

    // Registered response pulses (guaranteed >= 1 cycle after req_ready!)
    final icRespValidQ = Logic(name: 'ic_resp_valid_q');
    final icRespDataQ = Logic(name: 'ic_resp_data_q', width: 16);
    final dcRespValidQ = Logic(name: 'dc_resp_valid_q');
    final dcRespDataQ = Logic(name: 'dc_resp_data_q', width: 16);

    final isIdle = stQ.eq(Const(_stIdle, width: 3));
    final isCmd = stQ.eq(Const(_stCmd, width: 3));
    final isAddr = stQ.eq(Const(_stAddr, width: 3));
    final isWrite = stQ.eq(Const(_stWrite, width: 3));

    // Coherent 4-word I-cache hit detection
    final icTagMatch = icLineValidQ & icAddr.slice(15, 2).eq(icLineTagQ);
    final icHitWord = mux(
      icAddr[1],
      mux(icAddr[0], icWordsQ[3], icWordsQ[2]),
      mux(icAddr[0], icWordsQ[1], icWordsQ[0]),
    );
    final reqIcLineWord = mux(
      reqAddrQ[1],
      mux(reqAddrQ[0], icWordsQ[3], icWordsQ[2]),
      mux(reqAddrQ[0], icWordsQ[1], icWordsQ[0]),
    );

    // DC has priority over IC in ST_IDLE to avoid EX-vs-IF deadlock
    final acceptDc = isIdle & dcValid;
    final acceptIc = isIdle & (~dcValid) & icValid;

    dcReadyOut <= acceptDc;
    icReadyOut <= acceptIc;
    icRespValidOut <= icRespValidQ;
    icRespDataOut <= icRespDataQ;
    dcRespValidOut <= dcRespValidQ;
    dcRespDataOut <= dcRespDataQ;

    // QSPI chip selects & clock
    sckOut <= sckQ;
    flashCsNOut <= ~(csActiveQ & activeIsFlashQ);
    ramACsNOut <= ~(csActiveQ & (~activeIsFlashQ));
    ramBCsNOut <= Const(1);

    // Write nibble selector (little-endian: byte0_hi, byte0_lo, byte1_hi, byte1_lo)
    // cntQ counts down 3 -> 2 -> 1 -> 0 during ST_WRITE
    final wrNibble = mux(
      cntQ[1],
      mux(cntQ[0], reqWdataQ.slice(7, 4), reqWdataQ.slice(3, 0)),
      mux(cntQ[0], reqWdataQ.slice(15, 12), reqWdataQ.slice(11, 8)),
    );

    // QSPI SD output & output-enable muxing:
    // - ST_CMD  : drive SD0=cmdShiftQ[7], SD2=1, SD3=1 (keeps Flash /WP,/HOLD high!)
    // - ST_ADDR : drive SD[3:0] = addrShiftQ[23:20]
    // - ST_WRITE: drive SD[3:0] = wrNibble
    // - others  : Hi-Z (oe = 0)
    final cmdSdOut = [Const(3, width: 2), Const(0, width: 1), cmdShiftQ[7]].swizzle();
    sdOut <= mux(
      isCmd,
      cmdSdOut,
      mux(
        isAddr,
        addrShiftQ.slice(23, 20),
        mux(isWrite, wrNibble, Const(0, width: 4)),
      ),
    );
    sdOeOut <= mux(
      isCmd,
      Const(0xD, width: 4), // 4'b1101: SD0=MOSI, SD1=HiZ, SD2=/WP=1, SD3=/HOLD=1
      mux(isAddr | isWrite, Const(0xF, width: 4), Const(0, width: 4)),
    );

    // Helper: 24-bit byte address from 16-bit word address ({7'b0, word_addr, 1'b0})
    Logic wordToByteAddr24(Logic wordAddr16) =>
        [Const(0, width: 7), wordAddr16, Const(0, width: 1)].swizzle();

    // During ST_READ, cntQ counts down:
    // - DC 1-word read: 3, 2, 1, 0 -> wordIdx unused, nibSel = cntQ[1:0]
    // - IC 4-word burst: 15..0 -> wordIdx = 3 - cntQ[3:2] (0, 1, 2, 3), nibSel = cntQ[1:0]
    //   nibSel == 3 -> word[7:4], == 2 -> word[3:0], == 1 -> word[15:12], == 0 -> word[11:8]
    final nibSel = cntQ.slice(1, 0);
    final burstWordIdx = Const(3, width: 2) - cntQ.slice(3, 2);
    final completedWord = [
      rxWordQ.slice(15, 12),
      sdIn,
      rxWordQ.slice(7, 0),
    ].swizzle();

    final dcWriteHitsIcTag =
        dcWe & icLineValidQ & dcAddr.slice(15, 2).eq(icLineTagQ);

    Sequential(clk, reset: reset, resetValues: {
      stQ: _stIdle,
      sckQ: 0,
      csActiveQ: 0,
      activeIsFlashQ: 0,
      activeIsIcQ: 0,
      activeIsWriteQ: 0,
      cntQ: 0,
      reqAddrQ: 0,
      reqWdataQ: 0,
      cmdShiftQ: 0,
      addrShiftQ: 0,
      rxWordQ: 0,
      icLineValidQ: 0,
      icLineTagQ: 0,
      for (final w in icWordsQ) w: 0,
      icRespValidQ: 0,
      icRespDataQ: 0,
      dcRespValidQ: 0,
      dcRespDataQ: 0,
    }, [
      // Default: clear 1-cycle response pulses
      icRespValidQ < 0,
      dcRespValidQ < 0,

      Case(stQ, [
        // -------------------------------------------------------------------
        // ST_IDLE: arbitrate DC (priority) vs IC (1-cycle hit or 4-word burst)
        // -------------------------------------------------------------------
        CaseItem(Const(_stIdle, width: 3), [
          sckQ < 0,
          csActiveQ < 0,
          If(dcValid, then: [
            reqAddrQ < dcAddr,
            reqWdataQ < dcWdata,
            activeIsIcQ < 0,
            activeIsWriteQ < dcWe,
            // Writes always go to PSRAM (CS1); reads respect use_flash
            activeIsFlashQ < (flashSel & (~dcWe)),
            cmdShiftQ < mux(
              dcWe,
              Const(cmdQuadWrite, width: 8),
              Const(cmdQuadRead, width: 8),
            ),
            addrShiftQ < wordToByteAddr24(dcAddr),
            cntQ < Const(7, width: 4),
            csActiveQ < 1,
            stQ < Const(_stCmd, width: 3),
            // Coherent I-cache invalidation on write to cached line
            If(dcWriteHitsIcTag, then: [
              icLineValidQ < 0,
            ]),
          ], orElse: [
            If(icValid, then: [
              If(icTagMatch, then: [
                // 1-cycle coherent I-cache hit (zero QSPI traffic!)
                icRespDataQ < icHitWord,
                icRespValidQ < 1,
              ], orElse: [
                // 4-word aligned burst refill from {icAddr[15:2], 2'b00}
                reqAddrQ < icAddr,
                activeIsIcQ < 1,
                activeIsWriteQ < 0,
                activeIsFlashQ < flashSel,
                cmdShiftQ < Const(cmdQuadRead, width: 8),
                addrShiftQ < wordToByteAddr24(
                  [icAddr.slice(15, 2), Const(0, width: 2)].swizzle(),
                ),
                cntQ < Const(7, width: 4),
                csActiveQ < 1,
                stQ < Const(_stCmd, width: 3),
              ]),
            ]),
          ]),
        ]),

        // -------------------------------------------------------------------
        // ST_CMD: 8 SCK pulses, 1-bit MSB-first command on SD0
        // -------------------------------------------------------------------
        CaseItem(Const(_stCmd, width: 3), [
          If(~sckQ, then: [
            sckQ < 1,
          ], orElse: [
            sckQ < 0,
            cmdShiftQ < [cmdShiftQ.slice(6, 0), Const(0, width: 1)].swizzle(),
            If(cntQ.eq(Const(0, width: 4)), then: [
              cntQ < Const(5, width: 4), // 6 quad nibbles = 24-bit byte address
              stQ < Const(_stAddr, width: 3),
            ], orElse: [
              cntQ < cntQ - Const(1, width: 4),
            ]),
          ]),
        ]),

        // -------------------------------------------------------------------
        // ST_ADDR: 6 SCK pulses, 4-bit MSB-first 24-bit byte address on SD[3:0]
        // -------------------------------------------------------------------
        CaseItem(Const(_stAddr, width: 3), [
          If(~sckQ, then: [
            sckQ < 1,
          ], orElse: [
            sckQ < 0,
            addrShiftQ < [addrShiftQ.slice(19, 0), Const(0, width: 4)].swizzle(),
            If(cntQ.eq(Const(0, width: 4)), then: [
              If(activeIsWriteQ, then: [
                cntQ < Const(3, width: 4), // 4 nibbles = 16-bit word write
                stQ < Const(_stWrite, width: 3),
              ], orElse: [
                cntQ < Const(5, width: 4), // 6 dummy clocks for 0xEB Quad Read
                stQ < Const(_stDummy, width: 3),
              ]),
            ], orElse: [
              cntQ < cntQ - Const(1, width: 4),
            ]),
          ]),
        ]),

        // -------------------------------------------------------------------
        // ST_DUMMY: 6 SCK Hi-Z turnaround clocks (APS6404L / W25Q 0xEB latency)
        // -------------------------------------------------------------------
        CaseItem(Const(_stDummy, width: 3), [
          If(~sckQ, then: [
            sckQ < 1,
          ], orElse: [
            sckQ < 0,
            If(cntQ.eq(Const(0, width: 4)), then: [
              cntQ < mux(
                activeIsIcQ,
                Const(15, width: 4), // 4 words = 16 nibbles
                Const(3, width: 4), // 1 word = 4 nibbles
              ),
              stQ < Const(_stRead, width: 3),
            ], orElse: [
              cntQ < cntQ - Const(1, width: 4),
            ]),
          ]),
        ]),

        // -------------------------------------------------------------------
        // ST_READ: 4-bit Quad data read (little-endian: b0_hi, b0_lo, b1_hi, b1_lo)
        // Sampled at end of SCK=1 phase for maximum IO pad round-trip margin.
        // -------------------------------------------------------------------
        CaseItem(Const(_stRead, width: 3), [
          If(~sckQ, then: [
            sckQ < 1,
          ], orElse: [
            sckQ < 0,
            Case(nibSel, [
              CaseItem(Const(3, width: 2), [
                rxWordQ <
                    [rxWordQ.slice(15, 8), sdIn, rxWordQ.slice(3, 0)].swizzle(),
              ]),
              CaseItem(Const(2, width: 2), [
                rxWordQ < [rxWordQ.slice(15, 4), sdIn].swizzle(),
              ]),
              CaseItem(Const(1, width: 2), [
                rxWordQ < [sdIn, rxWordQ.slice(11, 0)].swizzle(),
              ]),
              CaseItem(Const(0, width: 2), [
                rxWordQ < completedWord,
                If(activeIsIcQ, then: [
                  Case(burstWordIdx, [
                    for (var wi = 0; wi < 4; wi++)
                      CaseItem(Const(wi, width: 2), [
                        icWordsQ[wi] < completedWord,
                      ]),
                  ]),
                ]),
              ]),
            ]),
            If(cntQ.eq(Const(0, width: 4)), then: [
              csActiveQ < 0,
              If(activeIsIcQ, then: [
                icLineValidQ < 1,
                icLineTagQ < reqAddrQ.slice(15, 2),
              ]),
              stQ < Const(_stFinish, width: 3),
            ], orElse: [
              cntQ < cntQ - Const(1, width: 4),
            ]),
          ]),
        ]),

        // -------------------------------------------------------------------
        // ST_WRITE: 4 SCK pulses, 4-bit Quad write (little-endian 16-bit word)
        // -------------------------------------------------------------------
        CaseItem(Const(_stWrite, width: 3), [
          If(~sckQ, then: [
            sckQ < 1,
          ], orElse: [
            sckQ < 0,
            If(cntQ.eq(Const(0, width: 4)), then: [
              csActiveQ < 0,
              stQ < Const(_stFinish, width: 3),
            ], orElse: [
              cntQ < cntQ - Const(1, width: 4),
            ]),
          ]),
        ]),

        // -------------------------------------------------------------------
        // ST_FINISH: 1-cycle CS-high deselect guard (tCPH) + response pulse
        // -------------------------------------------------------------------
        CaseItem(Const(_stFinish, width: 3), [
          sckQ < 0,
          csActiveQ < 0,
          If(activeIsIcQ, then: [
            icRespDataQ < reqIcLineWord,
            icRespValidQ < 1,
          ], orElse: [
            dcRespDataQ < rxWordQ,
            dcRespValidQ < 1,
          ]),
          stQ < Const(_stIdle, width: 3),
        ]),
      ]),
    ]);
  }

  Logic get icReqReady => output('ic_req_ready');
  Logic get icRespValid => output('ic_resp_valid');
  Logic get icRespData => output('ic_resp_data');
  Logic get dcReqReady => output('dc_req_ready');
  Logic get dcRespValid => output('dc_resp_valid');
  Logic get dcRespData => output('dc_resp_data');
  Logic get qspiSck => output('qspi_sck');
  Logic get qspiFlashCsN => output('qspi_flash_cs_n');
  Logic get qspiRamACsN => output('qspi_ram_a_cs_n');
  Logic get qspiRamBCsN => output('qspi_ram_b_cs_n');
  Logic get qspiSdOut => output('qspi_sd_out');
  Logic get qspiSdOe => output('qspi_sd_oe');
}

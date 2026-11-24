// ==============================================================================
// FILE: hdl/mr4/lib/cpu_core.dart
// MicroRISC4 16-Bit CPU Core Architecture (Track C.3: 4-Stage In-Order Pipeline)
// Stages: IF (Prefetch Ring) -> ID/RF (Decode + WB->ID) -> EX (WB->EX + ALU) -> WB
// Parallel Non-Blocking Port B Memory/MMIO/DCache Unit + Configurable Latency
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'math_accelerator.dart';
import 'memory_factory.dart';
import 'spi_master.dart';

class CpuCore extends Module {
  final CpuConfig config;
  late final DualPortMemory ram;

  // Parallel Memory / MMIO / DCache Unit States
  static const int _memIdle = 0;
  static const int _memWait1 = 1;
  static const int _memWait2 = 2;
  static const int _memWb = 3;

  // External SDRAM I-Cache Fetch States
  static const int _extIfIdle = 0;
  static const int _extIfReq = 1;
  static const int _extIfWait = 2;

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
    Logic? coreIdIn,
    this.config = const CpuConfig(),
    String? initHexFile,
    Map<int, int>? initialMemory,
    bool enableIqBypass = true,
    super.name = 'cpu_core',
  }) {
    assert(config.memReadLatency == 1 || config.memReadLatency == 2,
        'memReadLatency must be 1 (ASIC SRAM) or 2 (ECP5 TdpBram)');

    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    final Logic? coreIdPort = coreIdIn != null
        ? addInput('core_id_in', coreIdIn, width: coreIdIn.width)
        : null;

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

    // =========================================================================
    // Architectural & Shadow Registers (committed in WB stage)
    // =========================================================================
    final r = List.generate(4, (i) => Logic(name: 'r$i', width: 16));
    final shadowR =
        List.generate(4, (i) => Logic(name: 'shadow_r$i', width: 16));
    final epcQ = Logic(name: 'epc_q', width: 16);

    // Dual-Port Memory Interface Signals (registered at IF / EX->MEM boundaries)
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

    // =========================================================================
    // Low MMIO Decodes (shared upper-10-bit zero check -> 2 LUT4 levels)
    // =========================================================================
    final isMmioPage = portBAddr.slice(15, 6).eq(Const(0, width: 10));
    final mmioOff = portBAddr.slice(5, 0);
    final isMmioCpuid = config.enableCpuid
        ? (isMmioPage & mmioOff.eq(Const(0x0D, width: 6)))
        : Const(0);
    final isMmioRx = config.enableUart
        ? (isMmioPage &
            mmioOff.eq(Const(MicroRISC4Constants.addrUartRx, width: 6)))
        : Const(0);
    final isMmioTx = config.enableUart
        ? (isMmioPage &
            mmioOff.eq(Const(MicroRISC4Constants.addrUartTx, width: 6)))
        : Const(0);
    final hasEpc = config.hasEpc;
    final isMmioCpuVer = config.enableCpuInfo
        ? (isMmioPage &
            mmioOff.eq(Const(MicroRISC4Constants.addrCpuVer, width: 6)))
        : Const(0);
    final isMmioCpuCaps = config.enableCpuInfo
        ? (isMmioPage &
            mmioOff.eq(Const(MicroRISC4Constants.addrCpuCaps, width: 6)))
        : Const(0);
    final isMmioCpuCaps2 = config.enableCpuInfo
        ? (isMmioPage &
            mmioOff.eq(Const(MicroRISC4Constants.addrCpuCaps2, width: 6)))
        : Const(0);
    final isMmioEpc = hasEpc
        ? (isMmioPage &
            mmioOff.eq(Const(MicroRISC4Constants.addrEpc, width: 6)))
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

    // SPI Master Conditional Instantiation
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
        slowHalfDiv: SpiMaster.slowHalfDivForMhz(config.clkFreqMhz),
        fastHalfDiv: SpiMaster.fastHalfDivForMhz(config.clkFreqMhz),
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
            mmioOff.gte(Const(MicroRISC4Constants.addrNocTxData, width: 6)) &
            mmioOff.lte(Const(MicroRISC4Constants.addrNocInfo, width: 6)))
        : Const(0);

    final isMmio = isMmioCpuid |
        isMmioRx |
        isMmioTx |
        isMmioCpuVer |
        isMmioCpuCaps |
        isMmioCpuCaps2 |
        isMmioEpc |
        isMathMatch |
        isSpiMatch |
        isNocMatch;

    // External SDRAM-cached address detector (zero carry chain)
    final addrHigh = config.addrWidth - 1;
    Logic isExtAddr(Logic addr) => ~addr
        .slice(15, config.addrWidth)
        .eq(Const(0, width: 16 - config.addrWidth));
    final isExtPortB = useExtCache ? isExtAddr(portBAddr) : Const(0);
    final ramBWe =
        useExtCache ? (portBWe & ~isMmio & ~isExtPortB) : (portBWe & ~isMmio);

    // Instantiate Target-Selectable True Dual-Port Memory (ECP5 BRAM or ASIC SRAM/Flop + Boot ROM)
    ram = MemoryFactory.createMainRam(
      target: config.memoryTarget,
      clk: clk,
      portAAddr: portAAddr.slice(addrHigh, 0),
      portAEn: portAEn,
      portBAddr: portBAddr.slice(addrHigh, 0),
      portBWdata: portBWdata,
      portBWe: ramBWe,
      portBEn: portBEn,
      depth: config.memWords,
      dataWidth: 16,
      readLatency: config.memReadLatency,
      initHexFile: initHexFile,
      initialMemory: initialMemory,
      bootRomBase: config.bootRomBase,
      bootRomWords: config.bootRomWords,
      sramMacroName: config.sramMacroName,
      name: '${name}_ram',
    );
    portARdata <= ram.portARdata;
    portBRdata <= ram.portBRdata;

    // Direct Stride Vector Table Constants (default 0x0100, stride 16 words)
    final trapTableBaseConst = Const(config.trapTableBase, width: 16);
    final trapAlignFaultConst =
        Const(config.trapTableBase + (15 << 4), width: 16);
    final trapTableAligned256 = (config.trapTableBase & 0xFF) == 0;
    Logic computeTrapTarget(Logic vec4) {
      if (trapTableAligned256) {
        return [
          Const((config.trapTableBase >> 8) & 0xFF, width: 8),
          vec4,
          Const(0, width: 4),
        ].swizzle();
      }
      return trapTableBaseConst +
          [Const(0, width: 8), vec4, Const(0, width: 4)].swizzle();
    }

    // Pre-muxed peripheral/MMIO read bus (excludes wide BRAM output)
    final mmioOnlyData = mux(
      isMmioCpuid,
      coreIdPort != null
          ? coreIdPort.zeroExtend(16)
          : Const(config.coreId, width: 16),
      mux(
        isMmioRx,
        rxData,
        mux(
          isMmioTx,
          txStatus,
          mux(
            isMmioCpuVer,
            Const(config.cpuVersionWord, width: 16),
            mux(
              isMmioCpuCaps,
              Const(config.cpuCapsWord, width: 16),
              mux(
                isMmioCpuCaps2,
                Const(config.cpuCaps2Word, width: 16),
                mux(
                  isMmioEpc,
                  epcQ,
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
            ),
          ),
        ),
      ),
    );
    final mmioRdataReg = Logic(name: 'mmio_rdata_reg', width: 16);
    final isMmioRdReg = Logic(name: 'is_mmio_rd_reg');
    final effectivePortBData = mux(isMmioRdReg, mmioRdataReg, portBRdata);

    // =========================================================================
    // Pipeline State Registers (IF, ID/EX, WB, and Parallel MEM Unit)
    // =========================================================================
    // Stage 1 (IF): 8-entry distributed RAM prefetch queue (4x DPR16X4) + pure-FF FWFT head
    final iqWrPtrQ = Logic(name: 'iq_wr_ptr_q', width: 3);
    final iqRdPtrQ = Logic(name: 'iq_rd_ptr_q', width: 3);
    final iqCntQ = Logic(name: 'iq_cnt_q', width: 4);
    final idValidQ = Logic(name: 'id_valid_q');
    final idWordQ = Logic(name: 'id_word_q', width: 16);
    final paV1Q = Logic(name: 'pa_v1_q');
    final paV2Q = Logic(name: 'pa_v2_q');
    final idPcQ = Logic(name: 'id_pc_q', width: 16);
    final idSlotQ = Logic(name: 'id_slot_q');

    // External I-Cache fetch FSM (when useExtCache == true)
    final extIfStQ = Logic(name: 'ext_if_st_q', width: 2);
    final extIfAddrQ = Logic(name: 'ext_if_addr_q', width: 16);
    final extIfDropQ = Logic(name: 'ext_if_drop_q');

    // Stage 2 -> Stage 3 (ID/EX Pipeline Registers)
    final exValidQ = Logic(name: 'ex_valid_q');
    final exPcQ = Logic(name: 'ex_pc_q', width: 16);
    final exPcPlus1Q = Logic(name: 'ex_pc_plus1_q', width: 16);
    final exSlotQ = Logic(name: 'ex_slot_q');
    final exOpQ = Logic(name: 'ex_op_q', width: 4);
    final exRrQ = Logic(name: 'ex_rr_q', width: 2);
    final exRlQ = Logic(name: 'ex_rl_q', width: 2);
    final exImm4Q = Logic(name: 'ex_imm4_q', width: 4);
    final exImm8Q = Logic(name: 'ex_imm8_q', width: 8);
    final exValRQ = Logic(name: 'ex_val_r_q', width: 16);
    final exValLQ = Logic(name: 'ex_val_l_q', width: 16);
    final exShadowLQ = Logic(name: 'ex_shadow_l_q', width: 16);
    // Pre-selected adder operands & pure-FF WB->EX forwarding selects (1 LUT4 before CCU2C!)
    final exAddAQ = Logic(name: 'ex_add_a_q', width: 16);
    final exAddBQ = Logic(name: 'ex_add_b_q', width: 16);
    final exFwdRQ = Logic(name: 'ex_fwd_r_q');
    final exFwdLQ = Logic(name: 'ex_fwd_l_q');
    final exFwdShadowLQ = Logic(name: 'ex_fwd_shadow_l_q');
    final exFwdAddAQ = Logic(name: 'ex_fwd_add_a_q');
    final exFwdAddBQ = Logic(name: 'ex_fwd_add_b_q');

    // Pre-decoded EX control flags (pure FFs -> zero decode LUTs before ALU/stall!)
    final exUseRegLAsAddAQ = Logic(name: 'ex_use_regl_add_a_q');
    final exUseOneAsAddBQ = Logic(name: 'ex_use_one_add_b_q');
    final exArithSubQ = Logic(name: 'ex_arith_sub_q');
    final exIsArithQ = Logic(name: 'ex_is_arith_q');
    final exIsLoadQ = Logic(name: 'ex_is_load_q');
    final exIsStoreQ = Logic(name: 'ex_is_store_q');
    final exIsPushQ = Logic(name: 'ex_is_push_q');
    final exIsXchgQ = Logic(name: 'ex_is_xchg_q');
    final exIsEretQ = Logic(name: 'ex_is_eret_q');
    final exIsJmpQ = Logic(name: 'ex_is_jmp_q');
    final exIsLinkQ = Logic(name: 'ex_is_link_q');
    final exIsPush8Q = Logic(name: 'ex_is_push8_q');
    final exIsTrapQ = Logic(name: 'ex_is_trap_q');
    final exIsJmpZQ = Logic(name: 'ex_is_jmpz_q');
    final exIsJmpMQ = Logic(name: 'ex_is_jmpm_q');
    final exIllegalSlot1Q = Logic(name: 'ex_illegal_slot1_q');
    // 4-bit one-hot mask of all registers read/written by EX (1-PFUMX loadHazard!)
    final exRegMaskQ = Logic(name: 'ex_reg_mask_q', width: 4);
    final exWbEnQ = Logic(name: 'ex_wb_en_q');
    final exWbIdxQ = Logic(name: 'ex_wb_idx_q', width: 2);
    final exNeedsMemIdleQ = Logic(name: 'ex_needs_mem_idle_q');

    // Stage 3 -> Stage 4 (EX/WB Pipeline Registers: unified single commit & forward source)
    final wbValidQ = Logic(name: 'wb_valid_q');
    final wbWbEnQ = Logic(name: 'wb_wb_en_q');
    final wbWbIdxQ = Logic(name: 'wb_wb_idx_q', width: 2);
    final wbDataQ = Logic(name: 'wb_data_q', width: 16);
    final wbXchgQ = Logic(name: 'wb_xchg_q');
    final wbShadowDataQ = Logic(name: 'wb_shadow_data_q', width: 16);

    // Parallel Non-Blocking Port B Memory Unit Registers
    final memStQ = Logic(name: 'mem_st_q', width: 2);
    final memBusyQ = Logic(name: 'mem_busy_q');
    final memIsWbQ = Logic(name: 'mem_is_wb_q');
    final memDestQ = Logic(name: 'mem_dest_q', width: 2);
    final memDestMaskQ = Logic(name: 'mem_dest_mask_q', width: 4);
    final memIsExtWrQ = Logic(name: 'mem_is_ext_wr_q');

    debugPc <= exPcQ;

    final resetActive = ~rstN;

    // =========================================================================
    // Parallel Memory / Hazard / Stall Logic (2 LUT4 levels from pure FFs!)
    // =========================================================================
    final memBusy = memBusyQ;
    final memIsWait1 = memStQ.eq(Const(_memWait1, width: 2));
    final memIsWait2 = memStQ.eq(Const(_memWait2, width: 2));
    final memIsWb = memIsWbQ;

    // Pairwise 4-input LUT4s: h0, h1, h2 in Level 1 -> exHold in Level 2!
    final loadHaz01 =
        (exRegMaskQ[0] & memDestMaskQ[0]) | (exRegMaskQ[1] & memDestMaskQ[1]);
    final loadHaz23 =
        (exRegMaskQ[2] & memDestMaskQ[2]) | (exRegMaskQ[3] & memDestMaskQ[3]);
    final memCtrlStall = memIsWb | (memBusy & exNeedsMemIdleQ);
    final exStall = loadHaz01 | loadHaz23 | memCtrlStall;

    // Async Hardware Trap 14 (taken cleanly at a Slot-0 EX boundary when mem idle)
    final crossTrapTake = config.enableCrossTraps
        ? (crossTrapReq & (~memBusy) & exValidQ & (~exSlotQ))
        : Const(0);
    extTrapAckOut <= crossTrapTake;

    // exHold is strictly 2 LUT4 levels from pure FFs (ZERO crossTrap/flush!)
    final exHold = exValidQ & exStall;
    final exFire = exValidQ & (~exStall) & (~crossTrapTake);
    // When memBusy == 0 (_memIdle), memIsWb == 0 and memDestMaskQ == 0, so
    // exStall is identically 0 -> bypasses exStall off _memIdle and exTakeBranch!
    final exFireIdle = exValidQ & (~crossTrapTake);

    // Pulse UART RX Pop on the exact cycle Port B latches a valid rxData
    final memRxLatchState =
        (config.memReadLatency == 1) ? memIsWait1 : memIsWait2;
    rxPop <= (memRxLatchState & (~isExtPortB) & isMmioRx & rxData[15]);

    // External Cache Interfaces (strictly registered sources!)
    if (useExtCache) {
      icReqValidOut! <= extIfStQ.eq(Const(_extIfReq, width: 2));
      icReqAddrOut! <= extIfAddrQ;
      dcReqValidOut! <= memIsWait1 & isExtPortB;
      dcReqWeOut! <= portBWe;
      dcReqAddrOut! <= portBAddr;
      dcReqWdataOut! <= portBWdata;
    }

    // =========================================================================
    // Stage 3 (EX): Pure-FF WB->EX Forwarding + 16-bit ALU + Branch Resolution
    // =========================================================================
    final wbFwdValid = wbValidQ & wbWbEnQ;
    final effR = mux(exFwdRQ, wbDataQ, exValRQ);
    final effL = mux(exFwdLQ, wbDataQ, exValLQ);
    final effShadowL = config.enableShadowRegs
        ? mux(exFwdShadowLQ, wbShadowDataQ, exShadowLQ)
        : effL;
    final effEpc = hasEpc
        ? mux(portBEn & portBWe & isMmioEpc, portBWdata, epcQ)
        : Const(0, width: 16);

    // ALU Helpers
    Logic rotl1(Logic v) => [v.slice(14, 0), v[15]].swizzle();
    Logic rotr1(Logic v) => [v[0], v.slice(15, 1)].swizzle();
    Logic asr1(Logic v) => [v[15], v.slice(15, 1)].swizzle();

    // Unified 16-bit Add/Sub Carry Chain: strictly ONE LUT4 level before CCU2C!
    // (exFwdAddAQ, exFwdAddBQ, exArithSubQ, exAddAQ, exAddBQ, wbDataQ are ALL pure FFs!)
    final addA = mux(exFwdAddAQ, wbDataQ, exAddAQ);
    final addBInv = mux(
      exFwdAddBQ,
      mux(exArithSubQ, ~wbDataQ, wbDataQ),
      exAddBQ,
    );
    final arithSum17 =
        [addA, exArithSubQ].swizzle() + [addBInv, exArithSubQ].swizzle();
    final arithRes = arithSum17.slice(16, 1);

    // Fast (non-adder) EX results computed in parallel with CCU2C
    final isExLdReg = exOpQ.eq(Const(MicroRISC4Constants.opLdReg, width: 4));
    final isExLdImm4 = exOpQ.eq(Const(MicroRISC4Constants.opLdImm4, width: 4));
    final isExOr = exOpQ.eq(Const(MicroRISC4Constants.opOr, width: 4));
    final isExXor = exOpQ.eq(Const(MicroRISC4Constants.opXor, width: 4));
    final isExAnd = exOpQ.eq(Const(MicroRISC4Constants.opAnd, width: 4));
    final isExShift = exOpQ.eq(Const(MicroRISC4Constants.opShift, width: 4));
    final isExRotIncDec =
        exOpQ.eq(Const(MicroRISC4Constants.opRotIncDec, width: 4));

    final shiftRes = mux(
      exRrQ[1],
      mux(
        exRrQ[0],
        config.enableShadowRegs ? effShadowL : effL,
        asr1(effL),
      ),
      mux(
        exRrQ[0],
        [Const(0, width: 1), effL.slice(15, 1)].swizzle(),
        [effL.slice(14, 0), Const(0, width: 1)].swizzle(),
      ),
    );
    final rotRes = mux(exRrQ[0], rotr1(effL), rotl1(effL));
    final bitwiseRes = mux(
      exOpQ[1],
      effR & effL,
      mux(exOpQ[0], effR ^ effL, effR | effL),
    );
    final immOrPushOrLink = mux(
      isExLdImm4,
      [Const(0, width: 12), exImm4Q].swizzle(),
      mux(
        exIsPush8Q,
        [effL.slice(7, 0), exImm8Q].swizzle(),
        mux(isExLdReg, effL, exPcPlus1Q),
      ),
    );
    final exFastData = mux(
      exIllegalSlot1Q,
      exPcPlus1Q,
      mux(
        isExShift,
        shiftRes,
        mux(
          isExRotIncDec,
          rotRes,
          mux(isExOr | isExXor | isExAnd, bitwiseRes, immOrPushOrLink),
        ),
      ),
    );

    // Late-select WB data: arithRes passes through strictly ONE 2:1 mux into wbDataQ!
    final crossTrapClobbersR0 = hasEpc ? Const(0) : crossTrapTake;
    final nonArithWbData = mux(
      memIsWb,
      effectivePortBData,
      mux(crossTrapClobbersR0, exPcQ, exFastData),
    );
    final nextWbData = mux(
      (~memIsWb) & (~crossTrapClobbersR0) & exIsArithQ,
      arithRes,
      nonArithWbData,
    );

    // Next-cycle WB metadata (used in ID/EX to pre-compute pure-FF forwarding flags!)
    final nextWbEn = memIsWb | crossTrapClobbersR0 | (exFire & exWbEnQ);
    final nextWbIdx = mux(
      memIsWb,
      memDestQ,
      mux(crossTrapClobbersR0, Const(0, width: 2), exWbIdxQ),
    );
    final nextWbXchg = config.enableShadowRegs
        ? ((~memIsWb) &
            (~crossTrapClobbersR0) &
            exFire &
            exIsXchgQ &
            (~exIllegalSlot1Q))
        : Const(0);

    // Branch / Jump / Trap / ERET Resolution in EX (every branch has exNeedsMemIdleQ=1,
    // so memBusy==0 guarantees exStall==0 -> zero loadHazard path into flush!)
    final effLZero = effL.eq(Const(0, width: 16));
    final exIsEretFire = hasEpc ? exIsEretQ : Const(0);
    final exTakeBranch = exFireIdle &
        (~memBusy) &
        (exIllegalSlot1Q |
            exIsEretFire |
            exIsJmpQ |
            exIsLinkQ |
            exIsTrapQ |
            (exIsJmpZQ & effLZero) |
            (exIsJmpMQ & effL[15]));
    final flush = crossTrapTake | exTakeBranch;

    final exTrapTarget = computeTrapTarget(effL.slice(3, 0));
    final crossTrapTarget = computeTrapTarget(crossTrapNum);
    final exBranchTarget = mux(
      exIllegalSlot1Q,
      trapAlignFaultConst,
      mux(
        exIsEretFire,
        effEpc,
        mux(
          exIsTrapQ,
          exTrapTarget,
          mux(exIsJmpZQ | exIsJmpMQ, effR, effL),
        ),
      ),
    );
    final redirectTarget =
        mux(crossTrapTake, crossTrapTarget, exBranchTarget);

    // External SDRAM-cached store detector (checks effR BEFORE 16-bit CCU2C!)
    final isExtPoke = useExtCache ? isExtAddr(effR) : Const(0);
    final isExtPredec = useExtCache
        ? (isExtAddr(effR) | effR.eq(Const(0, width: 16)))
        : Const(0);
    final exIsExtStore = useExtCache
        ? mux(exIsPushQ, isExtPredec, isExtPoke)
        : Const(0);

    // =========================================================================
    // Stage 1 (IF) & Stage 2 (ID/RF): 8-Entry Prefetch Queue + Pure-FF FWFT Head
    // =========================================================================
    final iqEmpty = iqCntQ.eq(Const(0, width: 4));
    final iqNotEmpty = ~iqEmpty;
    // Issue whenever iqCntQ < 4 (<= 3 + up to 3 in-flight + 1 new = 7 <= 8!)
    final iqHasRoom = (~iqCntQ[2]) & (~iqCntQ[3]);

    // Note: If(flush, ...) directly clears iqCntQ/iqWrPtrQ/iqRdPtrQ/idValidQ,
    // so paRespValid/icRespPush/idAdvance/iqPop do NOT need ~flush in their cones!
    final paRespValid = config.memReadLatency == 2 ? paV2Q : paV1Q;
    final extIfIsIdle = extIfStQ.eq(Const(_extIfIdle, width: 2));
    final extIfIsReq = extIfStQ.eq(Const(_extIfReq, width: 2));
    final extIfIsWait = extIfStQ.eq(Const(_extIfWait, width: 2));
    final extIfActive = useExtCache ? (~extIfIsIdle) : Const(0);
    final icRespPush = useExtCache
        ? (extIfIsWait & icRespValidIn & (~extIfDropQ))
        : Const(0);
    final ifPushValid = paRespValid | icRespPush;
    final ifPushData =
        useExtCache ? mux(icRespPush, icRespDataIn, portARdata) : portARdata;

    // 8x16 1W1R Backing Prefetch Queue (DPR16X4 on ECP5, pure flop regfile on ASIC)
    final iqPushSig = Logic(name: 'iq_push');
    final iqRamRdata = MemoryFactory.createSmallRam(
      target: config.memoryTarget,
      clk: clk,
      waddr: iqWrPtrQ,
      wdata: ifPushData,
      we: iqPushSig,
      raddr: iqRdPtrQ,
      addrWidth: 3,
      dataWidth: 16,
      name: '${name}_iq_ram',
    );

    // ID decodes strictly from pure flip-flop idWordQ (ZERO DPR16X4 on ID path!)
    final idAdvance = idValidQ & (~exHold);
    final idByte = mux(idSlotQ, idWordQ.slice(15, 8), idWordQ.slice(7, 0));
    final idOp = idByte.slice(7, 4);
    final idRr = idByte.slice(3, 2);
    final idRl = idByte.slice(1, 0);
    final idImm4 = idByte.slice(3, 0);
    final idImm8 = idWordQ.slice(15, 8);
    final idPcPlus1 = idPcQ + 1;

    // ID Pre-Decode
    final idIsLdReg = idOp.eq(Const(MicroRISC4Constants.opLdReg, width: 4));
    final idIsLdImm4 = idOp.eq(Const(MicroRISC4Constants.opLdImm4, width: 4));
    final idIsPeek = idOp.eq(Const(MicroRISC4Constants.opLdPeek, width: 4));
    final idIsPoke = idOp.eq(Const(MicroRISC4Constants.opLdPoke, width: 4));
    final idIsPop = idOp.eq(Const(MicroRISC4Constants.opLdPostinc, width: 4));
    final idIsPush = idOp.eq(Const(MicroRISC4Constants.opLdPredec, width: 4));
    final idIsAdd = idOp.eq(Const(MicroRISC4Constants.opAdd, width: 4));
    final idIsSub = idOp.eq(Const(MicroRISC4Constants.opSub, width: 4));
    final idIsOr = idOp.eq(Const(MicroRISC4Constants.opOr, width: 4));
    final idIsXor = idOp.eq(Const(MicroRISC4Constants.opXor, width: 4));
    final idIsAnd = idOp.eq(Const(MicroRISC4Constants.opAnd, width: 4));
    final idIsShift = idOp.eq(Const(MicroRISC4Constants.opShift, width: 4));
    final idIsRotIncDec =
        idOp.eq(Const(MicroRISC4Constants.opRotIncDec, width: 4));
    final idIsJmpZ = idOp.eq(Const(MicroRISC4Constants.opJmpZ, width: 4));
    final idIsJmpM = idOp.eq(Const(MicroRISC4Constants.opJmpM, width: 4));
    final idIsSpecial =
        idOp.eq(Const(MicroRISC4Constants.opJmpSpecial, width: 4));

    final idIsEret = hasEpc
        ? idByte.eq(Const(MicroRISC4Constants.opEretByte, width: 8))
        : Const(0);
    final idIsNop = (~idIsEret) & idIsLdReg & idRr.eq(idRl);
    final idIsXchg = idIsShift &
        idRr.eq(Const(MicroRISC4Constants.subShiftXchg, width: 2));
    final idIsInc =
        idIsRotIncDec & idRr.eq(Const(MicroRISC4Constants.subInc, width: 2));
    final idIsDec =
        idIsRotIncDec & idRr.eq(Const(MicroRISC4Constants.subDec, width: 2));
    final idIsJmp =
        idIsSpecial & idRr.eq(Const(MicroRISC4Constants.subJmp, width: 2));
    final idIsLink =
        idIsSpecial & idRr.eq(Const(MicroRISC4Constants.subLink, width: 2));
    final idIsPush8 = (~idSlotQ) &
        idIsSpecial &
        idRr.eq(Const(MicroRISC4Constants.subPush8, width: 2));
    final idIsTrap =
        idIsSpecial & idRr.eq(Const(MicroRISC4Constants.subTrap, width: 2));
    final idIllegalSlot1 = idSlotQ & idIsSpecial & (idRr[1] | idRr[0]);

    // FWFT refill control for idWordQ / iqRam:
    // bypassDirect & iqPush depend ONLY on pure IF FFs (ZERO EX/exHold path into DPR16X4.WRE!)
    final idConsumesWord = idSlotQ | idIsPush8;
    final idWordDone = idAdvance & idConsumesWord;
    final idNeedsRefill = (~idValidQ) | idWordDone;
    final bypassDirect = (~idValidQ) & iqEmpty & ifPushValid;
    final iqPop = iqNotEmpty & idNeedsRefill;
    final iqPush = ifPushValid & (~bypassDirect);
    iqPushSig <= iqPush;

    final idUseRegLAsAddA = idIsPop | idIsRotIncDec;
    final idUseOneAsAddB = idIsPop | idIsPush | idIsRotIncDec;
    final idArithSub = idIsSub | idIsPush | idIsDec;
    final idIsArith = (~idIllegalSlot1) &
        (idIsPop | idIsPush | idIsAdd | idIsSub | idIsInc | idIsDec);
    final idIsLoad = (~idIllegalSlot1) & (idIsPeek | idIsPop);
    final idIsStore = (~idIllegalSlot1) & (idIsPoke | idIsPush);
    final idIsCtrlFlow =
        idIsJmpZ | idIsJmpM | (idIsSpecial & (~idIsPush8)) | idIsEret;
    final idNeedsMemIdle =
        idIllegalSlot1 | idIsLoad | idIsStore | idIsCtrlFlow;

    // Register Usage Flags for Exact Load-Use & WAW Interlock
    final idUsesR = (~idIllegalSlot1) &
        (idIsPoke |
            idIsPush |
            idIsAdd |
            idIsSub |
            idIsOr |
            idIsXor |
            idIsAnd |
            idIsJmpZ |
            idIsJmpM);
    final idUsesL = (~idIllegalSlot1) &
        (~idIsLdImm4) &
        (~idIsEret) &
        (~idIsNop);

    final idNormalWbEn = (idIsLdReg & (~idIsEret) & (~idIsNop)) |
        idIsLdImm4 |
        idIsPop |
        idIsPush |
        idIsAdd |
        idIsSub |
        idIsOr |
        idIsXor |
        idIsAnd |
        (config.enableShadowRegs ? idIsShift : (idIsShift & (~idIsXchg))) |
        idIsRotIncDec |
        idIsLink |
        idIsPush8 |
        idIsTrap;
    final idWbEn = idIllegalSlot1 | idNormalWbEn;
    final idWbForceR0 = idIllegalSlot1 | idIsLdImm4 | idIsLink | idIsTrap;
    final idWbUseRl = idIsPop | idIsShift | idIsRotIncDec | idIsPush8;
    final idWbIdx = mux(
      idWbForceR0,
      Const(0, width: 2),
      mux(idWbUseRl, idRl, idRr),
    );
    // Pre-decoded 4-bit one-hot register usage mask for 1-PFUMX loadHazard in EX
    final idRegMask = [
      for (var k = 3; k >= 0; k--)
        (idUsesR & idRr.eq(Const(k, width: 2))) |
            (idUsesL & idRl.eq(Const(k, width: 2))) |
            (idWbEn & idWbIdx.eq(Const(k, width: 2))),
    ].swizzle();

    // Balanced 4:1 Register-File Read Muxes + Pure-FF WB->ID Bypass
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
    final idRegR = mux(wbFwdValid & wbWbIdxQ.eq(idRr), wbDataQ, getReg(idRr));
    final idRegL = mux(wbFwdValid & wbWbIdxQ.eq(idRl), wbDataQ, getReg(idRl));
    final idShadowL = config.enableShadowRegs
        ? mux(wbValidQ & wbXchgQ & wbWbIdxQ.eq(idRl), wbShadowDataQ,
            getShadowReg(idRl))
        : Const(0, width: 16);

    // Pre-selected adder operands & pure-FF forwarding flags latched into ID/EX
    final idAddA = mux(idUseRegLAsAddA, idRegL, idRegR);
    final idAddAIdx = mux(idUseRegLAsAddA, idRl, idRr);
    final idAddBRaw = mux(idUseOneAsAddB, Const(1, width: 16), idRegL);
    final idAddB = mux(idArithSub, ~idAddBRaw, idAddBRaw);
    final idFwdR = nextWbEn & nextWbIdx.eq(idRr);
    final idFwdL = nextWbEn & nextWbIdx.eq(idRl);
    final idFwdShadowL = nextWbXchg & nextWbIdx.eq(idRl);
    final idFwdAddA = nextWbEn & nextWbIdx.eq(idAddAIdx);
    final idFwdAddB = (~idUseOneAsAddB) & nextWbEn & nextWbIdx.eq(idRl);
    final exAddAIdx = mux(exUseRegLAsAddAQ, exRlQ, exRrQ);

    // IF Address Sequencing Helpers (zero +1 adder on flush!)
    final portAAddrPlus1 = portAAddr + 1;
    final isExtPortA = useExtCache ? isExtAddr(portAAddr) : Const(0);
    final isExtPortAPlus1 = useExtCache ? isExtAddr(portAAddrPlus1) : Const(0);
    final isExtRedirect = useExtCache ? isExtAddr(redirectTarget) : Const(0);
    final localInFlight = portAEn |
        paV1Q |
        (config.memReadLatency == 2 ? paV2Q : Const(0));
    final extIfWillBeIdleOnFlush = useExtCache
        ? (extIfIsIdle |
            (extIfIsReq & (~icReqReadyIn)) |
            (extIfIsWait & icRespValidIn))
        : Const(1);

    // =========================================================================
    // Sequential Pipeline & Memory State Updates
    // =========================================================================
    Sequential(clk, reset: resetActive, resetValues: {
      // Register file & EPC
      for (final reg in r) reg: Const(0, width: 16),
      for (final sreg in shadowR) sreg: Const(0, width: 16),
      if (hasEpc) epcQ: Const(0, width: 16),
      // IF stage
      portAAddr: trapTableBaseConst,
      portAEn: Const(0, width: 1),
      paV1Q: Const(0, width: 1),
      if (config.memReadLatency == 2) paV2Q: Const(0, width: 1),
      iqWrPtrQ: Const(0, width: 3),
      iqRdPtrQ: Const(0, width: 3),
      iqCntQ: Const(0, width: 4),
      idValidQ: Const(0, width: 1),
      idWordQ: Const(0, width: 16),
      idPcQ: trapTableBaseConst,
      idSlotQ: Const(MicroRISC4Constants.slotByte0, width: 1),
      if (useExtCache) extIfStQ: Const(_extIfIdle, width: 2),
      if (useExtCache) extIfAddrQ: Const(0, width: 16),
      if (useExtCache) extIfDropQ: Const(0, width: 1),
      // ID/EX pipeline registers
      exValidQ: Const(0, width: 1),
      exPcQ: trapTableBaseConst,
      exPcPlus1Q: Const((config.trapTableBase + 1) & 0xFFFF, width: 16),
      exSlotQ: Const(0, width: 1),
      exOpQ: Const(0, width: 4),
      exRrQ: Const(0, width: 2),
      exRlQ: Const(0, width: 2),
      exImm4Q: Const(0, width: 4),
      exImm8Q: Const(0, width: 8),
      exValRQ: Const(0, width: 16),
      exValLQ: Const(0, width: 16),
      if (config.enableShadowRegs) exShadowLQ: Const(0, width: 16),
      exAddAQ: Const(0, width: 16),
      exAddBQ: Const(0, width: 16),
      exFwdRQ: Const(0, width: 1),
      exFwdLQ: Const(0, width: 1),
      if (config.enableShadowRegs) exFwdShadowLQ: Const(0, width: 1),
      exFwdAddAQ: Const(0, width: 1),
      exFwdAddBQ: Const(0, width: 1),
      exUseRegLAsAddAQ: Const(0, width: 1),
      exUseOneAsAddBQ: Const(0, width: 1),
      exArithSubQ: Const(0, width: 1),
      exIsArithQ: Const(0, width: 1),
      exIsLoadQ: Const(0, width: 1),
      exIsStoreQ: Const(0, width: 1),
      exIsPushQ: Const(0, width: 1),
      if (config.enableShadowRegs) exIsXchgQ: Const(0, width: 1),
      if (hasEpc) exIsEretQ: Const(0, width: 1),
      exIsJmpQ: Const(0, width: 1),
      exIsLinkQ: Const(0, width: 1),
      exIsPush8Q: Const(0, width: 1),
      exIsTrapQ: Const(0, width: 1),
      exIsJmpZQ: Const(0, width: 1),
      exIsJmpMQ: Const(0, width: 1),
      exIllegalSlot1Q: Const(0, width: 1),
      exRegMaskQ: Const(0, width: 4),
      exWbEnQ: Const(0, width: 1),
      exWbIdxQ: Const(0, width: 2),
      exNeedsMemIdleQ: Const(0, width: 1),
      // WB stage registers (wbDataQ / wbShadowDataQ are gated by wbValidQ/wbWbEnQ/exFwd*Q
      // which all reset to 0, avoiding a sync-reset LUT after the 16-bit CCU2C adder!)
      wbValidQ: Const(0, width: 1),
      wbWbEnQ: Const(0, width: 1),
      wbWbIdxQ: Const(0, width: 2),
      if (config.enableShadowRegs) wbXchgQ: Const(0, width: 1),
      // Parallel MEM unit & Port B
      memStQ: Const(_memIdle, width: 2),
      memBusyQ: Const(0, width: 1),
      memIsWbQ: Const(0, width: 1),
      memDestQ: Const(0, width: 2),
      memDestMaskQ: Const(0, width: 4),
      if (useExtCache) memIsExtWrQ: Const(0, width: 1),
      portBAddr: Const(0, width: 16),
      portBWdata: Const(0, width: 16),
      portBWe: Const(0, width: 1),
      portBEn: Const(0, width: 1),
      mmioRdataReg: Const(0, width: 16),
      isMmioRdReg: Const(0, width: 1),
      txData: Const(0, width: 8),
      txStrobe: Const(0, width: 1),
    }, [
      // Default single-cycle strobe
      txStrobe < 0,

      // =======================================================================
      // Stage 4 (WB): Commit Architectural & Shadow Register File (1 LUT4!)
      // =======================================================================
      If(wbValidQ & wbWbEnQ, then: [
        ..._writeReg(r, wbWbIdxQ, wbDataQ),
      ]),
      if (config.enableShadowRegs)
        If(wbValidQ & wbXchgQ, then: [
          ..._writeReg(shadowR, wbWbIdxQ, wbShadowDataQ),
        ]),

      // Dedicated hardware EPC (0x001E) updates
      if (hasEpc)
        If(crossTrapTake, then: [
          epcQ < exPcQ,
        ], orElse: [
          If(exFire & (exIllegalSlot1Q | exIsTrapQ), then: [
            epcQ < exPcPlus1Q,
          ], orElse: [
            If(portBEn & portBWe & isMmioEpc, then: [
              epcQ < portBWdata,
            ]),
          ]),
        ]),

      // =======================================================================
      // Stage 3 -> Stage 4 (EX / MEM -> WB Pipeline Latch, 1 LUT4 after CCU2C!)
      // =======================================================================
      wbValidQ < (memIsWb | crossTrapClobbersR0 | exFire),
      wbWbEnQ < nextWbEn,
      wbWbIdxQ < nextWbIdx,
      wbDataQ < nextWbData,
      if (config.enableShadowRegs) wbXchgQ < nextWbXchg,
      if (config.enableShadowRegs) wbShadowDataQ < effL,

      // =======================================================================
      // Parallel Non-Blocking Port B Memory / MMIO / DCache State Machine
      // =======================================================================
      Case(memStQ, [
        CaseItem(Const(_memIdle, width: 2), [
          If(exFireIdle & exIsLoadQ, then: [
            portBAddr < effL,
            portBWe < 0,
            portBEn < 1,
            memDestQ < exRrQ,
            memDestMaskQ < [
              exRrQ.eq(Const(3, width: 2)),
              exRrQ.eq(Const(2, width: 2)),
              exRrQ.eq(Const(1, width: 2)),
              exRrQ.eq(Const(0, width: 2)),
            ].swizzle(),
            if (useExtCache) memIsExtWrQ < 0,
            memStQ < Const(_memWait1, width: 2),
            memBusyQ < 1,
            memIsWbQ < 0,
          ], orElse: [
            If(exFireIdle & exIsStoreQ, then: [
              portBAddr < mux(exIsPushQ, arithRes, effR),
              portBWdata < effL,
              portBWe < 1,
              portBEn < 1,
              if (config.enableUart)
                If(
                  mux(
                    exIsPushQ,
                    effR.eq(Const(0x0010, width: 16)),
                    effR.eq(Const(MicroRISC4Constants.addrUartTx, width: 16)),
                  ),
                  then: [
                    txData < effL.slice(7, 0),
                    txStrobe < 1,
                  ],
                ),
              if (useExtCache)
                If(exIsExtStore, then: [
                  memIsExtWrQ < 1,
                  memDestMaskQ < Const(0, width: 4),
                  memStQ < Const(_memWait1, width: 2),
                  memBusyQ < 1,
                  memIsWbQ < 0,
                ]),
            ], orElse: [
              portBEn < 0,
              portBWe < 0,
            ]),
          ]),
        ]),

        // _memWait1: Cycle 1 of Port B BRAM read (or DCache req handshake)
        CaseItem(Const(_memWait1, width: 2), [
          if (useExtCache)
            If(isExtPortB, then: [
              If(dcReqReadyIn, then: [
                portBEn < 0,
                portBWe < 0,
                memStQ < Const(_memWait2, width: 2),
              ]),
            ], orElse: [
              portBEn < 0,
              portBWe < 0,
              If(memIsExtWrQ, then: [
                // Boundary case: pre-decrement crossed memWords -> memWords-1 (local BRAM)
                memIsExtWrQ < 0,
                memDestMaskQ < Const(0, width: 4),
                memStQ < Const(_memIdle, width: 2),
                memBusyQ < 0,
                memIsWbQ < 0,
              ], orElse: [
                if (config.memReadLatency == 1) ...[
                  mmioRdataReg < mmioOnlyData,
                  isMmioRdReg < isMmio,
                  memStQ < Const(_memWb, width: 2),
                  memIsWbQ < 1,
                ] else
                  memStQ < Const(_memWait2, width: 2),
              ]),
            ])
          else ...[
            portBEn < 0,
            portBWe < 0,
            if (config.memReadLatency == 1) ...[
              mmioRdataReg < mmioOnlyData,
              isMmioRdReg < isMmio,
              memStQ < Const(_memWb, width: 2),
              memIsWbQ < 1,
            ] else
              memStQ < Const(_memWait2, width: 2),
          ],
        ]),

        // _memWait2: Cycle 2 of Port B BRAM read (or wait for DCache resp)
        CaseItem(Const(_memWait2, width: 2), [
          portBEn < 0,
          portBWe < 0,
          if (useExtCache)
            If(isExtPortB, then: [
              If(dcRespValidIn, then: [
                If(memIsExtWrQ, then: [
                  memIsExtWrQ < 0,
                  memDestMaskQ < Const(0, width: 4),
                  memStQ < Const(_memIdle, width: 2),
                  memBusyQ < 0,
                  memIsWbQ < 0,
                ], orElse: [
                  mmioRdataReg < dcRespDataIn,
                  isMmioRdReg < 1,
                  memStQ < Const(_memWb, width: 2),
                  memIsWbQ < 1,
                ]),
              ]),
            ], orElse: [
              mmioRdataReg < mmioOnlyData,
              isMmioRdReg < isMmio,
              memStQ < Const(_memWb, width: 2),
              memIsWbQ < 1,
            ])
          else ...[
            mmioRdataReg < mmioOnlyData,
            isMmioRdReg < isMmio,
            memStQ < Const(_memWb, width: 2),
            memIsWbQ < 1,
          ],
        ]),

        // _memWb: Load word captured into WB stage; return to IDLE
        CaseItem(Const(_memWb, width: 2), [
          portBEn < 0,
          portBWe < 0,
          memDestMaskQ < Const(0, width: 4),
          memStQ < Const(_memIdle, width: 2),
          memBusyQ < 0,
          memIsWbQ < 0,
        ]),
      ]),

      // =======================================================================
      // Stage 2 -> Stage 3 (ID/RF -> EX Pipeline Latch & Stall Forward Capture)
      // Decoupled: ONLY 1-bit exValidQ sees flush; all 149 data/ctrl FFs depend
      // strictly on local 1-bit exHold (zero flush/crossTrap/idValid on CE!).
      // =======================================================================
      If(flush, then: [
        exValidQ < 0,
      ], orElse: [
        If(~exHold, then: [
          exValidQ < idValidQ,
        ]),
      ]),

      If(exHold, then: [
        // Capture any active WB->EX forwarded values while EX is stalled
        // so retiring WB data is never lost across stall cycles!
        exValRQ < effR,
        exValLQ < effL,
        if (config.enableShadowRegs) exShadowLQ < effShadowL,
        exAddAQ < addA,
        exAddBQ < addBInv,
        exFwdRQ < (nextWbEn & nextWbIdx.eq(exRrQ)),
        exFwdLQ < (nextWbEn & nextWbIdx.eq(exRlQ)),
        if (config.enableShadowRegs)
          exFwdShadowLQ < (nextWbXchg & nextWbIdx.eq(exRlQ)),
        exFwdAddAQ < (nextWbEn & nextWbIdx.eq(exAddAIdx)),
        exFwdAddBQ < ((~exUseOneAsAddBQ) & nextWbEn & nextWbIdx.eq(exRlQ)),
      ], orElse: [
        exPcQ < idPcQ,
        exPcPlus1Q < idPcPlus1,
        exSlotQ < idSlotQ,
        exOpQ < idOp,
        exRrQ < idRr,
        exRlQ < idRl,
        exImm4Q < idImm4,
        exImm8Q < idImm8,
        exValRQ < idRegR,
        exValLQ < idRegL,
        if (config.enableShadowRegs) exShadowLQ < idShadowL,
        exAddAQ < idAddA,
        exAddBQ < idAddB,
        exFwdRQ < idFwdR,
        exFwdLQ < idFwdL,
        if (config.enableShadowRegs) exFwdShadowLQ < idFwdShadowL,
        exFwdAddAQ < idFwdAddA,
        exFwdAddBQ < idFwdAddB,
        exUseRegLAsAddAQ < idUseRegLAsAddA,
        exUseOneAsAddBQ < idUseOneAsAddB,
        exArithSubQ < idArithSub,
        exIsArithQ < idIsArith,
        exIsLoadQ < idIsLoad,
        exIsStoreQ < idIsStore,
        exIsPushQ < idIsPush,
        if (config.enableShadowRegs) exIsXchgQ < idIsXchg,
        if (hasEpc) exIsEretQ < idIsEret,
        exIsJmpQ < idIsJmp,
        exIsLinkQ < idIsLink,
        exIsPush8Q < idIsPush8,
        exIsTrapQ < idIsTrap,
        exIsJmpZQ < idIsJmpZ,
        exIsJmpMQ < idIsJmpM,
        exIllegalSlot1Q < idIllegalSlot1,
        exRegMaskQ < idRegMask,
        exWbEnQ < idWbEn,
        exWbIdxQ < idWbIdx,
        exNeedsMemIdleQ < idNeedsMemIdle,
      ]),

      // =======================================================================
      // Stage 1 (IF): Prefetch Queue, Pure-FF FWFT Head & Port A Sequencer
      // =======================================================================
      If(flush, then: [
        iqWrPtrQ < Const(0, width: 3),
        iqRdPtrQ < Const(0, width: 3),
        iqCntQ < Const(0, width: 4),
        idValidQ < 0,
        idPcQ < redirectTarget,
        idSlotQ < Const(MicroRISC4Constants.slotByte0, width: 1),
        paV1Q < 0,
        if (config.memReadLatency == 2) paV2Q < 0,
        portAAddr < redirectTarget,
        portAEn < (extIfWillBeIdleOnFlush & (~isExtRedirect)),
        if (useExtCache)
          Case(extIfStQ, [
            CaseItem(Const(_extIfIdle, width: 2), [
              extIfDropQ < 0,
            ]),
            CaseItem(Const(_extIfReq, width: 2), [
              If(icReqReadyIn, then: [
                // I-Cache accepted old request on this edge; must drop its response
                extIfStQ < Const(_extIfWait, width: 2),
                extIfDropQ < 1,
              ], orElse: [
                extIfStQ < Const(_extIfIdle, width: 2),
                extIfDropQ < 0,
              ]),
            ]),
            CaseItem(Const(_extIfWait, width: 2), [
              If(icRespValidIn, then: [
                extIfStQ < Const(_extIfIdle, width: 2),
                extIfDropQ < 0,
              ], orElse: [
                extIfDropQ < 1,
              ]),
            ]),
          ]),
      ], orElse: [
        // Local BRAM Port A pipeline valid shift register
        paV1Q < portAEn,
        if (config.memReadLatency == 2) paV2Q < paV1Q,

        // Prefetch Queue pointers & count
        If(iqPush, then: [
          iqWrPtrQ < iqWrPtrQ + Const(1, width: 3),
        ]),
        If(iqPop, then: [
          iqRdPtrQ < iqRdPtrQ + Const(1, width: 3),
        ]),
        If(iqPush & (~iqPop), then: [
          iqCntQ < iqCntQ + Const(1, width: 4),
        ], orElse: [
          If((~iqPush) & iqPop, then: [
            iqCntQ < iqCntQ - Const(1, width: 4),
          ]),
        ]),

        // Pure-FF FWFT Head Register Refill (idWordQ / idValidQ)
        If(idNeedsRefill, then: [
          If(iqNotEmpty, then: [
            idWordQ < iqRamRdata,
            idValidQ < 1,
          ], orElse: [
            If(bypassDirect, then: [
              idWordQ < ifPushData,
              idValidQ < 1,
            ], orElse: [
              idValidQ < 0,
            ]),
          ]),
        ]),

        // ID PC & Slot progression
        If(idAdvance, then: [
          If(idConsumesWord, then: [
            idSlotQ < Const(MicroRISC4Constants.slotByte0, width: 1),
            idPcQ < idPcPlus1,
          ], orElse: [
            idSlotQ < Const(MicroRISC4Constants.slotByte1, width: 1),
          ]),
        ]),

        // External I-Cache fetch FSM progression
        if (useExtCache)
          Case(extIfStQ, [
            CaseItem(Const(_extIfReq, width: 2), [
              If(icReqReadyIn, then: [
                extIfStQ < Const(_extIfWait, width: 2),
              ]),
            ]),
            CaseItem(Const(_extIfWait, width: 2), [
              If(icRespValidIn, then: [
                extIfStQ < Const(_extIfIdle, width: 2),
                extIfDropQ < 0,
              ]),
            ]),
          ]),

        // Port A / Fetch Address Invariant:
        //  - portAEn == 1: portAAddr is being read now -> next un-fetched is portAAddr + 1
        //  - portAEn == 0: portAAddr IS the next un-fetched PC
        If(portAEn, then: [
          portAAddr < portAAddrPlus1,
          portAEn < ((~extIfActive) & (~isExtPortAPlus1) & iqHasRoom),
        ], orElse: [
          If((~extIfActive) & iqHasRoom, then: [
            if (useExtCache)
              If(isExtPortA, then: [
                If(~localInFlight, then: [
                  extIfAddrQ < portAAddr,
                  extIfStQ < Const(_extIfReq, width: 2),
                  extIfDropQ < 0,
                  portAAddr < portAAddrPlus1,
                  portAEn < 0,
                ]),
              ], orElse: [
                portAEn < 1,
              ])
            else
              portAEn < 1,
          ], orElse: [
            portAEn < 0,
          ]),
        ]),
      ]),
    ]);
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

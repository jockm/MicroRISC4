// ==============================================================================
// FILE: hdl/rohd/lib/ulx3s_top.dart
// ULX3S-85F Board Top-Level Module Wrapper (Intel ROHD)
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'cache_subsystem_top.dart';
import 'constants.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'ecp5_pll.dart';
import 'noc_cache_wrapper.dart';
import 'noc_router.dart';
import 'uart.dart';

class Ulx3sTop extends Module {
  late final CpuCore cpu;
  late final List<CpuCore> cores;
  late final bool hasSdram;
  LogicNet? sdramDNet;
  Logic? sdramDqOutDebug;
  Logic? sdramDqOeDebug;

  Ulx3sTop({
    required Logic clk25mhz,
    required Logic btnPwrN,
    required Logic ftdiTxd,
    LogicNet? sdramD,
    CpuConfig config = const CpuConfig(
      coreId: 0,
      enableCpuid: false,
      enableUart: true,
      enableCrossTraps: false,
      enableMathAccel: false,
      trapTableBase: 0x0100,
      memWords: 65536,
    ),
    int nocCores = 0,
    int workerMemWords = 2048,
    int mboxTrapVec = 0x0E,
    int clkFreqMhz = 48,
    int resetHoldBits = 2,
    int? sdramInitWaitCycles,
    int? sdramRefreshCycles,
    String? initHexFile = 'system_image.hex',
    String? workerInitHexFile,
    Map<int, int>? initialMemory,
    List<Map<int, int>?>? workerInitialMemories,
    super.name = 'ulx3s_top',
  }) {
    clk25mhz = addInput('clk_25mhz', clk25mhz);
    btnPwrN = addInput('btn_pwr_n', btnPwrN);
    ftdiTxd = addInput('ftdi_txd', ftdiTxd);

    final ftdiRxd = addOutput('ftdi_rxd');
    final wifiGpio0 = addOutput('wifi_gpio0');
    final led = addOutput('led', width: 8);

    // Keep onboard ESP32 out of bootloader/reset interference
    wifiGpio0 <= Const(1);

    // 25 MHz -> clkFreqMhz PLL (48/60/72/84/96 MHz) for exact 3 Mbaud UART
    // (uartDivisor = clkFreqMhz / 3, 4x RX oversampling = uartDivisor / 4)
    final pll = Ecp5Pll(clkIn: clk25mhz, clkFreqMhz: clkFreqMhz);
    final clkSys = pll.clkOut;
    final uartDivisor = clkFreqMhz ~/ 3;
    final sdramExtraReadPipeCycles = clkFreqMhz > 48 ? 1 : 0;

    // 2-FF synchronizer + power-on / button-debounce reset hold counter.
    // Raw async input (btnPwrN & pll.locked) only feeds rstSync0 so the
    // CPU/UART/NoC domain receives a clean synchronous single-register reset.
    final rawRstN = btnPwrN & pll.locked;
    final rstSync0 = Logic(name: 'rst_sync_0');
    final rstSync1 = Logic(name: 'rst_sync_1');
    final rstHoldCnt = Logic(name: 'rst_hold_cnt', width: resetHoldBits);
    final sysRstN = Logic(name: 'sys_rst_n');
    final rstHoldMax = Const((1 << resetHoldBits) - 1, width: resetHoldBits);

    Sequential(clkSys, [
      rstSync0 < rawRstN,
      rstSync1 < rstSync0,
      If(~rstSync1, then: [
        rstHoldCnt < 0,
        sysRstN < 0,
      ], orElse: [
        If(rstHoldCnt.eq(rstHoldMax), then: [
          sysRstN < 1,
        ], orElse: [
          rstHoldCnt < rstHoldCnt + 1,
          sysRstN < 0,
        ]),
      ]),
    ]);
    final uartReset = ~sysRstN;

    // UART MMIO Registers
    final uartRxdLatch = Logic(name: 'uart_rxd_latch', width: 8);
    final uartRxValid = Logic(name: 'uart_rx_valid');
    final txBusyLatch = Logic(name: 'tx_busy_latch');

    final useNoc = nocCores >= 2;
    final coreCount = useNoc ? nocCores : 1;
    final useSdramCache = config.enableSdramCache &&
        (config.memWords < 65536 || (useNoc && workerMemWords < 65536));
    hasSdram = useSdramCache;

    final effectiveConfig = useNoc
        ? CpuConfig(
            coreId: config.coreId,
            enableCpuid: true,
            enableCpuInfo: config.enableCpuInfo,
            enableUart: config.enableUart,
            enableCrossTraps: config.enableCrossTraps,
            enableEpc: config.enableEpc,
            enableShadowRegs: config.enableShadowRegs,
            enableMathAccel: config.enableMathAccel,
            enableFpu: config.enableFpu,
            enableSpi: config.enableSpi,
            enableNoc: true,
            enableSdramCache: useSdramCache && config.memWords < 65536,
            isPipelined: config.isPipelined,
            cpuVersionMajor: config.cpuVersionMajor,
            cpuVersionMinor: config.cpuVersionMinor,
            cpuCaps2: config.cpuCaps2,
            cacheLines: config.cacheLines,
            cacheLineWords: config.cacheLineWords,
            nocChannels: config.nocChannels,
            nocFifoDepth: config.nocFifoDepth,
            trapTableBase: config.trapTableBase,
            memWords: config.memWords,
          )
        : config;

    final cpuRxData = Logic(name: 'cpu_rx_data', width: 16);
    final cpuTxStatus = Logic(name: 'cpu_tx_status', width: 16);
    final nocRdataPerCore = List.generate(
      coreCount,
      (i) => Logic(name: 'noc_rdata_core$i', width: 16),
    );
    final coreExtTrapReq = List.generate(
      coreCount,
      (i) => Logic(name: 'core_ext_trap_req_$i'),
    );
    final icReqReadyPerCore = List.generate(
      coreCount,
      (i) => Logic(name: 'ic_req_ready_core$i'),
    );
    final icRespValidPerCore = List.generate(
      coreCount,
      (i) => Logic(name: 'ic_resp_valid_core$i'),
    );
    final icRespDataPerCore = List.generate(
      coreCount,
      (i) => Logic(name: 'ic_resp_data_core$i', width: 16),
    );
    final dcReqReadyPerCore = List.generate(
      coreCount,
      (i) => Logic(name: 'dc_req_ready_core$i'),
    );
    final dcRespValidPerCore = List.generate(
      coreCount,
      (i) => Logic(name: 'dc_resp_valid_core$i'),
    );
    final dcRespDataPerCore = List.generate(
      coreCount,
      (i) => Logic(name: 'dc_resp_data_core$i', width: 16),
    );
    final mboxTrapVecConst = Const(mboxTrapVec & 0x0F, width: 4);

    cpuRxData <= [uartRxValid, Const(0, width: 7), uartRxdLatch].swizzle();
    cpuTxStatus <= mux(txBusyLatch, Const(1, width: 16), Const(0, width: 16));

    // Core 0: Primary OS / UART / Monitor core
    final core0ExtCache =
        effectiveConfig.enableSdramCache && effectiveConfig.memWords < 65536;
    cpu = CpuCore(
      clk: clkSys,
      rstN: sysRstN,
      mmioRxData: cpuRxData,
      mmioTxStatus: cpuTxStatus,
      extTrapReq: (useNoc && effectiveConfig.enableCrossTraps)
          ? coreExtTrapReq[0]
          : null,
      extTrapNum: (useNoc && effectiveConfig.enableCrossTraps)
          ? mboxTrapVecConst
          : null,
      nocRdata: useNoc ? nocRdataPerCore[0] : null,
      icReqReady: core0ExtCache ? icReqReadyPerCore[0] : null,
      icRespValid: core0ExtCache ? icRespValidPerCore[0] : null,
      icRespData: core0ExtCache ? icRespDataPerCore[0] : null,
      dcReqReady: core0ExtCache ? dcReqReadyPerCore[0] : null,
      dcRespValid: core0ExtCache ? dcRespValidPerCore[0] : null,
      dcRespData: core0ExtCache ? dcRespDataPerCore[0] : null,
      config: effectiveConfig,
      initHexFile: initHexFile,
      initialMemory: initialMemory,
      name: 'cpu_core',
    );

    final instantiatedCores = <CpuCore>[cpu];

    // Worker Cores 1..N-1 (instantiated whenever nocCores >= 2)
    if (useNoc) {
      for (var c = 1; c < nocCores; c++) {
        final workerExtCache = useSdramCache && workerMemWords < 65536;
        final workerCfg = CpuConfig(
          coreId: c,
          enableCpuid: true,
          enableCpuInfo: effectiveConfig.enableCpuInfo,
          enableUart: false,
          enableCrossTraps: effectiveConfig.enableCrossTraps,
          enableEpc: effectiveConfig.enableEpc,
          enableShadowRegs: effectiveConfig.enableShadowRegs,
          enableMathAccel: effectiveConfig.enableMathAccel,
          enableFpu: effectiveConfig.enableFpu,
          enableSpi: false,
          enableNoc: true,
          enableSdramCache: workerExtCache,
          isPipelined: effectiveConfig.isPipelined,
          cpuVersionMajor: effectiveConfig.cpuVersionMajor,
          cpuVersionMinor: effectiveConfig.cpuVersionMinor,
          cpuCaps2: effectiveConfig.cpuCaps2,
          cacheLines: effectiveConfig.cacheLines,
          cacheLineWords: effectiveConfig.cacheLineWords,
          nocChannels: effectiveConfig.nocChannels,
          nocFifoDepth: effectiveConfig.nocFifoDepth,
          trapTableBase: effectiveConfig.trapTableBase,
          memWords: workerMemWords,
        );
        final workerMem =
            (workerInitialMemories != null && (c - 1) < workerInitialMemories.length)
                ? workerInitialMemories[c - 1]
                : null;
        instantiatedCores.add(
          CpuCore(
            clk: clkSys,
            rstN: sysRstN,
            extTrapReq: effectiveConfig.enableCrossTraps
                ? coreExtTrapReq[c]
                : null,
            extTrapNum: effectiveConfig.enableCrossTraps
                ? mboxTrapVecConst
                : null,
            nocRdata: nocRdataPerCore[c],
            icReqReady: workerExtCache ? icReqReadyPerCore[c] : null,
            icRespValid: workerExtCache ? icRespValidPerCore[c] : null,
            icRespData: workerExtCache ? icRespDataPerCore[c] : null,
            dcReqReady: workerExtCache ? dcReqReadyPerCore[c] : null,
            dcRespValid: workerExtCache ? dcRespValidPerCore[c] : null,
            dcRespData: workerExtCache ? dcRespDataPerCore[c] : null,
            config: workerCfg,
            initHexFile: workerMem != null ? null : workerInitHexFile,
            initialMemory: workerMem,
            name: 'cpu_worker_$c',
          ),
        );
      }
    }
    cores = List.unmodifiable(instantiatedCores);

    if (useSdramCache) {
      final sdramClkOut = addOutput('sdram_clk');
      final sdramCkeOut = addOutput('sdram_cke');
      final sdramCsnOut = addOutput('sdram_csn');
      final sdramRasnOut = addOutput('sdram_rasn');
      final sdramCasnOut = addOutput('sdram_casn');
      final sdramWenOut = addOutput('sdram_wen');
      final sdramBaOut = addOutput('sdram_ba', width: 2);
      final sdramAOut = addOutput('sdram_a', width: 13);
      final sdramDqmOut = addOutput('sdram_dqm', width: 2);
      final dqNet = addInOut(
        'sdram_d',
        sdramD ?? LogicNet(name: 'sdram_d_net', width: 16),
        width: 16,
      );
      sdramDNet = dqNet;

      final icReqValidList = <Logic>[];
      final icReqAddrList = <Logic>[];
      final dcReqValidList = <Logic>[];
      final dcReqWeList = <Logic>[];
      final dcReqAddrList = <Logic>[];
      final dcReqWdataList = <Logic>[];

      for (var c = 0; c < coreCount; c++) {
        final core = cores[c];
        final coreHasExt =
            core.config.enableSdramCache && core.config.memWords < 65536;
        if (coreHasExt) {
          icReqValidList.add(core.output('ic_req_valid'));
          icReqAddrList.add(core.output('ic_req_addr'));
          dcReqValidList.add(core.output('dc_req_valid'));
          dcReqWeList.add(core.output('dc_req_we'));
          dcReqAddrList.add(core.output('dc_req_addr'));
          dcReqWdataList.add(core.output('dc_req_wdata'));
        } else {
          icReqValidList.add(Const(0));
          icReqAddrList.add(Const(0, width: 16));
          dcReqValidList.add(Const(0));
          dcReqWeList.add(Const(0));
          dcReqAddrList.add(Const(0, width: 16));
          dcReqWdataList.add(Const(0, width: 16));
        }
      }

      final cacheCluster = SdramCacheCluster(
        clk: clkSys,
        rstN: sysRstN,
        icReqValid: icReqValidList,
        icReqAddr: icReqAddrList,
        dcReqValid: dcReqValidList,
        dcReqWe: dcReqWeList,
        dcReqAddr: dcReqAddrList,
        dcReqWdata: dcReqWdataList,
        sdramDqIn: dqNet,
        numCores: coreCount,
        numLines: effectiveConfig.cacheLines,
        lineWords: effectiveConfig.cacheLineWords,
        clkFreqMhz: clkFreqMhz,
        casLatency: 2,
        extraReadPipeCycles: sdramExtraReadPipeCycles,
        initWaitCycles: sdramInitWaitCycles,
        refreshCycles: sdramRefreshCycles,
        name: 'ulx3s_sdram_cluster',
      );

      for (var c = 0; c < coreCount; c++) {
        icReqReadyPerCore[c] <= cacheCluster.output('ic_req_ready_$c');
        icRespValidPerCore[c] <= cacheCluster.output('ic_resp_valid_$c');
        icRespDataPerCore[c] <= cacheCluster.output('ic_resp_data_$c');
        dcReqReadyPerCore[c] <= cacheCluster.output('dc_req_ready_$c');
        dcRespValidPerCore[c] <= cacheCluster.output('dc_resp_valid_$c');
        dcRespDataPerCore[c] <= cacheCluster.output('dc_resp_data_$c');
      }

      // Hardware ODDRX1F SDRAM clock forwarding (zero fabric LUT4 skew):
      // - 48 MHz: proven 180° inverted ODDRX1F from clkSys
      // - 60–96 MHz: non-inverting ODDRX1F from PLL CLKOS2 (270°–306° phase shift)
      if (clkFreqMhz > 48) {
        final sdramOddr =
            Ecp5OddrClkFwd(clkIn: pll.clkSdram, name: 'sdram_clk_oddr');
        sdramClkOut <= sdramOddr.clkOut;
      } else {
        final sdramOddr =
            Ecp5OddrClkInv(clkIn: clkSys, name: 'sdram_clk_oddr');
        sdramClkOut <= sdramOddr.clkOut;
      }
      sdramCkeOut <= cacheCluster.output('sdram_cke');
      sdramCsnOut <= cacheCluster.output('sdram_cs_n');
      sdramRasnOut <= cacheCluster.output('sdram_ras_n');
      sdramCasnOut <= cacheCluster.output('sdram_cas_n');
      sdramWenOut <= cacheCluster.output('sdram_we_n');
      sdramBaOut <= cacheCluster.output('sdram_ba');
      sdramAOut <= cacheCluster.output('sdram_a');
      sdramDqmOut <= cacheCluster.output('sdram_dqm');

      sdramDqOutDebug = cacheCluster.output('sdram_dq_out');
      sdramDqOeDebug = cacheCluster.output('sdram_dq_oe');
      final dqTri = TriStateBuffer(
        cacheCluster.output('sdram_dq_out'),
        enable: cacheCluster.output('sdram_dq_oe'),
        name: 'sdram_dq_tri',
      );
      dqNet <= dqTri.out;
    } else {
      for (var c = 0; c < coreCount; c++) {
        icReqReadyPerCore[c] <= Const(1);
        icRespValidPerCore[c] <= Const(0);
        icRespDataPerCore[c] <= Const(0, width: 16);
        dcReqReadyPerCore[c] <= Const(1);
        dcRespValidPerCore[c] <= Const(0);
        dcRespDataPerCore[c] <= Const(0, width: 16);
      }
    }

    final uart = Uart(
      clk: clkSys,
      reset: uartReset,
      serialRxd: ftdiTxd,
      txd: cpu.txData,
      txdStrobe: cpu.txStrobe,
      divisor: uartDivisor,
    );

    ftdiRxd <= uart.serialTxd;

    if (useNoc) {
      final mmioAddr = <Logic>[];
      final mmioWdata = <Logic>[];
      final mmioWe = <Logic>[];
      final mmioRe = <Logic>[];
      final netOutReady = List.generate(nocCores, (i) => Const(1));

      for (var c = 0; c < nocCores; c++) {
        final core = cores[c];
        final busEn = core.output('port_b_en_out');
        final busWe = core.output('port_b_we_out');
        final busAddr = core.output('port_b_addr_out');
        final busWdata = core.output('port_b_wdata_out');
        // Fast 2-LUT decode for 0x0020..0x002A (avoids 16-bit CCU2C comparators)
        final inNocRange = busAddr.slice(15, 4).eq(Const(0x002, width: 12)) &
            busAddr.slice(3, 0).lte(Const(0xA, width: 4));
        mmioAddr.add(busAddr);
        mmioWdata.add(busWdata);
        mmioWe.add(busEn & busWe & inNocRange);
        mmioRe.add(busEn & (~busWe) & inNocRange);
      }

      final srvIdWidth = NocRouterNi.idWidthForCores(nocCores);
      final nocFabric = NocMultiCoreCacheWrapper(
        clk: clkSys,
        reset: uartReset,
        mmioAddr: mmioAddr,
        mmioWdata: mmioWdata,
        mmioWe: mmioWe,
        mmioRe: mmioRe,
        netOutReady: netOutReady,
        srvInjectValid: Const(0),
        srvInjectType: Const(0),
        srvInjectSrcCore: Const(0, width: srvIdWidth),
        srvInjectDstCore: Const(0, width: srvIdWidth),
        srvInjectPayload: Const(0, width: MiniRISC4Constants.dataWidth),
        numCores: nocCores,
        serverCoreId: 0,
        fifoDepth: effectiveConfig.nocFifoDepth,
        name: 'ulx3s_noc_fabric',
      );

      for (var c = 0; c < nocCores; c++) {
        nocRdataPerCore[c] <= nocFabric.output('mmioRdataReg_$c');
        if (effectiveConfig.enableCrossTraps) {
          // One-shot-per-burst MBOX cross-trap gate: holds ext_trap_req high
          // until CpuCore reaches ST_EXEC and acknowledges (ext_trap_ack),
          // then masks re-entry until software drains the MBOX FIFO.
          final mboxReq = nocFabric.output('mboxTrapReq_$c');
          final inFlightQ = Logic(name: 'mbox_trap_inflight_$c');
          coreExtTrapReq[c] <= mboxReq & (~inFlightQ);
          Sequential(clkSys, reset: uartReset, resetValues: {
            inFlightQ: 0,
          }, [
            If(~mboxReq, then: [
              inFlightQ < 0,
            ], orElse: [
              If(cores[c].extTrapAck, then: [
                inFlightQ < 1,
              ]),
            ]),
          ]);
        } else {
          coreExtTrapReq[c] <= Const(0);
        }
      }

      led <= [
        pll.locked,
        nocFabric.output('mboxTrapReq_0'),
        cpu.debugPc.slice(5, 0),
      ].swizzle();
    } else {
      nocRdataPerCore[0] <= Const(0, width: 16);
      coreExtTrapReq[0] <= Const(0);
      led <= [pll.locked, cpu.debugPc.slice(6, 0)].swizzle();
    }

    Sequential(clkSys, reset: uartReset, resetValues: {
      uartRxValid: 0,
      uartRxdLatch: 0,
    }, [
      If(uart.rxdStrobe, then: [
        uartRxdLatch < uart.rxd,
        uartRxValid < 1,
      ], orElse: [
        If(cpu.rxPop, then: [
          uartRxValid < 0,
        ]),
      ]),
    ]);

    Sequential(clkSys, reset: uartReset, resetValues: {
      txBusyLatch: 0,
    }, [
      If(cpu.txStrobe, then: [
        txBusyLatch < 1,
      ], orElse: [
        If(uart.txdReady, then: [
          txBusyLatch < 0,
        ]),
      ]),
    ]);
  }

  Logic get ftdiRxd => output('ftdi_rxd');
  Logic get wifiGpio0 => output('wifi_gpio0');
  Logic get led => output('led');
  Logic get sdramClk => output('sdram_clk');
  Logic get sdramCke => output('sdram_cke');
  Logic get sdramCsn => output('sdram_csn');
  Logic get sdramRasn => output('sdram_rasn');
  Logic get sdramCasn => output('sdram_casn');
  Logic get sdramWen => output('sdram_wen');
  Logic get sdramBa => output('sdram_ba');
  Logic get sdramA => output('sdram_a');
  Logic get sdramDqm => output('sdram_dqm');
}

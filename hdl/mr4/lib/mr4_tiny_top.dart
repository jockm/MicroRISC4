// ==============================================================================
// FILE: hdl/mr4/lib/mr4_tiny_top.dart
// Tiny Tapeout MicroRISC4 Chip Top (`tt_um_mr4`, Track E.1.2)
//
// Targets a 2x2 Tiny Tapeout tile (~330 x 220 um on sky130hd / ihp-sg13g2)
// with ZERO mocked memories and ZERO FPGA primitives:
//   - MicroRISC4 4-stage pipelined CPU core (`CpuCore`)
//   - 16-word (256-FF) on-chip local scratchpad (`0x0000..0x000F`: SAVEALL, RSP, ASP)
//   - 256-word synthesizable `AsicBootRom` (`0x0100..0x01FF`: `tiny_boot.asm`)
//   - Compact `QspiMemController` (`0x0200..0xFFFF` = 127.5 KB external QSPI PSRAM / Flash)
//   - Full-duplex 8-N-1 UART (`Uart`) for console I/O and binary serial program upload
//
// Exact Tiny Tapeout Standard Pinout (`tt_um_mr4`):
//   clk        : System clock (50 MHz default on Tiny Tapeout demo board)
//   rst_n      : Active-low reset (synchronized cleanly with `ena`)
//   ena        : Active-high project enable (holds design in reset when 0)
//   ui_in[0]   : uart_rxd         (UART RX serial input, idle high)
//   ui_in[1]   : boot_from_flash  (0 = PSRAM CS1 reads/writes; 1 = Flash CS0 XIP reads)
//   ui_in[7:2] : Reserved
//   uo_out[0]  : uart_txd         (UART TX serial output, idle high)
//   uo_out[1]  : qspi_active      (1 when external QSPI CS0 or CS1 is asserted)
//   uo_out[2]  : uart_rx_valid    (1 when an unread UART RX byte is latched)
//   uo_out[3]  : uart_tx_busy     (1 while UART TX is shifting a frame)
//   uo_out[7:4]: debug_pc[3:0]    (live lower 4 bits of CPU PC for visual heartbeat)
//   uio[0]     : qspi_flash_cs_n  (CS0: QSPI Flash, active low, oe=1)
//   uio[1]     : qspi_sd[0]       (SD0 / MOSI, bidirectional)
//   uio[2]     : qspi_sd[1]       (SD1 / MISO, bidirectional)
//   uio[3]     : qspi_sck         (SCK Mode 0, clk / 2, oe=1)
//   uio[4]     : qspi_sd[2]       (SD2, bidirectional)
//   uio[5]     : qspi_sd[3]       (SD3, bidirectional)
//   uio[6]     : qspi_ram_a_cs_n  (CS1: APS6404L 8 MB PSRAM A, active low, oe=1)
//   uio[7]     : qspi_ram_b_cs_n  (CS2: PSRAM B, tied high, oe=1)
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'asic_top.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'memory_factory.dart';
import 'qspi_mem_controller.dart';
import 'uart.dart';

class Mr4TinyTop extends Module {
  late final CpuCore cpu;
  late final QspiMemController qspi;
  final int uartDivisor;

  Mr4TinyTop({
    required Logic clk,
    required Logic rstN,
    required Logic ena,
    required Logic uiIn,
    required Logic uioIn,
    List<int>? bootRomWords,
    int clkFreqMhz = 50,
    int? uartDivisor,
    int localRamWords = 8,
    int bootRomBase = 0x0100,
    bool enableCpuInfo = false,
    super.name = 'tt_um_mr4',
  }) : uartDivisor = uartDivisor ?? AsicTop.defaultUartDivisor(clkFreqMhz) {
    assert(this.uartDivisor >= 4 && (this.uartDivisor % 4) == 0,
        'uartDivisor must be >= 4 and a multiple of 4 for 4x UART RX oversampling');
    assert(localRamWords >= 8 && localRamWords <= 256,
        'localRamWords must be within [8, 256]');

    // Exact Tiny Tapeout Standard Top-Level Ports
    uiIn = addInput('ui_in', uiIn, width: 8);
    final uoOut = addOutput('uo_out', width: 8);
    uioIn = addInput('uio_in', uioIn, width: 8);
    final uioOut = addOutput('uio_out', width: 8);
    final uioOe = addOutput('uio_oe', width: 8);
    ena = addInput('ena', ena);
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);

    // 2-FF reset synchronizer gated by `ena` (active-low synchronous sysRstN)
    final rstSync0 = Logic(name: 'rst_sync_0');
    final rstSync1 = Logic(name: 'rst_sync_1');
    Sequential(clk, [
      rstSync0 < (rstN & ena),
      rstSync1 < rstSync0,
    ]);
    final sysRstN = rstSync1;
    final sysReset = ~sysRstN;

    // Input pin unpacking
    final uartRxd = uiIn[0];
    final useFlash = uiIn[1];

    // QSPI bidirectional input mapping (Tiny Tapeout QSPI PMOD)
    final qspiSdIn = [uioIn[5], uioIn[4], uioIn[2], uioIn[1]].swizzle();

    // UART RX/TX MMIO latches
    final uartRxdLatch = Logic(name: 'uart_rxd_latch', width: 8);
    final uartRxValid = Logic(name: 'uart_rx_valid');
    final txBusyLatch = Logic(name: 'tx_busy_latch');

    final cpuRxData = [uartRxValid, Const(0, width: 7), uartRxdLatch].swizzle();
    final cpuTxStatus =
        mux(txBusyLatch, Const(1, width: 16), Const(0, width: 16));

    // QSPI <-> CpuCore external bus wires
    final icReqReady = Logic(name: 'ic_req_ready');
    final icRespValid = Logic(name: 'ic_resp_valid');
    final icRespData = Logic(name: 'ic_resp_data', width: 16);
    final dcReqReady = Logic(name: 'dc_req_ready');
    final dcRespValid = Logic(name: 'dc_resp_valid');
    final dcRespData = Logic(name: 'dc_resp_data', width: 16);

    final cfg = CpuConfig(
      coreId: 0,
      enableCpuid: false,
      enableCpuInfo: enableCpuInfo,
      enableUart: true,
      enableCrossTraps: false,
      enableEpc: false,
      enableShadowRegs: true,
      enableMathAccel: false,
      enableFpu: false,
      enableSpi: false,
      enableNoc: false,
      enableSdramCache: true, // Routes all addresses >= 0x0200 to QSPI
      isPipelined: true,
      memReadLatency: 1,
      memoryTarget: MemoryTarget.asicFlop,
      bootRomBase: bootRomBase,
      bootRomWords: bootRomWords,
      bootRomPortBRead: false, // Single-port Port-A-only Boot ROM (cuts ROM area 50%)
      clkFreqMhz: clkFreqMhz,
      trapTableBase: 0x0100,
      memWords: 512, // 0x0000..0x01FF local; 0x0200..0xFFFF external QSPI
      localRamWords: localRamWords,
      iqAddrWidth: 2, // 4-entry prefetch queue (+ 1 FWFT head = 10 slots buffered)
    );

    cpu = CpuCore(
      clk: clk,
      rstN: sysRstN,
      mmioRxData: cpuRxData,
      mmioTxStatus: cpuTxStatus,
      icReqReady: icReqReady,
      icRespValid: icRespValid,
      icRespData: icRespData,
      dcReqReady: dcReqReady,
      dcRespValid: dcRespValid,
      dcRespData: dcRespData,
      config: cfg,
      name: 'cpu_core',
    );

    qspi = QspiMemController(
      clk: clk,
      reset: sysReset,
      icReqValid: cpu.output('ic_req_valid'),
      icReqAddr: cpu.output('ic_req_addr'),
      dcReqValid: cpu.output('dc_req_valid'),
      dcReqWe: cpu.output('dc_req_we'),
      dcReqAddr: cpu.output('dc_req_addr'),
      dcReqWdata: cpu.output('dc_req_wdata'),
      qspiSdIn: qspiSdIn,
      useFlash: useFlash,
      compactCache: true, // 2-word coherent I-cache for 2x2 TT tile fit
      name: 'qspi_ctrl',
    );

    icReqReady <= qspi.icReqReady;
    icRespValid <= qspi.icRespValid;
    icRespData <= qspi.icRespData;
    dcReqReady <= qspi.dcReqReady;
    dcRespValid <= qspi.dcRespValid;
    dcRespData <= qspi.dcRespData;

    final uart = Uart(
      clk: clk,
      reset: sysReset,
      serialRxd: uartRxd,
      txd: cpu.txData,
      txdStrobe: cpu.txStrobe,
      divisor: this.uartDivisor,
    );

    Sequential(clk, reset: sysReset, resetValues: {
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

    Sequential(clk, reset: sysReset, resetValues: {
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

    // Output pin packing
    final qspiActive = (~qspi.qspiRamACsN) | (~qspi.qspiFlashCsN);
    uoOut <= [
      cpu.debugPc.slice(3, 0), // uo_out[7:4]
      txBusyLatch, // uo_out[3]
      uartRxValid, // uo_out[2]
      qspiActive, // uo_out[1]
      uart.serialTxd, // uo_out[0]
    ].swizzle();

    // Standard Tiny Tapeout QSPI PMOD bidirectional mapping on uio[7:0]
    uioOut <= [
      qspi.qspiRamBCsN, // uio_out[7]
      qspi.qspiRamACsN, // uio_out[6]
      qspi.qspiSdOut[3], // uio_out[5]
      qspi.qspiSdOut[2], // uio_out[4]
      qspi.qspiSck, // uio_out[3]
      qspi.qspiSdOut[1], // uio_out[2]
      qspi.qspiSdOut[0], // uio_out[1]
      qspi.qspiFlashCsN, // uio_out[0]
    ].swizzle();

    uioOe <= [
      Const(1), // uio_oe[7] (CS2)
      Const(1), // uio_oe[6] (CS1 PSRAM A)
      qspi.qspiSdOe[3], // uio_oe[5] (SD3)
      qspi.qspiSdOe[2], // uio_oe[4] (SD2)
      Const(1), // uio_oe[3] (SCK)
      qspi.qspiSdOe[1], // uio_oe[2] (SD1)
      qspi.qspiSdOe[0], // uio_oe[1] (SD0)
      Const(1), // uio_oe[0] (CS0 Flash)
    ].swizzle();
  }

  @override
  String get definitionName => 'tt_um_mr4';

  Logic get uoOut => output('uo_out');
  Logic get uioOut => output('uio_out');
  Logic get uioOe => output('uio_oe');
}

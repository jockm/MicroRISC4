// ==============================================================================
// FILE: hdl/rohd/lib/cache_subsystem_top.dart
// Architecture: MiniRISC4 Dual-Core Cache & SDRAM Subsystem Top
// Framework: Intel ROHD (Dart)
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';
import 'sdram_controller.dart';

class CacheSubsystemTop extends Module {
  CacheSubsystemTop({
    required Logic clk,
    required Logic rstN,
    required Logic sdramDqIn,
    int clkFreqMhz = 25,
    int casLatency = 2,
    super.name = 'cache_subsystem_top',
  }) {
    clk = addInput('clk', clk);
    rstN = addInput('rst_n', rstN);
    sdramDqIn = addInput('sdram_dq_in', sdramDqIn, width: 16);

    // Cross-traps
    final core0TrapReq = Logic(name: 'core0_trap_req');
    final core0TrapNum = Logic(name: 'core0_trap_num', width: 4);
    final core1TrapReq = Logic(name: 'core1_trap_req');
    final core1TrapNum = Logic(name: 'core1_trap_num', width: 4);

    // Core 0 Instantiation (Client Core)
    final core0 = CpuCore(
      clk: clk,
      rstN: rstN,
      extTrapReq: core0TrapReq,
      extTrapNum: core0TrapNum,
      config: const CpuConfig(
        coreId: 0,
        memWords: 65536,
        trapTableBase: 0x0100,
        enableUart: true,
        enableCrossTraps: true,
      ),
    );

    // Core 1 Instantiation (Cache & SDRAM Worker Core)
    final core1 = CpuCore(
      clk: clk,
      rstN: rstN,
      extTrapReq: core1TrapReq,
      extTrapNum: core1TrapNum,
      config: const CpuConfig(
        coreId: 1,
        memWords: 2048,
        trapTableBase: 0x0100,
        enableUart: false,
        enableCrossTraps: true,
      ),
    );

    // Cross-Core Mailbox Interconnect Logic
    final c0MbStrobe = core0.portBEn &
        core0.portBWe &
        core0.portBAddr.eq(Const(0x000C, width: 16));
    final c1MbStrobe = core1.portBEn &
        core1.portBWe &
        core1.portBAddr.eq(Const(0x000C, width: 16));

    core1TrapReq <=
        c0MbStrobe & core0.portBWdata.slice(15, 8).eq(Const(1, width: 8));
    core1TrapNum <= core0.portBWdata.slice(3, 0);

    core0TrapReq <=
        c1MbStrobe & core1.portBWdata.slice(15, 8).eq(Const(0, width: 8));
    core0TrapNum <= core1.portBWdata.slice(3, 0);

    // SDRAM Registers & MMIO
    final regAddrLo = Logic(name: 'reg_sdram_addr_lo', width: 16);
    final regAddrHi = Logic(name: 'reg_sdram_addr_hi', width: 8);
    final sdramCmdReq = Logic(name: 'sdram_cmd_req');
    final sdramCmdRw = Logic(name: 'sdram_cmd_rw');

    final reset = ~rstN;

    Sequential(clk, reset: reset, resetValues: {
      regAddrLo: Const(0, width: 16),
      regAddrHi: Const(0, width: 8),
      sdramCmdReq: Const(0),
      sdramCmdRw: Const(0),
    }, [
      sdramCmdReq < 0,
      If(core1.portBEn & core1.portBWe, then: [
        If(core1.portBAddr.eq(Const(0x0010, width: 16)), then: [
          regAddrLo < core1.portBWdata,
        ]),
        If(core1.portBAddr.eq(Const(0x0011, width: 16)), then: [
          regAddrHi < core1.portBWdata.slice(7, 0),
        ]),
        If(core1.portBAddr.eq(Const(0x0012, width: 16)), then: [
          sdramCmdReq < 1,
          sdramCmdRw < core1.portBWdata.eq(Const(2, width: 16)),
        ]),
      ]),
    ]);

    // Instantiate SDRAM PHY Controller
    SdramController(
      clk: clk,
      rstN: rstN,
      cmdReq: sdramCmdReq,
      cmdRw: sdramCmdRw,
      cmdAddr: [regAddrHi, regAddrLo].swizzle(),
      cmdBurstLen: Const(8, width: 8),
      wdata: core1.portBWdata,
      wdataValid: core1.portBEn &
          core1.portBWe &
          core1.portBAddr.eq(Const(0x0014, width: 16)),
      sdramDqIn: sdramDqIn,
      clkFreqMhz: clkFreqMhz,
      casLatency: casLatency,
    );
  }
}

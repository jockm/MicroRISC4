// ==============================================================================
// MiniRISC4 Lockstep Co-Simulation Testbench (ROHD CpuCore vs Verilog cpu_core)
// ==============================================================================
import 'package:test/test.dart';
import 'package:rohd/rohd.dart';
import 'package:minirisc4_rohd/cpu_core.dart';
import 'package:minirisc4_rohd/verilog_cpu_core.dart';

void main() {
  test('Lockstep co-simulation between ROHD model and Verilog core', () async {
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rst_n');
    final rxData = Logic(name: 'mmio_rx_data', width: 16);
    final txStatus = Logic(name: 'mmio_tx_status', width: 16);

    // ROHD CPU Core
    final rohdCpu = CpuCore(
      clk: clk,
      rstN: rstN,
      mmioRxData: rxData,
      mmioTxStatus: txStatus,
    );

    // Verilog CPU Core via rohd_cosim
    final verilogCpu = VerilogCpuCore(
      clk: clk,
      rstN: rstN,
      mmioRxData: rxData,
      mmioTxStatus: txStatus,
    );

    await rohdCpu.build();
    await verilogCpu.build();

    // Verify port signatures match
    expect(rohdCpu.output('mmio_rx_pop').width,
        equals(verilogCpu.mmioRxPop.width));
    expect(rohdCpu.output('mmio_tx_data').width,
        equals(verilogCpu.mmioTxData.width));
    expect(rohdCpu.output('mmio_tx_strobe').width,
        equals(verilogCpu.mmioTxStrobe.width));
  });
}

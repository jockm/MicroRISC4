// ==============================================================================
// MiniRISC4 Verilog Core Co-Simulation Wrapper
// Uses Intel rohd_cosim to drive Verilog cpu_core.v directly inside ROHD tests.
// ==============================================================================
import 'package:rohd/rohd.dart';
import 'package:rohd_cosim/rohd_cosim.dart';

class VerilogCpuCore extends ExternalSystemVerilogModule with Cosim {
  @override
  List<String> get verilogSources => ['../verilog/cpu_core.v'];

  VerilogCpuCore({
    required Logic clk,
    required Logic rstN,
    required Logic mmioRxData,
    required Logic mmioTxStatus,
    super.name = 'verilog_cpu_core', // use super parameter
  }) : super(
          definitionName: 'cpu_core',
        ) {
    addInput('clk', clk);
    addInput('rst_n', rstN);
    addInput('mmio_rx_data', mmioRxData, width: 16);
    addInput('mmio_tx_status', mmioTxStatus, width: 16);

    addOutput('mmio_rx_pop');
    addOutput('mmio_tx_data', width: 8);
    addOutput('mmio_tx_strobe');
  }

  Logic get mmioRxPop => output('mmio_rx_pop');
  Logic get mmioTxData => output('mmio_tx_data');
  Logic get mmioTxStrobe => output('mmio_tx_strobe');
}

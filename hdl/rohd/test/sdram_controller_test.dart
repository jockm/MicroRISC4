import 'package:test/test.dart';
import 'package:rohd/rohd.dart';
import '../lib/sdram_controller.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('SDRAM Controller instantiates and transitions through Init into Idle',
      () async {
    final clk = SimpleClockGenerator(20).clk; // 25 MHz
    final rstN = Logic(name: 'rst_n');
    final cmdReq = Logic(name: 'cmd_req');
    final cmdRw = Logic(name: 'cmd_rw');
    final cmdAddr = Logic(name: 'cmd_addr', width: 24);
    final cmdBurstLen = Logic(name: 'cmd_burst_len', width: 8);
    final wdata = Logic(name: 'wdata', width: 16);
    final wdataValid = Logic(name: 'wdata_valid');
    final sdramDqIn = Logic(name: 'sdram_dq_in', width: 16);

    final ctrl = SdramController(
      clk: clk,
      rstN: rstN,
      cmdReq: cmdReq,
      cmdRw: cmdRw,
      cmdAddr: cmdAddr,
      cmdBurstLen: cmdBurstLen,
      wdata: wdata,
      wdataValid: wdataValid,
      sdramDqIn: sdramDqIn,
    );

    await ctrl.build();

    // Reset initialization
    rstN.put(0);
    cmdReq.put(0);
    cmdRw.put(0);
    cmdAddr.put(0);
    cmdBurstLen.put(0);
    wdata.put(0);
    wdataValid.put(0);
    sdramDqIn.put(0);

    Simulator.registerAction(40, () {
      rstN.put(1);
    });

    // Run until controller completes power-on initialization
    Simulator.registerAction(800, () {
      expect(ctrl.output('cmd_ready').value.toInt(), equals(1));
      expect(ctrl.output('busy').value.toInt(), equals(0));
    });

    Simulator.registerAction(900, () {
      Simulator.endSimulation();
    });

    await Simulator.run();
  });
}

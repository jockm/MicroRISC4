// ==============================================================================
// FILE: hdl/mr4/test/spi_master_test.dart
// Unit Test: MicroRISC4 SPI Mode 0 Master Loopback Verification
// ==============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:microrisc4_rohd/spi_master.dart';

void main() {
  test('SpiMaster Mode 0 loopback transfer', () async {
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic()..put(0);
    final addr = Logic(width: 16)..put(0);
    final wdata = Logic(width: 16)..put(0);
    final we = Logic()..put(0);
    final en = Logic()..put(0);
    final miso = Logic();

    final dut = SpiMaster(
      clk: clk,
      rstN: rstN,
      portBAddr: addr,
      portBWdata: wdata,
      portBWe: we,
      portBEn: en,
      spiMiso: miso,
      slowHalfDiv: 1,
      fastHalfDiv: 0,
    );

    // Loopback MOSI -> MISO
    miso <= dut.spiMosi;

    await dut.build();
    Simulator.registerAction(10, () => rstN.put(1));

    // Assert CS_N = 0, FAST_CLK = 1 (write 0x0002 to SPI_CTRL)
    Simulator.registerAction(20, () {
      addr.put(SpiMaster.addrCtrl);
      wdata.put(0x0002);
      we.put(1);
      en.put(1);
    });

    // Write 0xA5 to SPI_DATA to start 8-bit transfer
    Simulator.registerAction(30, () {
      addr.put(SpiMaster.addrData);
      wdata.put(0x00A5);
    });
    Simulator.registerAction(40, () {
      we.put(0);
      addr.put(SpiMaster.addrStat);
    });

    // After 8 bits (16 half-cycles = 160ns), verify BUSY == 0 and RX == 0xA5
    Simulator.registerAction(250, () {
      expect(dut.rdata.value.toInt(), equals(0)); // BUSY == 0
      addr.put(SpiMaster.addrData);
    });
    Simulator.registerAction(260, () {
      expect(dut.rdata.value.toInt(), equals(0x00A5));
      expect(dut.spiCsN.value.toInt(), equals(0));
      Simulator.endSimulation();
    });

    await Simulator.run();
  });
}

// ==============================================================================
// Parameterized Clock Divider Helper
// Intel ROHD Implementation
// ==============================================================================
import 'package:rohd/rohd.dart';

/// Parameterized synchronous integer clock divider.
/// Generates a single-cycle high strobe `out` every [n] input clock cycles.
class DivideByN extends Module {
  final int n;

  DivideByN({
    required Logic clk,
    required Logic reset,
    this.n = 2,
    super.name = 'divide_by_n',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final out = addOutput('out');

    final counter = Logic(name: 'counter', width: 32);

    Sequential(clk, reset: reset, [
      If(counter.eq(n - 1), then: [
        counter < 0,
        out < 1,
      ], orElse: [
        counter < counter + 1,
        out < 0,
      ]),
    ]);
  }

  Logic get out => output('out');
}

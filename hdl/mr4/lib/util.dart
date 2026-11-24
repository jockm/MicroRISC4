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

    final width = n > 1 ? (n - 1).bitLength : 1;
    final limit = Const(n > 1 ? n - 1 : 0, width: width);
    final counter = Logic(name: 'counter', width: width);

    Sequential(clk, reset: reset, resetValues: {
      counter: 0,
      out: 0,
    }, [
      If(counter.gte(limit), then: [
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

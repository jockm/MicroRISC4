import 'package:rohd/rohd.dart';
import 'cpu_config.dart';
import 'cpu_core.dart';

class Mr4RiscvTop extends Module {
  Mr4RiscvTop({
    required Logic clk,
    required Logic rstN,
    Logic? uartRx,
    super.name = 'mr4riscv_top',
  }) {
    // 1. Core 0: Fetch
    final core0 = CpuCore(
      clk: clk,
      rstN: rstN,
      config: const CpuConfig(
        coreId: 0,
        memWords: 1024,
        enableUart: false,
        enableCrossTraps: true,
        enableMathAccel: false,
        trapTableBase: 0x0100,
      ),
    );

    // 2. Core 1: Decode
    final core1 = CpuCore(
      clk: clk,
      rstN: rstN,
      config: const CpuConfig(
        coreId: 1,
        memWords: 1024,
        enableUart: false,
        enableCrossTraps: true,
        enableMathAccel: false,
        trapTableBase: 0x0100,
      ),
    );

    // 3. Core 2: Execute (Math Accelerator Active)
    final core2 = CpuCore(
      clk: clk,
      rstN: rstN,
      config: const CpuConfig(
        coreId: 2,
        memWords: 1024,
        enableUart: false,
        enableCrossTraps: true,
        enableMathAccel: true, // <--- Configures MMIO Math Engine
        trapTableBase: 0x0100,
      ),
    );

    // 4. Core 3: Mem/WB (UART Active)
    final core3 = CpuCore(
      clk: clk,
      rstN: rstN,
      mmioRxData: uartRx,
      config: const CpuConfig(
        coreId: 3,
        memWords: 2048,
        enableUart: true, // <--- Configures Local Serial MMIO
        enableCrossTraps: true,
        enableMathAccel: false,
        trapTableBase: 0x0100,
      ),
    );

    // 5. Core 4: Cache Controller
    final core4 = CpuCore(
      clk: clk,
      rstN: rstN,
      config: const CpuConfig(
        coreId: 4,
        memWords: 2048,
        enableUart: false,
        enableCrossTraps: true,
        enableMathAccel: false,
        trapTableBase: 0x0100,
      ),
    );
  }
}

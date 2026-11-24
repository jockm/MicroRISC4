// Remove: import 'package:rohd/rohd.dart';

abstract class MiniRISC4Constants {
  // Architectural Dimensions
  static const int dataWidth = 16;
  static const int addrWidth = 16;
  static const int byteWidth = 8;
  static const int regCount = 4;
  static const int regAddrWidth = 2;
  static const int memDepth = 65536;

  // Memory Map & Hardware Addresses
  static const int trapTableBase = 0xFFF0;
  static const int trapAlignAddr = 0xFFFF;
  static const int addrUartRx = 0x000E;
  static const int addrUartTx = 0x000F;
  static const int addrEpc    = 0x001E; // R/W: Hardware Exception Program Counter (EPC)
  static const int opEretByte = 0x0F;   // 1-byte ERET instruction (PC <- EPC, preserves R0..R3)

  // Lean Direct-Addressed NoC Ring & Doorbell MMIO Registers (0x0020-0x002A)
  static const int addrNocTxData    = 0x0020; // W: send 16-bit DATA word to dstCore
  static const int addrNocDstCore   = 0x0021; // R/W: target destination core ID
  static const int addrNocSelCh     = 0x0021; // Legacy alias for addrNocDstCore
  static const int addrNocRxData    = 0x0022; // R: pop word from shared RX FIFO
  static const int addrNocRxStat    = 0x0023; // R: status flags + rx_count[15:8]
  static const int addrNocRxTryR    = 0x0024; // R: non-blocking pop (0 if empty)
  static const int addrNocMboxSend  = 0x0025; // W: send doorbell/MBOX (fires Trap 14)
  static const int addrNocMboxData  = 0x0026; // R: pop doorbell payload (clears trap)
  static const int addrNocMboxSrc   = 0x0027; // R: sender core ID of doorbell
  static const int addrNocChCfg0    = 0x0028; // Reserved (unused in direct ring)
  static const int addrNocChCfg1    = 0x0029; // Reserved (unused in direct ring)
  static const int addrNocInfo      = 0x002A; // R: {fifoDepth[7:0], numCores[7:0]}

  // Primary Opcodes (Bits [7:4])
  static const int opLdReg      = 0x0;
  static const int opLdImm4     = 0x1;
  static const int opLdPeek     = 0x2;
  static const int opLdPoke     = 0x3;
  static const int opLdPostinc  = 0x4;
  static const int opLdPredec   = 0x5;
  static const int opAdd        = 0x6;
  static const int opSub        = 0x7;
  static const int opOr         = 0x8;
  static const int opXor        = 0x9;
  static const int opAnd        = 0xA;
  static const int opShift      = 0xB;
  static const int opRotIncDec  = 0xC;
  static const int opJmpZ       = 0xD;
  static const int opJmpM       = 0xE;
  static const int opJmpSpecial = 0xF;

  // Sub-Opcodes
  static const int subShiftL    = 0x0;
  static const int subShiftR    = 0x1;
  static const int subShiftAr   = 0x2;
  static const int subShiftXchg = 0x3;

  static const int subRotL      = 0x0;
  static const int subRotR      = 0x1;
  static const int subInc       = 0x2;
  static const int subDec       = 0x3;

  static const int subJmp       = 0x0;
  static const int subLink      = 0x1;
  static const int subPush8     = 0x2;
  static const int subTrap      = 0x3;

  // FSM Control States
  static const int stReset      = 0x0;
  static const int stFetch      = 0x1;
  static const int stExec       = 0x2;
  static const int stMemRd      = 0x3;
  static const int stTrapRd     = 0x4;

  // Slot Tracking
  static const int slotByte0    = 0x0;
  static const int slotByte1    = 0x1;
}
`timescale 1ns / 1ps
// =============================================================================
// FILE: hdl/verilog/cpu_core.v
// Architecture: MiniRISC4 16-Bit Word-Addressed Processor
// Target: Lattice ECP5 FPGA / ASIC Synthesizable
// =============================================================================

module cpu_core #(
    parameter DATA_WIDTH         = 16,
    parameter ADDR_WIDTH         = 16,
    parameter MEM_WORDS          = 65536,
    parameter TRAP_TABLE_BASE    = 16'h0100,

    // Modular Per-Core Hardware Feature Toggles
    parameter CORE_ID            = 0,
    parameter ENABLE_CPUID       = 1,      // 1 = 0x000D is CPUID, 0 = RAM
    parameter ENABLE_UART        = 1,      // 1 = 0x000E/0x000F are UART MMIO
    parameter ENABLE_CROSS_TRAPS = 0,      // 1 = Inter-core mailbox trap trigger enabled
    parameter ENABLE_SHADOW_REGS = 1,      // 1 = 4 dedicated shadow registers for XCHG
    parameter ENABLE_MATH_ACCEL  = 0       // 1 = RV32IM Math & Shifter Engine at 0x0010-0x0016
  )(
    input  wire                   clk,
    input  wire                   rst_n,

    // Optional UART MMIO Interface (Active when ENABLE_UART == 1)
    input  wire [15:0]            mmio_rx_data,
    output reg                    mmio_rx_pop,
    input  wire [15:0]            mmio_tx_status,
    output reg  [7:0]             mmio_tx_data,
    output reg                    mmio_tx_strobe,

    // Optional Cross-Core Interconnect Trap Strobe (Active when ENABLE_CROSS_TRAPS == 1)
    input  wire                   ext_trap_req,
    input  wire [3:0]             ext_trap_num
  );

  // =========================================================================
  // Manifest Constants: Memory Addresses & Instruction Opcodes
  // =========================================================================
  localparam ADDR_CPUID       = 16'h000D;
  localparam ADDR_UART_RX     = 16'h000E;
  localparam ADDR_UART_TX     = 16'h000F;
  localparam MATH_BASE_ADDR   = 16'h0010;

  localparam OP_LD_REG        = 4'h0;
  localparam OP_LD_IMM4       = 4'h1;
  localparam OP_LD_PEEK       = 4'h2;
  localparam OP_LD_POKE       = 4'h3;
  localparam OP_LD_POSTINC    = 4'h4;    // Pop:  LD Rr, (Rl++)
  localparam OP_LD_PREDEC     = 4'h5;    // Push: LD (--Rr), Rl
  localparam OP_ADD           = 4'h6;
  localparam OP_SUB           = 4'h7;
  localparam OP_OR            = 4'h8;
  localparam OP_XOR           = 4'h9;
  localparam OP_AND           = 4'hA;    // Single-cycle native AND
  localparam OP_SHIFT         = 4'hB;
  localparam OP_ROT_INC_DEC   = 4'hC;
  localparam OP_JMP_Z         = 4'hD;
  localparam OP_JMP_M         = 4'hE;
  localparam OP_JMP_SPECIAL   = 4'hF;

  localparam SUB_SHIFT_L      = 2'b00;
  localparam SUB_SHIFT_R      = 2'b01;
  localparam SUB_SHIFT_AR     = 2'b10;
  localparam SUB_SHIFT_XCHG   = 2'b11;   // XCHG Rr

  localparam SUB_ROT_L        = 2'b00;
  localparam SUB_ROT_R        = 2'b01;
  localparam SUB_INC          = 2'b10;
  localparam SUB_DEC          = 2'b11;

  localparam SUB_JMP          = 2'b00;
  localparam SUB_LINK         = 2'b01;
  localparam SUB_PUSH8        = 2'b10;
  localparam SUB_TRAP         = 2'b11;

  localparam STATE_WIDTH      = 3;
  localparam ST_RESET         = 3'd0;
  localparam ST_FETCH         = 3'd1;
  localparam ST_EXEC          = 3'd2;
  localparam ST_MEM_RD        = 3'd3;
  localparam ST_TRAP_RD       = 3'd4;

  localparam SLOT_BYTE0       = 1'b0;
  localparam SLOT_BYTE1       = 1'b1;

  // =========================================================================
  // Architectural Registers & Internal State
  // =========================================================================
  reg [DATA_WIDTH-1:0] pc;
  reg [DATA_WIDTH-1:0] r [0:3];
  reg [DATA_WIDTH-1:0] shadow_r [0:3];

  reg [DATA_WIDTH-1:0] inst_reg;
  reg                  slot;
  reg [1:0]            dest_reg;
  reg [STATE_WIDTH-1:0] state;

  // Memory Bus Signals
  reg  [ADDR_WIDTH-1:0] port_a_addr;
  reg                   port_a_en;
  reg  [DATA_WIDTH-1:0] port_a_rdata;

  reg  [ADDR_WIDTH-1:0] port_b_addr;
  reg  [DATA_WIDTH-1:0] port_b_wdata;
  reg                   port_b_we;
  reg                   port_b_en;
  reg  [DATA_WIDTH-1:0] port_b_rdata;

  // Dual Instruction Decoding
  wire [7:0] cur_inst = (slot == SLOT_BYTE0) ? port_a_rdata[7:0] : inst_reg[7:0];
  wire [3:0] op       = cur_inst[7:4];
  wire [1:0] rr       = cur_inst[3:2];
  wire [1:0] rl       = cur_inst[1:0];
  wire [3:0] imm4     = cur_inst[3:0];

  wire is_link        = (op == OP_JMP_SPECIAL) && (rr == SUB_LINK);
  wire is_push8       = (op == OP_JMP_SPECIAL) && (rr == SUB_PUSH8);
  wire is_trap        = (op == OP_JMP_SPECIAL) && (rr == SUB_TRAP);
  wire illegal_slot1  = (slot == SLOT_BYTE1) && (is_link | is_push8 | is_trap);

  // =========================================================================
  // Memory-Mapped Hardware Accelerator & Peripheral Decode
  // =========================================================================
  wire is_mmio_cpuid = ENABLE_CPUID && (port_b_addr == ADDR_CPUID);
  wire is_mmio_rx    = ENABLE_UART  && (port_b_addr == ADDR_UART_RX);
  wire is_mmio_tx    = ENABLE_UART  && (port_b_addr == ADDR_UART_TX);

  // Math Accelerator wiring
  wire [15:0] math_rdata;
  wire        math_busy;
  wire        math_match;

  generate
    if (ENABLE_MATH_ACCEL)
    begin : gen_math_accel
      math_accelerator #(
                         .BASE_ADDR(MATH_BASE_ADDR)
                       ) u_math_accel (
                         .clk         (clk),
                         .rst_n       (rst_n),
                         .port_b_addr (port_b_addr),
                         .port_b_wdata(port_b_wdata),
                         .port_b_we   (port_b_we),
                         .port_b_en   (port_b_en),
                         .rdata       (math_rdata),
                         .busy        (math_busy),
                         .match       (math_match)
                       );
    end
    else
    begin : gen_no_math_accel
      assign math_rdata = 16'h0000;
      assign math_busy  = 1'b0;
      assign math_match = 1'b0;
    end
  endgenerate

  wire is_mmio = is_mmio_cpuid | is_mmio_rx | is_mmio_tx | (ENABLE_MATH_ACCEL && math_match);

  // =========================================================================
  // On-Chip True Dual-Port (TDP) RAM Block
  // =========================================================================
  reg [DATA_WIDTH-1:0] mem [0:MEM_WORDS-1];
  reg [DATA_WIDTH-1:0] ram_b_dout;

  initial
  begin
    $readmemh("system_image.hex", mem);
  end

  // Port A (Instruction Fetch)
  always @(posedge clk)
  begin
    if (port_a_en)
    begin
      port_a_rdata <= mem[port_a_addr[ADDR_WIDTH-1:0]];
    end
  end

  // Port B (Data / Load / Store)
  wire ram_b_we = port_b_en && port_b_we && !is_mmio;
  always @(posedge clk)
  begin
    if (port_b_en)
    begin
      if (ram_b_we)
      begin
        mem[port_b_addr[ADDR_WIDTH-1:0]] <= port_b_wdata;
      end
      ram_b_dout <= mem[port_b_addr[ADDR_WIDTH-1:0]];
    end
  end

  // Port B Read Multiplexer
  always @(*)
  begin
    if (is_mmio_cpuid)
      port_b_rdata = {12'h000, CORE_ID[3:0]};
    else if (is_mmio_rx)
      port_b_rdata = mmio_rx_data;
    else if (is_mmio_tx)
      port_b_rdata = mmio_tx_status;
    else if (ENABLE_MATH_ACCEL && math_match)
      port_b_rdata = math_rdata;
    else
      port_b_rdata = ram_b_dout;
  end

  // Combinational UART RX Pop
  always @(*)
  begin
    mmio_rx_pop = ENABLE_UART && port_b_en && !port_b_we && is_mmio_rx;
  end

  // =========================================================================
  // ALU Helpers
  // =========================================================================
  function [DATA_WIDTH-1:0] rotl1(input [DATA_WIDTH-1:0] val);
    rotl1 = {val[DATA_WIDTH-2:0], val[DATA_WIDTH-1]};
  endfunction

  function [DATA_WIDTH-1:0] rotr1(input [DATA_WIDTH-1:0] val);
    rotr1 = {val[0], val[DATA_WIDTH-1:1]};
  endfunction

  function [DATA_WIDTH-1:0] asr1(input [DATA_WIDTH-1:0] val);
    asr1 = {val[DATA_WIDTH-1], val[DATA_WIDTH-1:1]};
  endfunction

  // =========================================================================
  // FSM State Control & Branches
  // =========================================================================
  task advance_slot_or_fetch;
    begin
      if (slot == SLOT_BYTE0)
      begin
        slot          <= SLOT_BYTE1;
        inst_reg[7:0] <= inst_reg[15:8];
        port_a_addr   <= pc + 16'd1;
        port_a_en     <= 1'b1;
        state         <= ST_EXEC;
      end
      else
      begin
        pc        <= pc + 16'd1;
        slot      <= SLOT_BYTE0;
        port_a_en <= 1'b0;
        state     <= ST_EXEC;
      end
    end
  endtask

  task branch_to;
    input [ADDR_WIDTH-1:0] target_addr;
    begin
      pc          <= target_addr;
      port_a_addr <= target_addr;
      port_a_en   <= 1'b1;
      slot        <= SLOT_BYTE0;
      state       <= ST_EXEC;
    end
  endtask

  integer j;
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      state          <= ST_RESET;
      pc             <= 16'h0000;
      slot           <= SLOT_BYTE0;
      dest_reg       <= 2'b00;
      inst_reg       <= 16'h0000;
      port_a_addr    <= 16'h0000;
      port_a_en      <= 1'b0;
      port_b_addr    <= TRAP_TABLE_BASE;
      port_b_wdata   <= 16'h0000;
      port_b_we      <= 1'b0;
      port_b_en      <= 1'b1;
      mmio_tx_data   <= 8'h00;
      mmio_tx_strobe <= 1'b0;

      for (j = 0; j < 4; j = j + 1)
      begin
        r[j]        <= 16'h0000;
        shadow_r[j] <= 16'h0000;
      end
    end
    else
    begin
      mmio_tx_strobe <= 1'b0;

      // External Inter-Core Asynchronous Trap Interrupt Request
      if (ENABLE_CROSS_TRAPS && ext_trap_req && (state == ST_EXEC))
      begin
        r[0]        <= (slot == SLOT_BYTE0) ? pc : (pc + 16'd1);
        port_b_addr <= TRAP_TABLE_BASE + (ext_trap_num << 4);
        port_b_we   <= 1'b0;
        port_b_en   <= 1'b1;
        state       <= ST_TRAP_RD;
      end
      else
      begin
        case (state)
          // Reset: Read Trap 0 Vector from TRAP_TABLE_BASE
          ST_RESET:
          begin
            port_b_en   <= 1'b0;
            pc          <= port_b_rdata;
            port_a_addr <= port_b_rdata;
            port_a_en   <= 1'b1;
            slot        <= SLOT_BYTE0;
            state       <= ST_EXEC;
          end

          // Word Fetch from PC
          ST_FETCH:
          begin
            port_a_addr <= pc;
            port_a_en   <= 1'b1;
            slot        <= SLOT_BYTE0;
            state       <= ST_EXEC;
          end

          // Instruction Execution Cycle
          ST_EXEC:
          begin
            if (slot == SLOT_BYTE0)
            begin
              inst_reg <= port_a_rdata;
            end

            port_b_en <= 1'b0;
            port_b_we <= 1'b0;

            if (illegal_slot1)
            begin
              r[0]        <= pc + 16'd1;
              port_b_addr <= TRAP_TABLE_BASE + (4'd15 << 4); // Trap 15 Alignment Fault
              port_b_we   <= 1'b0;
              port_b_en   <= 1'b1;
              state       <= ST_TRAP_RD;
            end
            else
            begin
              case (op)
                OP_LD_REG:
                begin
                  r[rr] <= r[rl];
                  advance_slot_or_fetch();
                end

                OP_LD_IMM4:
                begin
                  r[0] <= {12'h000, imm4};
                  advance_slot_or_fetch();
                end

                OP_LD_PEEK:
                begin
                  port_b_addr <= r[rl];
                  port_b_we   <= 1'b0;
                  port_b_en   <= 1'b1;
                  dest_reg    <= rr;
                  state       <= ST_MEM_RD;
                end

                OP_LD_POKE:
                begin
                  port_b_addr  <= r[rr];
                  port_b_wdata <= r[rl];
                  port_b_we    <= 1'b1;
                  port_b_en    <= 1'b1;

                  if (ENABLE_UART && (r[rr] == ADDR_UART_TX))
                  begin
                    mmio_tx_data   <= r[rl][7:0];
                    mmio_tx_strobe <= 1'b1;
                  end
                  advance_slot_or_fetch();
                end

                OP_LD_POSTINC:
                begin // Pop (FD): LD Rr, (Rl++)
                  port_b_addr <= r[rl];
                  port_b_we   <= 1'b0;
                  port_b_en   <= 1'b1;
                  dest_reg    <= rr;
                  r[rl]       <= r[rl] + 16'd1;
                  state       <= ST_MEM_RD;
                end

                OP_LD_PREDEC:
                begin // Push (FD): LD (--Rr), Rl
                  r[rr]        <= r[rr] - 16'd1;
                  port_b_addr  <= r[rr] - 16'd1;
                  port_b_wdata <= r[rl];
                  port_b_we    <= 1'b1;
                  port_b_en    <= 1'b1;

                  if (ENABLE_UART && ((r[rr] - 16'd1) == ADDR_UART_TX))
                  begin
                    mmio_tx_data   <= r[rl][7:0];
                    mmio_tx_strobe <= 1'b1;
                  end
                  advance_slot_or_fetch();
                end

                OP_ADD:
                begin
                  r[rr] <= r[rr] + r[rl];
                  advance_slot_or_fetch();
                end

                OP_SUB:
                begin
                  r[rr] <= r[rr] - r[rl];
                  advance_slot_or_fetch();
                end

                OP_OR:
                begin
                  r[rr] <= r[rr] | r[rl];
                  advance_slot_or_fetch();
                end

                OP_XOR:
                begin
                  r[rr] <= r[rr] ^ r[rl];
                  advance_slot_or_fetch();
                end

                OP_AND:
                begin // Opcode 0xA native AND
                  r[rr] <= r[rr] & r[rl];
                  advance_slot_or_fetch();
                end

                OP_SHIFT:
                begin
                  case (rr)
                    SUB_SHIFT_L:
                      r[rl] <= r[rl] << 1;
                    SUB_SHIFT_R:
                      r[rl] <= r[rl] >> 1;
                    SUB_SHIFT_AR:
                      r[rl] <= asr1(r[rl]);
                    SUB_SHIFT_XCHG:
                    begin // Single-cycle shadow swap
                      if (ENABLE_SHADOW_REGS)
                      begin
                        r[rl]        <= shadow_r[rl];
                        shadow_r[rl] <= r[rl];
                      end
                    end
                  endcase
                  advance_slot_or_fetch();
                end

                OP_ROT_INC_DEC:
                begin
                  case (rr)
                    SUB_ROT_L:
                      r[rl] <= rotl1(r[rl]);
                    SUB_ROT_R:
                      r[rl] <= rotr1(r[rl]);
                    SUB_INC:
                      r[rl] <= r[rl] + 16'd1;
                    SUB_DEC:
                      r[rl] <= r[rl] - 16'd1;
                  endcase
                  advance_slot_or_fetch();
                end

                OP_JMP_Z:
                begin
                  if (r[rl] == 16'h0000)
                    branch_to(r[rr]);
                  else
                    advance_slot_or_fetch();
                end

                OP_JMP_M:
                begin
                  if (r[rl][15] == 1'b1)
                    branch_to(r[rr]);
                  else
                    advance_slot_or_fetch();
                end

                OP_JMP_SPECIAL:
                begin
                  case (rr)
                    SUB_JMP:
                    begin
                      branch_to(r[rl]);
                    end
                    SUB_LINK:
                    begin
                      r[0] <= pc + 16'd1;
                      branch_to(r[rl]);
                    end
                    SUB_PUSH8:
                    begin
                      r[rl] <= {r[rl][7:0], port_a_rdata[15:8]};
                      branch_to(pc + 16'd1);
                    end
                    SUB_TRAP:
                    begin
                      r[0]        <= pc + 16'd1;
                      port_b_addr <= TRAP_TABLE_BASE + ((r[rl] & 16'h000F) << 4);
                      port_b_we   <= 1'b0;
                      port_b_en   <= 1'b1;
                      state       <= ST_TRAP_RD;
                    end
                  endcase
                end
              endcase
            end
          end

          // Memory Read Wait-State
          ST_MEM_RD:
          begin
            port_b_en   <= 1'b0;
            r[dest_reg] <= port_b_rdata;
            advance_slot_or_fetch();
          end

          // Trap Vector Address Fetch
          ST_TRAP_RD:
          begin
            port_b_en <= 1'b0;
            pc        <= port_b_rdata;
            state     <= ST_FETCH;
          end

          default:
            state <= ST_RESET;
        endcase
      end
    end
  end

endmodule

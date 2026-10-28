`timescale 1ns / 1ps
// =============================================================================
// FILE: hdl/verilog/math_accelerator.v
// Architecture: MiniRISC4 32-Bit Full RV32IM Math & Barrel Shift Coprocessor
// MMIO Mapping: 0x0010 - 0x0016
// =============================================================================

module math_accelerator #(
    parameter BASE_ADDR = 16'h0010
  )(
    input  wire        clk,
    input  wire        rst_n,

    // Port B MMIO interface from CPU core
    input  wire [15:0] port_b_addr,
    input  wire [15:0] port_b_wdata,
    input  wire        port_b_we,
    input  wire        port_b_en,

    // Accelerator outputs
    output reg  [15:0] rdata,
    output wire        busy,
    output wire        match
  );

  // Register file
  reg [15:0] op_a_lo, op_a_hi;
  reg [15:0] op_b_lo, op_b_hi;
  reg [15:0] res_lo, res_hi;
  reg        div_by_zero;
  reg        busy_r;

  assign busy = busy_r;
  assign match = port_b_en && (port_b_addr >= BASE_ADDR) && (port_b_addr <= (BASE_ADDR + 16'h0006));

  wire [31:0] op_a = {op_a_hi, op_a_lo};
  wire [31:0] op_b = {op_b_hi, op_b_lo};
  wire [4:0]  shamt = op_b[4:0];

  // -----------------------------------------------------------------
  // DSP Multiplier Arrays (ECP5 / ASIC)
  // -----------------------------------------------------------------
  wire [63:0]        prod_unsigned = op_a * op_b;
  wire signed [63:0] prod_signed   = $signed(op_a) * $signed(op_b);
  wire signed [63:0] prod_su       = $signed(op_a) * $signed({1'b0, op_b});

  // -----------------------------------------------------------------
  // Combinational 32-bit Barrel Shifters (Single-Cycle)
  // -----------------------------------------------------------------
  wire [31:0] sll_res = op_a << shamt;
  wire [31:0] srl_res = op_a >> shamt;
  wire [31:0] sra_res = $signed(op_a) >>> shamt;

  // -----------------------------------------------------------------
  // Division Engine (Restoring Divider supporting Signed + Unsigned)
  // -----------------------------------------------------------------
  reg [5:0]   div_count;
  reg [31:0]  div_quotient;
  reg [31:0]  div_remainder;
  reg [31:0]  div_divisor;
  reg         div_is_rem;
  reg         neg_quotient;
  reg         neg_remainder;

  wire [31:0] abs_a = (op_a[31]) ? (-op_a) : op_a;
  wire [31:0] abs_b = (op_b[31]) ? (-op_b) : op_b;

  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      op_a_lo       <= 16'h0000;
      op_a_hi       <= 16'h0000;
      op_b_lo       <= 16'h0000;
      op_b_hi       <= 16'h0000;
      res_lo        <= 16'h0000;
      res_hi        <= 16'h0000;
      div_by_zero   <= 1'b0;
      busy_r        <= 1'b0;
      div_count     <= 6'd0;
      div_quotient  <= 32'd0;
      div_remainder <= 32'd0;
      div_divisor   <= 32'd0;
      div_is_rem    <= 1'b0;
      neg_quotient  <= 1'b0;
      neg_remainder <= 1'b0;
    end
    else
    begin
      // MMIO Writes
      if (port_b_en && port_b_we && !busy_r)
      begin
        case (port_b_addr)
          BASE_ADDR + 16'h0000:
            op_a_lo <= port_b_wdata;
          BASE_ADDR + 16'h0001:
            op_a_hi <= port_b_wdata;
          BASE_ADDR + 16'h0002:
            op_b_lo <= port_b_wdata;
          BASE_ADDR + 16'h0003:
            op_b_hi <= port_b_wdata;
          BASE_ADDR + 16'h0004:
          begin
            div_by_zero <= 1'b0;
            case (port_b_wdata[3:0])
              // Single-Cycle Multiplications
              4'h0:
                {res_hi, res_lo} <= prod_unsigned[31:0];   // MUL
              4'h1:
                {res_hi, res_lo} <= prod_signed[63:32];    // MULH
              4'h2:
                {res_hi, res_lo} <= prod_unsigned[63:32];  // MULHU
              4'h3:
                {res_hi, res_lo} <= prod_su[63:32];        // MULHSU

              // Single-Cycle Barrel Shifters
              4'h8:
                {res_hi, res_lo} <= sll_res;               // SLL
              4'h9:
                {res_hi, res_lo} <= srl_res;               // SRL
              4'hA:
                {res_hi, res_lo} <= sra_res;               // SRA

              // Division / Remainder
              4'h4, 4'h5:
              begin // DIVU (4), REMU (5)
                if (op_b == 32'd0)
                begin
                  div_by_zero      <= 1'b1;
                  {res_hi, res_lo} <= (port_b_wdata[3:0] == 4'h4) ? 32'hFFFFFFFF : op_a;
                end
                else
                begin
                  busy_r        <= 1'b1;
                  div_count     <= 6'd32;
                  div_quotient  <= op_a;
                  div_remainder <= 32'd0;
                  div_divisor   <= op_b;
                  div_is_rem    <= (port_b_wdata[3:0] == 4'h5);
                  neg_quotient  <= 1'b0;
                  neg_remainder <= 1'b0;
                end
              end

              4'h6, 4'h7:
              begin // DIV (6), REM (7) - SIGNED
                if (op_b == 32'd0)
                begin
                  div_by_zero      <= 1'b1;
                  {res_hi, res_lo} <= (port_b_wdata[3:0] == 4'h6) ? 32'hFFFFFFFF : op_a;
                end
                else if (op_a == 32'h80000000 && op_b == 32'hFFFFFFFF)
                begin
                  // RV32 Overflow corner-case: -2^31 / -1
                  {res_hi, res_lo} <= (port_b_wdata[3:0] == 4'h6) ? 32'h80000000 : 32'd0;
                end
                else
                begin
                  busy_r        <= 1'b1;
                  div_count     <= 6'd32;
                  div_quotient  <= abs_a;
                  div_remainder <= 32'd0;
                  div_divisor   <= abs_b;
                  div_is_rem    <= (port_b_wdata[3:0] == 4'h7);
                  neg_quotient  <= op_a[31] ^ op_b[31];
                  neg_remainder <= op_a[31];
                end
              end
              default:
                ;
            endcase
          end
          default:
            ;
        endcase
      end

      // Divider FSM Iteration
      if (busy_r)
      begin
        if (div_count > 0)
        begin
          wire [32:0] sub_res = {div_remainder[30:0], div_quotient[31]} - {1'b0, div_divisor};
          div_quotient  <= {div_quotient[30:0], ~sub_res[32]};
          div_remainder <= sub_res[32] ? {div_remainder[30:0], div_quotient[31]} : sub_res[31:0];
          div_count     <= div_count - 1'b1;
        end
        else
        begin
          busy_r <= 1'b0;
          if (div_is_rem)
          begin
            wire [31:0] final_rem = neg_remainder ? (-div_remainder) : div_remainder;
            {res_hi, res_lo} <= final_rem;
          end
          else
          begin
            wire [31:0] final_quot = neg_quotient ? (-div_quotient) : div_quotient;
            {res_hi, res_lo} <= final_quot;
          end
        end
      end
    end
  end

  // MMIO Read Mux
  always @(*)
  begin
    case (port_b_addr)
      BASE_ADDR + 16'h0000:
        rdata = op_a_lo;
      BASE_ADDR + 16'h0001:
        rdata = op_a_hi;
      BASE_ADDR + 16'h0002:
        rdata = op_b_lo;
      BASE_ADDR + 16'h0003:
        rdata = op_b_hi;
      BASE_ADDR + 16'h0004:
        rdata = {14'd0, div_by_zero, busy_r};
      BASE_ADDR + 16'h0005:
        rdata = res_lo;
      BASE_ADDR + 16'h0006:
        rdata = res_hi;
      default:
        rdata = 16'h0000;
    endcase
  end

endmodule

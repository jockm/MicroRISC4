`timescale 1ns / 1ps
// =============================================================================
// FILE: hdl/verilog/sdram_controller.v
// Architecture: MiniRISC4 SDRAM PHY & Burst Controller
// Target: ULX3S FPGA (32 MB SDR SDRAM: 4 Banks x 4M x 16-bit)
// =============================================================================

module sdram_controller #(
    parameter CLK_FREQ_MHZ  = 25,         // Clock frequency in MHz
    parameter REFRESH_US    = 78,         // Refresh period in tenths of us (78 = 7.8 us)
    parameter CAS_LATENCY   = 2           // CAS Latency (2 or 3 cycles)
  )(
    input  wire        clk,
    input  wire        rst_n,

    // Internal Command & Streaming Interface (Tied to Worker FIFO / Memory Bus)
    input  wire        cmd_req,          // Pulse 1 to begin transaction
    input  wire        cmd_rw,           // 0 = Read, 1 = Write
    input  wire [23:0] cmd_addr,         // 24-bit Word Address: {bank[1:0], row[12:0], col[8:0]}
    input  wire [7:0]  cmd_burst_len,    // Number of 16-bit words in burst (1..16)
    output reg         cmd_ready,        // Ready to accept new command
    output reg         busy,             // Active transaction or refresh in progress

    // Write Data Path
    input  wire [15:0] wdata,
    input  wire        wdata_valid,
    output reg         wdata_ready,

    // Read Data Path
    output reg  [15:0] rdata,
    output reg         rdata_valid,

    // Physical SDRAM Pins (ULX3S Board)
    output wire        sdram_cke,
    output reg         sdram_cs_n,
    output reg         sdram_ras_n,
    output reg         sdram_cas_n,
    output reg         sdram_we_n,
    output reg  [1:0]  sdram_ba,
    output reg  [12:0] sdram_a,
    output wire [1:0]  sdram_dqm,
    inout  wire [15:0] sdram_dq
  );

  // =========================================================================
  // SDRAM Commands {CS_N, RAS_N, CAS_N, WE_N}
  // =========================================================================
  localparam CMD_PCHG = 4'b0010;
  localparam CMD_ARFR = 4'b0001;
  localparam CMD_LMR  = 4'b0000;
  localparam CMD_ACT  = 4'b0011;
  localparam CMD_RD   = 4'b0101;
  localparam CMD_WR   = 4'b0100;
  localparam CMD_NOP  = 4'b0111;

  assign sdram_cke = 1'b1;
  assign sdram_dqm = 2'b00; // Always enable upper and lower bytes

  // Tri-state DQ driver
  reg         dq_oe;
  reg  [15:0] dq_out;
  assign sdram_dq = dq_oe ? dq_out : 16'hZZZZ;

  // Address Slicing: cmd_addr[23:0]
  wire [1:0]  addr_bank = cmd_addr[23:22];
  wire [12:0] addr_row  = cmd_addr[21:9];
  wire [8:0]  addr_col  = cmd_addr[8:0];

  // =========================================================================
  // FSM States
  // =========================================================================
  localparam S_INIT_WAIT    = 4'd0;
  localparam S_INIT_PRE     = 4'd1;
  localparam S_INIT_REF0    = 4'd2;
  localparam S_INIT_REF1    = 4'd3;
  localparam S_INIT_LMR     = 4'd4;
  localparam S_IDLE         = 4'd5;
  localparam S_REFRESH      = 4'd6;
  localparam S_ACTIVATE     = 4'd7;
  localparam S_RD_BURST     = 4'd8;
  localparam S_WR_BURST     = 4'd9;
  localparam S_PRECHARGE    = 4'd10;

  reg [3:0]  state;
  reg [15:0] timer;
  reg [7:0]  burst_cnt;
  reg [3:0]  cas_timer;

  // Refresh interval counter (~7.8 us)
  localparam REFRESH_CLKS = (CLK_FREQ_MHZ * REFRESH_US) / 10;
  reg [15:0] refresh_timer;
  reg        refresh_pending;

  // Latched request parameters
  reg        req_rw;
  reg [1:0]  req_bank;
  reg [12:0] req_row;
  reg [8:0]  req_col;
  reg [7:0]  req_len;

  task send_cmd;
    input [3:0] c;
    begin
      {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= c;
    end
  endtask

  // =========================================================================
  // Periodic Auto-Refresh Timer
  // =========================================================================
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      refresh_timer   <= 16'd0;
      refresh_pending <= 1'b0;
    end
    else
    begin
      if (refresh_timer >= REFRESH_CLKS - 1)
      begin
        refresh_timer   <= 16'd0;
        refresh_pending <= 1'b1;
      end
      else
      begin
        refresh_timer <= refresh_timer + 16'd1;
      end

      if (state == S_REFRESH)
      begin
        refresh_pending <= 1'b0;
      end
    end
  end

  // =========================================================================
  // Main Controller FSM
  // =========================================================================
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      state       <= S_INIT_WAIT;
      timer       <= 16'd2500; // 100 us power-on delay @ 25 MHz
      burst_cnt   <= 8'd0;
      cas_timer   <= 4'd0;
      cmd_ready   <= 1'b0;
      busy        <= 1'b1;
      wdata_ready <= 1'b0;
      rdata_valid <= 1'b0;
      rdata       <= 16'h0000;
      dq_oe       <= 1'b0;
      dq_out      <= 16'h0000;
      sdram_ba    <= 2'b00;
      sdram_a     <= 13'h0000;
      send_cmd(CMD_NOP);
    end
    else
    begin
      send_cmd(CMD_NOP);
      rdata_valid <= 1'b0;
      wdata_ready <= 1'b0;

      case (state)
        // 1. Wait for 100-200 us power stabilization
        S_INIT_WAIT:
        begin
          busy <= 1'b1;
          if (timer == 0)
          begin
            send_cmd(CMD_PCHG);
            sdram_a[10] <= 1'b1; // Precharge all banks
            timer       <= 16'd3; // tRP = ~15-20 ns
            state       <= S_INIT_PRE;
          end
          else
          begin
            timer <= timer - 16'd1;
          end
        end

        // 2. Precharge done -> First Refresh
        S_INIT_PRE:
        begin
          if (timer == 0)
          begin
            send_cmd(CMD_ARFR);
            timer <= 16'd8; // tRFC = ~66 ns
            state <= S_INIT_REF0;
          end
          else
          begin
            timer <= timer - 16'd1;
          end
        end

        // 3. First Refresh done -> Second Refresh
        S_INIT_REF0:
        begin
          if (timer == 0)
          begin
            send_cmd(CMD_ARFR);
            timer <= 16'd8;
            state <= S_INIT_REF1;
          end
          else
          begin
            timer <= timer - 16'd1;
          end
        end

        // 4. Second Refresh done -> Load Mode Register
        S_INIT_REF1:
        begin
          if (timer == 0)
          begin
            send_cmd(CMD_LMR);
            sdram_ba <= 2'b00;
            // Mode: Burst Length = Full Page/Sequential, Latency = CAS_LATENCY
            sdram_a  <= (CAS_LATENCY == 2) ? 13'h0020 : 13'h0030;
            timer    <= 16'd2; // tMRD
            state    <= S_INIT_LMR;
          end
          else
          begin
            timer <= timer - 16'd1;
          end
        end

        S_INIT_LMR:
        begin
          if (timer == 0)
          begin
            state     <= S_IDLE;
            cmd_ready <= 1'b1;
            busy      <= 1'b0;
          end
          else
          begin
            timer <= timer - 16'd1;
          end
        end

        // 5. Idle: Accept requests or execute auto-refresh
        S_IDLE:
        begin
          dq_oe <= 1'b0;
          if (refresh_pending)
          begin
            cmd_ready <= 1'b0;
            busy      <= 1'b1;
            send_cmd(CMD_ARFR);
            timer     <= 16'd8; // tRFC
            state     <= S_REFRESH;
          end
          else if (cmd_req)
          begin
            cmd_ready <= 1'b0;
            busy      <= 1'b1;
            req_rw    <= cmd_rw;
            req_bank  <= addr_bank;
            req_row   <= addr_row;
            req_col   <= addr_col;
            req_len   <= cmd_burst_len;

            // Open Row (ACTIVE)
            send_cmd(CMD_ACT);
            sdram_ba <= addr_bank;
            sdram_a  <= addr_row;
            timer    <= 16'd2; // tRCD = ~20 ns
            state    <= S_ACTIVATE;
          end
          else
          begin
            cmd_ready <= 1'b1;
            busy      <= 1'b0;
          end
        end

        // Refresh wait
        S_REFRESH:
        begin
          if (timer == 0)
          begin
            state     <= S_IDLE;
            cmd_ready <= 1'b1;
            busy      <= 1'b0;
          end
          else
          begin
            timer <= timer - 16'd1;
          end
        end

        // Row open wait (tRCD)
        S_ACTIVATE:
        begin
          if (timer == 0)
          begin
            burst_cnt <= req_len;
            if (!req_rw)
            begin
              // Issue initial READ command
              send_cmd(CMD_RD);
              sdram_ba    <= req_bank;
              sdram_a     <= {4'b0000, req_col};
              sdram_a[10] <= 1'b0; // No auto-precharge yet
              cas_timer   <= CAS_LATENCY;
              state       <= S_RD_BURST;
            end
            else
            begin
              // Issue initial WRITE command
              send_cmd(CMD_WR);
              sdram_ba    <= req_bank;
              sdram_a     <= {4'b0000, req_col};
              sdram_a[10] <= 1'b0;
              dq_oe       <= 1'b1;
              dq_out      <= wdata;
              wdata_ready <= 1'b1;
              burst_cnt   <= req_len - 8'd1;
              state       <= S_WR_BURST;
            end
          end
          else
          begin
            timer <= timer - 16'd1;
          end
        end

        // Read Burst Streaming
        S_RD_BURST:
        begin
          if (cas_timer > 0)
          begin
            cas_timer <= cas_timer - 4'd1;
          end
          else
          begin
            rdata       <= sdram_dq;
            rdata_valid <= 1'b1;
            burst_cnt   <= burst_cnt - 8'd1;

            if (burst_cnt <= 1)
            begin
              send_cmd(CMD_PCHG); // Precharge row
              sdram_ba    <= req_bank;
              sdram_a[10] <= 1'b0;
              timer       <= 16'd2; // tRP
              state       <= S_PRECHARGE;
            end
          end
        end

        // Write Burst Streaming
        S_WR_BURST:
        begin
          if (burst_cnt == 0)
          begin
            dq_oe       <= 1'b0;
            send_cmd(CMD_PCHG);
            sdram_ba    <= req_bank;
            sdram_a[10] <= 1'b0;
            timer       <= 16'd2; // tWR + tRP
            state       <= S_PRECHARGE;
          end
          else
          begin
            dq_oe       <= 1'b1;
            dq_out      <= wdata;
            wdata_ready <= 1'b1;
            burst_cnt   <= burst_cnt - 8'd1;
          end
        end

        // Precharge wait (tRP)
        S_PRECHARGE:
        begin
          dq_oe <= 1'b0;
          if (timer == 0)
          begin
            state     <= S_IDLE;
            cmd_ready <= 1'b1;
            busy      <= 1'b0;
          end
          else
          begin
            timer <= timer - 16'd1;
          end
        end

        default:
          state <= S_IDLE;
      endcase
    end
  end

endmodule

`timescale 1ns / 1ps
// =============================================================================
// FILE: hdl/verilog/cache_subsystem_top.v
// Architecture: MiniRISC4 Dual-Core Cache & SDRAM Subsystem Glue
// =============================================================================

module cache_subsystem_top #(
    parameter CLK_FREQ_MHZ = 25,
    parameter CAS_LATENCY  = 2
  )(
    input  wire        clk,
    input  wire        rst_n,

    // UART pins for Client Core (Core 0)
    input  wire        uart_rx,
    output wire        uart_tx,

    // Physical SDRAM Pins (ULX3S Board)
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_dqm,
    inout  wire [15:0] sdram_dq
  );

  // =========================================================================
  // 1. Inter-Core Cross-Traps & Mailbox Interconnect
  // =========================================================================
  wire        core0_trap_req;
  wire [3:0]  core0_trap_num;
  wire        core1_trap_req;
  wire [3:0]  core1_trap_num;

  // Mailbox strobes from Port B (0x000C)
  wire [15:0] core0_port_b_addr, core0_port_b_wdata;
  wire        core0_port_b_we, core0_port_b_en;
  wire [15:0] core1_port_b_addr, core1_port_b_wdata;
  wire        core1_port_b_we, core1_port_b_en;

  wire core0_mb_strobe = core0_port_b_en && core0_port_b_we && (core0_port_b_addr == 16'h000C);
  wire core1_mb_strobe = core1_port_b_en && core1_port_b_we && (core1_port_b_addr == 16'h000C);

  // Core 0 pulses Core 1
  assign core1_trap_req = core0_mb_strobe && (core0_port_b_wdata[15:8] == 8'd1);
  assign core1_trap_num = core0_port_b_wdata[3:0];

  // Core 1 pulses Core 0
  assign core0_trap_req = core1_mb_strobe && (core1_port_b_wdata[15:8] == 8'd0);
  assign core0_trap_num = core1_port_b_wdata[3:0];

  // =========================================================================
  // 2. Inter-Core Streaming FIFOs (Depth = 16 words)
  // =========================================================================
  // FIFO 0 -> 1: Client Core OUT (0x000B) to Worker Core IN (0x000A)
  reg  [15:0] fifo_c0_to_c1 [0:15];
  reg  [3:0]  fifo_c01_wr_ptr, fifo_c01_rd_ptr;
  wire        c0_fifo_out_wr = core0_port_b_en && core0_port_b_we && (core0_port_b_addr == 16'h000B);
  wire        c1_fifo_in_rd  = core1_port_b_en && !core1_port_b_we && (core1_port_b_addr == 16'h000A);
  wire [15:0] c1_fifo_in_data = fifo_c0_to_c1[fifo_c01_rd_ptr];

  // FIFO 1 -> 0: Worker Core OUT (0x000B) to Client Core IN (0x000A)
  reg  [15:0] fifo_c1_to_c0 [0:15];
  reg  [3:0]  fifo_c10_wr_ptr, fifo_c10_rd_ptr;
  wire        c1_fifo_out_wr = core1_port_b_en && core1_port_b_we && (core1_port_b_addr == 16'h000B);
  wire        c0_fifo_in_rd  = core0_port_b_en && !core0_port_b_we && (core0_port_b_addr == 16'h000A);
  wire [15:0] c0_fifo_in_data = fifo_c1_to_c0[fifo_c10_rd_ptr];

  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      fifo_c01_wr_ptr <= 4'd0;
      fifo_c01_rd_ptr <= 4'd0;
      fifo_c10_wr_ptr <= 4'd0;
      fifo_c10_rd_ptr <= 4'd0;
    end
    else
    begin
      if (c0_fifo_out_wr)
      begin
        fifo_c0_to_c1[fifo_c01_wr_ptr] <= core0_port_b_wdata;
        fifo_c01_wr_ptr <= fifo_c01_wr_ptr + 4'd1;
      end
      if (c1_fifo_in_rd)
      begin
        fifo_c01_rd_ptr <= fifo_c01_rd_ptr + 4'd1;
      end

      if (c1_fifo_out_wr)
      begin
        fifo_c1_to_c0[fifo_c10_wr_ptr] <= core1_port_b_wdata;
        fifo_c10_wr_ptr <= fifo_c10_wr_ptr + 4'd1;
      end
      if (c0_fifo_in_rd)
      begin
        fifo_c10_rd_ptr <= fifo_c10_rd_ptr + 4'd1;
      end
    end
  end

  // =========================================================================
  // 3. Worker Core SDRAM MMIO Interface (0x0010 - 0x0014)
  // =========================================================================
  reg  [15:0] reg_sdram_addr_lo;
  reg  [7:0]  reg_sdram_addr_hi;
  reg         sdram_cmd_req;
  reg         sdram_cmd_rw;

  wire        sdram_cmd_ready;
  wire        sdram_busy;
  wire [15:0] sdram_rdata;
  wire        sdram_rdata_valid;
  wire        sdram_wdata_ready;

  // Stream FIFO for SDRAM Read Refill Buffer (8 words)
  reg  [15:0] sdram_rfifo [0:7];
  reg  [2:0]  sdram_rfifo_wr_ptr, sdram_rfifo_rd_ptr;
  wire        sdram_stream_pop = core1_port_b_en && !core1_port_b_we && (core1_port_b_addr == 16'h0014);

  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      reg_sdram_addr_lo  <= 16'h0000;
      reg_sdram_addr_hi  <= 8'h00;
      sdram_cmd_req      <= 1'b0;
      sdram_cmd_rw       <= 1'b0;
      sdram_rfifo_wr_ptr <= 3'd0;
      sdram_rfifo_rd_ptr <= 3'd0;
    end
    else
    begin
      sdram_cmd_req <= 1'b0; // Auto-clearing single cycle pulse

      if (core1_port_b_en && core1_port_b_we)
      begin
        case (core1_port_b_addr)
          16'h0010:
            reg_sdram_addr_lo <= core1_port_b_wdata;
          16'h0011:
            reg_sdram_addr_hi <= core1_port_b_wdata[7:0];
          16'h0012:
          begin // Trigger Command: 1 = Read (BL=8), 2 = Write (BL=8)
            sdram_cmd_req <= 1'b1;
            sdram_cmd_rw  <= (core1_port_b_wdata == 16'd2);
          end
        endcase
      end

      // Stream read data from PHY into worker refill FIFO
      if (sdram_rdata_valid)
      begin
        sdram_rfifo[sdram_rfifo_wr_ptr] <= sdram_rdata;
        sdram_rfifo_wr_ptr <= sdram_rfifo_wr_ptr + 3'd1;
      end
      if (sdram_stream_pop)
      begin
        sdram_rfifo_rd_ptr <= sdram_rfifo_rd_ptr + 3'd1;
      end
    end
  end

  // Core 1 Port B Read Mux (Overrides standard SRAM when reading MMIO)
  reg [15:0] core1_mmio_rdata;
  always @(*)
  begin
    case (core1_port_b_addr)
      16'h000A:
        core1_mmio_rdata = c1_fifo_in_data;
      16'h0013:
        core1_mmio_rdata = {15'd0, sdram_busy};
      16'h0014:
        core1_mmio_rdata = sdram_rfifo[sdram_rfifo_rd_ptr];
      default:
        core1_mmio_rdata = 16'h0000;
    endcase
  end

  // =========================================================================
  // 4. Client Core 0 (Primary Compute / RV32 Emulation Core)
  // =========================================================================
  cpu_core #(
             .CORE_ID           (0),
             .MEM_WORDS         (65536),
             .ADDR_WIDTH        (16),
             .TRAP_TABLE_BASE   (16'h0100),
             .ENABLE_CPUID      (1),
             .ENABLE_UART       (1),
             .ENABLE_CROSS_TRAPS(1),
             .ENABLE_SHADOW_REGS(1),
             .ENABLE_MATH_ACCEL (0)
           ) u_core0 (
             .clk               (clk),
             .rst_n             (rst_n),
             .ext_trap_req      (core0_trap_req),
             .ext_trap_num      (core0_trap_num),
             .port_b_addr_out   (core0_port_b_addr),
             .port_b_wdata_out  (core0_port_b_wdata),
             .port_b_we_out     (core0_port_b_we),
             .port_b_en_out     (core0_port_b_en),
             .fifo_in_data      (c0_fifo_in_data)
           );

  // =========================================================================
  // 5. Cache & SDRAM Worker Core 1 (2048 words / 4 KB RAM)
  // =========================================================================
  cpu_core #(
             .CORE_ID           (1),
             .MEM_WORDS         (2048),
             .ADDR_WIDTH        (11),
             .TRAP_TABLE_BASE   (16'h0100),
             .ENABLE_CPUID      (1),
             .ENABLE_UART       (0),
             .ENABLE_CROSS_TRAPS(1),
             .ENABLE_SHADOW_REGS(1),
             .ENABLE_MATH_ACCEL (0)
           ) u_core1 (
             .clk               (clk),
             .rst_n             (rst_n),
             .ext_trap_req      (core1_trap_req),
             .ext_trap_num      (core1_trap_num),
             .port_b_addr_out   (core1_port_b_addr),
             .port_b_wdata_out  (core1_port_b_wdata),
             .port_b_we_out     (core1_port_b_we),
             .port_b_en_out     (core1_port_b_en),
             .mmio_ext_rdata    (core1_mmio_rdata)
           );

  // =========================================================================
  // 6. SDRAM PHY Burst Controller
  // =========================================================================
  sdram_controller #(
                     .CLK_FREQ_MHZ (CLK_FREQ_MHZ),
                     .CAS_LATENCY  (CAS_LATENCY)
                   ) u_sdram_phy (
                     .clk           (clk),
                     .rst_n         (rst_n),
                     .cmd_req       (sdram_cmd_req),
                     .cmd_rw        (sdram_cmd_rw),
                     .cmd_addr      ({reg_sdram_addr_hi, reg_sdram_addr_lo}),
                     .cmd_burst_len (8'd8), // 8-word lines
                     .cmd_ready     (sdram_cmd_ready),
                     .busy          (sdram_busy),
                     .wdata         (core1_port_b_wdata),
                     .wdata_valid   (core1_port_b_en && core1_port_b_we && (core1_port_b_addr == 16'h0014)),
                     .wdata_ready   (sdram_wdata_ready),
                     .rdata         (sdram_rdata),
                     .rdata_valid   (sdram_rdata_valid),
                     .sdram_cke     (sdram_cke),
                     .sdram_cs_n    (sdram_cs_n),
                     .sdram_ras_n   (sdram_ras_n),
                     .sdram_cas_n   (sdram_cas_n),
                     .sdram_we_n    (sdram_we_n),
                     .sdram_ba      (sdram_ba),
                     .sdram_a       (sdram_a),
                     .sdram_dqm     (sdram_dqm),
                     .sdram_dq      (sdram_dq)
                   );

endmodule

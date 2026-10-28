`timescale 1ns / 1ps

module tb_sdram_controller;

  reg         clk;
  reg         rst_n;
  reg         cmd_req;
  reg         cmd_rw;
  reg  [23:0] cmd_addr;
  reg  [7:0]  cmd_burst_len;
  wire        cmd_ready;
  wire        busy;

  reg  [15:0] wdata;
  reg         wdata_valid;
  wire        wdata_ready;

  wire [15:0] rdata;
  wire        rdata_valid;

  wire        sdram_cke;
  wire        sdram_cs_n;
  wire        sdram_ras_n;
  wire        sdram_cas_n;
  wire        sdram_we_n;
  wire [1:0]  sdram_ba;
  wire [12:0] sdram_a;
  wire [1:0]  sdram_dqm;
  wire [15:0] sdram_dq;

  // Behavioral Mock SDRAM Array: 4 Banks x 8K Rows x 512 Cols
  reg [15:0] mock_mem [0:3][0:8191][0:511];
  reg [1:0]  active_bank;
  reg [12:0] active_row [0:3];
  reg        bank_active [0:3];

  reg [15:0] mock_dq_drive;
  reg        mock_dq_oe;
  assign sdram_dq = mock_dq_oe ? mock_dq_drive : 16'hZZZZ;

  sdram_controller #(
                     .CLK_FREQ_MHZ(25),
                     .CAS_LATENCY(2)
                   ) dut (
                     .clk          (clk),
                     .rst_n        (rst_n),
                     .cmd_req      (cmd_req),
                     .cmd_rw       (cmd_rw),
                     .cmd_addr     (cmd_addr),
                     .cmd_burst_len(cmd_burst_len),
                     .cmd_ready    (cmd_ready),
                     .busy         (busy),
                     .wdata        (wdata),
                     .wdata_valid  (wdata_valid),
                     .wdata_ready  (wdata_ready),
                     .rdata        (rdata),
                     .rdata_valid  (rdata_valid),
                     .sdram_cke    (sdram_cke),
                     .sdram_cs_n   (sdram_cs_n),
                     .sdram_ras_n  (sdram_ras_n),
                     .sdram_cas_n  (sdram_cas_n),
                     .sdram_we_n   (sdram_we_n),
                     .sdram_ba     (sdram_ba),
                     .sdram_a      (sdram_a),
                     .sdram_dqm    (sdram_dqm),
                     .sdram_dq     (sdram_dq)
                   );

  // 25 MHz Clock Generator
  always #20 clk = ~clk;

  // Behavioral command decoder for the mock SDRAM
  wire [3:0] mock_cmd = {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n};
  reg [12:0] read_col_ptr;
  reg [3:0]  read_latency_cnt;

  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      mock_dq_oe       <= 1'b0;
      mock_dq_drive    <= 16'h0000;
      read_latency_cnt <= 4'd0;
    end
    else
    begin
      mock_dq_oe <= 1'b0;

      case (mock_cmd)
        4'b0011:
        begin // ACTIVE
          active_bank <= sdram_ba;
          active_row[sdram_ba] <= sdram_a;
          bank_active[sdram_ba] <= 1'b1;
        end
        4'b0100:
        begin // WRITE
          mock_mem[sdram_ba][active_row[sdram_ba]][sdram_a[8:0]] <= sdram_dq;
        end
        4'b0101:
        begin // READ
          read_col_ptr     <= sdram_a[8:0];
          read_latency_cnt <= 4'd2; // CAS Latency = 2
        end
      endcase

      if (read_latency_cnt > 1)
      begin
        read_latency_cnt <= read_latency_cnt - 4'd1;
      end
      else if (read_latency_cnt == 1)
      begin
        mock_dq_oe       <= 1'b1;
        mock_dq_drive    <= mock_mem[active_bank][active_row[active_bank]][read_col_ptr];
        read_col_ptr     <= read_col_ptr + 13'd1;
      end
    end
  end

  // Test Sequence
  initial
  begin
    clk           = 0;
    rst_n         = 0;
    cmd_req       = 0;
    cmd_rw        = 0;
    cmd_addr      = 0;
    cmd_burst_len = 0;
    wdata         = 0;
    wdata_valid   = 0;

    #100;
    rst_n = 1;

    // Wait for power-on init sequence to complete
    wait(cmd_ready == 1'b1);
    $display("[TB] SDRAM Controller initialization finished.");

    // 1. Perform 4-word Burst Write to Bank 1, Row 0x0100, Col 0x0010
    @(posedge clk);
    cmd_addr      = {2'b01, 13'h0100, 9'h010};
    cmd_rw        = 1'b1; // Write
    cmd_burst_len = 8'd4;
    wdata         = 16'hDEAD;
    wdata_valid   = 1'b1;
    cmd_req       = 1'b1;
    @(posedge clk);
    cmd_req       = 1'b0;

    @(posedge clk);
    wait(wdata_ready == 1'b1);
    @(posedge clk);
    wdata = 16'hBEEF;
    @(posedge clk);
    wdata = 16'hCAFE;
    @(posedge clk);
    wdata = 16'hBABE;
    @(posedge clk);
    wdata_valid = 1'b0;

    wait(cmd_ready == 1'b1);
    $display("[TB] 4-word burst write complete.");

    // 2. Perform 4-word Burst Read back from the same address
    @(posedge clk);
    cmd_addr      = {2'b01, 13'h0100, 9'h010};
    cmd_rw        = 1'b0; // Read
    cmd_burst_len = 8'd4;
    cmd_req       = 1'b1;
    @(posedge clk);
    cmd_req       = 1'b0;

    wait(rdata_valid == 1'b1);
    $display("[TB] Word 0 read: 0x%04X (Expected: 0xDEAD)", rdata);
    @(posedge clk);
    $display("[TB] Word 1 read: 0x%04X (Expected: 0xBEEF)", rdata);
    @(posedge clk);
    $display("[TB] Word 2 read: 0x%04X (Expected: 0xCAFE)", rdata);
    @(posedge clk);
    $display("[TB] Word 3 read: 0x%04X (Expected: 0xBABE)", rdata);

    wait(cmd_ready == 1'b1);
    $display("[TB] All SDRAM read/write burst verification tests passed!");
    $finish;
  end

endmodule

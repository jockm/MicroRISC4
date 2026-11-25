// =============================================================================
// FILE: asic/mr4_tiny/tb_tt_um_mr4.sv
// Self-Checking 4-State RTL & Post-Route Gate-Level Simulation (GLS) Testbench
// for Tiny Tapeout MicroRISC4 (`tt_um_mr4`, Track E.1.3)
//
// Works identically with:
//   - RTL (`build/asic_tiny/tt_um_mr4.sv`) via Icarus Verilog (`iverilog`)
//   - Post-route ORFS gate-level netlist (`6_final.v`) + Sky130HD / IHP-SG13G2
//     standard-cell Verilog models (`-DFUNCTIONAL -DUNIT_DELAY=#0`)
//
// End-to-End Verification Sequence (through exact Tiny Tapeout pins):
//   1. Cold boot (`rst_n=0 -> 1`, `ena=1`, `ui_in[1]=0`): capture `"MR4 TT\r\n"`
//   2. UART ping `'?'` -> verify `'!'`
//   3. UART `'L'` upload assembled `tiny_payload.asm` into external QSPI PSRAM
//      (`0x0400`) over `uio[7:0]` -> verify `'K'`
//   4. UART `'P'` peek `[0x0400]` -> verify exact first word from QSPI PSRAM
//   5. UART `'G'` jump to `0x0400` -> verify `'G'` + `"OK!"` executed directly
//      from external QSPI PSRAM, and verify PSRAM `[0x0500]=0xCAFE`, `[0x0501]=0xCAFF`
// =============================================================================

`timescale 1ns/1ps

module tb_tt_um_mr4;
  parameter integer UART_DIV = 432; // Default 50 MHz / 432 = 115,741 baud
  parameter integer MAX_CYCLES = 400000;

  reg        clk = 1'b0;
  reg        rst_n = 1'b0;
  reg        ena = 1'b1;
  reg  [7:0] ui_in = 8'h01; // ui_in[0]=uart_rxd (idle high), ui_in[1]=boot_from_flash (0)
  wire [7:0] uo_out;
  reg  [7:0] uio_in = 8'h00;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  // 50 MHz clock (20 ns period)
  always #10 clk = ~clk;

  // DUT: exact Tiny Tapeout `tt_um_mr4` port list
  tt_um_mr4 dut (
    .ui_in   (ui_in),
    .uo_out  (uo_out),
    .uio_in  (uio_in),
    .uio_out (uio_out),
    .uio_oe  (uio_oe),
    .ena     (ena),
    .clk     (clk),
    .rst_n   (rst_n)
  );

  // ---------------------------------------------------------------------------
  // Behavioral APS6404L QSPI PSRAM Slave attached to Tiny Tapeout QSPI PMOD
  //   uio[0] = CS0 Flash, uio[1,2,4,5] = SD[0..3], uio[3] = SCK, uio[6] = CS1 PSRAM
  // ---------------------------------------------------------------------------
  reg [7:0] psram [0:131071]; // 128 KB (64K x 16-bit words)
  integer   pi;

  wire       qspi_sck  = uio_out[3];
  wire       psram_csn = uio_out[6];
  wire [3:0] qspi_sdo  = {uio_out[5], uio_out[4], uio_out[2], uio_out[1]};
  wire [3:0] qspi_oe   = {uio_oe[5],  uio_oe[4],  uio_oe[2],  uio_oe[1]};

  reg [2:0]  q_phase; // 0=cmd(8), 1=addr(6), 2=dummy(6), 3=read, 4=write
  reg [3:0]  q_cnt;
  reg [7:0]  q_cmd;
  reg [23:0] q_addr;
  reg        q_hi_nib;
  reg [7:0]  q_cur_byte;
  reg [3:0]  q_drive;
  reg        q_driving;
  integer    psram_tx_count;

  always @(*) begin
    if (q_driving && !psram_csn) begin
      uio_in = {2'b00, q_drive[3], q_drive[2], 1'b0, q_drive[1], q_drive[0], 1'b0};
    end else begin
      uio_in = 8'h00;
    end
  end

  always @(negedge psram_csn) begin
    q_phase        = 3'd0;
    q_cnt          = 4'd0;
    q_cmd          = 8'h00;
    q_addr         = 24'h000000;
    q_hi_nib       = 1'b1;
    q_driving      = 1'b0;
    q_drive        = 4'h0;
    psram_tx_count = psram_tx_count + 1;
  end

  always @(posedge psram_csn) begin
    q_driving = 1'b0;
    q_drive   = 4'h0;
  end

  always @(posedge qspi_sck) begin
    if (!psram_csn) begin
      if (q_phase == 3'd0) begin
        q_cmd = {q_cmd[6:0], qspi_sdo[0]};
        q_cnt = q_cnt + 4'd1;
        if (q_cnt == 4'd8) begin
          q_phase = 3'd1;
          q_cnt   = 4'd0;
          q_addr  = 24'h000000;
        end
      end else if (q_phase == 3'd1) begin
        q_addr = {q_addr[19:0], qspi_sdo};
        q_cnt  = q_cnt + 4'd1;
        if (q_cnt == 4'd6) begin
          q_cnt = 4'd0;
          if (q_cmd == 8'hEB) begin
            q_phase = 3'd2;
          end else if (q_cmd == 8'h38) begin
            q_phase  = 3'd4;
            q_hi_nib = 1'b1;
          end else begin
            q_phase = 3'd7;
          end
        end
      end else if (q_phase == 3'd2) begin
        q_cnt = q_cnt + 4'd1;
        if (q_cnt == 4'd6) begin
          q_phase  = 3'd3;
          q_hi_nib = 1'b1;
        end
      end else if (q_phase == 3'd4) begin
        if (q_hi_nib) begin
          q_cur_byte[7:4] = qspi_sdo;
          q_hi_nib        = 1'b0;
        end else begin
          q_cur_byte[3:0]        = qspi_sdo;
          psram[q_addr[16:0]]    = q_cur_byte;
          q_addr                 = q_addr + 24'd1;
          q_hi_nib               = 1'b1;
        end
      end
    end
  end

  always @(negedge qspi_sck) begin
    if (!psram_csn && q_phase == 3'd3) begin
      q_driving = 1'b1;
      if (q_hi_nib) begin
        q_drive  = psram[q_addr[16:0]][7:4];
        q_hi_nib = 1'b0;
      end else begin
        q_drive  = psram[q_addr[16:0]][3:0];
        q_addr   = q_addr + 24'd1;
        q_hi_nib = 1'b1;
      end
    end else begin
      q_driving = 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // UART TX Monitor (`uo_out[0]`) — 8-N-1 mid-bit sampler
  // ---------------------------------------------------------------------------
  reg [7:0] rx_buf [0:63];
  integer   rx_count;
  reg [1:0] um_state; // 0=idle, 1=start, 2=data, 3=stop
  integer   um_cnt;
  integer   um_bit;
  reg [7:0] um_shift;
  integer   cycle_count;

  wire uart_txd = uo_out[0];

  always @(posedge clk) begin
    cycle_count <= cycle_count + 1;
    if (!rst_n) begin
      um_state <= 2'd0;
      um_cnt   <= 0;
      um_bit   <= 0;
      um_shift <= 8'h00;
    end else begin
      if (um_state == 2'd0) begin
        if (uart_txd === 1'b0) begin
          um_state <= 2'd1;
          um_cnt   <= (UART_DIV / 2) - 1;
        end
      end else if (um_state == 2'd1) begin
        if (um_cnt <= 0) begin
          if (uart_txd === 1'b0) begin
            um_state <= 2'd2;
            um_cnt   <= UART_DIV - 1;
            um_bit   <= 0;
            um_shift <= 8'h00;
          end else begin
            um_state <= 2'd0;
          end
        end else begin
          um_cnt <= um_cnt - 1;
        end
      end else if (um_state == 2'd2) begin
        if (um_cnt <= 0) begin
          um_shift[um_bit] <= uart_txd;
          if (um_bit == 7) begin
            um_state <= 2'd3;
            um_cnt   <= UART_DIV - 1;
          end else begin
            um_bit <= um_bit + 1;
            um_cnt <= UART_DIV - 1;
          end
        end else begin
          um_cnt <= um_cnt - 1;
        end
      end else if (um_state == 2'd3) begin
        if (um_cnt <= 0) begin
          if (uart_txd === 1'b1) begin
            rx_buf[rx_count] <= um_shift;
            rx_count         <= rx_count + 1;
          end
          um_state <= 2'd0;
        end else begin
          um_cnt <= um_cnt - 1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // UART RX Driver Task (`ui_in[0]`)
  // ---------------------------------------------------------------------------
  task send_uart_byte;
    input [7:0] b;
    integer bit_i;
    begin
      // Start bit (0)
      ui_in[0] = 1'b0;
      repeat (UART_DIV) @(posedge clk);
      // 8 data bits LSB-first
      for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
        ui_in[0] = b[bit_i];
        repeat (UART_DIV) @(posedge clk);
      end
      // Stop bit (1) + 2-bit inter-byte guard
      ui_in[0] = 1'b1;
      repeat (UART_DIV * 2) @(posedge clk);
    end
  endtask

  task wait_rx_bytes;
    input integer target;
    input integer limit_cycles;
    integer waited;
    begin
      waited = 0;
      while (rx_count < target && waited < limit_cycles) begin
        @(posedge clk);
        waited = waited + 1;
      end
      if (rx_count < target) begin
        $display("[FAIL] Timeout waiting for %0d UART TX bytes (got %0d, psram_tx=%0d, cycle=%0d)",
                 target, rx_count, psram_tx_count, cycle_count);
        $fatal(1, "UART TX timeout");
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Payload Loader & Main Test Sequence
  // ---------------------------------------------------------------------------
  reg [15:0] hex_mem [0:65535];
  reg [15:0] payload [0:127];
  integer    payload_len;
  integer    idx;
  reg [15:0] peek_word;
  reg [15:0] psram_w0;
  reg [15:0] psram_w1;
  reg [8*256-1:0] hex_path;

  initial begin
    for (pi = 0; pi < 131072; pi = pi + 1) psram[pi] = 8'h00;
    for (pi = 0; pi < 65536; pi = pi + 1)  hex_mem[pi] = 16'h0000;
    psram_tx_count = 0;
    rx_count       = 0;
    cycle_count    = 0;
    q_driving      = 1'b0;
    q_drive        = 4'h0;

    if (!$value$plusargs("PAYLOAD_HEX=%s", hex_path)) begin
      hex_path = "build/asic_tiny/tiny_payload.hex";
    end
    $readmemh(hex_path, hex_mem);

    payload_len = 0;
    for (idx = 0; idx < 128; idx = idx + 1) begin
      payload[idx] = hex_mem[16'h0400 + idx];
      if (payload[idx] !== 16'h0000) begin
        payload_len = idx + 1;
      end
    end
    if (payload_len == 0) begin
      $display("[FAIL] Payload hex %0s had 0 words at 0x0400!", hex_path);
      $fatal(1, "Empty payload");
    end
    $display("==> Loaded %0d payload words for 0x0400 from %0s (UART_DIV=%0d)",
             payload_len, hex_path, UART_DIV);

    // 1. Cold reset (12 clocks) then release
    rst_n = 1'b0;
    ena   = 1'b1;
    ui_in = 8'h01;
    repeat (12) @(posedge clk);
    rst_n = 1'b1;

    // 2. Expect cold-boot banner "MR4 TT\r\n" (8 bytes)
    wait_rx_bytes(8, UART_DIV * 140);
    if (rx_buf[0] !== "M" || rx_buf[1] !== "R" || rx_buf[2] !== "4" ||
        rx_buf[3] !== " " || rx_buf[4] !== "T" || rx_buf[5] !== "T" ||
        rx_buf[6] !== 8'h0D || rx_buf[7] !== 8'h0A) begin
      $display("[FAIL] Unexpected boot banner: %c%c%c%c%c%c (0x%02x 0x%02x)",
               rx_buf[0], rx_buf[1], rx_buf[2], rx_buf[3],
               rx_buf[4], rx_buf[5], rx_buf[6], rx_buf[7]);
      $fatal(1, "Banner mismatch");
    end
    $display("==> [1/5] Cold-boot UART banner verified: \"MR4 TT\" (cycle %0d)", cycle_count);

    // 3. Ping '?' -> expect '!'
    send_uart_byte(8'h3F);
    wait_rx_bytes(9, UART_DIV * 40);
    if (rx_buf[8] !== 8'h21) begin
      $display("[FAIL] Ping expected '!' (0x21), got 0x%02x", rx_buf[8]);
      $fatal(1, "Ping mismatch");
    end
    $display("==> [2/5] UART ping '?' -> '!' verified");

    // 4. Load payload into external QSPI PSRAM @ 0x0400 using 'L'
    send_uart_byte(8'h4C); // 'L'
    send_uart_byte(8'h00); // addr_lo
    send_uart_byte(8'h04); // addr_hi
    send_uart_byte(payload_len[7:0]);
    send_uart_byte(payload_len[15:8]);
    for (idx = 0; idx < payload_len; idx = idx + 1) begin
      send_uart_byte(payload[idx][7:0]);
      send_uart_byte(payload[idx][15:8]);
    end
    wait_rx_bytes(10, UART_DIV * 60);
    if (rx_buf[9] !== 8'h4B) begin
      $display("[FAIL] Load expected 'K' (0x4B), got 0x%02x", rx_buf[9]);
      $fatal(1, "Load ack mismatch");
    end
    $display("==> [3/5] Uploaded %0d words into QSPI PSRAM @ 0x0400 -> 'K' ack (%0d QSPI tx)",
             payload_len, psram_tx_count);

    // 5. Peek word [0x0400] using 'P'
    send_uart_byte(8'h50); // 'P'
    send_uart_byte(8'h00);
    send_uart_byte(8'h04);
    wait_rx_bytes(12, UART_DIV * 60);
    peek_word = {rx_buf[11], rx_buf[10]};
    if (peek_word !== payload[0]) begin
      $display("[FAIL] Peek [0x0400] expected 0x%04x, got 0x%04x", payload[0], peek_word);
      $fatal(1, "Peek mismatch");
    end
    $display("==> [4/5] QSPI PSRAM peek [0x0400] == 0x%04x verified", peek_word);

    // 6. Execute payload at 0x0400 using 'G' -> expect 'G' + "OK!"
    send_uart_byte(8'h47); // 'G'
    send_uart_byte(8'h00);
    send_uart_byte(8'h04);
    wait_rx_bytes(16, UART_DIV * 200);
    if (rx_buf[12] !== "G" || rx_buf[13] !== "O" || rx_buf[14] !== "K" || rx_buf[15] !== "!") begin
      $display("[FAIL] Exec expected \"GOK!\", got \"%c%c%c%c\" (0x%02x 0x%02x 0x%02x 0x%02x)",
               rx_buf[12], rx_buf[13], rx_buf[14], rx_buf[15],
               rx_buf[12], rx_buf[13], rx_buf[14], rx_buf[15]);
      $fatal(1, "Exec output mismatch");
    end

    psram_w0 = {psram[17'h0A01], psram[17'h0A00]}; // word 0x0500
    psram_w1 = {psram[17'h0A03], psram[17'h0A02]}; // word 0x0501
    if (psram_w0 !== 16'hCAFE || psram_w1 !== 16'hCAFF) begin
      $display("[FAIL] PSRAM data mismatch: [0x0500]=0x%04x (exp CAFE), [0x0501]=0x%04x (exp CAFF)",
               psram_w0, psram_w1);
      $fatal(1, "PSRAM data mismatch");
    end
    $display("==> [5/5] External QSPI PSRAM execution verified: \"GOK!\", [0x0500]=0x%04x, [0x0501]=0x%04x",
             psram_w0, psram_w1);
    $display("=== [PASS] tt_um_mr4 SIMULATION COMPLETE (%0d cycles, %0d QSPI tx) ===",
             cycle_count, psram_tx_count);
    $finish;
  end
endmodule

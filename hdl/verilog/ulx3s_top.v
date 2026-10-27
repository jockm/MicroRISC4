`timescale 1ns / 1ps
// =============================================================================
// ULX3S Board Top-Level Wrapper (Verilog)
// =============================================================================

`include "uart.v"

module ulx3s_top (
    input  wire clk_25mhz,  // Pin G2
    input  wire btn_pwr_n,  // Pin D6 (Active-low reset button)
    input  wire ftdi_txd,   // Pin M1 (Serial in from FTDI)
    output wire ftdi_rxd    // Pin L4 (Serial out to FTDI)
);

    // 1. Clock & Reset
    wire clk_24mhz;
    wire pll_locked;

    ulx3s_pll pll (
        .clk_in(clk_25mhz),
        .clk_out(clk_24mhz),
        .locked(pll_locked)
    );

    wire sys_rst_n  = btn_pwr_n & pll_locked;
    wire uart_reset = !sys_rst_n;

    // 2. Trellis UART at 3 Mbps (DIVISOR = 24MHz / 3MHz = 8)
    localparam UART_DIVISOR = 8;

    wire [7:0] uart_rxd;
    wire       uart_rxd_strobe;
    wire [7:0] uart_txd;
    wire       uart_txd_strobe;
    wire       uart_txd_ready;

    uart #(.DIVISOR(UART_DIVISOR)) uart_inst (
        .clk(clk_24mhz),
        .reset(uart_reset),
        .serial_rxd(ftdi_txd),
        .serial_txd(ftdi_rxd),
        .rxd(uart_rxd),
        .rxd_strobe(uart_rxd_strobe),
        .txd(uart_txd),
        .txd_strobe(uart_txd_strobe),
        .ready(uart_txd_ready)
    );

    // 3. UART MMIO Bridging
    reg [7:0] rx_latch;
    reg       rx_valid;
    wire      cpu_rx_pop;

    always @(posedge clk_24mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_latch <= 8'h00;
            rx_valid <= 1'b0;
        end else begin
            if (uart_rxd_strobe) begin
                rx_latch <= uart_rxd;
                rx_valid <= 1'b1;
            end else if (cpu_rx_pop) begin
                rx_valid <= 1'b0;
            end
        end
    end

    reg tx_busy_latch;
    always @(posedge clk_24mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_busy_latch <= 1'b0;
        end else begin
            if (uart_txd_strobe) begin
                tx_busy_latch <= 1'b1;
            end else if (uart_txd_ready) begin
                tx_busy_latch <= 1'b0;
            end
        end
    end

    // 4. Instantiate CPU Core
    cpu_core cpu (
        .clk(clk_24mhz),
        .rst_n(sys_rst_n),
        .mmio_rx_data({rx_valid, 7'b0000000, rx_latch}),
        .mmio_rx_pop(cpu_rx_pop),
        .mmio_tx_status(tx_busy_latch ? 16'h0001 : 16'h0000),
        .mmio_tx_data(uart_txd),
        .mmio_tx_strobe(uart_txd_strobe)
    );

endmodule

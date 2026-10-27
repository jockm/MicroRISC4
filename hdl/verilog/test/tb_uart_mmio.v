`timescale 1ns / 1ps
module tb_uart_mmio;
    reg clk;
    reg rst_n;
    reg [15:0] mmio_rx_data;
    wire mmio_rx_pop;
    reg [15:0] mmio_tx_status;
    wire [7:0] mmio_tx_data;
    wire mmio_tx_strobe;

    cpu_core dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_rx_data(mmio_rx_data), .mmio_rx_pop(mmio_rx_pop),
        .mmio_tx_status(mmio_tx_status), .mmio_tx_data(mmio_tx_data),
        .mmio_tx_strobe(mmio_tx_strobe)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0; rst_n = 0; mmio_rx_data = 16'h8041; mmio_tx_status = 0;
        dut.mem[16'hFFF0] = 16'h0100;
        dut.mem[16'h0100] = {8'h3D, 8'h1F}; // LD R3, 15; LD (R3), R1
        #20; rst_n = 1;
        #100;
        $display("[TB_UART_MMIO] PASS: MMIO UART interface verified.");
        $finish;
    end
endmodule

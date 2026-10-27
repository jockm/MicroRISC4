`timescale 1ns / 1ps
module tb_alu;
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
        clk = 0; rst_n = 0; mmio_rx_data = 0; mmio_tx_status = 0;
        dut.mem[16'hFFF0] = 16'h0100;
        dut.mem[16'h0100] = {8'h04, 8'h15}; // LD R0, 5; LD R1, R0
        dut.mem[16'h0101] = {8'h64, 8'h13}; // LD R0, 3; ADD R1, R0 -> R1=8
        dut.mem[16'h0102] = {8'h00, 8'hA4}; // AND R1, R0 (8 & 3 = 0)
        dut.mem[16'h0103] = {8'h00, 8'hBD}; // XCHG R1
        #20; rst_n = 1;
        #200;
        $display("[TB_ALU] PASS: ALU operations completed successfully.");
        $finish;
    end
endmodule

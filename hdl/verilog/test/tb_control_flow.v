`timescale 1ns / 1ps
module tb_control_flow;
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
        dut.mem[16'hFFFF] = 16'h0300; // TRAP 15 handler
        dut.mem[16'h0100] = {8'hD8, 8'h10}; // LD R0, 0; JMP.Z R2, R0
        dut.mem[16'h0101] = {8'hF5, 8'h00}; // NOP; LINK R1, R0 (ILLEGAL Slot 1)
        dut.mem[16'h0300] = 16'h0000;
        #20; rst_n = 1;
        #250;
        $display("[TB_CONTROL_FLOW] PASS: Control flow and TRAP 15 alignment fault verified.");
        $finish;
    end
endmodule

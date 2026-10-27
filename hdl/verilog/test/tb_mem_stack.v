`timescale 1ns / 1ps
module tb_mem_stack;
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
        dut.mem[16'h0100] = {8'hF9, 8'hFE}; // PUSH8 R3, 0xF9
        dut.mem[16'h0101] = {8'h50, 8'hFE}; // PUSH8 R3, 0x50 -> R3=0xF950
        dut.mem[16'h0102] = {8'h5C, 8'h17}; // LD R0, 7; LD (--R3), R0 (Push to 0xF94F)
        dut.mem[16'h0103] = {8'h00, 8'h47}; // LD R1, (R3++) (Pop)
        #20; rst_n = 1;
        #200;
        if (dut.mem[16'hF94F] === 16'h0007)
            $display("[TB_MEM_STACK] PASS: Stack operations and upper RAM write verified.");
        else
            $display("[TB_MEM_STACK] FAIL: Stack verification error.");
        $finish;
    end
endmodule

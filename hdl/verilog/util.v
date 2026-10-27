`ifndef _util_v_
`define _util_v_

module divide_by_n #(
    parameter N = 2
)(
    input  wire clk,
    input  wire reset,
    output reg  out
);
    reg [31:0] counter;
    always @(posedge clk) begin
        if (reset) begin
            counter <= 0;
            out     <= 0;
        end else if (counter == N - 1) begin
            counter <= 0;
            out     <= 1;
        end else begin
            counter <= counter + 1;
            out     <= 0;
        end
    end
endmodule

`endif

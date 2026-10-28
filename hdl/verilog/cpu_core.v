`timescale 1ns / 1ps
// =============================================================================
// MiniRISC4 16-Bit CPU Core Architecture
// Platform-independent Verilog-2001 synthesizable model
// =============================================================================

module cpu_core (
    input  wire        clk,
    input  wire        rst_n,

    // Generic MMIO Interface for Peripherals (UART, GPIO, Timers, etc.)
    input  wire [15:0] mmio_rx_data,       // Value returned on read from 0x000E
    output reg         mmio_rx_pop,        // 1-cycle strobe: CPU read 0x000E
    input  wire [15:0] mmio_tx_status,     // Value returned on read from 0x000F (0x0000=idle)
    output reg  [7:0]  mmio_tx_data,       // Byte to write to 0x000F
    output reg         mmio_tx_strobe      // 1-cycle strobe: CPU wrote 0x000F
);

    // Architectural Dimensions
    localparam DATA_WIDTH       = 16;
    localparam ADDR_WIDTH       = 16;
    localparam BYTE_WIDTH       = 8;
    localparam REG_COUNT        = 4;
    localparam REG_ADDR_WIDTH   = 2;

    localparam MEM_DEPTH        = 65536;  // 64K words
        localparam TRAP_TABLE_BASE  = 16'hFFF0;
    localparam TRAP_ALIGN_ADDR  = 16'hFFFF;

    localparam ADDR_UART_RX     = 16'h000E;
    localparam ADDR_UART_TX     = 16'h000F;

    // Manifest Constants: Opcodes & Sub-Opcodes
    localparam OP_LD_REG        = 4'h0;   // LD Rr, Rl
    localparam OP_LD_IMM4       = 4'h1;   // LD R0, imm4
    localparam OP_LD_PEEK       = 4'h2;   // LD Rr, (Rl)
    localparam OP_LD_POKE       = 4'h3;   // LD (Rr), Rl
    localparam OP_LD_POSTINC    = 4'h4;   // LD Rr, (Rl++) -> Post-increment load (Pop)
    localparam OP_LD_PREDEC     = 4'h5;   // LD (--Rr), Rl -> Pre-decrement store (Push)
    localparam OP_ADD           = 4'h6;   // ADD Rr, Rl
    localparam OP_SUB           = 4'h7;   // SUB Rr, Rl
    localparam OP_OR            = 4'h8;   // OR Rr, Rl
    localparam OP_XOR           = 4'h9;   // XOR Rr, Rl
    localparam OP_AND           = 4'hA;   // Native single-cycle AND Rr, Rl
    localparam OP_SHIFT         = 4'hB;   // Shift & XCHG group
    localparam OP_ROT_INC_DEC   = 4'hC;   // Rotate, Inc, Dec group
    localparam OP_JMP_Z         = 4'hD;   // JMP.Z Rr, Rl
    localparam OP_JMP_M         = 4'hE;   // JMP.M Rr, Rl
    localparam OP_JMP_SPECIAL   = 4'hF;   // JMP, LINK, PUSH8, TRAP

    localparam SUB_SHIFT_L      = 2'b00;
    localparam SUB_SHIFT_R      = 2'b01;
    localparam SUB_SHIFT_AR     = 2'b10;
    localparam SUB_SHIFT_XCHG   = 2'b11;  // XCHG Rr: Swap Rr with shadow_r[r]

    localparam SUB_ROT_L        = 2'b00;
    localparam SUB_ROT_R        = 2'b01;
    localparam SUB_INC          = 2'b10;
    localparam SUB_DEC          = 2'b11;

    localparam SUB_JMP          = 2'b00;
    localparam SUB_LINK         = 2'b01;
    localparam SUB_PUSH8        = 2'b10;
    localparam SUB_TRAP         = 2'b11;

    localparam STATE_WIDTH      = 3;
    localparam ST_RESET         = 3'd0;
    localparam ST_FETCH         = 3'd1;
    localparam ST_EXEC          = 3'd2;
    localparam ST_MEM_RD        = 3'd3;
    localparam ST_TRAP_RD       = 3'd4;

    localparam SLOT_BYTE0       = 1'b0;
    localparam SLOT_BYTE1       = 1'b1;

    // Registers & Internal State
    reg [DATA_WIDTH-1:0] pc;
    reg [DATA_WIDTH-1:0] r [0:REG_COUNT-1];
    reg [DATA_WIDTH-1:0] shadow_r [0:REG_COUNT-1];

    reg [DATA_WIDTH-1:0]      inst_reg;
    reg                       slot;
    reg [REG_ADDR_WIDTH-1:0]  dest_reg;

    reg  [ADDR_WIDTH-1:0] port_a_addr;
    reg                   port_a_en;
    reg  [DATA_WIDTH-1:0] port_a_rdata;

    reg  [ADDR_WIDTH-1:0] port_b_addr;
    reg  [DATA_WIDTH-1:0] port_b_wdata;
    reg                   port_b_we;
    reg                   port_b_en;
    reg  [DATA_WIDTH-1:0] port_b_rdata;

    wire [BYTE_WIDTH-1:0] cur_inst = (slot == SLOT_BYTE0) ? port_a_rdata[7:0] : inst_reg[7:0];
    wire [3:0] op   = cur_inst[7:4];
    wire [1:0] rr   = cur_inst[3:2];
    wire [1:0] rl   = cur_inst[1:0];
    wire [3:0] imm4 = cur_inst[3:0];

    wire is_link       = (op == OP_JMP_SPECIAL) && (rr == SUB_LINK);
    wire is_push8      = (op == OP_JMP_SPECIAL) && (rr == SUB_PUSH8);
    wire is_trap       = (op == OP_JMP_SPECIAL) && (rr == SUB_TRAP);
    wire illegal_slot1 = (slot == SLOT_BYTE1) && (is_link | is_push8 | is_trap);

    // Unified 64K TDP BRAM Storage
    reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    initial begin
        $readmemh("system_image.hex", mem);
    end

    wire is_mmio_rx = (port_b_addr == ADDR_UART_RX);
    wire is_mmio_tx = (port_b_addr == ADDR_UART_TX);
    wire is_mmio    = is_mmio_rx | is_mmio_tx;
    // Memory protection for upper 2K removed
    wire ram_b_we   = port_b_en && port_b_we && !is_mmio;

    // Port A (Instruction Fetch)
    
    // Modular MMIO Address Decodes (0x000D = CPUID, 0x000E = RX, 0x000F = TX)
    wire is_mmio_cpuid = ENABLE_CPUID && (port_b_addr == 16'h000D);
    wire is_mmio_rx    = ENABLE_UART  && (port_b_addr == 16'h000E);
    wire is_mmio_tx    = ENABLE_UART  && (port_b_addr == 16'h000F);
    wire is_mmio       = is_mmio_cpuid | is_mmio_rx | is_mmio_tx;

always @(posedge clk) begin
        if (port_a_en) begin
            port_a_rdata <= mem[port_a_addr];
        end
    end

    // Port B (Data & MMIO)
    always @(posedge clk) begin
        if (port_b_en) begin
            if (ram_b_we) begin
                mem[port_b_addr] <= port_b_wdata;
            end

            if (is_mmio_rx) begin
                port_b_rdata <= mmio_rx_data;
            end else if (is_mmio_tx) begin
                port_b_rdata <= mmio_tx_status;
            end else begin
                if (is_mmio_cpuid)
                port_b_rdata <= {12'h000, CORE_ID[3:0]};
            else
                port_b_rdata <= mem[port_b_addr];
            end
        end
    end

    always @(*) begin
        mmio_rx_pop = port_b_en && !port_b_we && is_mmio_rx;
    end

    // ALU Helpers
    function [DATA_WIDTH-1:0] rotl1(input [DATA_WIDTH-1:0] val);
        rotl1 = {val[DATA_WIDTH-2:0], val[DATA_WIDTH-1]};
    endfunction

    function [DATA_WIDTH-1:0] rotr1(input [DATA_WIDTH-1:0] val);
        rotr1 = {val[0], val[DATA_WIDTH-1:1]};
    endfunction

    function [DATA_WIDTH-1:0] asr1(input [DATA_WIDTH-1:0] val);
        asr1 = {val[DATA_WIDTH-1], val[DATA_WIDTH-1:1]};
    endfunction

    // FSM Control
    reg [STATE_WIDTH-1:0] state;

    task advance_slot_or_fetch;
        begin
            if (slot == SLOT_BYTE0) begin
                slot          <= SLOT_BYTE1;
                inst_reg[7:0] <= inst_reg[15:8];
                port_a_addr   <= pc + 16'd1;
                port_a_en     <= 1'b1;
                state         <= ST_EXEC;
            end else begin
                pc          <= pc + 16'd1;
                slot        <= SLOT_BYTE0;
                port_a_en   <= 1'b0;
                state       <= ST_EXEC;
            end
        end
    endtask

    task branch_to;
        input [ADDR_WIDTH-1:0] target_addr;
        begin
            pc          <= target_addr;
            port_a_addr <= target_addr;
            port_a_en   <= 1'b1;
            slot        <= SLOT_BYTE0;
            state       <= ST_EXEC;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_RESET;
            pc             <= {ADDR_WIDTH{1'b0}};
            slot           <= SLOT_BYTE0;
            dest_reg       <= {REG_ADDR_WIDTH{1'b0}};
            port_a_addr    <= {ADDR_WIDTH{1'b0}};
            port_a_en      <= 1'b0;
            port_b_addr    <= TRAP_TABLE_BASE;
            port_b_wdata   <= {DATA_WIDTH{1'b0}};
            port_b_we      <= 1'b0;
            port_b_en      <= 1'b1;
            mmio_tx_data   <= 8'h00;
            mmio_tx_strobe <= 1'b0;

            r[0]           <= {DATA_WIDTH{1'b0}};
            r[1]           <= {DATA_WIDTH{1'b0}};
            r[2]           <= {DATA_WIDTH{1'b0}};
            r[3]           <= {DATA_WIDTH{1'b0}};

            shadow_r[0]    <= {DATA_WIDTH{1'b0}};
            shadow_r[1]    <= {DATA_WIDTH{1'b0}};
            shadow_r[2]    <= {DATA_WIDTH{1'b0}};
            shadow_r[3]    <= {DATA_WIDTH{1'b0}};
        end else begin
            mmio_tx_strobe <= 1'b0;

            case (state)
                ST_RESET: begin
                    port_b_en   <= 1'b0;
                    pc          <= port_b_rdata;
                    port_a_addr <= port_b_rdata;
                    port_a_en   <= 1'b1;
                    slot        <= SLOT_BYTE0;
                    state       <= ST_EXEC;
                end

                ST_FETCH: begin
                    port_a_addr <= pc;
                    port_a_en   <= 1'b1;
                    slot        <= SLOT_BYTE0;
                    state       <= ST_EXEC;
                end

                ST_EXEC: begin
                    if (slot == SLOT_BYTE0) begin
                        inst_reg <= port_a_rdata;
                    end

                    port_b_en <= 1'b0;
                    port_b_we <= 1'b0;

                    if (illegal_slot1) begin
                        r[0]        <= pc + 16'd1;
                        port_b_addr <= TRAP_ALIGN_ADDR;
                        port_b_we   <= 1'b0;
                        port_b_en   <= 1'b1;
                        state       <= ST_TRAP_RD;
                    end else begin
                        case (op)
                            OP_LD_REG: begin
                                r[rr] <= r[rl];
                                advance_slot_or_fetch();
                            end

                            OP_LD_IMM4: begin
                                r[0] <= {12'h000, imm4};
                                advance_slot_or_fetch();
                            end

                            OP_LD_PEEK: begin
                                port_b_addr <= r[rl];
                                port_b_we   <= 1'b0;
                                port_b_en   <= 1'b1;
                                dest_reg    <= rr;
                                state       <= ST_MEM_RD;
                            end

                            OP_LD_POKE: begin
                                port_b_addr  <= r[rr];
                                port_b_wdata <= r[rl];
                                port_b_we    <= 1'b1;
                                port_b_en    <= 1'b1;

                                if (r[rr] == ADDR_UART_TX) begin
                                    mmio_tx_data   <= r[rl][7:0];
                                    mmio_tx_strobe <= 1'b1;
                                end
                                advance_slot_or_fetch();
                            end

                            OP_LD_POSTINC: begin
                                port_b_addr <= r[rl];
                                port_b_we   <= 1'b0;
                                port_b_en   <= 1'b1;
                                dest_reg    <= rr;
                                r[rl]       <= r[rl] + 16'd1;
                                state       <= ST_MEM_RD;
                            end

                            OP_LD_PREDEC: begin
                                r[rr]        <= r[rr] - 16'd1;
                                port_b_addr  <= r[rr] - 16'd1;
                                port_b_wdata <= r[rl];
                                port_b_we    <= 1'b1;
                                port_b_en    <= 1'b1;

                                if ((r[rr] - 16'd1) == ADDR_UART_TX) begin
                                    mmio_tx_data   <= r[rl][7:0];
                                    mmio_tx_strobe <= 1'b1;
                                end
                                advance_slot_or_fetch();
                            end

                            OP_ADD: begin
                                r[rr] <= r[rr] + r[rl];
                                advance_slot_or_fetch();
                            end

                            OP_SUB: begin
                                r[rr] <= r[rr] - r[rl];
                                advance_slot_or_fetch();
                            end

                            OP_OR: begin
                                r[rr] <= r[rr] | r[rl];
                                advance_slot_or_fetch();
                            end

                            OP_XOR: begin
                                r[rr] <= r[rr] ^ r[rl];
                                advance_slot_or_fetch();
                            end

                            OP_AND: begin
                                r[rr] <= r[rr] & r[rl];
                                advance_slot_or_fetch();
                            end

                            OP_SHIFT: begin
                                case (rr)
                                    SUB_SHIFT_L:      r[rl] <= r[rl] << 1;
                                    SUB_SHIFT_R:      r[rl] <= r[rl] >> 1;
                                    SUB_SHIFT_AR:     r[rl] <= asr1(r[rl]);
                                    SUB_SHIFT_XCHG: begin
                                        r[rl]        <= shadow_r[rl];
                                        shadow_r[rl] <= r[rl];
                                    end
                                endcase
                                advance_slot_or_fetch();
                            end

                            OP_ROT_INC_DEC: begin
                                case (rr)
                                    SUB_ROT_L: r[rl] <= rotl1(r[rl]);
                                    SUB_ROT_R: r[rl] <= rotr1(r[rl]);
                                    SUB_INC:   r[rl] <= r[rl] + 16'd1;
                                    SUB_DEC:   r[rl] <= r[rl] - 16'd1;
                                endcase
                                advance_slot_or_fetch();
                            end

                            OP_JMP_Z: begin
                                if (r[rl] == {DATA_WIDTH{1'b0}}) begin
                                    branch_to(r[rr]);
                                end else begin
                                    advance_slot_or_fetch();
                                end
                            end

                            OP_JMP_M: begin
                                if (r[rl][DATA_WIDTH-1] == 1'b1) begin
                                    branch_to(r[rr]);
                                end else begin
                                    advance_slot_or_fetch();
                                end
                            end

                            OP_JMP_SPECIAL: begin
                                case (rr)
                                    SUB_JMP: begin
                                        branch_to(r[rl]);
                                    end
                                    SUB_LINK: begin
                                        r[0] <= pc + 16'd1;
                                        branch_to(r[rl]);
                                    end
                                    SUB_PUSH8: begin
                                        r[rl] <= (r[rl] << 8) | port_a_rdata[15:8];
                                        branch_to(pc + 16'd1);
                                    end
                                    SUB_TRAP: begin
                                        port_b_addr <= TRAP_TABLE_BASE + (r[rl] & 16'h000F);
                                        r[0]        <= pc + 16'd1;
                                        port_b_we   <= 1'b0;
                                        port_b_en   <= 1'b1;
                                        state       <= ST_TRAP_RD;
                                    end
                                endcase
                            end
                        endcase
                    end
                end

                ST_MEM_RD: begin
                    port_b_en   <= 1'b0;
                    r[dest_reg] <= port_b_rdata;
                    advance_slot_or_fetch();
                end

                ST_TRAP_RD: begin
                    port_b_en <= 1'b0;
                    pc        <= port_b_rdata;
                    state     <= ST_FETCH;
                end

                default: state <= ST_RESET;
            endcase
        end
    end

endmodule

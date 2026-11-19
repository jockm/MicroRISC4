`timescale 1ns / 1ps
// =============================================================================
// FILE: hdl/verilog/mr4riscv_top.v
// Architecture: 5-Core Heterogeneous RV32IM Subsystem
// =============================================================================

module mr4riscv_top #(
    parameter CLK_FREQ_MHZ = 25,
    parameter CAS_LATENCY  = 2
  )(
    input  wire        clk,
    input  wire        rst_n,

    // Hardware UART connected directly to Core 3 (Mem/WB)
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

  // -------------------------------------------------------------------------
  // Core 0: Fetch (1024 words / 2 KB)
  // -------------------------------------------------------------------------
  cpu_core #(
             .CORE_ID           (0),
             .MEM_WORDS         (1024),
             .ADDR_WIDTH        (10),
             .TRAP_TABLE_BASE   (16'h0100),
             .ENABLE_CPUID      (1),
             .ENABLE_UART       (0),
             .ENABLE_CROSS_TRAPS(1),
             .ENABLE_SHADOW_REGS(1),
             .ENABLE_MATH_ACCEL (0)
           ) u_core0_fetch (
             .clk               (clk),
             .rst_n             (rst_n),
             .ext_trap_req      (core0_trap_req),
             .ext_trap_num      (core0_trap_num),
             .port_b_addr_out   (c0_port_b_addr),
             .port_b_wdata_out  (c0_port_b_wdata),
             .port_b_we_out     (c0_port_b_we),
             .port_b_en_out     (c0_port_b_en),
             .fifo_in_data      (c0_fifo_in_data)
           );

  // -------------------------------------------------------------------------
  // Core 1: Decode & Register File (1024 words / 2 KB)
  // -------------------------------------------------------------------------
  cpu_core #(
             .CORE_ID           (1),
             .MEM_WORDS         (1024),
             .ADDR_WIDTH        (10),
             .TRAP_TABLE_BASE   (16'h0100),
             .ENABLE_CPUID      (1),
             .ENABLE_UART       (0),
             .ENABLE_CROSS_TRAPS(1),
             .ENABLE_SHADOW_REGS(1),
             .ENABLE_MATH_ACCEL (0)
           ) u_core1_decode (
             .clk               (clk),
             .rst_n             (rst_n),
             .ext_trap_req      (core1_trap_req),
             .ext_trap_num      (core1_trap_num),
             .port_b_addr_out   (c1_port_b_addr),
             .port_b_wdata_out  (c1_port_b_wdata),
             .port_b_we_out     (c1_port_b_we),
             .port_b_en_out     (c1_port_b_en),
             .fifo_in_data      (c1_fifo_in_data)
           );

  // -------------------------------------------------------------------------
  // Core 2: Execute & Math Accelerator (1024 words / 2 KB)
  // -------------------------------------------------------------------------
  cpu_core #(
             .CORE_ID           (2),
             .MEM_WORDS         (1024),
             .ADDR_WIDTH        (10),
             .TRAP_TABLE_BASE   (16'h0100),
             .ENABLE_CPUID      (1),
             .ENABLE_UART       (0),
             .ENABLE_CROSS_TRAPS(1),
             .ENABLE_SHADOW_REGS(1),
             .ENABLE_MATH_ACCEL (1)         // <--- Math Engine enabled at 0x0010-0x0016
           ) u_core2_exec (
             .clk               (clk),
             .rst_n             (rst_n),
             .ext_trap_req      (core2_trap_req),
             .ext_trap_num      (core2_trap_num),
             .port_b_addr_out   (c2_port_b_addr),
             .port_b_wdata_out  (c2_port_b_wdata),
             .port_b_we_out     (c2_port_b_we),
             .port_b_en_out     (c2_port_b_en),
             .fifo_in_data      (c2_fifo_in_data)
           );

  // -------------------------------------------------------------------------
  // Core 3: Memory Access & Console UART (2048 words / 4 KB)
  // -------------------------------------------------------------------------
  cpu_core #(
             .CORE_ID           (3),
             .MEM_WORDS         (2048),
             .ADDR_WIDTH        (11),
             .TRAP_TABLE_BASE   (16'h0100),
             .ENABLE_CPUID      (1),
             .ENABLE_UART       (1),         // <--- Physical FTDI UART enabled at 0x000E/0x000F
             .ENABLE_CROSS_TRAPS(1),
             .ENABLE_SHADOW_REGS(1),
             .ENABLE_MATH_ACCEL (0)
           ) u_core3_mem_wb (
             .clk               (clk),
             .rst_n             (rst_n),
             .uart_rx           (uart_rx),
             .uart_tx           (uart_tx),
             .ext_trap_req      (core3_trap_req),
             .ext_trap_num      (core3_trap_num),
             .port_b_addr_out   (c3_port_b_addr),
             .port_b_wdata_out  (c3_port_b_wdata),
             .port_b_we_out     (c3_port_b_we),
             .port_b_en_out     (c3_port_b_en),
             .fifo_in_data      (c3_fifo_in_data)
           );

  // -------------------------------------------------------------------------
  // Core 4: Cache Controller & SDRAM PHY Interface (2048 words / 4 KB)
  // -------------------------------------------------------------------------
  cpu_core #(
             .CORE_ID           (4),
             .MEM_WORDS         (2048),
             .ADDR_WIDTH        (11),
             .TRAP_TABLE_BASE   (16'h0100),
             .ENABLE_CPUID      (1),
             .ENABLE_UART       (0),
             .ENABLE_CROSS_TRAPS(1),
             .ENABLE_SHADOW_REGS(1),
             .ENABLE_MATH_ACCEL (0)
           ) u_core4_cache_mgr (
             .clk               (clk),
             .rst_n             (rst_n),
             .ext_trap_req      (core4_trap_req),
             .ext_trap_num      (core4_trap_num),
             .port_b_addr_out   (c4_port_b_addr),
             .port_b_wdata_out  (c4_port_b_wdata),
             .port_b_we_out     (c4_port_b_we),
             .port_b_en_out     (c4_port_b_en),
             .mmio_ext_rdata    (core4_sdram_mmio_rdata) // 0x0010-0x0014 interface to PHY
           );

  // ... (Instantiate SDRAM Controller & Cross-Core Interconnect) ...

# Makefile for MiniRISC4 Verilog HDL & ULX3S Synthesis Flow
PROJ = ulx3s_cpu
TOP = ulx3s_top
DEVICE ?= 12k
PACKAGE ?= CABGA381

SRCS = ulx3s_top.v ulx3s_pll.v cpu_core.v
TESTS = test/tb_alu.v test/tb_mem_stack.v test/tb_control_flow.v test/tb_uart_mmio.v

all: $(PROJ).bit

test: $(TESTS) cpu_core.v
	@echo "=== Running Verilog Testbenches ==="
	iverilog -o sim_alu.vvp test/tb_alu.v cpu_core.v && vvp sim_alu.vvp
	iverilog -o sim_mem.vvp test/tb_mem_stack.v cpu_core.v && vvp sim_mem.vvp
	iverilog -o sim_ctrl.vvp test/tb_control_flow.v cpu_core.v && vvp sim_ctrl.vvp
	iverilog -o sim_uart.vvp test/tb_uart_mmio.v cpu_core.v && vvp sim_uart.vvp
	@rm -f sim_alu.vvp sim_mem.vvp sim_ctrl.vvp sim_uart.vvp
	@echo "=== All Verilog Tests Passed ==="

$(PROJ).json: $(SRCS) uart.v util.v system_image.hex
	yosys -p "synth_ecp5 -top $(TOP) -json $@" $(SRCS)

$(PROJ)_out.config: $(PROJ).json ulx3s.lpf
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --json $(PROJ).json --lpf ulx3s.lpf --textcfg $@

$(PROJ).bit: $(PROJ)_out.config
	ecppack --compress $< $@

prog: $(PROJ).bit
	ujprog $<

clean:
	rm -f $(PROJ).json $(PROJ)_out.config $(PROJ).bit sim_*.vvp

.PHONY: all test prog clean

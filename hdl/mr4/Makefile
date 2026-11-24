DART = dart
PROJ = ulx3s_top_rohd
TOP = ulx3s_top
DEVICE ?= 85k
PACKAGE ?= CABGA381

.PHONY: all setup test gen synth prog clean

all: synth

setup:
	$(DART) pub get

test: setup
	$(DART) test

gen: setup
	$(DART) run bin/generate.dart

$(PROJ).sv:
	$(MAKE) gen

synth: $(PROJ).sv
	yosys -p "read_verilog -sv $(PROJ).sv; synth_ecp5 -top $(TOP) -json $(PROJ).json"
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --json $(PROJ).json --lpf ulx3s.lpf --textcfg $(PROJ)_out.config
	ecppack --compress $(PROJ)_out.config $(PROJ).bit

prog: $(PROJ).bit
	ujprog $<

clean:
	rm -f $(PROJ).sv $(PROJ).json $(PROJ)_out.config $(PROJ).bit
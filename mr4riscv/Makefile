# ==============================================================================
# FILE: mr4riscv/Makefile
# Builds hex memory images and listings for all 5 pipeline stages via bin/assemble
# ==============================================================================

ASSEMBLE  = ../bin/assemble
BUILD_DIR = build
INCLUDES  = -I ../lib -I .

HEX_TARGETS = \
    $(BUILD_DIR)/fetch.hex \
    $(BUILD_DIR)/decode.hex \
    $(BUILD_DIR)/execute.hex \
    $(BUILD_DIR)/mem_wb.hex \
    $(BUILD_DIR)/cache_controller.hex

.PHONY: all clean

all: $(HEX_TARGETS)

# Core 0: Fetch Stage
$(BUILD_DIR)/fetch.hex: fetch.asm riscv_common.inc ../lib/common.inc
	$(ASSEMBLE) $(INCLUDES) --hex --trap-base 0x0100 $<

# Core 1: Decode & Register File Stage
$(BUILD_DIR)/decode.hex: decode.asm riscv_common.inc ../lib/common.inc
	$(ASSEMBLE) $(INCLUDES) --hex --trap-base 0x0100 $<

# Core 2: Execute & Math Accelerator Stage
$(BUILD_DIR)/execute.hex: execute.asm riscv_common.inc ../lib/common.inc
	$(ASSEMBLE) $(INCLUDES) --hex --trap-base 0x0100 $<

# Core 3: Memory Access, UART MMIO & Writeback Stage
$(BUILD_DIR)/mem_wb.hex: mem_wb.asm riscv_common.inc ../lib/common.inc
	$(ASSEMBLE) $(INCLUDES) --hex --trap-base 0x0100 $<

# Core 4: Cache Controller & SDRAM PHY Interface Stage
$(BUILD_DIR)/cache_controller.hex: cache_controller.asm riscv_common.inc ../lib/common.inc
	$(ASSEMBLE) $(INCLUDES) --hex --trap-base 0x0100 $<

clean:
	rm -rf $(BUILD_DIR)
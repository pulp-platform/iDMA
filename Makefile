GIT ?= git
BENDER ?= bender
VSIM ?= vsim
PYTHON ?= python3

all: sim_all

clean: sim_clean

# Ensure half-built targets are purged
.DELETE_ON_ERROR:

# --------------
# RTL SIMULATION
# --------------

VLOG_ARGS += -suppress vlog-2583 -suppress vlog-13314 -suppress vlog-13233 -timescale \"1 ns / 1 ps\"
XVLOG_ARGS += -64bit -compile -vtimescale 1ns/1ns -quiet

define generate_vsim
	echo 'set ROOT [file normalize [file dirname [info script]]/$3]' > $1
	bender script $(VSIM) --vlog-arg="$(VLOG_ARGS)" $2 | grep -v "set ROOT" >> $1
	echo >> $1
endef

sim_all: scripts/compile.tcl

sim_clean:
	rm -rf scripts/compile.tcl
	rm -rf work

scripts/compile.tcl: Bender.yml
	$(call generate_vsim, $@, -t rtl -t test,..)

# --------------
# TRACER
# --------------

trace:
	dma_trace_00000.txt

dma_trace_%.txt: scripts/dma_trace.py scripts/dma_backend.py
	$(PYTHON) $< dma_trace_$*.log > $@

REG_PATH ?= $(shell $(BENDER) path register_interface)
REG_TOOL ?= $(REG_PATH)/vendor/lowrisc_opentitan/util/regtool.py

REG32_2D_FE_DIR = src/frontends/register_32bit_2d/
REG32_2D_HJSON = $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend.hjson
REG64_FE_DIR = src/frontends/register_64bit/
REG64_HJSON = $(REG64_FE_DIR)/idma_reg64_frontend.hjson
DESC64_FE_DIR = src/frontends/desc64/
DESC64_HJSON = $(DESC64_FE_DIR)/idma_desc64_frontend.hjson

REG_HTML_STRING = "<!DOCTYPE html>\n<html>\n<head>\n<link rel="stylesheet" href="reg_html.css">\n</head>\n"

reg32_2d_regs:
	$(PYTHON) $(REG_TOOL) $(REG32_2D_HJSON) -t $(REG32_2D_FE_DIR) -r
	$(PYTHON) $(REG_TOOL) $(REG32_2D_HJSON) -D > $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend.h
	printf $(REG_HTML_STRING) > $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend.html
	$(PYTHON) $(REG_TOOL) $(REG32_2D_HJSON) -d >> $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend.html
	printf "</html>\n" >> $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend.html
	cp $(REG_PATH)/vendor/lowrisc_opentitan/util/reggen/reg_html.css $(REG32_2D_FE_DIR)

reg64_regs:
	$(PYTHON) $(REG_TOOL) $(REG64_HJSON) -t $(REG64_FE_DIR) -r
	$(PYTHON) $(REG_TOOL) $(REG64_HJSON) -D > $(REG64_FE_DIR)/idma_reg64_frontend.h
	printf $(REG_HTML_STRING) > $(REG64_FE_DIR)/idma_reg64_frontend.html
	$(PYTHON) $(REG_TOOL) $(REG64_HJSON) -d >> $(REG64_FE_DIR)/idma_reg64_frontend.html
	printf "</html>\n" >> $(REG64_FE_DIR)/idma_reg64_frontend.html
	cp $(REG_PATH)/vendor/lowrisc_opentitan/util/reggen/reg_html.css $(REG64_FE_DIR)

desc64_regs:
	$(PYTHON) $(REG_TOOL) $(DESC64_HJSON) -t $(DESC64_FE_DIR) -r
	$(PYTHON) $(REG_TOOL) $(DESC64_HJSON) -D > $(DESC64_FE_DIR)/idma_desc64_frontend.h
	printf $(REG_HTML_STRING) > $(DESC64_FE_DIR)/idma_desc64_frontend.html
	$(PYTHON) $(REG_TOOL) $(DESC64_HJSON) -d >> $(DESC64_FE_DIR)/idma_desc64_frontend.html
	printf "</html>\n" >> $(DESC64_FE_DIR)/idma_desc64_frontend.html
	cp $(REG_PATH)/vendor/lowrisc_opentitan/util/reggen/reg_html.css $(DESC64_FE_DIR)

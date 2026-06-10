# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Author: Daniel Keller <dankeller@iis.ee.ethz.ch>
#
# Standalone build + sim flow for the Snitch inst64 integration. Elaborates the
# upstream single-head idma_inst64_top + the recycled harness against iDMA's own
# deps (axi, common_cells, common_verification). Uses the split_rtl compute-
# enabled rw_axi backend (the bundled idma_generated.sv predates opt.compute).

SNITCH_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
IDMA_ROOT  := $(realpath $(SNITCH_DIR)/../..)
BENDER     ?= bender
VSIM       ?= questa-2023.4 vsim

BUILD      := $(SNITCH_DIR)/build
TARGETS    := -t rtl -t split_rtl -t snitch_cluster -t idma_test -t test
TOP        ?= tb_idma_inst64_copy

# Transpose end-to-end sweep: shapes across all element sizes (int8/fp16/fp32),
# single/multi-tile, edge, exact-multiple (zero padding), and the NE=StrbWidth
# in-flight boundary. Each mode (EB=1/2/4) gets single-tile + aligned-multi-tile
# + edge-multi-tile coverage.
TP_SWEEP := 8,8,4 40,70,4 48,16,4 \
            32,32,2 50,40,2 96,96,2 70,96,2 \
            64,64,1 130,80,1 128,64,1 256,96,1

.PHONY: snitch_sim snitch_compile snitch_transpose_sweep snitch_clean
snitch_sim: snitch_compile
	cd $(BUILD) && $(VSIM) -c $(TOP)_opt -do "run -all; quit"

snitch_transpose_sweep: $(BUILD)/compile_snitch.tcl
	@for cfg in $(TP_SWEEP); do \
	  m=$${cfg%%,*}; r=$${cfg#*,}; n=$${r%%,*}; e=$${r##*,}; \
	  cd $(BUILD) && $(VSIM) -c -do \
	    "source compile_snitch.tcl; vopt +acc tb_idma_inst64_transpose -gM=$$m -gN=$$n -gEB=$$e -o tb_sw; quit" \
	    >/dev/null 2>&1; \
	  printf '%-14s ' "$$m x $$n EB=$$e:"; \
	  $(VSIM) -c tb_sw -do "run -all; quit" 2>&1 | grep -E '\[TP\] (PASS|FAIL)' | sed 's/# //'; \
	done

snitch_compile: $(BUILD)/compile_snitch.tcl
	cd $(BUILD) && $(VSIM) -c -do \
	  "source compile_snitch.tcl; vopt +acc $(TOP) -o $(TOP)_opt; quit"

$(BUILD)/compile_snitch.tcl: | $(BUILD)
	$(MAKE) -C $(IDMA_ROOT) idma_hw_all
	cd $(IDMA_ROOT) && $(BENDER) script vsim $(TARGETS) \
	  --vlog-arg="-svinputport=compat" > $@

$(BUILD):
	mkdir -p $(BUILD)

snitch_clean:
	rm -rf $(BUILD)

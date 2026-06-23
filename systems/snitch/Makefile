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

.PHONY: snitch_sim snitch_compile snitch_transpose snitch_clean
snitch_sim: snitch_compile
	cd $(BUILD) && $(VSIM) -c $(TOP)_opt -do "run -all; quit"

# Transpose end-to-end: the TB sweeps the geometry list (M/N/EB) internally; one
# run per structural config (BankSkew off/on).
snitch_transpose: $(BUILD)/compile_snitch.tcl
	@for sk in 0 1; do \
	  cd $(BUILD) && $(VSIM) -c -do \
	    "source compile_snitch.tcl; vopt +acc tb_idma_inst64_transpose -gBankSkew=$$sk -o tb_tp; quit" \
	    >/dev/null 2>&1; \
	  printf 'BankSkew=%s: ' $$sk; \
	  $(VSIM) -c tb_tp -do "run -all; quit" 2>&1 | grep -E '\[TP\] (PASS|FAIL)' | sed 's/# //'; \
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

# Copyright 2026 Mosaic SoC AG
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Generic Verilator build and run plumbing. Testbench-specific variants,
# elaboration parameters, and runtime arguments belong in separate
# configuration fragments.

IDMA_VLT_DIR := $(abspath $(IDMA_ROOT)/target/sim/vlt)
IDMA_VLT_FILELIST_TMP_DIR := $(IDMA_VLT_DIR)/.tmp

IDMA_TRACE ?= $(TRACE)

IDMA_VLT_BENDER_ARGS := \
	-t test \
	-t idma_test \
	-t rtl \
	-t synth \
	-t simulation \
	-t snitch_cluster

IDMA_VLT_ARGS ?= \
	--assert \
	--binary \
	--error-limit 1000 \
	--timing \
	--timescale 1ns/1ps \
	-Wno-fatal

# Optional flags for Verilator's generated C++ compilation and final link.
IDMA_VLT_CFLAGS ?=
IDMA_VLT_LDFLAGS ?=

ifeq ($(IDMA_TRACE), 1)
IDMA_VLT_ARGS += --trace-fst
endif

ifeq ($(IDMA_TRACE), 2)
IDMA_VLT_ARGS += --trace-fst --trace-structs
endif
# Configuration names use "<top>__<variant>". The explicit separator keeps
# top extraction independent of the underscores commonly used in module names.
idma_vlt_top = $(word 1,$(subst __, ,$(1)))
idma_vlt_configs = $(addprefix $(1)__,$(IDMA_VLT_SUFFIXES_$(1)))

IDMA_VLT_CONFIGS := $(strip $(foreach testbench,$(IDMA_VLT_TESTBENCHES),\
	$(call idma_vlt_configs,$(testbench))))

# Make cannot inspect the sources named by the Verilator file list. Use
# Bender's plain file list for source dependencies and conservatively track all
# Verilog headers in this package and its checked-out dependencies.
IDMA_VLT_SOURCES := $(shell \
	$(BENDER) script flist $(IDMA_VLT_BENDER_ARGS))
IDMA_VLT_HEADERS := $(shell \
	find $(IDMA_ROOT)/src $(IDMA_ROOT)/target/rtl/include $(IDMA_ROOT)/test \
		$(IDMA_ROOT)/.bender/git/checkouts -type f \
		\( -name '*.svh' -o -name '*.vh' \) 2>/dev/null)

# Bender records the DPI model but omits C sources from both its Verilator
# script and plain file list, so pass this shared source to Verilator directly.
IDMA_VLT_DPI_SOURCES := $(IDMA_ROOT)/test/idma_transpose_dpi.c

.PHONY: idma_vlt_force
idma_vlt_force:

.PRECIOUS: $(IDMA_VLT_DIR)/build-%/vlt-sources.flist

# Regenerate a configuration-specific candidate filelist on every invocation.
# The temporary files share one directory but retain the configuration name so
# parallel builds cannot overwrite each other. rsync preserves the stable
# build-local file's timestamp when its contents did not change.
$(IDMA_VLT_DIR)/build-%/vlt-sources.flist: \
		idma_vlt_force \
		$(IDMA_FULL_RTL) \
		$(IDMA_FULL_TB) \
		$(IDMA_INCLUDE_ALL)
	mkdir -p $(@D)
	mkdir -p $(IDMA_VLT_FILELIST_TMP_DIR)
	$(BENDER) script verilator \
		$(IDMA_VLT_BENDER_ARGS) \
		> $(IDMA_VLT_FILELIST_TMP_DIR)/$*.flist
	rsync -c $(IDMA_VLT_FILELIST_TMP_DIR)/$*.flist $@
	rm -f $(IDMA_VLT_FILELIST_TMP_DIR)/$*.flist

$(IDMA_VLT_DIR)/build-%/vlt.bin: \
		$(IDMA_VLT_DIR)/build-%/vlt-sources.flist \
		$(IDMA_VLT_SOURCES) \
		$(IDMA_VLT_HEADERS) \
		$(IDMA_VLT_DPI_SOURCES) \
		$(IDMA_INCLUDE_ALL)
	$(VERILATOR) \
		-f $(@D)/vlt-sources.flist \
		$(IDMA_VLT_DPI_SOURCES) \
		$(IDMA_VLT_ARGS) \
		$(if $(IDMA_VLT_CFLAGS),-CFLAGS "$(IDMA_VLT_CFLAGS)") \
		$(if $(IDMA_VLT_LDFLAGS),-LDFLAGS "$(IDMA_VLT_LDFLAGS)") \
		$(IDMA_VLT_ELAB_ARGS_$*) \
		--top-module $(call idma_vlt_top,$*) \
		--Mdir $(@D)/obj_dir \
		-o $(abspath $@)

define idma_vlt_define_run_target
.PHONY: idma_vlt_run_$(1)
idma_vlt_run_$(1): $(IDMA_VLT_DIR)/build-$(1)/vlt.bin
	$$< $$(IDMA_VLT_RUN_ARGS_$(1))
endef

$(foreach config,$(IDMA_VLT_CONFIGS),\
	$(eval $(call idma_vlt_define_run_target,$(config))))

# Friendly per-testbench targets run every suffix declared for that top.
define idma_vlt_define_testbench_target
.PHONY: idma_sim_vlt_$(1)
idma_sim_vlt_$(1): $$(addprefix idma_vlt_run_,$$(call idma_vlt_configs,$(1)))
endef

$(foreach testbench,$(IDMA_VLT_TESTBENCHES),\
	$(eval $(call idma_vlt_define_testbench_target,$(testbench))))

IDMA_VLT_TB_TARGETS := $(addprefix idma_sim_vlt_,$(IDMA_VLT_TESTBENCHES))

.PHONY: idma_sim_vlt_all
idma_sim_vlt_all: $(IDMA_VLT_TB_TARGETS)

.PHONY: idma_vlt_clean idma_verilator_clean
idma_vlt_clean idma_verilator_clean:
	rm -rf $(IDMA_VLT_DIR)/build-*
	rm -rf $(IDMA_VLT_FILELIST_TMP_DIR)

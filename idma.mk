# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

BENDER      ?= bender
CAT         ?= cat
CC          ?= cc
GIT         ?= git
PRINTF      ?= printf
UV          ?= uv
VCS         ?= vcs
VERILATOR   ?= verilator
VLOGAN      ?= vlogan
VSIM        ?= vsim
VLOG        ?= vlog
VLIB        ?= vlib

# iDMA root, resolved via bender so integrators can host iDMA anywhere
IDMA_ROOT   ?= $(shell $(BENDER) path idma)

# All generator/doc tooling runs through uv against the locked environment
# (pyproject.toml + uv.lock are the single source of truth).
UV_RUN      := $(UV) run --locked --project $(IDMA_ROOT)
PYTHON      ?= $(UV_RUN) python
PEAKRDL     ?= $(UV_RUN) peakrdl
NPM         ?= npm

# Shell
SHELL := /bin/bash

# iDMA Variants
IDMA_BASE_IDS    := \
					rw_axi \
					r_obi_w_axi \
					r_axi_w_obi \
					rw_axi_rw_axis \
					rw_obi
IDMA_OCCAMY_IDS  := \
					r_obi_rw_init_w_axi \
					r_axi_rw_init_rw_obi \
					rw_axi_rw_init_rw_obi
# The ids the tracked aggregates cover. Literal on purpose: growing or shrinking the
# tracked set is an edit to this file, which every aggregate depends on, so make sees
# it. Overriding it - or IDMA_BACKEND_IDS - from the command line is not supported
# without a preceding idma_rtl_clean; IDMA_ADD_IDS is the supported extension knob.
IDMA_TREE_IDS    := $(IDMA_BASE_IDS) $(IDMA_OCCAMY_IDS)
IDMA_ADD_IDS     ?=
IDMA_BACKEND_IDS ?= $(IDMA_TREE_IDS) $(IDMA_ADD_IDS)

# generated frontends
IDMA_BASE_FE_IDS := reg32_3d reg64_2d reg64_1d
IDMA_ADD_FE_IDS  ?=
IDMA_FE_IDS      ?= $(IDMA_BASE_FE_IDS) $(IDMA_ADD_FE_IDS)

# iDMA paths
IDMA_UTIL_DIR := $(IDMA_ROOT)/util
IDMA_RTL_DIR  := $(IDMA_ROOT)/target/rtl
IDMA_SW_DIR  := $(IDMA_ROOT)/target/sw

# job file
IDMA_JOBS_JSON := jobs/jobs.json

# Bender files
IDMA_BENDER_FILES := $(IDMA_ROOT)/Bender.yml \
					 $(IDMA_ROOT)/Bender.lock

# Helper functions
# Relative paths for VLOGAN
IDMA_VLOGAN_REL_PATHS    := | grep -v "ROOT=" | sed '3 i ROOT="../../.."'

# Ensure half-built targets are purged
.DELETE_ON_ERROR:


# --------------
# RTL
# --------------

.PHONY: idma_rtl_clean

# All RTL files
IDMA_INCLUDE_ALL :=
IDMA_RTL_ALL     :=
IDMA_PICKLE_ALL  :=
IDMA_TB_ALL      :=
IDMA_WAVE_ALL    :=
IDMA_RTL_DOC_ALL :=

# Generated cumulative RTL files
IDMA_FULL_RTL   := $(IDMA_RTL_DIR)/idma_generated.sv
IDMA_FULL_TB    := $(IDMA_RTL_DIR)/tb_idma_generated.sv
IDMA_ADD_RTL    := $(IDMA_RTL_DIR)/idma_generated_add.sv
IDMA_ADD_TB     := $(IDMA_RTL_DIR)/tb_idma_generated_add.sv

IDMA_GEN        := $(IDMA_UTIL_DIR)/gen_idma.py
IDMA_GEN_SRC    := $(IDMA_UTIL_DIR)/mario/backend.py \
				   $(IDMA_UTIL_DIR)/mario/database.py \
				   $(IDMA_UTIL_DIR)/mario/frontend.py \
				   $(IDMA_UTIL_DIR)/mario/legalizer.py \
				   $(IDMA_UTIL_DIR)/mario/synth.py \
				   $(IDMA_UTIL_DIR)/mario/testbench.py \
				   $(IDMA_UTIL_DIR)/mario/tracer.py \
				   $(IDMA_UTIL_DIR)/mario/transport_layer.py \
				   $(IDMA_UTIL_DIR)/mario/util.py \
				   $(IDMA_UTIL_DIR)/mario/wave.py
IDMA_DB_DIR     := $(IDMA_ROOT)/src/db
IDMA_DB_FILES   := $(IDMA_DB_DIR)/idma_axi.yml \
                   $(IDMA_DB_DIR)/idma_axi_lite.yml \
                   $(IDMA_DB_DIR)/idma_axi_stream.yml \
                   $(IDMA_DB_DIR)/idma_init.yml \
                   $(IDMA_DB_DIR)/idma_obi.yml \
                   $(IDMA_DB_DIR)/idma_tilelink.yml
IDMA_RTL_FILES  := $(IDMA_RTL_DIR)/idma_transport_layer \
				   $(IDMA_RTL_DIR)/idma_legalizer \
				   $(IDMA_RTL_DIR)/idma_backend \
				   $(IDMA_RTL_DIR)/idma_backend_synth
IDMA_VSIM_DIR   := $(IDMA_ROOT)/target/sim/vsim

define idma_gen
	$(PYTHON) $(IDMA_GEN) --entity $1 --tpl $2 --db $3 --ids $4 --fids $5 $(if $7,--cpuif $7) > $6
endef

$(IDMA_RTL_DIR)/idma_transport_layer_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_ROOT)/src/backend/tpl/idma_transport_layer.sv.tpl $(IDMA_DB_FILES)
	$(call idma_gen,transport,$(IDMA_ROOT)/src/backend/tpl/idma_transport_layer.sv.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_RTL_DIR)/idma_legalizer_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_ROOT)/src/backend/tpl/idma_legalizer.sv.tpl $(IDMA_DB_FILES)
	$(call idma_gen,legalizer,$(IDMA_ROOT)/src/backend/tpl/idma_legalizer.sv.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_RTL_DIR)/idma_backend_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_RTL_DIR)/idma_legalizer_%.sv $(IDMA_RTL_DIR)/idma_transport_layer_%.sv $(IDMA_ROOT)/src/backend/tpl/idma_backend.sv.tpl $(IDMA_DB_FILES)
	$(call idma_gen,backend,$(IDMA_ROOT)/src/backend/tpl/idma_backend.sv.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_RTL_DIR)/idma_backend_synth_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_RTL_DIR)/idma_backend_%.sv $(IDMA_ROOT)/src/backend/tpl/idma_backend_synth.sv.tpl $(IDMA_DB_FILES)
	$(call idma_gen,synth_wrapper,$(IDMA_ROOT)/src/backend/tpl/idma_backend_synth.sv.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_RTL_DIR)/tb_idma_backend_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_RTL_DIR)/idma_backend_%.sv $(IDMA_ROOT)/test/tpl/tb_idma_backend.sv.tpl $(IDMA_DB_FILES)
	$(call idma_gen,testbench,$(IDMA_ROOT)/test/tpl/tb_idma_backend.sv.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_VSIM_DIR)/wave/backend_%.do: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_RTL_DIR)/tb_idma_backend_%.sv $(IDMA_VSIM_DIR)/wave/tpl/backend.do.tpl
	$(call idma_gen,vsim_wave,$(IDMA_VSIM_DIR)/wave/tpl/backend.do.tpl,$(IDMA_DB_FILES),$*,,$@)

IDMA_INC_DIR    := $(IDMA_RTL_DIR)/include/idma
IDMA_INC_TPL    := $(IDMA_ROOT)/src/include/idma/tpl

# The id-independent tracer helpers; a pure function of their own template
$(IDMA_INC_DIR)/tracer.svh: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_INC_TPL)/tracer.svh.tpl
	mkdir -p $(@D)
	$(call idma_gen,tracer_common,$(IDMA_INC_TPL)/tracer.svh.tpl,,,,$@)

# One tracer macro per backend id. The content is a function of the id in the target
# name, the databases and the template only, so "up to date" implies "correct" and no
# id-list state has to be recorded anywhere.
$(IDMA_INC_DIR)/tracer_%.svh: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_INC_TPL)/tracer_id.svh.tpl $(IDMA_DB_FILES)
	mkdir -p $(@D)
	$(call idma_gen,tracer,$(IDMA_INC_TPL)/tracer_id.svh.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_INC_DIR)/compute.svh: $(IDMA_ROOT)/src/frontend/reg/tpl/compute.svh.tpl $(IDMA_ROOT)/src/frontend/reg/idma_reg.rdl
	mkdir -p $(IDMA_INC_DIR)
	$(PEAKRDL) raw-header $(IDMA_ROOT)/src/frontend/reg/idma_reg.rdl \
	  --template $(IDMA_ROOT)/src/frontend/reg/tpl/compute.svh.tpl -o $@

idma_rtl_clean:
	rm -f  $(IDMA_RTL_DIR)/Bender.yml
	rm -f  $(IDMA_RTL_DIR)/*.sv
	rm -f  $(IDMA_VSIM_DIR)/wave/*.do
	rm -rf $(IDMA_INC_DIR)

# assemble the required files
IDMA_INCLUDE_ALL += $(IDMA_INC_DIR)/tracer.svh
IDMA_INCLUDE_ALL += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_INC_DIR)/tracer_$Y.svh)
IDMA_INCLUDE_ALL += $(IDMA_INC_DIR)/compute.svh

# The tracked aggregates below concatenate the tree ids only; out-of-tree ids are
# collected separately so no command-line variable can change what they contain.
IDMA_TREE_RTL_ALL := $(foreach X,$(IDMA_RTL_FILES),$(foreach Y,$(IDMA_TREE_IDS),$X_$Y.sv))
IDMA_ADD_RTL_ALL  := $(foreach X,$(IDMA_RTL_FILES),$(foreach Y,$(IDMA_ADD_IDS),$X_$Y.sv))
IDMA_TREE_TB_ALL  := $(foreach Y,$(IDMA_TREE_IDS),$(IDMA_RTL_DIR)/tb_idma_backend_$Y.sv)
IDMA_ADD_TB_ALL   := $(foreach Y,$(IDMA_ADD_IDS),$(IDMA_RTL_DIR)/tb_idma_backend_$Y.sv)
IDMA_WAVE_ALL     += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_VSIM_DIR)/wave/backend_$Y.do)


# --------------
# Register
# --------------

.PHONY: idma_reg_clean

IDMA_DOC_FIG_DIR := $(IDMA_ROOT)/doc/fig
IDMA_DOC_OUT_DIR := $(IDMA_ROOT)/target/doc
IDMA_HTML_DIR    := $(IDMA_DOC_OUT_DIR)/html
IDMA_FE_DIR      := $(IDMA_ROOT)/src/frontend
IDMA_FE_REGS      := desc64
IDMA_FE_REGS      += $(IDMA_FE_IDS)
IDMA_TREE_FE_REGS := desc64 $(IDMA_BASE_FE_IDS)

# Config-bus CPUIF for the register frontend: PeakRDL regblock --cpuif + matching wrapper
# packing. apb4-flat (default, industry standard); also obi-flat / passthrough / axi4-lite-flat.
IDMA_REG_CPUIF   ?= apb4-flat


regwidth = $(word 1,$(subst _, ,$1))
dimension = $(word 2,$(subst _, ,$1))
log2dimension = $(shell echo $$(( $$( echo "obase=2;$$(($(1)-1))" | bc | wc -c ) - 1 )) )

# Shared SPDX license header (raw-header takes plain text; c-header gets the //-prefixed variant)
IDMA_LICENSE   := Copyright 2026 ETH Zurich and University of Bologna.\nSolderpad Hardware License, Version 0.51, see LICENSE for details.\nSPDX-License-Identifier: SHL-0.51
IDMA_C_HDR_LIC := // $(subst \n,\n// ,$(IDMA_LICENSE))\n

$(IDMA_RTL_DIR)/idma_reg%d_reg_pkg.sv $(IDMA_RTL_DIR)/idma_reg%d_reg_top.sv $(IDMA_RTL_DIR)/idma_reg%d_addrmap_pkg.sv:
	$(PEAKRDL) regblock $(IDMA_FE_DIR)/reg/idma_reg.rdl -o $(IDMA_RTL_DIR) \
	  --default-reset arst_n --cpuif $(IDMA_REG_CPUIF) \
	  --module-name idma_reg$*d_reg_top \
	  --package idma_reg$*d_reg_pkg \
	  -P SysAddrWidth=$(call regwidth,$*) \
	  -P NumDims=$(call dimension,$*) \
	  -P Log2NumDims=$(call log2dimension,$(call dimension,$*))
	$(PEAKRDL) raw-header $(IDMA_FE_DIR)/reg/idma_reg.rdl \
	  --format svpkg \
	  -o $(IDMA_RTL_DIR)/idma_reg$*d_addrmap_pkg.sv \
	  --base_name idma_reg$*d \
	  --license_str="Copyright 2025 ETH Zurich and University of Bologna.\nSolderpad Hardware License, Version 0.51, see LICENSE for details.\nSPDX-License-Identifier: SHL-0.51" \
	  -P SysAddrWidth=$(call regwidth,$*) \
	  -P NumDims=$(call dimension,$*) \
	  -P Log2NumDims=$(call log2dimension,$(call dimension,$*))

$(IDMA_RTL_DIR)/idma_desc64_reg_pkg.sv $(IDMA_RTL_DIR)/idma_desc64_reg_top.sv $(IDMA_RTL_DIR)/idma_desc64_addrmap_pkg.sv:
	# desc64 has static, hand-written APB reg wrappers (idma_desc64_reg_wrapper.sv); it is
	# APB-native and not part of the CPUIF selector — keep its reg_top apb4-flat.
	$(PEAKRDL) regblock $(IDMA_FE_DIR)/desc64/idma_desc64_reg.rdl -o $(IDMA_RTL_DIR) \
	  --default-reset arst_n --cpuif apb4-flat \
	  --module-name idma_desc64_reg_top \
	  --package idma_desc64_reg_pkg
	$(PEAKRDL) raw-header $(IDMA_FE_DIR)/desc64/idma_desc64_reg.rdl \
	  --format svpkg \
	  -o $(IDMA_RTL_DIR)/idma_desc64_addrmap_pkg.sv \
	  --base_name idma_desc64 \
	  --license_str="Copyright 2025 ETH Zurich and University of Bologna.\nSolderpad Hardware License, Version 0.51, see LICENSE for details.\nSPDX-License-Identifier: SHL-0.51"

$(IDMA_RTL_DIR)/idma_%_top.sv: $(IDMA_GEN) $(IDMA_FE_DIR)/reg/tpl/idma_reg.sv.tpl
	$(call idma_gen,reg_top,$(IDMA_FE_DIR)/reg/tpl/idma_reg.sv.tpl,,,$*,$@,$(if $(filter desc64,$*),apb4-flat,$(IDMA_REG_CPUIF)))

$(IDMA_HTML_DIR)/regs/idma_reg%d_reg/index.html:
	$(PEAKRDL) html $(IDMA_FE_DIR)/reg/idma_reg.rdl -o $(IDMA_HTML_DIR)/regs/idma_reg$*d_reg \
	  -P SysAddrWidth=$(call regwidth,$*) \
	  -P NumDims=$(call dimension,$*) \
	  -P Log2NumDims=$(call log2dimension,$(call dimension,$*))

$(IDMA_HTML_DIR)/regs/idma_desc64_reg/index.html:
	$(PEAKRDL) html $(IDMA_FE_DIR)/desc64/idma_desc64_reg.rdl -o $(IDMA_HTML_DIR)/regs/idma_desc64_reg

# C header
$(IDMA_SW_DIR)/idma_reg%d_regs.h :
	$(PEAKRDL) c-header $(IDMA_FE_DIR)/reg/idma_reg.rdl -o $@ \
	  -b ltoh --type-style hier --rename idma_reg$*d \
	  -P SysAddrWidth=$(call regwidth,$*) \
	  -P NumDims=$(call dimension,$*) \
	  -P Log2NumDims=$(call log2dimension,$(call dimension,$*))
	sed -i '1i$(IDMA_C_HDR_LIC)' $@

$(IDMA_SW_DIR)/idma_reg%d_regs_unpacked.h : $(IDMA_SW_DIR)/idma_reg%d_regs.h
# with `packed` structs, the compiler may get confused and generate byte loads/stores to access fields.
	sed -e "s/__attribute__ ((__packed__)) //" $^ > $@


$(IDMA_SW_DIR)/idma_reg%d_raw_regs.h:
	$(PEAKRDL) raw-header $(IDMA_FE_DIR)/reg/idma_reg.rdl -o $@ \
	  --format c \
	  --license_str="$(IDMA_LICENSE)" \
	  -P SysAddrWidth=$(call regwidth,$*) \
	  -P NumDims=$(call dimension,$*) \
	  -P Log2NumDims=$(call log2dimension,$(call dimension,$*))


$(IDMA_SW_DIR)/idma_desc64_regs.h:
	$(PEAKRDL) c-header $(IDMA_FE_DIR)/desc64/idma_desc64_reg.rdl -o $@ \
	  -b ltoh --type-style hier --rename idma_desc64
	sed -i '1i$(IDMA_C_HDR_LIC)' $@
$(IDMA_SW_DIR)/idma_desc64_regs_unpacked.h: $(IDMA_SW_DIR)/idma_desc64_regs.h
	sed -e "s/__attribute__ ((__packed__)) //" $< > $@
$(IDMA_SW_DIR)/idma_desc64_raw_regs.h:
	$(PEAKRDL) raw-header $(IDMA_FE_DIR)/desc64/idma_desc64_reg.rdl -o $@ \
	  --format c --base_name idma_desc64 \
	  --license_str="$(IDMA_LICENSE)"

idma_reg_clean:
	rm -rf $(IDMA_HTML_DIR)/regs
	rm -f  $(IDMA_RTL_DIR)/*_reg_top.sv
	rm -f  $(IDMA_RTL_DIR)/*_reg_pkg.sv
	rm -f  $(IDMA_RTL_DIR)/Bender.yml
	rm -f  $(IDMA_REG_CUST_ALL)

# assemble the required files
IDMA_TREE_RTL_ALL += $(foreach Y,$(IDMA_TREE_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_reg_pkg.sv)
IDMA_TREE_RTL_ALL += $(foreach Y,$(IDMA_TREE_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_reg_top.sv)
IDMA_TREE_RTL_ALL += $(foreach Y,$(IDMA_TREE_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_addrmap_pkg.sv)
IDMA_TREE_RTL_ALL += $(foreach Y,$(IDMA_TREE_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_top.sv)
IDMA_ADD_RTL_ALL  += $(foreach Y,$(IDMA_ADD_FE_IDS),$(IDMA_RTL_DIR)/idma_$Y_reg_pkg.sv)
IDMA_ADD_RTL_ALL  += $(foreach Y,$(IDMA_ADD_FE_IDS),$(IDMA_RTL_DIR)/idma_$Y_reg_top.sv)
IDMA_ADD_RTL_ALL  += $(foreach Y,$(IDMA_ADD_FE_IDS),$(IDMA_RTL_DIR)/idma_$Y_addrmap_pkg.sv)
IDMA_ADD_RTL_ALL  += $(foreach Y,$(IDMA_ADD_FE_IDS),$(IDMA_RTL_DIR)/idma_$Y_top.sv)
IDMA_RTL_DOC_ALL  += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_HTML_DIR)/regs/idma_$Y_reg/index.html)

# C headers
IDMA_SW_ALL      += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_SW_DIR)/idma_$Y_regs.h)
IDMA_SW_ALL      += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_SW_DIR)/idma_$Y_regs_unpacked.h)

# C headers with the "raw-header" plugin
IDMA_SW_ALL      += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_SW_DIR)/idma_$Y_raw_regs.h)

# ---------------
# RTL assembly
# ---------------

IDMA_RTL_ALL += $(IDMA_TREE_RTL_ALL) $(IDMA_ADD_RTL_ALL)
IDMA_TB_ALL  += $(IDMA_TREE_TB_ALL) $(IDMA_ADD_TB_ALL)

# Bender hardcodes the two names below, so both files stay a cat of a per-id set. A
# set that shrinks is invisible to make - every remaining part is older than the
# target - hence the tracked aggregates take their id list from the literal
# IDMA_TREE_IDS and depend on the file that spells it out.
$(IDMA_FULL_RTL): $(IDMA_TREE_RTL_ALL) $(IDMA_ROOT)/idma.mk
	$(CAT) $(IDMA_TREE_RTL_ALL) > $@

$(IDMA_FULL_TB): $(IDMA_TREE_TB_ALL) $(IDMA_ROOT)/idma.mk
	$(CAT) $(IDMA_TREE_TB_ALL) > $@

# Out-of-tree IDMA_ADD_IDS variants, reached through the add_ids bender target only.
# Not part of idma_hw_all: IDMA_ADD_IDS is a command-line knob, so make cannot see
# its set shrink and this pair carries the one staleness make cannot express. Ask for
# it explicitly (idma_add_all) and it is exact; a set that shrinks between two such
# builds leaves the dropped variant behind until idma_rtl_clean. Nothing a tracked
# build parses can reach these files.
$(IDMA_ADD_RTL): $(IDMA_ADD_RTL_ALL) $(IDMA_ROOT)/idma.mk
	$(CAT) /dev/null $(IDMA_ADD_RTL_ALL) > $@

$(IDMA_ADD_TB): $(IDMA_ADD_TB_ALL) $(IDMA_ROOT)/idma.mk
	$(CAT) /dev/null $(IDMA_ADD_TB_ALL) > $@


# ---------------
# Pickle
# ---------------

.PHONY: idma_pickle_clean

IDMA_PICKLE_DIR     := $(IDMA_ROOT)/target/pickle
IDMA_PICKLE_TARGETS := -t rtl -t synth -t asic -t snitch_cluster -t cc_no_deprecated
IDMA_PICKLE_ARGS    ?=

$(IDMA_PICKLE_DIR)/%.sv: $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_PICKLE_DIR)
	$(BENDER) pickle $(IDMA_PICKLE_TARGETS) --top $* --expand-macros $(IDMA_PICKLE_ARGS) -o $@

# hierarchy graphs
IDMA_DOT     ?= dot
IDMA_AST2DOT := $(IDMA_UTIL_DIR)/ast2dot.py

$(IDMA_PICKLE_DIR)/%.dot: $(IDMA_AST2DOT) $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_PICKLE_DIR)
	set -o pipefail; $(BENDER) pickle $(IDMA_PICKLE_TARGETS) --top $* --expand-macros --ast-json | \
		$(PYTHON) $(IDMA_AST2DOT) - --top $* -o $@

$(IDMA_DOC_FIG_DIR)/graph/%.png: $(IDMA_PICKLE_DIR)/%.dot
	mkdir -p $(IDMA_DOC_FIG_DIR)/graph
	$(IDMA_DOT) -Tpng $< > $@

idma_pickle_clean:
	rm -rf $(IDMA_PICKLE_DIR)
	rm -f  $(IDMA_DOC_FIG_DIR)/graph/*.png

# 1Ds
IDMA_RTL_DOC_ALL += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_DOC_FIG_DIR)/graph/idma_backend_synth_$Y.png)
IDMA_PICKLE_ALL  += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_PICKLE_DIR)/idma_backend_synth_$Y.sv)

# nDs
IDMA_RTL_DOC_ALL += $(IDMA_DOC_FIG_DIR)/graph/idma_nd_midend_synth.png
IDMA_PICKLE_ALL  += $(IDMA_PICKLE_DIR)/idma_nd_midend_synth.sv

# descriptor-based frontend
IDMA_RTL_DOC_ALL += $(IDMA_DOC_FIG_DIR)/graph/idma_desc64_synth.png
IDMA_PICKLE_ALL  += $(IDMA_PICKLE_DIR)/idma_desc64_synth.sv

# RT midend
IDMA_RTL_DOC_ALL += $(IDMA_DOC_FIG_DIR)/graph/idma_rt_midend_synth.png
IDMA_PICKLE_ALL  += $(IDMA_PICKLE_DIR)/idma_rt_midend_synth.sv

# Mempool midend
IDMA_RTL_DOC_ALL += $(IDMA_DOC_FIG_DIR)/graph/idma_mp_midend_synth.png
IDMA_PICKLE_ALL  += $(IDMA_PICKLE_DIR)/idma_mp_midend_synth.sv


# ---------------
# Trimmed compile scripts
# ---------------

# Per-top vsim compile script trimmed via slang (bender >= 0.32.0)
$(IDMA_VSIM_DIR)/compile_%.tcl: $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL) $(IDMA_WAVE_ALL)
	echo 'set ROOT [file normalize [file dirname [info script]]/../../..]' > $@
	set -o pipefail; $(BENDER) script vsim --vlog-arg="$(IDMA_VLOG_ARGS)" \
		-t sim -t test -t idma_test -t synth -t rtl -t asic -t snitch_cluster \
		--top $* | grep -v "set ROOT" >> $@
	echo >> $@


# --------------
# QuestaSim
# --------------

.PHONY: idma_sim_clean

IDMA_VLOG_ARGS  := -suppress vlog-2583 \
			  	   -suppress vlog-13314 \
			  	   -suppress vlog-13233 \
			  	   +define+INC_ASSERT \
			  	   -timescale \"1 ns / 1 ps\"

define idma_generate_vsim
	echo 'set ROOT [file normalize [file dirname [info script]]/$3]' > $1
	$(BENDER) script vsim --vlog-arg="$(IDMA_VLOG_ARGS)" $2 | grep -v "set ROOT" >> $1
	echo >> $1
endef

$(IDMA_VSIM_DIR)/compile.tcl: $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL) $(IDMA_WAVE_ALL)
	$(call idma_generate_vsim, $@, -t sim -t test -t idma_test -t synth -t rtl -t asic -t snitch_cluster,../../..)

# Standalone self-checking transpose-engine regression (DPI-C golden, no backend deps).
# Run with the Questa SEPP wrapper, e.g.:
#   make idma_sim_tb_idma_otf_transpose VSIM="questa-2023.4 vsim" VLOG="questa-2023.4 vlog" VLIB="questa-2023.4 vlib"
IDMA_OTF_TP_RTL := $(abspath $(IDMA_ROOT)/src/backend/idma_otf_transpose.sv)
IDMA_OTF_TP_TB  := $(abspath $(IDMA_ROOT)/test/tb_idma_otf_transpose.sv)
IDMA_OTF_TP_DPI := $(abspath $(IDMA_ROOT)/test/idma_transpose_dpi.c)
IDMA_OTF_TP_DIR := $(abspath $(IDMA_VSIM_DIR))/otf_transpose

.PHONY: idma_sim_tb_idma_otf_transpose
idma_sim_tb_idma_otf_transpose:
	mkdir -p $(IDMA_OTF_TP_DIR)
	cd $(IDMA_OTF_TP_DIR); $(VLIB) work
	cd $(IDMA_OTF_TP_DIR); $(VLOG) -sv $(IDMA_OTF_TP_DPI)
	cd $(IDMA_OTF_TP_DIR); $(VLOG) -sv -svinputport=compat -timescale "1ns/1fs" $(IDMA_OTF_TP_RTL) $(IDMA_OTF_TP_TB)
	# the TB sweeps the geometry list internally; one run per StrbWidth x FullDuplex
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gStrbWidth=8  -gFullDuplex=1 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gStrbWidth=8  -gFullDuplex=0 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gStrbWidth=64 -gFullDuplex=1 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gStrbWidth=64 -gFullDuplex=0 tb_idma_otf_transpose +BP -do "run -all; quit"

# Multi-tile transpose via the ND midend -> rw_axi backend -> axi_sim_mem.
# Run with the Questa SEPP wrapper: make idma_sim_tb_idma_transpose_nd VSIM="questa-2023.4 vsim"
.PHONY: idma_sim_tb_idma_transpose_nd
idma_sim_tb_idma_transpose_nd: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	# the TB sweeps the geometry list internally; one run per bus width
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=64 tb_idma_transpose_nd -do "run -all; quit"

# Back-to-back regressions: the ND midend must reload each new transfer's base
# address (it does, for a protocol-compliant producer that drops nd_req_valid on
# accept). tb_idma_nd_midend_b2b checks the midend's burst-address sequence under
# backpressure; tb_idma_transpose_b2b checks two end-to-end transposes to distinct
# destinations.  Run with the Questa SEPP wrapper.
.PHONY: idma_sim_tb_idma_nd_midend_b2b
idma_sim_tb_idma_nd_midend_b2b: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc tb_idma_nd_midend_b2b -do "run -all; quit"

.PHONY: idma_sim_tb_idma_reg_frontend
idma_sim_tb_idma_reg_frontend: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gNumStreams=1 tb_idma_reg_frontend -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gNumStreams=2 tb_idma_reg_frontend -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gNumStreams=2 -gNumRegs=2 tb_idma_reg_frontend -do "run -all; quit"

.PHONY: idma_sim_tb_idma_inst64_axi_copy
idma_sim_tb_idma_inst64_axi_copy: $(IDMA_VSIM_DIR)/compile_tb_idma_inst64_axi_copy.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile_tb_idma_inst64_axi_copy.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc tb_idma_inst64_axi_copy \
		-logfile inst64_axi_copy.log -do "run -all; quit"
	# Questa does not propagate $$fatal to the exit code; gate on the transcript
	cd $(IDMA_VSIM_DIR); ! grep -qE "Error:|Fatal:" inst64_axi_copy.log
	cd $(IDMA_VSIM_DIR); grep -q "TEST PASSED" inst64_axi_copy.log

.PHONY: idma_sim_tb_idma_transpose_b2b
idma_sim_tb_idma_transpose_b2b: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	# the TB sweeps the geometry list internally; one run per bus width
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 tb_idma_transpose_b2b -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=64 tb_idma_transpose_b2b -do "run -all; quit"

# Run a self-checking MX sim across data widths. Questa does not propagate
# $fatal to the exit code, so fail on any Error:/Fatal: in the run log.
# $(1) = testbench, $(2) = space-separated data widths.
define idma_run_mx_sim
	cd $(IDMA_VSIM_DIR); set -e; for dw in $(2); do \
	  $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=$$dw $(1) -do "run -all; quit" > $(1)_$$dw.log 2>&1 || true; \
	  if grep -qE "Error:|Fatal:" $(1)_$$dw.log; then \
	    echo "$(1) DW=$$dw FAILED (see $(1)_$$dw.log)"; tail -40 $(1)_$$dw.log; exit 1; fi; \
	done
endef

.PHONY: idma_sim_tb_idma_mxquant
idma_sim_tb_idma_mxquant: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VLOG) -sv $(abspath $(IDMA_ROOT)/test/idma_mxquant_dpi.c)
	$(call idma_run_mx_sim,tb_idma_mxquant,32 64 256 512 1024)

.PHONY: idma_sim_tb_idma_mxroundtrip
idma_sim_tb_idma_mxroundtrip: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VLOG) -sv $(abspath $(IDMA_ROOT)/test/idma_mxquant_dpi.c)
	$(call idma_run_mx_sim,tb_idma_mxroundtrip,32 64 256 512 1024)

.PHONY: idma_sim_tb_idma_mxrand
idma_sim_tb_idma_mxrand: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VLOG) -sv $(abspath $(IDMA_ROOT)/test/idma_mxquant_dpi.c)
	$(call idma_run_mx_sim,tb_idma_mxrand,32 64 256 512 1024)

.PHONY: idma_sim_tb_idma_mxperf
idma_sim_tb_idma_mxperf: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	$(call idma_run_mx_sim,tb_idma_mxperf,32 64)

.PHONY: idma_sim_tb_idma_mxclear
idma_sim_tb_idma_mxclear: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); set -e; \
	for c in "1 quant" "0 dequant"; do \
	  set -- $$c; \
	  $(VSIM) -c -t 1ps -voptargs=+acc -gQuant=$$1 tb_idma_mxclear -do "run -all; quit" > mxclear_$$2.log 2>&1 || true; \
	  if grep -qE "clear.with.in-flight.state" mxclear_$$2.log; then echo "[MXCLR] $$2 clear-guard FIRED"; \
	  else echo "[MXCLR] $$2 clear-guard DID NOT FIRE (see mxclear_$$2.log)"; exit 1; fi; \
	done

# each case must print its guard assert; case 6 needs the op compiled out, case 4 a 1024-bit bus
.PHONY: idma_sim_tb_idma_mxneg
idma_sim_tb_idma_mxneg: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); set -e; \
	for c in "1 ComputeSizeAligned 64 1 1" "2 ComputeSrcAligned 64 1 1" \
	         "3 ComputeDstAligned 64 1 1" "4 ComputeMxFp16Width 1024 1 1" \
	         "5 ComputeMxdequantBeatAligned 64 1 1" "6 ComputeOpUnsupported 64 0 1" \
	         "7 ComputeMxSrcProtocol 64 1 1" "8 ComputeMxDstProtocol 64 1 1" \
	         "10 ComputeTransposeSingleBeat 64 1 1" "11 ComputeMxdequantLengthFits 64 1 1" \
	         "12 ComputeMxFp16Width 1024 1 1" "13 not.elaborated 64 1 0"; do \
	  set -- $$c; \
	  $(VSIM) -c -t 1ps -voptargs=+acc -gNegCase=$$1 -gDataWidth=$$3 -gEnDequant=$$4 -gEnFp16=$$5 \
	    tb_idma_mxneg -do "run -all; quit" > mxneg_$$1.log 2>&1 || true; \
	  if grep -qE "(ASSERT FAILED.*$$2|$$2)" mxneg_$$1.log; then echo "[MXNEG] case $$1 $$2 FIRED"; \
	  else echo "[MXNEG] case $$1 $$2 DID NOT FIRE (see mxneg_$$1.log)"; exit 1; fi; \
	done

.PHONY: idma_sim_tb_idma_transpose_midend
idma_sim_tb_idma_transpose_midend: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	# the TB sweeps the geometry list internally; one run per bus width
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=64  tb_idma_transpose_midend -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=512 tb_idma_transpose_midend -do "run -all; quit"

.PHONY: idma_sim_tb_idma_rt_midend

idma_sim_tb_idma_rt_midend: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc tb_idma_rt_midend -do "run -all; quit"

idma_sim_clean:
	rm -rf $(IDMA_OTF_TP_DIR)
	rm -rf $(IDMA_VSIM_DIR)/compile.tcl
	rm -rf $(IDMA_VSIM_DIR)/work
	rm -f  $(IDMA_VSIM_DIR)/dma_trace_*
	rm -f  $(IDMA_VSIM_DIR)/dma_transfers.txt
	rm -f  $(IDMA_VSIM_DIR)/transcript
	rm -f  $(IDMA_VSIM_DIR)/wlf*
	rm -f  $(IDMA_VSIM_DIR)/*.wlf
	rm -f  $(IDMA_VSIM_DIR)/*.vstf
	rm -f  $(IDMA_VSIM_DIR)/*.vcd
	rm -f  $(IDMA_VSIM_DIR)/modelsim.ini
	rm -f  $(IDMA_VSIM_DIR)/*.log
	rm -f  $(IDMA_VSIM_DIR)/*.txt


# --------------
# VCS
# --------------

.PHONY: idma_vcs_compile idma_vcs_clean

IDMA_VCS_DIR     := $(IDMA_ROOT)/target/sim/vcs
IDMA_VLOGAN_ARGS := -assert svaext \
					-assert disable_cover \
					-full64 \
					-sysc=q \
					-nc \
					-q \
					-timescale=1ns/1ns
IDMA_VCS_ARGS    := -full64 \
			   		-debug_access+r \
			   		-j 8 \
			   		-CFLAGS "-Os"
IDMA_VCS_TB      ?=
IDMA_VCS_PARAMS  ?=

$(IDMA_VCS_DIR)/compile.sh: $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	$(BENDER) script vcs -t test -t idma_test -t rtl -t synth -t simulation -t snitch_cluster --vlog-arg "\$(IDMA_VLOGAN_ARGS)" --vlogan-bin "$(VLOGAN)" $(IDMA_VLOGAN_REL_PATHS) > $@
	chmod +x $@

idma_vcs_compile: $(IDMA_VCS_DIR)/compile.sh
	cd $(IDMA_VCS_DIR); ./compile.sh

$(IDMA_VCS_DIR)/bin/%.vcs: idma_vcs_compile $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_VCS_DIR)/bin
	cd $(IDMA_VCS_DIR); $(VCS) $(IDMA_VCS_ARGS) $(IDMA_VCS_PARAMS) $(IDMA_VCS_TB) -o bin/$*.vcs

idma_vcs_clean:
	rm -rf $(IDMA_VCS_DIR)/AN.DB
	rm -rf $(IDMA_VCS_DIR)/csrc
	rm -f  $(IDMA_VCS_DIR)/compile.sh
	rm -rf $(IDMA_VCS_DIR)/bin
	rm -f  $(IDMA_VCS_DIR)/ucli.key
	rm -f  $(IDMA_VCS_DIR)/vc_hdrs.h
	rm -f  $(IDMA_VCS_DIR)/*.log
	rm -f  $(IDMA_VCS_DIR)/*.txt


# --------------
# Verilator
# --------------

.PHONY: idma_verilator_clean

IDMA_VLT_DIR   := $(IDMA_ROOT)/target/sim/verilator
IDMA_VLT_ARGS  := --cc \
				  --Wall \
				  --Wno-fatal \
				  +1800-2017ext+ \
				  --assert \
				  --error-limit 1000 \
				  --hierarchical \
				  --no-skip-identical

IDMA_VLT_TOP     ?=
IDMA_VLT_PARAMS  ?=

# Warning classes measured at 0 occurrences over all 12 synth tops, so they gate.
# Not promoted, with the measurement: UNOPTFLAT (31, includes the known
# idma_nd_midend stage_done loop) and PINMISSING (12, all in axi_stream and
# common_cells, none iDMA-owned).
IDMA_VLT_WERROR    := -Werror-LATCH -Werror-MULTIDRIVEN -Werror-IMPLICIT
# The unroll budget matches util/run_vlt_sim.py; without it verilator 5.020 reports
# BLKLOOPINIT on the compute pack/unpack loops at DataWidth >= 256.
IDMA_VLT_LINT_ARGS := --lint-only -Wno-fatal --timing $(IDMA_VLT_WERROR) \
                      --unroll-count 4096 --unroll-stmts 200000

.PRECIOUS: $(IDMA_VLT_DIR)/%_elab.log

$(IDMA_VLT_DIR)/%_elab.log: $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_VLT_DIR)
	# We need a dedicated pickle here to set the defines
	$(BENDER) pickle $(IDMA_PICKLE_TARGETS) --top $(IDMA_VLT_TOP) -D VERILATOR --expand-macros -o $(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv
	cd $(IDMA_VLT_DIR); $(VERILATOR) $(IDMA_VLT_ARGS) $(IDMA_VLT_PARAMS) -Mdir obj_$* $(IDMA_VLT_TOP).sv --top-module $(IDMA_VLT_TOP) 2> $*_elab.log

idma_verilator_clean:
	rm -rf $(IDMA_VLT_DIR)

# inst64 frontend elaboration gate: verilator --lint-only over tb_idma_inst64_axi_copy,
# the only public concrete binding of the snitch_cluster-gated idma_inst64_top. -t test
# adds obi_sim_mem; --top-module is load-bearing, it trims the flat filelist to the
# reachable cone. Run after idma_hw_all. slang covers the same top via
# IDMA_TB_SHARED_TOPS.
IDMA_INST64_TB   := tb_idma_inst64_axi_copy
IDMA_INST64_T    := -t rtl -t synth -t idma_test -t simulation -t sim -t test \
                    -t snitch_cluster

.PHONY: idma_lint_inst64
idma_lint_inst64:
	mkdir -p $(IDMA_VLT_DIR)
	$(BENDER) script verilator $(IDMA_INST64_T) --top $(IDMA_INST64_TB) \
	  > $(IDMA_VLT_DIR)/idma_inst64_tb.f
	$(VERILATOR) $(IDMA_VLT_LINT_ARGS) -f $(IDMA_VLT_DIR)/idma_inst64_tb.f \
	  --top-module $(IDMA_INST64_TB)

# Synthesis-wrapper elaboration gate: verilator elaborates every synth top so a
# port, parameter or connectivity break is caught without the proprietary EDA
# sims (which fork PRs never run). Run after idma_hw_all.
IDMA_LINT_TOPS ?= $(addprefix idma_backend_synth_,$(IDMA_BACKEND_IDS)) \
                  idma_desc64_synth \
                  idma_nd_midend_synth \
                  idma_mp_midend_synth \
                  idma_rt_midend_synth

# Tree-scoped SystemVerilog style lint. The PR-annotating CI job reports through
# reviewdog with -diff, so it only ever sees lines a PR touched; this target
# checks all of src/ so pre-existing violations cannot accumulate unseen.
VERIBLE ?= verible-verilog-lint

.PHONY: idma_lint_sv
idma_lint_sv:
	$(VERIBLE) --waiver_files $(IDMA_ROOT)/.github/verible.waiver \
	  $$(find $(IDMA_ROOT)/src -name '*.sv' -o -name '*.svh' | sort)

.PHONY: idma_lint_elab
idma_lint_elab:
	mkdir -p $(IDMA_VLT_DIR)
	$(BENDER) script verilator -t rtl -t synth > $(IDMA_VLT_DIR)/idma_elab.f
	@rc=0; for top in $(IDMA_LINT_TOPS); do \
	  echo "--- elaborating $$top ---"; \
	  $(VERILATOR) --lint-only -Wno-fatal --timing -f $(IDMA_VLT_DIR)/idma_elab.f --top-module $$top || rc=1; \
	done; exit $$rc

.PHONY: idma_lint_all
idma_lint_all: idma_lint_elab idma_lint_inst64


# ---------------
# Public verification
# ---------------

# License-free elaboration and simulation gates, run on verilator and slang only,
# so fork PRs (which skip the proprietary EDA sims) still get a real signal.
# Every top-level target below is one CI leg and reproduces a red check locally.

.PHONY: idma_verify_codegen idma_verify_backend idma_verify_shared idma_verify_multihead
.PHONY: idma_verify_tb_shared idma_verify_sim_mxquant idma_verify_sim_mxroundtrip
.PHONY: idma_verify_sim_transpose idma_verify_sim_mxclear idma_verify_sim_mxneg
.PHONY: idma_verify_all idma_lint_params idma_slang_elab idma_slang_tb idma_slang_report
.PHONY: idma_verify_clean

# Module to elaborate; every per-top target takes it
IDMA_TOP           ?=
# Backend variant a leg covers
IDMA_VERIFY_ID     ?= rw_axi
# DataWidth points elaborated on top of the jobs.json parameter sets. Every
# jobs.json entry pins DataWidth=32, so nothing wider is elaborated otherwise.
IDMA_ELAB_WIDTHS   ?= 32 64 512 1024

# Compute-enabled configurations, as DataWidth:ComputeOps:ComputeTuning. No
# jobs.json entry enables the compute datapath, so its generate branches are
# unreachable otherwise. ComputeOps is {transpose, mxquant, mxdequant, mxfp16}.
#   64:15:1   every sub-unit, ping-pong transpose banks
#   512:15:1  the wide bus, where the pack/unpack loops are stressed
#   64:8:0    transpose only, single bank; also the no-mxquant/no-mxdequant branches
#   64:6:1    mx only, Fp16En=0; also the no-transpose branch
IDMA_ELAB_COMPUTE  ?= 64:15:1 512:15:1 64:8:0 64:6:1

IDMA_VERIFY_DIR    := $(IDMA_ROOT)/target/verify
IDMA_SLANG_DIR     := $(IDMA_ROOT)/target/sim/slang
IDMA_SLANG_VERSION ?= 11.0.0
# pyslang ships the slang driver itself. Never call a site `slang` wrapper: one
# turns a SIGSEGV into rc=0 with no output, which makes the gate vacuous.
SLANG              ?= $(UV) run --with pyslang==$(IDMA_SLANG_VERSION) python \
                      $(IDMA_UTIL_DIR)/slang_elab.py
IDMA_SLANG_ARGS    := -Werror --error-limit 0
# -Wno-finish-num covers 9 $fatal("<string>") calls in common_verification; no
# iDMA file has one, and slang cannot scope a waiver to a dependency checkout.
IDMA_SLANG_TB_ARGS := --timescale=1ns/1ps -Wno-finish-num
IDMA_SLANG_SYNTH_T := -t rtl -t synth
IDMA_SLANG_TB_T    := -t rtl -t synth -t idma_test -t simulation -t sim -t test \
                      -t snitch_cluster -t asic

# Non-backend synthesis tops, elaborated with their own jobs.json parameters
IDMA_SHARED_TOPS   := idma_desc64_synth idma_nd_midend_synth idma_mp_midend_synth \
                      idma_rt_midend_synth

# Out-of-tree multi-head variants; license-free but generated only on request
IDMA_MULTIHEAD_IDS ?= 2r_axi_w_axi 2rw_axi

# Generated register frontends, as RegVariant:module. They share a parameter and
# port list, so tb_idma_reg_frontend - the only public concrete binding - elaborates
# each of them; without this reg64_2d and reg64_1d are elaborated by nothing. Only
# variant 0 is simulated; the testbench refuses to run on the other two.
IDMA_REG_VARIANTS  ?= 3:idma_reg32_3d 2:idma_reg64_2d 1:idma_reg64_1d

# Testbench tops that are not per-backend. tb_idma_backend_* are covered by the
# matching idma_verify_backend leg; tb_idma_reg_frontend by IDMA_REG_VARIANTS.
IDMA_TB_SHARED_TOPS := tb_idma_desc64_top tb_idma_desc64_bench \
                       tb_idma_nd_midend tb_idma_nd_midend_b2b tb_idma_rt_midend \
                       tb_idma_transpose_midend tb_idma_otf_transpose \
                       tb_idma_transpose_nd tb_idma_transpose_b2b tb_idma_mxquant \
                       tb_idma_mxroundtrip tb_idma_mxrand tb_idma_mxneg \
                       tb_idma_mxperf tb_idma_mxclear $(IDMA_INST64_TB)

IDMA_SOURCE_GLOBS  := --source '$(IDMA_RTL_DIR)/*.sv' --source '$(IDMA_ROOT)/src/**/*.sv' \
                      --source '$(IDMA_ROOT)/test/**/*.sv'

# CI workflow that has to fan out over every backend id and negative-test case;
# a matrix leg that silently does not exist is worse than no leg
IDMA_MATRIX_FILE   ?= $(IDMA_ROOT)/.github/workflows/verify.yml

# Emit the elaboration configurations of $1 (jobs.json parameter sets + width sweep)
define idma_elab_cfg
	mkdir -p $(IDMA_VERIFY_DIR)
	$(PYTHON) $(IDMA_UTIL_DIR)/idma_params.py --top $1 \
	  --jobs $(IDMA_ROOT)/$(IDMA_JOBS_JSON) --widths "$(IDMA_ELAB_WIDTHS)" \
	  --compute "$(IDMA_ELAB_COMPUTE)" \
	  $(IDMA_SOURCE_GLOBS) > $(IDMA_VERIFY_DIR)/$1.cfg
endef

# Filelists
$(IDMA_VLT_DIR)/idma_verify.f: $(IDMA_BENDER_FILES) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_VLT_DIR)
	$(BENDER) script verilator $(IDMA_SLANG_SYNTH_T) > $@

$(IDMA_SLANG_DIR)/synth.f: $(IDMA_BENDER_FILES) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_SLANG_DIR)
	$(BENDER) script flist-plus $(IDMA_SLANG_SYNTH_T) > $@

$(IDMA_SLANG_DIR)/tb.f: $(IDMA_BENDER_FILES) $(IDMA_FULL_RTL) $(IDMA_FULL_TB) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_SLANG_DIR)
	$(BENDER) script flist-plus $(IDMA_SLANG_TB_T) > $@


# Verilator elaboration of IDMA_TOP over every jobs.json configuration and width
# point. verilator rejects an unknown -G name; slang ignores it, which is why
# idma_params.py checks the names against the module header itself.
idma_lint_params: $(IDMA_VLT_DIR)/idma_verify.f
	@test -n "$(IDMA_TOP)" || { echo "error: set IDMA_TOP=<module>"; exit 1; }
	$(call idma_elab_cfg,$(IDMA_TOP))
	@test -s $(IDMA_VERIFY_DIR)/$(IDMA_TOP).cfg || \
	  { echo "error: no configurations for $(IDMA_TOP)"; exit 1; }
	@rc=0; while read -r cfg flags; do \
	  echo "--- verilator $(IDMA_TOP) [$$cfg] $$flags ---"; \
	  $(VERILATOR) $(IDMA_VLT_LINT_ARGS) -f $(IDMA_VLT_DIR)/idma_verify.f \
	    --top-module $(IDMA_TOP) $$flags || rc=1; \
	done < $(IDMA_VERIFY_DIR)/$(IDMA_TOP).cfg; \
	test $$rc -eq 0 && echo "idma_lint_params: $(IDMA_TOP) OK" || \
	  echo "idma_lint_params: $(IDMA_TOP) FAILED"; exit $$rc

# slang elaboration of IDMA_TOP over the same configurations
idma_slang_elab: $(IDMA_SLANG_DIR)/synth.f
	@test -n "$(IDMA_TOP)" || { echo "error: set IDMA_TOP=<module>"; exit 1; }
	$(call idma_elab_cfg,$(IDMA_TOP))
	@test -s $(IDMA_VERIFY_DIR)/$(IDMA_TOP).cfg || \
	  { echo "error: no configurations for $(IDMA_TOP)"; exit 1; }
	@rc=0; while read -r cfg flags; do \
	  echo "--- slang $(IDMA_TOP) [$$cfg] $$flags ---"; \
	  $(SLANG) -f $(IDMA_SLANG_DIR)/synth.f --top $(IDMA_TOP) $(IDMA_SLANG_ARGS) $$flags \
	    || rc=1; \
	done < $(IDMA_VERIFY_DIR)/$(IDMA_TOP).cfg; \
	test $$rc -eq 0 && echo "idma_slang_elab: $(IDMA_TOP) OK" || \
	  echo "idma_slang_elab: $(IDMA_TOP) FAILED"; exit $$rc

# slang elaboration of one testbench top; verilator cannot parse the verification
# stack at all (axi_test/apb_test type-identifier errors, randomize()-with).
idma_slang_tb: $(IDMA_SLANG_DIR)/tb.f
	@test -n "$(IDMA_TOP)" || { echo "error: set IDMA_TOP=<module>"; exit 1; }
	$(SLANG) -f $(IDMA_SLANG_DIR)/tb.f --top $(IDMA_TOP) \
	  $(IDMA_SLANG_ARGS) $(IDMA_SLANG_TB_ARGS)

# One backend variant: synthesis top under both front ends, plus its testbench
idma_verify_backend:
	$(MAKE) idma_lint_params IDMA_TOP=idma_backend_synth_$(IDMA_VERIFY_ID)
	$(MAKE) idma_slang_elab  IDMA_TOP=idma_backend_synth_$(IDMA_VERIFY_ID)
	$(MAKE) idma_slang_tb    IDMA_TOP=tb_idma_backend_$(IDMA_VERIFY_ID)

# The four non-backend synthesis tops with their jobs.json parameters, plus the
# default-parameter elaboration of every top from idma_lint_all
idma_verify_shared: idma_lint_all
	set -e; for top in $(IDMA_SHARED_TOPS); do \
	  $(MAKE) idma_lint_params IDMA_TOP=$$top; \
	  $(MAKE) idma_slang_elab  IDMA_TOP=$$top; \
	done

idma_verify_tb_shared: $(IDMA_SLANG_DIR)/tb.f
	@set -e; for id in $(IDMA_FE_IDS); do \
	  case " $(IDMA_REG_VARIANTS) " in *":idma_$$id "*) ;; \
	    *) echo "error: no IDMA_REG_VARIANTS entry elaborates idma_$$id"; exit 1;; esac; \
	done
	set -e; for top in $(IDMA_TB_SHARED_TOPS); do \
	  echo "--- slang $$top ---"; \
	  $(SLANG) -f $(IDMA_SLANG_DIR)/tb.f --top $$top \
	    $(IDMA_SLANG_ARGS) $(IDMA_SLANG_TB_ARGS); \
	done
	set -e; for entry in $(IDMA_REG_VARIANTS); do \
	  IFS=: read -r v mod <<< "$$entry"; \
	  echo "--- slang tb_idma_reg_frontend [$$mod] ---"; \
	  $(SLANG) -f $(IDMA_SLANG_DIR)/tb.f --top tb_idma_reg_frontend -GRegVariant=$$v \
	    $(IDMA_SLANG_ARGS) $(IDMA_SLANG_TB_ARGS); \
	done

# Out-of-tree multi-head build: regenerate with the extra ids, then elaborate the
# two extra synthesis tops and the two multi-head testbenches
idma_verify_multihead:
	$(MAKE) idma_hw_all idma_add_all IDMA_ADD_IDS="$(IDMA_MULTIHEAD_IDS)"
	mkdir -p $(IDMA_VLT_DIR) $(IDMA_SLANG_DIR)
	$(BENDER) script verilator $(IDMA_SLANG_SYNTH_T) -t add_ids > $(IDMA_VLT_DIR)/idma_multihead.f
	$(BENDER) script flist-plus $(IDMA_SLANG_SYNTH_T) -t add_ids > $(IDMA_SLANG_DIR)/mh_synth.f
	$(BENDER) script flist-plus $(IDMA_SLANG_TB_T) -t multihead -t add_ids \
	  > $(IDMA_SLANG_DIR)/mh_tb.f
	set -e; for id in $(IDMA_MULTIHEAD_IDS); do \
	  echo "--- verilator idma_backend_synth_$$id ---"; \
	  $(VERILATOR) $(IDMA_VLT_LINT_ARGS) -f $(IDMA_VLT_DIR)/idma_multihead.f \
	    --top-module idma_backend_synth_$$id; \
	  echo "--- slang idma_backend_synth_$$id ---"; \
	  $(SLANG) -f $(IDMA_SLANG_DIR)/mh_synth.f --top idma_backend_synth_$$id \
	    $(IDMA_SLANG_ARGS); \
	done
	set -e; for tb in tb_idma_backend_multihead tb_idma_backend_multihead_rw; do \
	  echo "--- slang $$tb ---"; \
	  $(SLANG) -f $(IDMA_SLANG_DIR)/mh_tb.f --top $$tb \
	    $(IDMA_SLANG_ARGS) $(IDMA_SLANG_TB_ARGS); \
	done
	# the tracked aggregates never saw the extra ids, so this is a no-op assertion
	$(MAKE) idma_hw_all


# ---------------
# Public simulation (verilator)
# ---------------

IDMA_VLT_SIM_T     := -t rtl -t idma_test -t simulation -t synth
IDMA_VLT_MAKEFLAGS ?=
IDMA_VLT_SIM       := VERILATOR="$(VERILATOR)" IDMA_VLT_MAKEFLAGS="$(IDMA_VLT_MAKEFLAGS)" \
                      $(PYTHON) $(IDMA_UTIL_DIR)/run_vlt_sim.py --dir $(IDMA_VLT_DIR)

# DataWidth 512 and 1024 are elaboration-only: verilator 5.020 SIGSEGVs before
# time 0 (512 in the initial-block coroutine, 1024 in the model constructor).
IDMA_MX_WIDTHS     ?= 32 64 256

# case:guard:DataWidth:EnDequant:EnFp16
IDMA_MXNEG_TABLE   := 1:ComputeSizeAligned:64:1:1 \
                      2:ComputeSrcAligned:64:1:1 \
                      3:ComputeDstAligned:64:1:1 \
                      5:ComputeMxdequantBeatAligned:64:1:1 \
                      6:ComputeOpUnsupported:64:0:1 \
                      7:ComputeMxSrcProtocol:64:1:1 \
                      8:ComputeMxDstProtocol:64:1:1 \
                      10:ComputeTransposeSingleBeat:64:1:1 \
                      13:ComputeOpUnsupported:64:1:0
IDMA_MXNEG_CASES   ?= 1 2 3 5 6 7 8 10 13

# Named rather than skipped, and checked by check_jobs.py: a case the testbench
# defines must be here or in the table, and a legalizer guard must be proven to
# fire by some case or be named here. case:reason, no spaces in the reason.
IDMA_MXNEG_SKIP    := 4:needs-DataWidth-1024-verilator-SIGSEGV \
                      11:request-never-accepted-guard-never-sampled \
                      12:needs-DataWidth-1024-verilator-SIGSEGV
IDMA_MXNEG_GUARD_SKIP := ComputeMxFp16Width:only-reachable-from-the-DataWidth-1024-cases \
                         ComputeMxdequantLengthFits:case-11-never-accepted \
                         ComputeDstTilelink:no-tilelink-backend-variant-exists

$(IDMA_VLT_DIR)/%.f: $(IDMA_BENDER_FILES) $(IDMA_FULL_RTL) $(IDMA_FULL_TB) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_VLT_DIR)
	$(BENDER) script verilator $(IDMA_VLT_SIM_T) --top $* > $@

# verilator hands a .c file to the C++ driver, so the DPI goldens are compiled
# here and linked in. idma_mxquant_dpi and idma_transpose_dpi both export
# gm_load/gm_get and must never end up in the same binary.
$(IDMA_VLT_DIR)/%_dpi.o: $(IDMA_ROOT)/test/%_dpi.c
	mkdir -p $(IDMA_VLT_DIR)
	$(CC) -c -O2 -fPIC $< -o $@

idma_verify_sim_mxquant: $(IDMA_VLT_DIR)/tb_idma_mxquant.f $(IDMA_VLT_DIR)/idma_mxquant_dpi.o
	set -e; for dw in $(IDMA_MX_WIDTHS); do \
	  $(IDMA_VLT_SIM) --top tb_idma_mxquant --flist $(IDMA_VLT_DIR)/tb_idma_mxquant.f \
	    --tag mxquant_$$dw --param DataWidth=$$dw \
	    --dpi $(IDMA_VLT_DIR)/idma_mxquant_dpi.o --token "[MXQ] ALL PASS"; \
	done

idma_verify_sim_mxroundtrip: $(IDMA_VLT_DIR)/tb_idma_mxroundtrip.f \
                             $(IDMA_VLT_DIR)/idma_mxquant_dpi.o
	set -e; for dw in $(IDMA_MX_WIDTHS); do \
	  $(IDMA_VLT_SIM) --top tb_idma_mxroundtrip \
	    --flist $(IDMA_VLT_DIR)/tb_idma_mxroundtrip.f \
	    --tag mxroundtrip_$$dw --param DataWidth=$$dw \
	    --dpi $(IDMA_VLT_DIR)/idma_mxquant_dpi.o --token "[MXRT] ALL PASS"; \
	done

# +BP is a second stimulus (backpressured transpose), not a rerun
idma_verify_sim_transpose: $(IDMA_VLT_DIR)/tb_idma_otf_transpose.f \
                           $(IDMA_VLT_DIR)/tb_idma_transpose_midend.f \
                           $(IDMA_VLT_DIR)/idma_transpose_dpi.o
	$(IDMA_VLT_SIM) --top tb_idma_otf_transpose \
	  --flist $(IDMA_VLT_DIR)/tb_idma_otf_transpose.f --tag otf_transpose \
	  --param StrbWidth=8 --param FullDuplex=1 \
	  --dpi $(IDMA_VLT_DIR)/idma_transpose_dpi.o --token "[TB] ALL PASS"
	$(IDMA_VLT_SIM) --top tb_idma_otf_transpose \
	  --flist $(IDMA_VLT_DIR)/tb_idma_otf_transpose.f --tag otf_transpose_bp \
	  --param StrbWidth=8 --param FullDuplex=1 --plusarg +BP \
	  --dpi $(IDMA_VLT_DIR)/idma_transpose_dpi.o --token "[TB] ALL PASS"
	set -e; for dw in 64 512; do \
	  $(IDMA_VLT_SIM) --top tb_idma_transpose_midend \
	    --flist $(IDMA_VLT_DIR)/tb_idma_transpose_midend.f --tag transpose_midend_$$dw \
	    --param DataWidth=$$dw --dpi $(IDMA_VLT_DIR)/idma_transpose_dpi.o \
	    --token "[MID] ALL PASS"; \
	done

# Negative tests: the run must exit non-zero AND name its guard. --assert is
# load-bearing; without it both testbenches exit 0 and the leg cannot fail.
idma_verify_sim_mxclear: $(IDMA_VLT_DIR)/tb_idma_mxclear.f
	set -e; for q in 1 0; do \
	  $(IDMA_VLT_SIM) --top tb_idma_mxclear --flist $(IDMA_VLT_DIR)/tb_idma_mxclear.f \
	    --tag mxclear_$$q --param Quant=$$q --define INC_ASSERT --expect fail \
	    --token "clear with in-flight state"; \
	done

idma_verify_sim_mxneg: $(IDMA_VLT_DIR)/tb_idma_mxneg.f $(IDMA_VLT_DIR)/idma_mxquant_dpi.o
	set -e; ran=0; \
	for entry in $(IDMA_MXNEG_TABLE); do \
	  IFS=: read -r c guard dw deq fp <<< "$$entry"; \
	  case " $(IDMA_MXNEG_CASES) " in *" $$c "*) ;; *) continue;; esac; \
	  $(IDMA_VLT_SIM) --top tb_idma_mxneg --flist $(IDMA_VLT_DIR)/tb_idma_mxneg.f \
	    --tag mxneg_$$c --param NegCase=$$c --param DataWidth=$$dw \
	    --param EnDequant=$$deq --param EnFp16=$$fp \
	    --dpi $(IDMA_VLT_DIR)/idma_mxquant_dpi.o --define INC_ASSERT --expect fail \
	    --token "$$guard"; \
	  ran=$$((ran+1)); \
	done; \
	want=$$(echo $(IDMA_MXNEG_CASES) | wc -w); \
	test $$ran -eq $$want || { echo "error: ran $$ran of $$want requested cases"; exit 1; }


# ---------------
# Codegen consistency and advisory report
# ---------------

IDMA_GEN_FILES := $(IDMA_RTL_ALL) $(IDMA_TB_ALL) $(IDMA_FULL_RTL) $(IDMA_FULL_TB) \
                  $(IDMA_INCLUDE_ALL) $(IDMA_WAVE_ALL)

# Not verification: jobs.json and the generated tree must still describe the same
# design, and a second generation must be byte-identical. The zero-git-diff form
# is deliberately not used; target/rtl is gitignored on source branches, so it
# would pass unconditionally.
idma_verify_codegen:
	$(MAKE) idma_hw_all
	$(PYTHON) $(IDMA_UTIL_DIR)/check_jobs.py --ids "$(IDMA_BACKEND_IDS)" \
	  --jobs $(IDMA_ROOT)/$(IDMA_JOBS_JSON) --jobs-dir $(IDMA_ROOT)/jobs \
	  --matrix-file $(IDMA_MATRIX_FILE) --mxneg-cases "$(IDMA_MXNEG_CASES)" \
	  --mxneg-tb $(IDMA_ROOT)/test/tb_idma_mxneg.sv \
	  --mxneg-skip "$(IDMA_MXNEG_SKIP)" \
	  --mxneg-guard-src $(IDMA_ROOT)/src/backend/tpl/idma_legalizer.sv.tpl \
	  --mxneg-guard-tested "$(IDMA_MXNEG_TABLE)" \
	  --mxneg-guard-skip "$(IDMA_MXNEG_GUARD_SKIP)" \
	  $(IDMA_SOURCE_GLOBS)
	mkdir -p $(IDMA_VERIFY_DIR)
	md5sum $(IDMA_GEN_FILES) | sort -k2 > $(IDMA_VERIFY_DIR)/gen1.md5
	$(MAKE) idma_rtl_clean idma_reg_clean
	$(MAKE) idma_hw_all
	md5sum $(IDMA_GEN_FILES) | sort -k2 > $(IDMA_VERIFY_DIR)/gen2.md5
	diff -u $(IDMA_VERIFY_DIR)/gen1.md5 $(IDMA_VERIFY_DIR)/gen2.md5

# Advisory only: -Wextra without -Werror, so findings do not fail the target and
# a real compile error still does. Never add this to the required checks.
idma_slang_report: $(IDMA_SLANG_DIR)/synth.f
	mkdir -p $(IDMA_VERIFY_DIR)
	: > $(IDMA_VERIFY_DIR)/slang_extra.log
	set -e; for top in $(IDMA_LINT_TOPS); do \
	  $(SLANG) -f $(IDMA_SLANG_DIR)/synth.f --top $$top -Wextra --error-limit 0 \
	    >> $(IDMA_VERIFY_DIR)/slang_extra.log 2>&1; \
	done
	awk '/ (warning|error): /' $(IDMA_VERIFY_DIR)/slang_extra.log | \
	  awk '!/^\.bender\//' | sort -u > $(IDMA_VERIFY_DIR)/slang_extra.txt
	@echo "slang -Wextra: $$(wc -l < $(IDMA_VERIFY_DIR)/slang_extra.txt) unique iDMA findings"

idma_verify_all: idma_verify_codegen idma_verify_shared idma_verify_tb_shared \
                 idma_verify_multihead idma_verify_sim_mxquant \
                 idma_verify_sim_mxroundtrip idma_verify_sim_transpose \
                 idma_verify_sim_mxclear idma_verify_sim_mxneg
	set -e; for id in $(IDMA_BACKEND_IDS); do \
	  $(MAKE) idma_verify_backend IDMA_VERIFY_ID=$$id; \
	done

idma_verify_clean:
	rm -rf $(IDMA_VERIFY_DIR)
	rm -rf $(IDMA_SLANG_DIR)


# ---------------
# Trace
# ---------------

.PHONY: idma_trace_clean

IDMA_TRACE := $(IDMA_UTIL_DIR)/trace_idma.py

%_trace.rpt: $(IDMA_TRACE) $(IDMA_DB_FILES) %.txt
	$(PYTHON) $(IDMA_TRACE) --db $(IDMA_DB_FILES) --trace $*.txt > $@

idma_trace_clean:
	rm -f $(IDMA_VSIM_DIR)/*_trace.rpt
	rm -f $(IDMA_VCS_DIR)/*_trace.rpt


# ---------------
# Doc
# ---------------

.PHONY: idma_doc_site idma_doc_clean

IDMA_SITE_DIR := $(IDMA_ROOT)/doc/site

# Copy the generated hierarchy graphs into the Astro site's static assets
idma_doc_site: $(IDMA_RTL_DOC_ALL)
	mkdir -p $(IDMA_SITE_DIR)/public/fig/graph
	cp -f $(IDMA_DOC_FIG_DIR)/graph/*.png $(IDMA_SITE_DIR)/public/fig/graph/

idma_doc_clean:
	rm -rf $(IDMA_DOC_OUT_DIR)
	rm -rf $(IDMA_SITE_DIR)/dist
	rm -rf $(IDMA_SITE_DIR)/public/fig/graph


# --------------
# Nonfree
# --------------

.PHONY: idma_nonfree_init idma_nonfree_clean

IDMA_NONFREE_REMOTE ?= git@iis-git.ee.ethz.ch:bslk/idma/idma-non-free.git
IDMA_NONFREE_DIR    ?= $(IDMA_ROOT)/nonfree
IDMA_NONFREE_COMMIT ?= deploy

idma_nonfree_init:
	git clone $(IDMA_NONFREE_REMOTE) $(IDMA_NONFREE_DIR)
	cd $(IDMA_NONFREE_DIR) && git checkout $(IDMA_NONFREE_COMMIT)

-include $(IDMA_NONFREE_DIR)/nonfree.mk

idma_nonfree_clean:
	rm -rf $(IDMA_NONFREE_DIR)


# --------------
# Misc Clean
# --------------

.PHONY: idma_clean_all idma_clean idma_misc_clean idma_sw_clean

idma_clean_all idma_clean: idma_rtl_clean idma_reg_clean idma_pickle_clean idma_sim_clean idma_vcs_clean idma_verilator_clean idma_verify_clean idma_doc_clean idma_trace_clean idma_sw_clean

idma_misc_clean:
	rm -rf scripts/__pycache__
	rm -rf util/__pycache__
	rm -rf util/mario/__pycache__
	rm -f  gmon.out

idma_nuke: idma_clean idma_nonfree_clean
	rm -rf .bender

idma_sw_clean:
	rm -rf $(IDMA_SW_DIR)/*.h


# --------------
# Phony Targets
# --------------

.PHONY: idma_all idma_add_all idma_doc_all idma_pickle_all idma_rtl_all idma_sim_all

# Build the Starlight/Astro site (output in doc/site/dist) after staging the graphs
idma_doc_all: idma_doc_site
	cd $(IDMA_SITE_DIR); $(NPM) ci && $(NPM) run build

idma_pickle_all: $(IDMA_PICKLE_ALL)

idma_hw_all: $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL) $(IDMA_FULL_TB) $(IDMA_HJSON_ALL) \
             $(IDMA_WAVE_ALL)

# The IDMA_ADD_IDS aggregates; ask for it next to idma_hw_all on an add-id build
idma_add_all: $(IDMA_ADD_RTL) $(IDMA_ADD_TB)

idma_sw_all: $(IDMA_SW_ALL)

idma_sim_all: $(IDMA_VCS_DIR)/compile.sh $(IDMA_VSIM_DIR)/compile.tcl

idma_all: idma_hw_all idma_sim_all idma_doc_all idma_pickle_all

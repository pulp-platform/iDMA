# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

BENDER      ?= bender
CAT         ?= cat
GIT         ?= git
PRINTF      ?= printf
PEAKRDL     ?= peakrdl
PYTHON      ?= python3
SPHINXBUILD ?= sphinx-build
VCS         ?= vcs
VERILATOR   ?= verilator
VLOGAN      ?= vlogan
VSIM        ?= vsim
VLOG        ?= vlog
VLIB        ?= vlib

# Provision a local uv venv when the generator deps are not already available.
IDMA_VENV_PY := $(IDMA_ROOT)/.venv/bin/python
ifeq ($(shell $(PYTHON) -c 'import mako' >/dev/null 2>&1 && echo ok),ok)
else ifeq ($(shell $(IDMA_VENV_PY) -c 'import mako' >/dev/null 2>&1 && echo ok),ok)
  PYTHON      := $(IDMA_VENV_PY)
  export PATH := $(IDMA_ROOT)/.venv/bin:$(PATH)
else ifeq ($(shell command -v uv >/dev/null 2>&1 && echo ok),ok)
  $(info iDMA: provisioning the generator environment (uv sync --locked) ...)
  _idma_uv_sync := $(shell cd $(IDMA_ROOT) && uv sync --locked 1>&2 || echo FAIL)
  ifeq ($(_idma_uv_sync),FAIL)
    $(error iDMA: 'uv sync --locked' failed; see output above)
  endif
  PYTHON      := $(IDMA_VENV_PY)
  export PATH := $(IDMA_ROOT)/.venv/bin:$(PATH)
else
  $(error iDMA RTL generation needs 'uv' (https://docs.astral.sh/uv) on PATH, or a venv with the pyproject.toml deps activated)
endif

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
IDMA_ADD_IDS     ?=
IDMA_BACKEND_IDS ?= $(IDMA_BASE_IDS) $(IDMA_OCCAMY_IDS) $(IDMA_ADD_IDS)
# Compute-hosting variants (single AXI write); empty default = stock has no compute
IDMA_VIDMA_IDS   ?=
# Compute variants (strip the optional :op:fd suffix) must be built backends
_idma_vidma_unknown := $(filter-out $(IDMA_BACKEND_IDS),\
	$(foreach c,$(IDMA_VIDMA_IDS),$(firstword $(subst :, ,$(c)))))
ifneq ($(_idma_vidma_unknown),)
  $(error iDMA: IDMA_VIDMA_IDS variant(s) not in IDMA_BACKEND_IDS: $(_idma_vidma_unknown))
endif

# generated frontends
IDMA_BASE_FE_IDS := reg32_3d reg64_2d reg64_1d
IDMA_ADD_FE_IDS  ?=
IDMA_FE_IDS      ?= $(IDMA_BASE_FE_IDS) $(IDMA_ADD_FE_IDS)

# iDMA paths
IDMA_ROOT     ?= $(shell $(BENDER) path idma)
IDMA_UTIL_DIR := $(IDMA_ROOT)/util
IDMA_RTL_DIR  := $(IDMA_ROOT)/target/rtl

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
	$(PYTHON) $(IDMA_GEN) --entity $1 --tpl $2 --db $3 --ids $4 --fids $5 $(if $7,--compute-ids $7) > $6
endef

# Force an RTL regen when IDMA_VIDMA_IDS changes; rewritten only on change
IDMA_VIDMA_STAMP := $(IDMA_RTL_DIR)/.vidma_ids
.PHONY: idma_vidma_stamp_check
idma_vidma_stamp_check:
	@mkdir -p $(IDMA_RTL_DIR)
	@printf '%s' '$(IDMA_VIDMA_IDS)' | cmp -s - $(IDMA_VIDMA_STAMP) 2>/dev/null || \
		printf '%s' '$(IDMA_VIDMA_IDS)' > $(IDMA_VIDMA_STAMP)
$(IDMA_VIDMA_STAMP): idma_vidma_stamp_check ;

$(IDMA_RTL_DIR)/idma_transport_layer_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_ROOT)/src/backend/tpl/idma_transport_layer.sv.tpl $(IDMA_DB_FILES) $(IDMA_VIDMA_STAMP)
	$(call idma_gen,transport,$(IDMA_ROOT)/src/backend/tpl/idma_transport_layer.sv.tpl,$(IDMA_DB_FILES),$*,,$@,$(IDMA_VIDMA_IDS))

$(IDMA_RTL_DIR)/idma_legalizer_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_ROOT)/src/backend/tpl/idma_legalizer.sv.tpl $(IDMA_DB_FILES) $(IDMA_VIDMA_STAMP)
	$(call idma_gen,legalizer,$(IDMA_ROOT)/src/backend/tpl/idma_legalizer.sv.tpl,$(IDMA_DB_FILES),$*,,$@,$(IDMA_VIDMA_IDS))

$(IDMA_RTL_DIR)/idma_backend_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_RTL_DIR)/idma_legalizer_%.sv $(IDMA_RTL_DIR)/idma_transport_layer_%.sv $(IDMA_ROOT)/src/backend/tpl/idma_backend.sv.tpl $(IDMA_DB_FILES) $(IDMA_VIDMA_STAMP)
	$(call idma_gen,backend,$(IDMA_ROOT)/src/backend/tpl/idma_backend.sv.tpl,$(IDMA_DB_FILES),$*,,$@,$(IDMA_VIDMA_IDS))

$(IDMA_RTL_DIR)/idma_backend_synth_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_RTL_DIR)/idma_backend_%.sv $(IDMA_ROOT)/src/backend/tpl/idma_backend_synth.sv.tpl $(IDMA_DB_FILES)
	$(call idma_gen,synth_wrapper,$(IDMA_ROOT)/src/backend/tpl/idma_backend_synth.sv.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_RTL_DIR)/tb_idma_backend_%.sv: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_RTL_DIR)/idma_backend_%.sv $(IDMA_ROOT)/test/tpl/tb_idma_backend.sv.tpl $(IDMA_DB_FILES)
	$(call idma_gen,testbench,$(IDMA_ROOT)/test/tpl/tb_idma_backend.sv.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_VSIM_DIR)/wave/backend_%.do: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_RTL_DIR)/tb_idma_backend_%.sv $(IDMA_VSIM_DIR)/wave/tpl/backend.do.tpl
	$(call idma_gen,vsim_wave,$(IDMA_VSIM_DIR)/wave/tpl/backend.do.tpl,$(IDMA_DB_FILES),$*,,$@)

$(IDMA_RTL_DIR)/include/idma/tracer.svh: $(IDMA_GEN) $(IDMA_GEN_SRC) $(IDMA_ROOT)/src/include/idma/tpl/tracer.svh.tpl $(IDMA_DB_FILES) $(IDMA_ROOT)/idma.mk $(IDMA_DB_FILES)
	mkdir -p $(IDMA_RTL_DIR)/include/idma
	$(call idma_gen,tracer,$(IDMA_ROOT)/src/include/idma/tpl/tracer.svh.tpl,$(IDMA_DB_FILES),$(IDMA_BACKEND_IDS),$(IDMA_FE_IDS),$@)

idma_rtl_clean:
	rm -f  $(IDMA_RTL_DIR)/Bender.yml
	rm -f  $(IDMA_RTL_DIR)/*.sv
	rm -f  $(IDMA_VSIM_DIR)/wave/*.do
	rm -f  $(IDMA_RTL_DIR)/include/idma/tracer.svh
	rm -rf $(IDMA_RTL_DIR)/include/idma

# assemble the required files
IDMA_INCLUDE_ALL += $(IDMA_RTL_DIR)/include/idma/tracer.svh
IDMA_RTL_ALL     += $(foreach X,$(IDMA_RTL_FILES),$(foreach Y,$(IDMA_BACKEND_IDS),$X_$Y.sv))
IDMA_TB_ALL      += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_RTL_DIR)/tb_idma_backend_$Y.sv)
IDMA_WAVE_ALL    += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_VSIM_DIR)/wave/backend_$Y.do)


# --------------
# Register
# --------------

.PHONY: idma_reg_clean

IDMA_DOC_SRC_DIR := $(IDMA_ROOT)/doc/src
IDMA_DOC_FIG_DIR := $(IDMA_ROOT)/doc/fig
IDMA_DOC_OUT_DIR := $(IDMA_ROOT)/target/doc
IDMA_HTML_DIR    := $(IDMA_DOC_OUT_DIR)/html
IDMA_FE_DIR      := $(IDMA_ROOT)/src/frontend
IDMA_FE_REGS     := desc64
IDMA_FE_REGS     += $(IDMA_FE_IDS)


regwidth = $(word 1,$(subst _, ,$1))
dimension = $(word 2,$(subst _, ,$1))
log2dimension = $(shell echo $$(( $$( echo "obase=2;$$(($(1)-1))" | bc | wc -c ) - 1 )) )

$(IDMA_RTL_DIR)/idma_reg%d_reg_pkg.sv $(IDMA_RTL_DIR)/idma_reg%d_reg_top.sv $(IDMA_RTL_DIR)/idma_reg%d_addrmap_pkg.sv:
	$(PEAKRDL) regblock $(IDMA_FE_DIR)/reg/idma_reg.rdl -o $(IDMA_RTL_DIR) \
	  --default-reset arst_n --cpuif apb4-flat \
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
	$(call idma_gen,reg_top,$(IDMA_FE_DIR)/reg/tpl/idma_reg.sv.tpl,,,$*,$@)

$(IDMA_HTML_DIR)/regs/idma_reg%d_reg/index.html:
	$(PEAKRDL) html $(IDMA_FE_DIR)/reg/idma_reg.rdl -o $(IDMA_HTML_DIR)/regs/idma_reg$*d_reg \
	  -P SysAddrWidth=$(call regwidth,$*) \
	  -P NumDims=$(call dimension,$*) \
	  -P Log2NumDims=$(call log2dimension,$(call dimension,$*))

$(IDMA_HTML_DIR)/regs/idma_desc64_reg/index.html:
	$(PEAKRDL) html $(IDMA_FE_DIR)/desc64/idma_desc64_reg.rdl -o $(IDMA_HTML_DIR)/regs/idma_desc64_reg

idma_reg_clean:
	rm -rf $(IDMA_HTML_DIR)/regs
	rm -f  $(IDMA_RTL_DIR)/*_reg_top.sv
	rm -f  $(IDMA_RTL_DIR)/*_reg_pkg.sv
	rm -f  $(IDMA_RTL_DIR)/Bender.yml
	rm -f  $(IDMA_REG_CUST_ALL)

# assemble the required files
IDMA_RTL_ALL     += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_reg_pkg.sv)
IDMA_RTL_ALL     += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_reg_top.sv)
IDMA_RTL_ALL     += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_addrmap_pkg.sv)
IDMA_RTL_ALL     += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_top.sv)
IDMA_RTL_DOC_ALL += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_HTML_DIR)/regs/idma_$Y_reg/index.html)


# ---------------
# RTL assembly
# ---------------

$(IDMA_FULL_RTL): $(IDMA_RTL_ALL)
	$(CAT) $^ > $@

$(IDMA_FULL_TB): $(IDMA_TB_ALL)
	$(CAT) $^ > $@


# ---------------
# Pickle
# ---------------

.PHONY: idma_pickle_clean

IDMA_PICKLE_DIR     := $(IDMA_ROOT)/target/pickle
IDMA_PICKLE_TARGETS := -t rtl -t synth -t asic -t snitch_cluster
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
		-t sim -t test -t idma_test -t synth -t rtl -t asic -t snitch_cluster -t split_rtl \
		--top $* | grep -v "set ROOT" >> $@
	echo >> $@


# --------------
# QuestaSim
# --------------

.PHONY: idma_sim_clean

IDMA_VLOG_ARGS  := -suppress vlog-2583 \
			  	   -suppress vlog-13314 \
			  	   -suppress vlog-13233 \
			  	   -timescale \"1 ns / 1 ps\"

define idma_generate_vsim
	echo 'set ROOT [file normalize [file dirname [info script]]/$3]' > $1
	$(BENDER) script vsim --vlog-arg="$(IDMA_VLOG_ARGS)" $2 | grep -v "set ROOT" >> $1
	echo >> $1
endef

$(IDMA_VSIM_DIR)/compile.tcl: $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL) $(IDMA_WAVE_ALL)
	$(call idma_generate_vsim, $@, -t sim -t test -t idma_test -t synth -t rtl -t asic -t snitch_cluster -t split_rtl,../../..)

.PHONY: idma_sim_tb_idma_rt_midend

idma_sim_tb_idma_rt_midend: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc \
	    tb_idma_rt_midend -do "run -all; quit"

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
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gStrbWidth=8  -gM=13  -gN=19 -gEB=1 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gStrbWidth=8  -gM=7   -gN=5  -gEB=2 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gStrbWidth=8  -gM=5   -gN=3  -gEB=4 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gStrbWidth=64 -gM=130 -gN=70 -gEB=1 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gFullDuplex=0 -gStrbWidth=8  -gM=13 -gN=19 -gEB=1 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gFullDuplex=0 -gStrbWidth=8  -gM=7  -gN=5  -gEB=2 tb_idma_otf_transpose +BP -do "run -all; quit"
	cd $(IDMA_OTF_TP_DIR); $(VSIM) -c -t 1ps -gFullDuplex=0 -gStrbWidth=64 -gM=130 -gN=70 -gEB=1 tb_idma_otf_transpose +BP -do "run -all; quit"

# Multi-tile transpose via the ND midend (transposed strides) -> rw_axi backend
# (engine spliced at the write seam) -> axi_sim_mem. Covers aligned and edge
# (M or N not a multiple of NE) geometries for int8/fp16/fp32. Needs the
# split_rtl flow (per-variant routing). Run with the Questa SEPP wrapper:
#   make idma_sim_tb_idma_transpose_nd VSIM="questa-2023.4 vsim"
# These tests need the write-seam engine: build rw_axi with compute (stamp regens)
idma_sim_tb_idma_transpose_nd idma_sim_tb_idma_transpose_b2b: IDMA_VIDMA_IDS := rw_axi

.PHONY: idma_sim_tb_idma_transpose_nd
idma_sim_tb_idma_transpose_nd: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	# ── aligned (regression: M,N multiples of NE) ──
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=8   -gN=8  -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=16  -gN=16 -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=16  -gN=8  -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=64 -gM=32  -gN=24 -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=8   -gN=8  -gEB=2 tb_idma_transpose_nd -do "run -all; quit"
	# ── edge: partial output cols only (M%NE!=0, N%NE==0; within-beat wstrb) ──
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=6   -gN=8  -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	# ── edge: partial output rows only (N%NE!=0; zero-strobe drain beats) ──
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=8   -gN=6  -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	# ── edge: both partial (int8) ──
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=6   -gN=6  -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=5   -gN=7  -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=10  -gN=6  -gEB=1 tb_idma_transpose_nd -do "run -all; quit"
	# ── edge: fp16 (EB=2) and fp32 (EB=4) ──
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=5   -gN=5  -gEB=2 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=64 -gM=9   -gN=5  -gEB=4 tb_idma_transpose_nd -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=64 -gM=13  -gN=19 -gEB=1 tb_idma_transpose_nd -do "run -all; quit"

# Back-to-back regressions: the ND midend must reload each new transfer's base
# address (it does, for a protocol-compliant producer that drops nd_req_valid on
# accept). tb_idma_nd_midend_b2b checks the midend's burst-address sequence under
# backpressure; tb_idma_transpose_b2b checks two end-to-end transposes to distinct
# destinations.  Run with the Questa SEPP wrapper.
.PHONY: idma_sim_tb_idma_nd_midend_b2b
idma_sim_tb_idma_nd_midend_b2b: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc tb_idma_nd_midend_b2b -do "run -all; quit"

.PHONY: idma_sim_tb_idma_transpose_b2b
idma_sim_tb_idma_transpose_b2b: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=6  -gN=8 -gEB=1 tb_idma_transpose_b2b -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=8  -gN=8 -gEB=1 tb_idma_transpose_b2b -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=64 -gM=13 -gN=19 -gEB=1 tb_idma_transpose_b2b -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 -gM=5  -gN=5 -gEB=2 tb_idma_transpose_b2b -do "run -all; quit"

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

.PRECIOUS: $(IDMA_VLT_DIR)/%_elab.log

$(IDMA_VLT_DIR)/%_elab.log: $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_VLT_DIR)
	# We need a dedicated pickle here to set the defines
	$(BENDER) pickle $(IDMA_PICKLE_TARGETS) --top $(IDMA_VLT_TOP) -D VERILATOR --expand-macros -o $(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv
	cd $(IDMA_VLT_DIR); $(VERILATOR) $(IDMA_VLT_ARGS) $(IDMA_VLT_PARAMS) -Mdir obj_$* $(IDMA_VLT_TOP).sv --top-module $(IDMA_VLT_TOP) 2> $*_elab.log

idma_verilator_clean:
	rm -rf $(IDMA_VLT_DIR)


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

.PHONY: idma_spinx_doc idma_spinx_doc_clean

idma_spinx_doc: $(IDMA_RTL_DOC_ALL)
	$(SPHINXBUILD) -M html $(IDMA_DOC_SRC_DIR) $(IDMA_DOC_OUT_DIR)

idma_spinx_doc_clean:
	rm -rf $(IDMA_DOC_OUT_DIR)


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

.PHONY: idma_clean_all idma_clean idma_misc_clean

idma_clean_all idma_clean: idma_rtl_clean idma_reg_clean idma_pickle_clean idma_sim_clean idma_vcs_clean idma_verilator_clean idma_spinx_doc_clean idma_trace_clean

idma_misc_clean:
	rm -rf scripts/__pycache__
	rm -rf util/__pycache__
	rm -rf util/mario/__pycache__
	rm -f  gmon.out

idma_nuke: idma_clean idma_nonfree_clean
	rm -rf .bender


# --------------
# Phony Targets
# --------------

.PHONY: idma_all idma_doc_all idma_pickle_all idma_rtl_all idma_sim_all

idma_doc_all: idma_spinx_doc

idma_pickle_all: $(IDMA_PICKLE_ALL)

idma_hw_all: $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL) $(IDMA_FULL_TB) $(IDMA_HJSON_ALL) $(IDMA_WAVE_ALL)

idma_sim_all: $(IDMA_VCS_DIR)/compile.sh $(IDMA_VSIM_DIR)/compile.tcl

idma_all: idma_hw_all idma_sim_all idma_doc_all idma_pickle_all

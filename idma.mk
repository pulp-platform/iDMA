# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

BENDER      ?= bender
CAT         ?= cat
DOT         ?= dot
GIT         ?= git
MORTY       ?= morty
PEAKRDL     ?= peakrdl
PRINTF      ?= printf
PYTHON      ?= python3
SPHINXBUILD ?= sphinx-build
VCS         ?= vcs
VERILATOR   ?= verilator
VLOGAN      ?= vlogan

# Shell
SHELL := /bin/bash

# iDMA Variants
IDMA_BASE_IDS    := \
					rw_axi \
					r_obi_w_axi \
					r_axi_w_obi \
					rw_axi_rw_axis
IDMA_OCCAMY_IDS  := \
					r_obi_rw_init_w_axi \
					r_axi_rw_init_rw_obi
IDMA_ADD_IDS     ?=
IDMA_BACKEND_IDS := $(IDMA_BASE_IDS) $(IDMA_OCCAMY_IDS) $(IDMA_ADD_IDS)

# generated frontends
IDMA_BASE_FE_IDS := reg32_3d reg64_2d reg64_1d
IDMA_ADD_FE_IDS  ?=
IDMA_FE_IDS      := $(IDMA_BASE_FE_IDS) $(IDMA_ADD_FE_IDS)

# iDMA paths
IDMA_ROOT     ?= $(shell $(BENDER) path idma)
IDMA_REG_DIR  := $(shell $(BENDER) path register_interface)
IDMA_CC_DIR   := $(shell $(BENDER) path common_cells)
IDMA_REGTOOL  ?= $(IDMA_REG_DIR)/vendor/lowrisc_opentitan/util/regtool.py
IDMA_UTIL_DIR := $(IDMA_ROOT)/util
IDMA_RTL_DIR  := $(IDMA_ROOT)/target/rtl

# cf_math_pkg file
IDMA_CF_PKG   := $(IDMA_CC_DIR)/src/cf_math_pkg.sv

# job file
IDMA_JOBS_JSON := jobs/jobs.json

# Bender files
IDMA_BENDER_FILES := $(IDMA_ROOT)/Bender.yml \
					 $(IDMA_ROOT)/Bender.lock

# Helper functions
# Relative paths for VLOGAN
IDMA_VLOGAN_REL_PATHS    := | grep -v "ROOT=" | sed '3 i ROOT="../../.."'
# Morty helpers
IDMA_PATH_ESCAPED        := $(shell pwd | sed 's_/_\\/_g')
IDMA_RELATIVE_PATH_REGEX := 's/$(IDMA_PATH_ESCAPED)/./'

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
	$(PYTHON) $(IDMA_GEN) --entity $1 --tpl $2 --db $3 --ids $4 --fids $5 > $6
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

# ----

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

$(IDMA_RTL_DIR)/idma_desc64_reg_pkg.sv $(IDMA_RTL_DIR)/idma_desc_reg_top.sv $(IDMA_RTL_DIR)/idma_desc64_addrmap_pkg.sv:
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
IDMA_HJSON_ALL   += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y.hjson)


# ---------------
# RTL assembly
# ---------------

$(IDMA_FULL_RTL): $(IDMA_RTL_ALL)
	$(CAT) $^ > $@

$(IDMA_FULL_TB): $(IDMA_TB_ALL)
	$(CAT) $^ > $@


# ---------------
# Morty
# ---------------

.PHONY: idma_morty_clean

IDMA_PICKLE_DIR  := $(IDMA_ROOT)/target/morty
IDMA_MORTY_ARGS  ?=

$(IDMA_PICKLE_DIR)/sources.json: $(IDMA_BENDER_FILES) $(IDMA_FULL_TB) $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL)
	mkdir -p $(IDMA_PICKLE_DIR)
	$(BENDER) sources -f -t rtl -t synth -t asic -t snitch_cluster | sed -e $(IDMA_RELATIVE_PATH_REGEX) > $@

$(IDMA_PICKLE_DIR)/%.sv: $(IDMA_PICKLE_DIR)/sources.json
	$(MORTY) -f $< -i --top $* $(IDMA_MORTY_ARGS) --propagate_defines -o $@.pre
	# Hack cf_math_pkg in
	if grep -q "package cf_math_pkg;" "$@.pre"; then \
		$(CAT) $@.pre > $@; \
	else \
		$(CAT) $(IDMA_CF_PKG) $@.pre > $@; \
	fi
	rm -f $@.pre

$(IDMA_HTML_DIR)/%/index.html: $(IDMA_PICKLE_DIR)/%.sv
	mkdir -p $(IDMA_HTML_DIR)/$*
	$(MORTY) -i --doc $(IDMA_HTML_DIR)/$* $<

$(IDMA_PICKLE_DIR)/%.dot: $(IDMA_PICKLE_DIR)/sources.json
	$(MORTY) -f $< -i $(IDMA_MORTY_ARGS) --top $* --propagate_defines --graph_file $@ > /dev/null

$(IDMA_DOC_FIG_DIR)/graph/%.png: $(IDMA_PICKLE_DIR)/%.dot
	mkdir -p $(IDMA_DOC_FIG_DIR)/graph
	$(DOT) -Tpng $< > $@

idma_morty_clean:
	rm -rf $(IDMA_PICKLE_DIR)
	rm -f  $(IDMA_DOC_FIG_DIR)/graph/*.png
	rm -rf $(IDMA_HTML_DIR)

# 1Ds
IDMA_RTL_DOC_ALL += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_DOC_FIG_DIR)/graph/idma_backend_synth_$Y.png)
IDMA_RTL_DOC_ALL += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_HTML_DIR)/idma_backend_synth_$Y/index.html)
IDMA_PICKLE_ALL  += $(foreach Y,$(IDMA_BACKEND_IDS),$(IDMA_PICKLE_DIR)/idma_backend_synth_$Y.sv)

# nDs
IDMA_RTL_DOC_ALL += $(IDMA_DOC_FIG_DIR)/graph/idma_nd_midend_synth.png
IDMA_RTL_DOC_ALL += $(IDMA_HTML_DIR)/idma_nd_midend_synth/index.html
IDMA_PICKLE_ALL  += $(IDMA_PICKLE_DIR)/idma_nd_midend_synth.sv

# descriptor-based frontend
IDMA_RTL_DOC_ALL += $(IDMA_DOC_FIG_DIR)/graph/idma_desc64_synth.png
IDMA_RTL_DOC_ALL += $(IDMA_HTML_DIR)/idma_desc64_synth/index.html
IDMA_PICKLE_ALL  += $(IDMA_PICKLE_DIR)/idma_desc64_synth.sv

# RT midend
IDMA_RTL_DOC_ALL += $(IDMA_DOC_FIG_DIR)/graph/idma_rt_midend_synth.png
IDMA_RTL_DOC_ALL += $(IDMA_HTML_DIR)/idma_rt_midend_synth/index.html
IDMA_PICKLE_ALL  += $(IDMA_PICKLE_DIR)/idma_rt_midend_synth.sv

# Mempool midend
IDMA_RTL_DOC_ALL += $(IDMA_DOC_FIG_DIR)/graph/idma_mp_midend_synth.png
IDMA_RTL_DOC_ALL += $(IDMA_HTML_DIR)/idma_mp_midend_synth/index.html
IDMA_PICKLE_ALL  += $(IDMA_PICKLE_DIR)/idma_mp_midend_synth.sv


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
	$(call idma_generate_vsim, $@, -t sim -t test -t idma_test -t synth -t rtl -t asic -t snitch_cluster,../../..)

idma_sim_clean:
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

$(IDMA_VLT_DIR)/%_elab.log: $(IDMA_PICKLE_DIR)/sources.json
	mkdir -p $(IDMA_VLT_DIR)
	# We need a dedicated pickle here to set the defines
	$(MORTY) -f $< -i --top $(IDMA_VLT_TOP) -DVERILATOR --propagate_defines -o $(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv.pre
	# Hack cf_math_pkg in
	if grep -q "package cf_math_pkg;" "$(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv.pre"; then \
  		$(CAT) $(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv.pre > $(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv; \
	else \
		$(CAT) $(IDMA_CF_PKG) $(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv.pre > $(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv; \
	fi
	rm -f $(IDMA_VLT_DIR)/$(IDMA_VLT_TOP).sv.pre
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

idma_clean_all idma_clean: idma_rtl_clean idma_reg_clean idma_morty_clean idma_sim_clean idma_vcs_clean idma_verilator_clean idma_spinx_doc_clean idma_trace_clean

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

idma_hw_all: $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL) $(IDMA_FULL_TB) $(IDMA_WAVE_ALL)

idma_sim_all: $(IDMA_VCS_DIR)/compile.sh $(IDMA_VSIM_DIR)/compile.tcl

idma_all: idma_hw_all idma_sim_all idma_doc_all idma_pickle_all

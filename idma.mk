# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

BENDER      ?= bender
CAT         ?= cat
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
SPHINXBUILD ?= $(UV_RUN) sphinx-build

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
IDMA_RTL_ALL     += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_reg_pkg.sv)
IDMA_RTL_ALL     += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_reg_top.sv)
IDMA_RTL_ALL     += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_addrmap_pkg.sv)
IDMA_RTL_ALL     += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_RTL_DIR)/idma_$Y_top.sv)
IDMA_RTL_DOC_ALL += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_HTML_DIR)/regs/idma_$Y_reg/index.html)

# C headers
IDMA_SW_ALL      += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_SW_DIR)/idma_$Y_regs.h)
IDMA_SW_ALL      += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_SW_DIR)/idma_$Y_regs_unpacked.h)

# C headers with the "raw-header" plugin
IDMA_SW_ALL      += $(foreach Y,$(IDMA_FE_REGS),$(IDMA_SW_DIR)/idma_$Y_raw_regs.h)

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

.PHONY: idma_sim_tb_idma_transpose_b2b
idma_sim_tb_idma_transpose_b2b: $(IDMA_VSIM_DIR)/compile.tcl
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -do "source compile.tcl; quit"
	# the TB sweeps the geometry list internally; one run per bus width
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=32 tb_idma_transpose_b2b -do "run -all; quit"
	cd $(IDMA_VSIM_DIR); $(VSIM) -c -t 1ps -voptargs=+acc -gDataWidth=64 tb_idma_transpose_b2b -do "run -all; quit"

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

include $(IDMA_ROOT)/target/sim/vlt/testbenches.mk
include $(IDMA_ROOT)/target/sim/vlt/vlt.mk


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

.PHONY: idma_clean_all idma_clean idma_misc_clean idma_sw_clean

idma_clean_all idma_clean: idma_rtl_clean idma_reg_clean idma_pickle_clean idma_sim_clean idma_vcs_clean idma_verilator_clean idma_spinx_doc_clean idma_trace_clean idma_sw_clean

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

.PHONY: idma_all idma_doc_all idma_pickle_all idma_rtl_all idma_sim_all

idma_doc_all: idma_spinx_doc

idma_pickle_all: $(IDMA_PICKLE_ALL)

idma_hw_all: $(IDMA_FULL_RTL) $(IDMA_INCLUDE_ALL) $(IDMA_FULL_TB) $(IDMA_HJSON_ALL) $(IDMA_WAVE_ALL)

idma_sw_all: $(IDMA_SW_ALL)

idma_sim_all: $(IDMA_VCS_DIR)/compile.sh $(IDMA_VSIM_DIR)/compile.tcl

idma_all: idma_hw_all idma_sim_all idma_doc_all idma_pickle_all

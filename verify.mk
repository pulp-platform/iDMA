# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

# License-free verification: elaboration and simulation on verilator and slang
# only. Included by idma.mk, whose variables it uses; it adds no build rules, so
# building iDMA never reads it.

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

# verilator --timing compiles to C++20 coroutines, which g++ 11 miscompiles: the
# wide compute testbenches then SIGSEGV before time 0. Pick the newest available
# g++ rather than whatever `g++` happens to be; ubuntu-24.04 defaults to 13.
IDMA_VLT_CXX       ?= $(firstword $(foreach C,g++-14 g++-13 g++-13.2.0 g++-12 g++, \
                        $(if $(shell command -v $C 2>/dev/null),$C)))
IDMA_VLT_CXX_MAJOR := $(shell $(IDMA_VLT_CXX) -dumpfullversion -dumpversion 2>/dev/null | cut -d. -f1)

# Prepended, so a caller passing IDMA_VLT_MAKEFLAGS=-j4 adds to the toolchain
# rather than silently replacing it
IDMA_VLT_SIM       := VERILATOR="$(VERILATOR)" \
                      IDMA_VLT_MAKEFLAGS="CXX=$(IDMA_VLT_CXX) LINK=$(IDMA_VLT_CXX) $(IDMA_VLT_MAKEFLAGS)" \
                      $(PYTHON) $(IDMA_UTIL_DIR)/run_vlt_sim.py --dir $(IDMA_VLT_DIR)

# Fail loudly here; the symptom otherwise is a SIGSEGV with an empty log
.PHONY: idma_verify_toolchain
idma_verify_toolchain:
	@test -n "$(IDMA_VLT_CXX)" || { echo "error: no g++ found"; exit 1; }
	@test "$(IDMA_VLT_CXX_MAJOR)" -ge 12 2>/dev/null || { \
	  echo "error: $(IDMA_VLT_CXX) is g++ $(IDMA_VLT_CXX_MAJOR); the coroutine"; \
	  echo "       lowering needs g++ 12 or newer. Set IDMA_VLT_CXX=<g++-13 or newer>."; \
	  exit 1; }

# mxquant runs every width. mxroundtrip stops at 256: at 512 the run dies with a
# glibc heap abort that is not in the DPI golden (static, bounds-checked) and is
# invisible to ASAN; verilator 5.046 moves it to 256 rather than fixing it, so it
# is a live bug, not a width limit. Do not widen this without a fix.
IDMA_MXQUANT_WIDTHS ?= 32 64 256 512 1024
IDMA_MXRT_WIDTHS    ?= 32 64 256

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
IDMA_MXNEG_SKIP    := 4:DataWidth-1024-SIGSEGVs-on-verilator-5.020-passes-on-5.046 \
                      11:request-never-accepted-guard-never-sampled \
                      12:DataWidth-1024-SIGSEGVs-on-verilator-5.020-passes-on-5.046
IDMA_MXNEG_GUARD_SKIP := ComputeMxFp16Width:only-reachable-from-the-skipped-1024-cases \
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

idma_verify_sim_mxquant: idma_verify_toolchain $(IDMA_VLT_DIR)/tb_idma_mxquant.f $(IDMA_VLT_DIR)/idma_mxquant_dpi.o
	set -e; for dw in $(IDMA_MXQUANT_WIDTHS); do \
	  $(IDMA_VLT_SIM) --top tb_idma_mxquant --flist $(IDMA_VLT_DIR)/tb_idma_mxquant.f \
	    --tag mxquant_$$dw --param DataWidth=$$dw \
	    --dpi $(IDMA_VLT_DIR)/idma_mxquant_dpi.o --token "[MXQ] ALL PASS"; \
	done

idma_verify_sim_mxroundtrip: idma_verify_toolchain $(IDMA_VLT_DIR)/tb_idma_mxroundtrip.f \
                             $(IDMA_VLT_DIR)/idma_mxquant_dpi.o
	set -e; for dw in $(IDMA_MXRT_WIDTHS); do \
	  $(IDMA_VLT_SIM) --top tb_idma_mxroundtrip \
	    --flist $(IDMA_VLT_DIR)/tb_idma_mxroundtrip.f \
	    --tag mxroundtrip_$$dw --param DataWidth=$$dw \
	    --dpi $(IDMA_VLT_DIR)/idma_mxquant_dpi.o --token "[MXRT] ALL PASS"; \
	done

# +BP is a second stimulus (backpressured transpose), not a rerun
idma_verify_sim_transpose: idma_verify_toolchain $(IDMA_VLT_DIR)/tb_idma_otf_transpose.f \
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
idma_verify_sim_mxclear: idma_verify_toolchain $(IDMA_VLT_DIR)/tb_idma_mxclear.f
	set -e; for q in 1 0; do \
	  $(IDMA_VLT_SIM) --top tb_idma_mxclear --flist $(IDMA_VLT_DIR)/tb_idma_mxclear.f \
	    --tag mxclear_$$q --param Quant=$$q --define INC_ASSERT --expect fail \
	    --token "clear with in-flight state"; \
	done

idma_verify_sim_mxneg: idma_verify_toolchain $(IDMA_VLT_DIR)/tb_idma_mxneg.f $(IDMA_VLT_DIR)/idma_mxquant_dpi.o
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

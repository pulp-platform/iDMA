# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Thomas Benz <tbenz@iis.ee.ethz.ch>

GIT ?= git
BENDER ?= bender
PYTHON ?= python3

.PHONY: all help prepare_sim

# phony targets
all: help

prepare_sim: scripts/compile_vsim.tcl scripts/compile_vcs.sh

clean: sim_clean vcs_clean ver_clean pickle_clean doc_clean misc_clean jobs_clean

# Ensure half-built targets are purged
.DELETE_ON_ERROR:


# --------------
# help
# --------------

help:
	@echo ""
	@echo "iDMA Makefile"
	@echo "-------------"
	@echo ""
	@echo "prepare_sim:                       uses bender to generate the analyze scripts needed for simulating the iDMA"
	@echo "bin/iDMA.vcs VCS_TP=**YOUR_TB**:   creates the VCS executable"
	@echo "obj_iDMA VLT_TOP=**YOUR_TOP_LVL**: elaborates the hardware using verilator"
	@echo "pickle:                            uses morty to generate a pickled version of the hardware"
	@echo "doc:                               generates the documentation in doc/build"
	@echo "gen_ci:                            regenerates the gitlab CI (only ETH internal used)"
	@echo "gen_regs:                          regenerates the registers using reggen"
	@echo ""
	@echo "clean:                             cleans generated files"
	@echo "nuke:                              cleans all generated file, also almost all files checked in"
	@echo ""


# --------------
# QuestaSim
# --------------

.PHONY: sim_clean

VLOG_ARGS += -suppress vlog-2583 -suppress vlog-13314 -suppress vlog-13233 -timescale \"1 ns / 1 ps\"
XVLOG_ARGS += -64bit -compile -vtimescale 1ns/1ns -quiet

define generate_vsim
	echo 'set ROOT [file normalize [file dirname [info script]]/$3]' > $1
	$(BENDER) script vsim --vlog-arg="$(VLOG_ARGS)" $2 | grep -v "set ROOT" >> $1
	echo >> $1
endef

scripts/compile_vsim.tcl: Bender.yml
	$(call generate_vsim, $@, -t rtl -t test,..)

sim_clean:
	rm -rf scripts/compile_vsim.tcl
	rm -rf work
	rm -f  dma_trace_*
	rm -f  dma_transfers.txt
	rm -f  transcript
	rm -f  wlf*
	rm -f  logs/wlf*
	rm -f  logs/*.wlf
	rm -f  *.vstf
	rm -f  *.vcd
	rm -f  modelsim.ini
	rm -f  logs/*vsim.log


# --------------
# VCS
# --------------

.PHONY: vcs_compile vcs_clean

VLOGAN_ARGS := -assert svaext
VLOGAN_ARGS += -assert disable_cover
VLOGAN_ARGS += -full64
VLOGAN_ARGS += -sysc=q
VLOGAN_ARGS += -nc
VLOGAN_ARGS += -q
VLOGAN_ARGS += -timescale=1ns/1ns

VCS_ARGS    := -full64
VCS_ARGS    += -Mlib=work-vcs
VCS_ARGS    += -Mdir=work-vcs
VCS_ARGS    += -debug_access+r
VCS_ARGS    += -j 8
VCS_ARGS    += -CFLAGS "-Os"

VCS_PARAMS  ?=
VCS_TB      ?=

VLOGAN_BIN  ?= vlogan
VCS_BIN     ?= vcs

VLOGAN_REL_PATHS ?= | grep -v "ROOT=" | sed '3 i ROOT="."'

scripts/compile_vcs.sh: Bender.yml Bender.lock
	$(BENDER) script vcs -t test -t rtl -t simulation --vlog-arg "\$(VLOGAN_ARGS)" --vlogan-bin "$(VLOGAN_BIN)" $(VLOGAN_REL_PATHS) > $@
	chmod +x $@

vcs_compile: scripts/compile_vcs.sh
	scripts/compile_vcs.sh

bin/%.vcs: scripts/compile_vcs.sh vcs_compile
	mkdir -p bin
	$(VCS_BIN) $(VCS_ARGS) $(VCS_PARAMS) $(VCS_TB) -o $@

vcs_clean:
	rm -rf AN.DB
	rm -f  scripts/compile_vcs.sh
	rm -rf bin
	rm -rf work-vcs
	rm -f  ucli.key
	rm -f  vc_hdrs.h
	rm -f  logs/*.vcs.log


## --------------
## Verilator
## --------------

.PHONY: ver_clean

VERILATOR ?= verilator

VLT_ARGS  :=
VLT_ARGS  += --cc
VLT_ARGS  += --Wall
VLT_ARGS  += --Wno-fatal
VLT_ARGS  += +1800-2017ext+
VLT_ARGS  += --assert
VLT_ARGS  += --hierarchical
VLT_ARGS  += --no-skip-identical

VLT_TOP   ?=

verilator/files_raw.txt: Bender.yml Bender.lock
	$(BENDER) script verilator -t synthesis > $@

verilator/files.txt: verilator/scripts/preprocess.py verilator/files_raw.txt
	$(PYTHON) $^ > $@

obj_%: verilator/files.txt
	$(VERILATOR) $(VLT_ARGS) -Mdir obj_$* -f $^ --top-module $(VLT_TOP) 2> logs/verilator_$*_elab.log

ver_clean:
	rm -rf obj_*
	rm -f  logs/verilator*.log
	rm -f  verilator/files*.txt


# ---------------
# Morty (Pickle)
# ---------------

.PHONY: pickle pickle_clean

MORTY               ?= morty
PATH_ESCAPED         = $(shell pwd | sed 's_/_\\/_g')
RELATIVE_PATH_REGEX  = 's/$(PATH_ESCAPED)/./'

pickle: pickle/idma_pickle.sv pickle/idma_pickle_stripped.sv

sources.txt: Bender.yml Bender.lock
	$(BENDER) script flist -t rtl -t synthesis -t pulp -t cva6 | sed -e $(RELATIVE_PATH_REGEX) > sources.txt

pickle/idma_pickle.sv: sources.txt gen_regs
	mkdir -p pickle
	$(MORTY) -s _pickle $$(cat sources.txt | sed -e "s/+incdir+/-I /") -o $@

pickle/idma_pickle_stripped.sv: sources.txt gen_regs
	mkdir -p pickle
	$(MORTY) --strip-comments -s _pickle_stripped $$(cat sources.txt | sed -e "s/+incdir+/-I /") -o $@

pickle_clean:
	rm -rf pickle


# --------------
# Doc
# --------------

.PHONY: doc doc_clean

SPHINXBUILD ?= sphinx-build

doc: sources.txt gen_regs
	$(MAKE) -C doc morty-docs regs html SPHINXBUILD=$(SPHINXBUILD)

doc_clean:
	$(MAKE) -C doc clean
	rm -rf  doc/build
	rm  -f  doc/gmon.out


# --------------
# Misc Clean
# --------------

.PHONY: misc_clean nuke

misc_clean:
	rm -rf scripts/__pycache__
	rm -rf scripts/synth.*.params.tcl
	rm -f  sources.txt
	rm -f  contributions.txt
	rm -f  open_todos.txt
	rm -f  gmon.out

nuke: clean regs_clean ci_clean
	rm -rf .bender


## --------------
## Job File
## --------------

.PHONY: gen_jobs jobs_clean

JOBS_JSON   ?= jobs.json
JOBS_OUTDIR ?= jobs

$(JOBS_OUTDIR):
	mkdir -p $(JOBS_OUTDIR)

gen_jobs: $(JOBS_JSON) util/gen_jobs.py | $(JOBS_OUTDIR)
	$(PYTHON) util/gen_jobs.py $(JOBS_JSON) $(JOBS_OUTDIR)

jobs_clean:
	rm -f jobs/gen_*.txt
	rm -f jobs/*/gen_*.txt


## --------------
## CI
## --------------

.PHONY: gen_ci ci_clean

CI_TPL ?= .ci/gitlab-ci.yml.tpl

gen_ci: .gitlab-ci.yml

.gitlab-ci.yml: $(CI_TPL) util/gen_ci.py $(JOBS_JSON)
	$(PYTHON) util/gen_ci.py $(JOBS_JSON) $(CI_TPL) > $@

ci_clean:
	rm -f .gitlab-ci.yml

bender:
ifeq (,$(wildcard ./bender))
	curl --proto '=https' --tlsv1.2 -sSf https://pulp-platform.github.io/bender/init \
		| bash -s -- 0.25.3
	touch bender
endif

.PHONY: bender-rm
bender-rm:
	rm -f bender


## --------------
## Register
## --------------

.PHONY: gen_regs reg32_2d_regs reg64_regs desc64_regs regs_clean

REG_PATH ?= $(shell $(BENDER) path register_interface)
REG_TOOL ?= $(REG_PATH)/vendor/lowrisc_opentitan/util/regtool.py

REG32_2D_FE_DIR = src/frontends/register_32bit_2d/
REG32_2D_HJSON = $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend.hjson
REG64_FE_DIR = src/frontends/register_64bit/
REG64_HJSON = $(REG64_FE_DIR)/idma_reg64_frontend.hjson
DESC64_FE_DIR = src/frontends/desc64/
DESC64_HJSON = $(DESC64_FE_DIR)/idma_desc64_frontend.hjson

REG_HTML_STRING = "<!DOCTYPE html>\n<html>\n<head>\n<link rel="stylesheet" href="reg_html.css">\n</head>\n"

gen_regs: reg32_2d_regs reg64_regs desc64_regs

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

regs_clean:
	rm -f $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend.h
	rm -f $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend_reg_pkg.sv
	rm -f $(REG32_2D_FE_DIR)/idma_reg32_2d_frontend_reg_top.sv
	rm -f $(REG32_2D_FE_DIR)/reg_html.css
	rm -f $(REG64_FE_DIR)/idma_reg64_frontend.h
	rm -f $(REG64_FE_DIR)/idma_reg32_frontend_reg_pkg.sv
	rm -f $(REG64_FE_DIR)/idma_reg32_frontend_reg_top.sv
	rm -f $(REG64_FE_DIR)/reg_html.css
	rm -f $(DESC64_FE_DIR)/idma_desc64_frontend.h
	rm -f $(DESC64_FE_DIR)/idma_desc64_reg_pkg.sv
	rm -f $(DESC64_FE_DIR)/idma_desc64_reg_top.sv
	rm -f $(DESC64_FE_DIR)/reg_html.css

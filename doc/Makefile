# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Minimal makefile for Sphinx documentation

# You can set these variables from the command line.
SPHINXOPTS    =
SPHINXBUILD  ?= sphinx-build
SPHINXPROJ    = iDMA
SOURCEDIR     = source
BUILDDIR      = build
MORTY        ?= morty

all-html: morty-docs regs html

# Put it first so that "make" without argument is like "make help".
help:
	@$(SPHINXBUILD) -M help "$(SOURCEDIR)" "$(BUILDDIR)" $(SPHINXOPTS) $(O)

.PHONY: help Makefile morty-docs

# Catch-all target: route all unknown targets to Sphinx using the new
# "make mode" option.  $(O) is meant as a shortcut for $(SPHINXOPTS).
%: Makefile
	@$(SPHINXBUILD) -M $@ "$(SOURCEDIR)" "$(BUILDDIR)" $(SPHINXOPTS) $(O)

# Requires an up-to-date morty installation
morty-docs:
	$(MORTY) $$(cat ../sources.txt | sed -e "s/+incdir+/-I /" | sed -e "s/.\//..\//" | grep "\.\.\/src/\|-I") --doc $(BUILDDIR)/html/morty

regs:
	mkdir -p $(BUILDDIR)/html/regs
	cp ../src/frontends/register_32bit_2d/idma_reg32_2d_frontend.html $(BUILDDIR)/html/regs/.
	cp ../src/frontends/register_64bit/idma_reg64_frontend.html $(BUILDDIR)/html/regs/.
	cp ../src/frontends/desc64/idma_desc64_frontend.html build/html/regs/.
	cp ../src/frontends/register_32bit_2d/reg_html.css $(BUILDDIR)/html/regs/.


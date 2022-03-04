# Minimal makefile for Sphinx documentation
#

# You can set these variables from the command line.
SPHINXOPTS    =
SPHINXBUILD   = sphinx-build
SPHINXPROJ    = iDMA
SOURCEDIR     = source
BUILDDIR      = build

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
	morty -d $(BUILDDIR)/html/morty ../src/*.sv

regs:
	mkdir -p $(BUILDDIR)/html/regs
	cp ../src/frontends/register_32bit_2d/idma_reg32_2d_frontend.html $(BUILDDIR)/html/regs/.
	cp ../src/frontends/register_64bit/idma_reg64_frontend.html $(BUILDDIR)/html/regs/.
	cp ../src/frontends/register_32bit_2d/reg_html.css $(BUILDDIR)/html/regs/.

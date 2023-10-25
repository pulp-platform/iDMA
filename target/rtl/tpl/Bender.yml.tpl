# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

package:
  name: idma_gen
  authors:
    - "Thomas Benz <tbenz@iis.ee.ethz.ch>"
    - "Tobias Senti <tsenti@ethz.ch>"

dependencies:
  common_cells:       { git: "https://github.com/pulp-platform/common_cells.git",       version: 1.31.1 }
  axi:                { git: "https://github.com/pulp-platform/axi.git",                version: 0.39.0 }
  register_interface: { git: "https://github.com/pulp-platform/register_interface.git", version: 0.4.2  }

export_include_dirs:
  - ../../src/include
  - ../../test

sources:
  # Source files grouped in levels. Files in level 0 have no dependencies on files in this
  # package. Files in level 1 only depend on files in level 0, files in level 2 on files in
  # levels 1 and 0, etc. Files within a level are ordered alphabetically.
  - target: rtl
    files:
      # Level 0
      - ../../src/idma_pkg.sv
      - idma_desc64_reg_pkg.sv
${fe_packages}
      # Level 1
      - idma_desc64_reg_top.sv
${fe_sources}
${rtl_sources}
  - target: test
    files:
      # Level 0
      - ../../test/idma_intf.sv
      # Level 1
      - ../../test/idma_test.sv
      # Level 2
${test_sources}
  - target: synthesis
    files:
      # Level 0
${synth_sources}

# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
package:
  name: idma_backend
  authors:
    - "Tobias Senti <tsenti@student.ethz.ch>"

dependencies:
  common_cells:    { git: "https://github.com/pulp-platform/common_cells.git", version: 1.31.1 }
  axi:             { git: "https://github.com/pulp-platform/axi.git",          version: 0.39.0 }

  tb_idma_backend: { path: "../../test" }
  idma_pkg:        { path: "../package" } 

export_include_dirs:
  - ../include

sources:
  # Source files grouped in levels. Files in level 0 have no dependencies on files in this
  # package. Files in level 1 only depend on files in level 0, files in level 2 on files in
  # levels 1 and 0, etc. Files within a level are ordered alphabetically.
  # Level 0
  - src/idma_axi_lite_read.sv
  - src/idma_axi_lite_write.sv
  - src/idma_axi_read.sv
  - src/idma_axi_write.sv
  - src/idma_obi_read.sv
  - src/idma_obi_write.sv
  - src/idma_tilelink_read.sv
  - src/idma_tilelink_write.sv
  - src/idma_init_read.sv
  - src/idma_axi_stream_read.sv
  - src/idma_axi_stream_write.sv
  - src/idma_stream_fifo.sv
  - src/idma_improved_fifo.sv
  - src/idma_legalizer_page_splitter.sv
  - src/idma_legalizer_pow2_splitter.sv
  # Level 1
  - src/idma_dataflow_element.sv
  - src/idma_error_handler.sv
  - src/idma_channel_coupler.sv

  # Backends

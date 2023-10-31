// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "idma/typedef.svh"

/// Synthesis package for the Mempool midend
package idma_mp_midend_synth_pkg;

    localparam int unsigned NumBEs      = 32'd8;
    localparam int unsigned RegionWidth = 32'h0001_0000;
    localparam int unsigned RegionStart = 32'h0000_0000;
    localparam int unsigned RegionEnd   = 32'h1000_0000;

    typedef logic [5:0]  axi_id_t;
    typedef logic [31:0] tf_len_t;
    typedef logic [31:0] axi_addr_t;

    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_id_t, axi_addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, axi_addr_t)

endpackage

// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

/// synth package
package idma_desc64_synth_pkg;

    `include "apb/typedef.svh"
    `include "axi/typedef.svh"
    `include "idma/typedef.svh"

    localparam int unsigned AddrWidth        = 64;
    localparam int unsigned DataWidth        = 64;
    localparam int unsigned StrbWidth        = DataWidth / 8;
    localparam int unsigned OneDLength       = 32;
    localparam int unsigned IdWidth          = 8;
    localparam int unsigned UserWidth        = 1;
    localparam int unsigned TFLenWidth       = 32;
    localparam int unsigned InputFifoDepth   = 8;
    localparam int unsigned PendingFifoDepth = 8;

    typedef logic [AddrWidth-1:0]  addr_t;
    typedef logic [DataWidth-1:0]  data_t;
    typedef logic [StrbWidth-1:0]  strb_t;
    typedef logic [OneDLength-1:0] length_t;
    typedef logic [IdWidth-1:0]    id_t;
    typedef logic [UserWidth-1:0]  user_t;
    typedef logic [TFLenWidth-1:0] tf_len_t;

    `APB_TYPEDEF_ALL(apb, addr_t, data_t, strb_t)
    `AXI_TYPEDEF_ALL_CT(axi, axi_req_t, axi_rsp_t, addr_t, id_t, data_t, strb_t, user_t)
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

endpackage

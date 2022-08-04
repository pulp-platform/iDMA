// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

// synth package
package idma_desc64_synth_pkg;

    `include "register_interface/typedef.svh"

    localparam int unsigned AddrWidth  = 64;
    localparam int unsigned DataWidth  = 64;
    localparam int unsigned StrbWidth  = DataWidth / 8;
    localparam int unsigned OneDLength = 32;
    localparam int unsigned IdWidth    = 8;

    typedef logic [AddrWidth-1:0]  addr_t;
    typedef logic [DataWidth-1:0]  data_t;
    typedef logic [StrbWidth-1:0]  strb_t;
    typedef logic [OneDLength-1:0] length_t;
    typedef logic [IdWidth-1:0]    id_t;

    `REG_BUS_TYPEDEF_ALL(reg, addr_t, data_t, strb_t)

    typedef struct packed {
        id_t              id;
        addr_t            src;
        addr_t            dst;
        length_t          num_bytes;
        axi_pkg::cache_t  src_cache;
        axi_pkg::cache_t  dst_cache;
        axi_pkg::burst_t  src_burst;
        axi_pkg::burst_t  dst_burst;
        logic             decouple_rw;
        logic             deburst;
        logic             serialize;
    } burst_req_t;

endpackage : idma_desc64_synth_pkg

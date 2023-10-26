// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

/// This module reshapes the 256 bits of a descriptor into its corresponding
/// iDMA backend request
module idma_desc64_reshaper #(
    parameter type idma_req_t   = logic,
    parameter type addr_t       = logic,
    parameter type descriptor_t = logic
)(
    input  descriptor_t  descriptor_i,
    output idma_req_t    idma_req_o,
    output addr_t        next_addr_o,
    output logic         do_irq_o
);

assign next_addr_o = descriptor_i.next;
assign do_irq_o    = descriptor_i.flags[0];

always_comb begin
        idma_req_o                        = '0;

        idma_req_o.length                 = descriptor_i.length;
        idma_req_o.src_addr               = descriptor_i.src_addr;
        idma_req_o.dst_addr               = descriptor_i.dest_addr;

        // Current backend only supports one ID
        idma_req_o.opt.axi_id             = descriptor_i.flags[23:16];
        idma_req_o.opt.src.burst          = descriptor_i.flags[2:1];
        idma_req_o.opt.src.cache          = descriptor_i.flags[11:8];
        // AXI4 does not support locked transactions, use atomics
        idma_req_o.opt.src.lock           = '0;
        // unpriviledged, secure, data access
        idma_req_o.opt.src.prot           = '0;
        // not participating in qos
        idma_req_o.opt.src.qos            = '0;
        // only one region
        idma_req_o.opt.src.region         = '0;
        idma_req_o.opt.dst.burst          = descriptor_i.flags[4:3];
        idma_req_o.opt.dst.cache          = descriptor_i.flags[15:12];
        // AXI4 does not support locked transactions, use atomics
        idma_req_o.opt.dst.lock           = '0;
        // unpriviledged, secure, data access
        idma_req_o.opt.dst.prot           = '0;
        // not participating in qos
        idma_req_o.opt.dst.qos            = '0;
        // only one region in system
        idma_req_o.opt.dst.region         = '0;
        idma_req_o.opt.beo.decouple_aw    = descriptor_i.flags[6];
        idma_req_o.opt.beo.decouple_rw    = descriptor_i.flags[5];
        // this frontend currently only supports completely debursting
        idma_req_o.opt.beo.src_max_llen   = '0;
        // this frontend currently only supports completely debursting
        idma_req_o.opt.beo.dst_max_llen   = '0;
        idma_req_o.opt.beo.src_reduce_len = descriptor_i.flags[7];
        idma_req_o.opt.beo.dst_reduce_len = descriptor_i.flags[7];
end

endmodule

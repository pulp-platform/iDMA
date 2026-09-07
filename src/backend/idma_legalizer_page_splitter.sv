// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Tobias Senti <tsenti@ethz.ch>

/// Legalizer module implementing a page splitter
module idma_legalizer_page_splitter #(
    parameter int unsigned PageAddrWidth = 32'd5,
    parameter type         addr_t        = logic,
    parameter type         page_len_t    = logic,
    parameter type         page_addr_t   = logic
) (
    /// current address
    input  addr_t                    addr_i,
    /// page size, log2 bytes
    input  logic [PageAddrWidth-1:0] page_width_i,
    /// number of bytes until the next page boundary
    output page_len_t                num_bytes_to_pb_o
);
    page_len_t  page_size;
    page_addr_t page_offset;

    // calculate the page size in bytes
    assign page_size = page_len_t'(1 << page_width_i);

    // this is written very confusing due to system verilog not allowing variable
    // length ranges.
    // the goal is to get 'addr_i[page_width_i-1:0]' where page_width_i is dynamically
    // changing
    always_comb begin : proc_range_select
        page_offset = '0;
        for (int i = 0; i < PageAddrWidth; i++) begin
            page_offset[i] = (page_width_i > i) ? addr_i[i] : 1'b0;
        end
    end

    // calculate the number of bytes left in the page (number of bytes until
    // we reach the page boundary (bp)
    assign num_bytes_to_pb_o = page_size - page_offset;

endmodule

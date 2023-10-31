// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "idma/typedef.svh"

/// Sanity testbench for the RT midend
module tb_idma_rt_midend;

    logic clk;
    logic rst_n;

    localparam int unsigned NumEvents = 5;
    localparam int unsigned NumDim = 3;

    typedef logic [5:0]  axi_id_t;
    typedef logic [31:0] tf_len_t;
    typedef logic [31:0] axi_addr_t;
    typedef logic [31:0] reps_t;
    typedef logic [31:0] strides_t;

    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_id_t, axi_addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, axi_addr_t)
    `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)

    tf_len_t [NumEvents-1:0] event_counts = '0;
    logic    [NumEvents-1:0] event_ena    = '0;

    clk_rst_gen #(
        .ClkPeriod    ( 1ns ),
        .RstClkCycles ( 1   )
    ) i_clk_rst_gen (
        .clk_o  ( clk   ),
        .rst_no ( rst_n )
    );

    // DUT
    idma_rt_midend #(
        .NumEvents      ( NumEvents      ),
        .EventCntWidth  ( 32'd32         ),
        .NumOutstanding ( 32'd2          ),
        .addr_t         ( axi_addr_t     ),
        .idma_nd_req_t  ( idma_nd_req_t  ),
        .idma_rsp_t     ( idma_rsp_t     )
    ) i_idma_rt_midend (
        .clk_i             ( clk              ),
        .rst_ni            ( rst_n            ),
        .event_counts_i    ( event_counts     ),
        .src_addr_i        ( '0               ),
        .dst_addr_i        ( '0               ),
        .length_i          ( {32'd1, 32'd2, 32'd3, 32'd4, 32'd5} ),
        .src_1d_stride_i   ( '0               ),
        .dst_1d_stride_i   ( '0               ),
        .num_1d_reps_i     ( '0               ),
        .src_2d_stride_i   ( '0               ),
        .dst_2d_stride_i   ( '0               ),
        .num_2d_reps_i     ( '0               ),
        .event_ena_i       ( event_ena        ),
        .event_counts_o    (),
        .nd_req_o          (),
        .nd_req_valid_o    (),
        .nd_req_ready_i    ( 1'b1             ),
        .burst_rsp_i       ( '1               ),
        .burst_rsp_valid_i ( 1'b1             ),
        .burst_rsp_ready_o (),
        .nd_req_i          ( '1               ),
        .nd_req_ready_o    (),
        .nd_req_valid_i    ( 1'b0             ),
        .burst_rsp_o       ( ),
        .burst_rsp_valid_o ( ),
        .burst_rsp_ready_i ( 1'b1             )
    );

    initial begin
        event_counts = {32'd17, 32'd300, 32'd800, 32'd1000, 32'd2000};
        #10ns;
        event_ena    = {1'd1, 1'd1, 1'd1, 1'd1, 1'd1};
        #5000ns;
        $finish();
    end

endmodule

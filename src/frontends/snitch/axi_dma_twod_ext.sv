// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Thomas Benz <tbenz@ethz.ch>

`include "common_cells/registers.svh"

/// Accept 2D requests and flatten them to 1D requests.
module axi_dma_twod_ext #(
    parameter int unsigned ADDR_WIDTH      = -1,
    parameter int unsigned REQ_FIFO_DEPTH  = -1,
    parameter type burst_req_t = logic,
    parameter type twod_req_t = logic
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    /// Arbitrary burst request
    output burst_req_t               burst_req_o,
    output logic                     burst_req_valid_o,
    input  logic                     burst_req_ready_i,
    /// 2D Request
    input  twod_req_t                twod_req_i,
    input  logic                     twod_req_valid_i,
    output logic                     twod_req_ready_o,
    /// 2D Request Completed
    output logic                     twod_req_last_o
);

    //--------------------------------------
    // 2D Request Fifo
    //--------------------------------------
    // currently worked on element
    twod_req_t twod_req_current;
    // control signals
    logic req_fifo_full;
    logic req_fifo_empty;
    logic req_fifo_push;
    logic req_fifo_pop;

    fifo_v3 #(
        .DEPTH       ( REQ_FIFO_DEPTH            ),
        .dtype       ( twod_req_t                )
    ) i_twod_req_fifo_v3 (
        .clk_i       ( clk_i              ),
        .rst_ni      ( rst_ni             ),
        .flush_i     ( 1'b0               ),
        .testmode_i  ( 1'b0               ),
        .full_o      ( req_fifo_full      ),
        .empty_o     ( req_fifo_empty     ),
        .usage_o     ( ),
        .data_i      ( twod_req_i         ),
        .push_i      ( req_fifo_push      ),
        .data_o      ( twod_req_current   ),
        .pop_i       ( req_fifo_pop       )
    );

    // handshaking to fill the fifo
    assign twod_req_ready_o     = !req_fifo_full;
    assign req_fifo_push        = twod_req_valid_i & twod_req_ready_o;

    //--------------------------------------
    // Counter
    //--------------------------------------
    logic [ADDR_WIDTH-1:0] num_bursts_d,  num_bursts_q;
    logic [ADDR_WIDTH-1:0] src_address_d, src_address_q;
    logic [ADDR_WIDTH-1:0] dst_address_d, dst_address_q;

    //--------------------------------------
    // 2D Extension
    //--------------------------------------
    always_comb begin : proc_twod_ext
        // defaults
        req_fifo_pop      = 1'b0;
        burst_req_o       =  '0;
        burst_req_valid_o = 1'b0;
        twod_req_last_o   = 1'b0;

        // counter keeps its value
        num_bursts_d  = num_bursts_q;
        src_address_d = src_address_q;
        dst_address_d = dst_address_q;

        //--------------------------------------
        // 1D Case
        //--------------------------------------
        // in the case that we have a 1D transfer, hand the transfer out
        if (!twod_req_current.is_twod) begin
            // bypass the 1D parameters
            burst_req_o.id           = twod_req_current.id;
            burst_req_o.src          = twod_req_current.src;
            burst_req_o.dst          = twod_req_current.dst;
            burst_req_o.num_bytes    = twod_req_current.num_bytes;
            burst_req_o.cache_src    = twod_req_current.cache_src;
            burst_req_o.cache_dst    = twod_req_current.cache_dst;
            burst_req_o.burst_src    = twod_req_current.burst_src;
            burst_req_o.burst_dst    = twod_req_current.burst_dst;
            burst_req_o.decouple_rw  = twod_req_current.decouple_rw;
            burst_req_o.deburst      = twod_req_current.deburst;

            // handshaking
            req_fifo_pop      = burst_req_ready_i & ~req_fifo_empty;
            burst_req_valid_o = ~req_fifo_empty;
            twod_req_last_o   = 1'b1;

        //--------------------------------------
        // 2D Case - Counter Management
        //--------------------------------------
        // in the 2D case: we need to work with a counter
        end else begin
            // some signals are bypassed
            burst_req_o.id           = twod_req_current.id;
            burst_req_o.num_bytes    = twod_req_current.num_bytes;
            burst_req_o.cache_src    = twod_req_current.cache_src;
            burst_req_o.cache_dst    = twod_req_current.cache_dst;
            burst_req_o.burst_src    = twod_req_current.burst_src;
            burst_req_o.burst_dst    = twod_req_current.burst_dst;
            burst_req_o.decouple_rw  = twod_req_current.decouple_rw;
            burst_req_o.deburst      = twod_req_current.deburst;

            // check if the counter can be loaded
            if ((num_bursts_q == '0) & !req_fifo_empty & burst_req_ready_i) begin
                // load the counters
                // check first if num_repetitions is 0. Start the counters if the input is != 0
                if (twod_req_current.num_repetitions != '0) begin
                    num_bursts_d  = twod_req_current.num_repetitions - 'h1;
                    src_address_d = twod_req_current.src;
                    dst_address_d = twod_req_current.dst;
                    // signal that the counter has now valid data
                    burst_req_valid_o = 1'b1;

                // the num_repetitions is 0.
                end else begin
                    // just pop the invalid request out of the fifo
                    req_fifo_pop = 1'b1;
                end

            // check if we should count down
            end else if ((num_bursts_q != '0) & !req_fifo_empty & burst_req_ready_i) begin
                // we can send out an request
                num_bursts_d  = num_bursts_q - 'h1;
                // modify addresses
                src_address_d = src_address_q + twod_req_current.stride_src;
                dst_address_d = dst_address_q + twod_req_current.stride_dst;
                // request is valid
                burst_req_valid_o = 1'b1;
                // if counter has finished -> pop fifo
                if (num_bursts_d == '0) begin
                    req_fifo_pop    = 1'b1;
                    twod_req_last_o = 1'b1;
                end
            end

            // present modified signals
            burst_req_o.src = src_address_d;
            burst_req_o.dst = dst_address_d;
        end
    end

    //--------------------------------------
    // Update Counters
    //--------------------------------------
    `FF(num_bursts_q, num_bursts_d, '0)
    `FF(src_address_q, src_address_d, '0)
    `FF(dst_address_q, dst_address_d, '0)

endmodule

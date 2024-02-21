// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

/// Event generation for iDMA
module idma_inst64_events #(
    parameter int unsigned DataWidth     = 32'd0,
    parameter type         axi_req_t     = logic,
    parameter type         axi_res_t     = logic,
    parameter type         dma_events_t  = logic
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    // AXI4 bus
    input  axi_req_t             axi_req_i,
    input  axi_res_t             axi_rsp_i,
    // DMA busy
    input  logic                 busy_i,
    // events
    output dma_events_t          events_o
);

    localparam int unsigned StrbWidth = DataWidth / 8;

    logic [$clog2(StrbWidth)+1-1:0] num_bytes_written;

    // need popcount common cell to get the number of bytes active in the strobe signal
    popcount #(
        .INPUT_WIDTH ( StrbWidth  )
    ) i_popcount (
        .data_i      ( axi_req_i.w.strb   ),
        .popcount_o  ( num_bytes_written      )
    );

    // see if counters should be increased
    always_comb begin : proc_next_perf_state

        // default: 0
        events_o = '0;

        // aw
        events_o.aw_valid = axi_req_i.aw_valid;
        events_o.aw_ready = axi_rsp_i.aw_ready;
        events_o.aw_done = axi_rsp_i.aw_ready & axi_req_i.aw_valid;
        events_o.aw_stall = !axi_rsp_i.aw_ready & axi_req_i.aw_valid;
        if ( axi_rsp_i.aw_ready & axi_req_i.aw_valid) begin
            events_o.aw_len = axi_req_i.aw.len;
            events_o.aw_size = axi_req_i.aw.size;
        end

        // ar
        events_o.ar_valid = axi_req_i.ar_valid;
        events_o.ar_ready = axi_rsp_i.ar_ready;
        events_o.ar_done = axi_rsp_i.ar_ready && axi_req_i.ar_valid;
        events_o.ar_stall = !axi_rsp_i.ar_ready && axi_req_i.ar_valid;
        if (axi_rsp_i.ar_ready && axi_req_i.ar_valid) begin
            events_o.ar_len = axi_req_i.ar.len;
            events_o.ar_size = axi_req_i.ar.size;
        end

        // r
        events_o.r_valid = axi_rsp_i.r_valid;
        events_o.r_ready = axi_req_i.r_ready;
        events_o.r_done = axi_req_i.r_ready &&  axi_rsp_i.r_valid;
        events_o.r_bw = axi_req_i.r_ready &&  axi_rsp_i.r_valid;
        events_o.r_stall = axi_req_i.r_ready && !axi_rsp_i.r_valid;

        // w
        events_o.w_valid = axi_req_i.w_valid;
        events_o.w_ready = axi_rsp_i.w_ready;
        events_o.w_done = axi_rsp_i.w_ready && axi_req_i.w_valid;
        events_o.w_stall = !axi_rsp_i.w_ready && axi_req_i.w_valid;
        if (axi_rsp_i.w_ready && axi_req_i.w_valid) begin
            events_o.num_bytes_written = num_bytes_written;
        end

        // b
        events_o.b_valid = axi_rsp_i.b_valid;
        events_o.b_ready = axi_req_i.b_ready;
        events_o.b_done = axi_req_i.b_ready && axi_rsp_i.b_valid;

        // buffer
        events_o.w_stall = axi_rsp_i.w_ready && !axi_req_i.w_valid;
        events_o.r_stall = !axi_req_i.r_ready &&  axi_rsp_i.r_valid;

        // busy
        events_o.dma_busy = busy_i;
    end

endmodule

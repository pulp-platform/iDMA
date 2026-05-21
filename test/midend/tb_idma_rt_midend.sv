// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "idma/typedef.svh"

/// Sanity testbench for the RT midend.
/// Drives both the counter-generated (internal) and bypass nd_req streams,
/// then checks that the number of responses routed to the bypass output
/// matches the number of bypass requests issued. A routing mismatch
/// (responses going to the wrong output) indicates a misalignment between
/// the choice FIFO and the arbiter, the bug fixed by Flavien Solt's patch.
module tb_idma_rt_midend;

    logic clk;
    logic rst_n;

    localparam int unsigned NumEvents = 5;
    localparam int unsigned NumDim    = 3;

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

    // Downstream side: drains nd_req_o and supplies burst_rsp.
    idma_nd_req_t out_req;
    logic         out_req_valid;
    logic         out_req_ready;

    idma_rsp_t    out_rsp;
    logic         out_rsp_valid;
    logic         out_rsp_ready;

    // Bypass side: driven by this TB.
    idma_nd_req_t byp_req;
    logic         byp_req_valid;
    logic         byp_req_ready;

    idma_rsp_t    byp_rsp;
    logic         byp_rsp_valid;
    logic         byp_rsp_ready;

    // Counters to detect routing mismatch.
    int unsigned bypass_req_issued;
    int unsigned bypass_rsp_seen;
    int unsigned internal_rsp_seen;

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
        .NumOutstanding ( 32'd4          ),
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
        .event_counts_o    (                  ),
        .nd_req_o          ( out_req          ),
        .nd_req_valid_o    ( out_req_valid    ),
        .nd_req_ready_i    ( out_req_ready    ),
        .burst_rsp_i       ( out_rsp          ),
        .burst_rsp_valid_i ( out_rsp_valid    ),
        .burst_rsp_ready_o ( out_rsp_ready    ),
        .nd_req_i          ( byp_req          ),
        .nd_req_valid_i    ( byp_req_valid    ),
        .nd_req_ready_o    ( byp_req_ready    ),
        .burst_rsp_o       ( byp_rsp          ),
        .burst_rsp_valid_o ( byp_rsp_valid    ),
        .burst_rsp_ready_i ( byp_rsp_ready    )
    );

    // Always accept the downstream request and acknowledge any response stream.
    assign out_req_ready = 1'b1;
    assign byp_rsp_ready = 1'b1;

    // Drive a "pretend" response one cycle after every accepted request.
    // This keeps requests and responses in 1:1 order at the downstream side.
    logic out_req_handshake;
    assign out_req_handshake = out_req_valid & out_req_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_rsp_valid <= 1'b0;
            out_rsp       <= '0;
        end else begin
            // If we already issued a response and it was not yet consumed, keep it.
            if (out_rsp_valid && !out_rsp_ready) begin
                out_rsp_valid <= 1'b1;
            end else begin
                out_rsp_valid <= out_req_handshake;
                out_rsp       <= '1;
            end
        end
    end

    // -- Counters ------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bypass_req_issued <= '0;
            bypass_rsp_seen   <= '0;
            internal_rsp_seen <= '0;
        end else begin
            if (byp_req_valid && byp_req_ready)
                bypass_req_issued <= bypass_req_issued + 1;
            if (byp_rsp_valid && byp_rsp_ready)
                bypass_rsp_seen <= bypass_rsp_seen + 1;
            // Burst responses consumed by the demux but not routed to bypass
            // are "internal" responses (consumed by the internal sink).
            if (out_rsp_valid && out_rsp_ready && !byp_rsp_valid)
                internal_rsp_seen <= internal_rsp_seen + 1;
        end
    end

    // -- Bypass stimulus -----------------------------------------------
    initial begin : drive_bypass
        byp_req_valid = 1'b0;
        byp_req       = '0;
        // Pre-load a request payload distinguishable from the counters'.
        byp_req.burst_req.length   = 32'h0000_1000;
        byp_req.burst_req.src_addr = 32'hC000_0000;
        byp_req.burst_req.dst_addr = 32'hD000_0000;

        wait (rst_n === 1'b1);
        @(posedge clk);

        // Issue 8 bypass requests interleaved with the counter traffic.
        for (int i = 0; i < 8; i++) begin
            // Random spacing to interleave with internal arbitration.
            repeat (3 + (i % 4)) @(posedge clk);
            byp_req_valid = 1'b1;
            byp_req.burst_req.length = 32'h0000_1000 + i;
            @(posedge clk);
            while (!byp_req_ready) @(posedge clk);
            byp_req_valid = 1'b0;
        end
    end

    // -- Main stimulus -------------------------------------------------
    initial begin
        bypass_req_issued = '0;
        bypass_rsp_seen   = '0;
        internal_rsp_seen = '0;

        event_counts = {32'd17, 32'd300, 32'd800, 32'd1000, 32'd2000};
        #10ns;
        event_ena    = {1'd1, 1'd1, 1'd1, 1'd1, 1'd1};
        #5000ns;

        // Drain outstanding bypass responses with a bounded wait so lost
        // routing doesn't masquerade as "responses haven't arrived yet".
        for (int i = 0; i < 1000; i++) begin
            if (bypass_rsp_seen >= bypass_req_issued) break;
            @(posedge clk);
        end

        // -- Final check: every bypass request must produce exactly one
        //                 response on the bypass output. A routing mismatch
        //                 would either lose bypass responses (they go to
        //                 the internal sink) or duplicate them.
        if (bypass_rsp_seen != bypass_req_issued) begin
            $fatal(1, "[tb_idma_rt_midend] routing mismatch: bypass_req_issued=%0d bypass_rsp_seen=%0d",
                   bypass_req_issued, bypass_rsp_seen);
        end

        $display("[tb_idma_rt_midend] bypass requests: %0d, bypass responses: %0d, internal responses: %0d",
                 bypass_req_issued, bypass_rsp_seen, internal_rsp_seen);
        $finish();
    end

endmodule

// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Bowen Wang <bowwang@iis.ee.ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"
`include "idma/guard.svh"

/// Indexed-gather midend. A request with `gather.enable` set is expanded into one ND request
/// per index, read from an index stream in memory:
///
///     src_addr[i] = src_addr + idx[i] * d_req[0].src_strides     (i = 0 .. d_req[0].reps-1)
///     dst_addr[i] = dst_addr + i      * d_req[0].dst_strides
///     length      = length
///
/// `d_req[0].src_strides` is the size of one source row and must be a power of two, so the
/// offset is a shift. Every emitted request is 1D (all repetitions set to one), so the
/// downstream `idma_nd_midend` answers each with exactly one response; this module merges the
/// responses of a gather into one. Requests without `gather.enable` pass through unchanged.
/// A gather with zero indices, a source stride that is not a power of two, or an index base
/// not aligned to the index width is rejected with an `ND_MIDEND` error response.
module idma_gather_midend #(
    /// Number of dimensions of the ND request; the gather uses the first repetition dimension
    parameter int unsigned NumDim             = 32'd2,
    /// Width of one index-stream read in bits; holds at least one 64-bit index
    parameter int unsigned IdxDataWidth       = 32'd64,
    /// Index words that may be in flight or buffered at the same time
    parameter int unsigned NumIdxOutstanding  = 32'd2,
    /// Transfers whose response is still pending at the same time
    parameter int unsigned NumXferOutstanding = 32'd4,
    /// Address type
    parameter type addr_t            = logic,
    /// iDMA response type
    parameter type idma_rsp_t        = logic,
    /// ND iDMA request type
    parameter type idma_nd_req_t     = logic,
    /// Gather request type, see `IDMA_TYPEDEF_GATHER_REQ_T`
    parameter type idma_gather_req_t = logic,
    /// Index-stream data type
    localparam type idx_data_t       = logic [IdxDataWidth-1:0]
) (
    /// Clock
    input  logic             clk_i,
    /// Asynchronous reset, active low
    input  logic             rst_ni,

    /// Gather request
    input  idma_gather_req_t gather_req_i,
    /// Gather request valid
    input  logic             gather_req_valid_i,
    /// Gather request ready
    output logic             gather_req_ready_o,

    /// Gather response, one per request
    output idma_rsp_t        gather_rsp_o,
    /// Gather response valid
    output logic             gather_rsp_valid_o,
    /// Gather response ready
    input  logic             gather_rsp_ready_i,

    /// ND request to the ND midend
    output idma_nd_req_t     nd_req_o,
    /// ND request valid
    output logic             nd_req_valid_o,
    /// ND request ready
    input  logic             nd_req_ready_i,

    /// ND response from the ND midend
    input  idma_rsp_t        nd_rsp_i,
    /// ND response valid
    input  logic             nd_rsp_valid_i,
    /// ND response ready
    output logic             nd_rsp_ready_o,

    /// Index read request; the address is aligned to `IdxDataWidth / 8`
    output logic             idx_req_o,
    /// Index read address
    output addr_t            idx_addr_o,
    /// Index read grant
    input  logic             idx_gnt_i,
    /// Index read response valid; responses return in order and are never back-pressured
    input  logic             idx_rvalid_i,
    /// Index read response data
    input  idx_data_t        idx_rdata_i,

    /// The midend is busy
    output logic             busy_o
);

    localparam int unsigned WordBytes   = IdxDataWidth / 32'd8;
    localparam int unsigned WordOffW    = $clog2(WordBytes);
    localparam int unsigned MaxLanes    = WordBytes;
    localparam int unsigned LaneW       = $clog2(MaxLanes);
    localparam int unsigned LanesW      = $clog2(MaxLanes + 1);
    localparam int unsigned BitOffW     = $clog2(IdxDataWidth);
    localparam int unsigned AddrW       = $bits(addr_t);
    localparam int unsigned ShiftW      = $clog2(AddrW);
    localparam int unsigned RepW        = $bits(gather_req_i.nd_req.d_req[0].reps);
    localparam int unsigned IdxCntW     = $clog2(NumIdxOutstanding + 1);

    typedef logic [RepW-1:0] reps_t;
    typedef logic [RepW:0]   fetch_cnt_t;

    /// Response bookkeeping of one accepted request
    typedef struct packed {
        logic  reject;
        reps_t num_rsp;
    } xfer_t;

    //--------------------------------------
    // Request decode
    //--------------------------------------
    logic       is_gather;
    reps_t      num_idx;
    addr_t      src_stride;
    logic [1:0] idx_width;
    addr_t      idx_base;
    logic       stride_pow2;
    logic       idx_aligned;
    logic       reject;

    assign is_gather   = gather_req_i.gather.enable;
    assign num_idx     = gather_req_i.nd_req.d_req[0].reps;
    assign src_stride  = gather_req_i.nd_req.d_req[0].src_strides;
    assign idx_width   = gather_req_i.gather.idx_width;
    assign idx_base    = gather_req_i.gather.idx_addr;
    assign stride_pow2 = (src_stride != '0) && ((src_stride & (src_stride - addr_t'(1))) == '0);
    assign idx_aligned = (idx_base & ((addr_t'(1) << idx_width) - addr_t'(1))) == '0;
    assign reject      = is_gather & ((num_idx == '0) | !stride_pow2 | !idx_aligned);

    // log2 of the power-of-two source stride
    logic [ShiftW-1:0] stride_log2;

    cc_lzc #(
        .Width ( AddrW                          ),
        .Mode  ( cc_pkg::LZC_TRAILING_ZERO_CNT  )
    ) i_stride_lzc (
        .in_i    ( src_stride  ),
        .cnt_o   ( stride_log2 ),
        .empty_o ( /* NC */    )
    );

    // indices per index word and the lane of the first index
    logic [LanesW-1:0] lanes_per_word;
    logic [LaneW-1:0]  first_lane;

    assign lanes_per_word = LanesW'(MaxLanes >> idx_width);
    assign first_lane     = LaneW'(idx_base[WordOffW-1:0] >> idx_width);

    //--------------------------------------
    // State
    //--------------------------------------
    logic              run_q, run_d;
    reps_t             idx_cnt_q, idx_cnt_d;
    logic [LaneW-1:0]  lane_q, lane_d;
    addr_t             dst_addr_q, dst_addr_d;
    logic [ShiftW-1:0] shift_q, shift_d;
    addr_t             fetch_addr_q, fetch_addr_d;
    fetch_cnt_t        fetch_rem_q, fetch_rem_d;
    logic [IdxCntW-1:0] idx_credit_q, idx_credit_d;

    //--------------------------------------
    // Response bookkeeping
    //--------------------------------------
    xfer_t xfer_in, xfer_head;
    logic  xfer_push, xfer_ready, xfer_valid, xfer_pop;

    cc_stream_fifo #(
        .Depth  ( NumXferOutstanding ),
        .data_t ( xfer_t             )
    ) i_xfer_fifo (
        .clk_i,
        .rst_ni,
        .clr_i   ( 1'b0       ),
        .flush_i ( 1'b0       ),
        .usage_o ( /* NC */   ),
        .data_i  ( xfer_in    ),
        .valid_i ( xfer_push  ),
        .ready_o ( xfer_ready ),
        .data_o  ( xfer_head  ),
        .valid_o ( xfer_valid ),
        .ready_i ( xfer_pop   )
    );

    //--------------------------------------
    // Index buffer
    //--------------------------------------
    idx_data_t idx_word;
    logic      idx_word_valid, idx_word_pop, idx_buf_ready;

    // the credit counter guarantees room for every granted read
    cc_stream_fifo #(
        .Depth  ( NumIdxOutstanding ),
        .data_t ( idx_data_t        )
    ) i_idx_fifo (
        .clk_i,
        .rst_ni,
        .clr_i   ( 1'b0           ),
        .flush_i ( 1'b0           ),
        .usage_o ( /* NC */       ),
        .data_i  ( idx_rdata_i    ),
        .valid_i ( idx_rvalid_i   ),
        .ready_o ( idx_buf_ready  ),
        .data_o  ( idx_word       ),
        .valid_o ( idx_word_valid ),
        .ready_i ( idx_word_pop   )
    );

    assign idx_req_o  = run_q & (fetch_rem_q != '0) & (idx_credit_q < IdxCntW'(NumIdxOutstanding));
    assign idx_addr_o = fetch_addr_q;

    //--------------------------------------
    // Index extraction and address generation
    //--------------------------------------
    idx_data_t idx_shifted;
    addr_t     idx_val;
    addr_t     gather_src;

    always_comb begin : proc_idx_extract
        idx_shifted = idx_word >> (BitOffW'(lane_q) << (32'd3 + 32'(idx_width)));
        unique case (idx_width)
            2'b00:   idx_val = addr_t'(idx_shifted[7:0]);
            2'b01:   idx_val = addr_t'(idx_shifted[15:0]);
            2'b10:   idx_val = addr_t'(idx_shifted[31:0]);
            default: idx_val = addr_t'(idx_shifted[63:0]);
        endcase
        gather_src = gather_req_i.nd_req.burst_req.src_addr + (idx_val << shift_q);
    end

    //--------------------------------------
    // Request path
    //--------------------------------------
    logic last_idx, lane_wrap, emit_hs;

    assign last_idx  = idx_cnt_q == num_idx - reps_t'(1);
    assign lane_wrap = LanesW'(lane_q) == lanes_per_word - LanesW'(1);
    assign emit_hs   = nd_req_valid_o & nd_req_ready_i;

    always_comb begin : proc_request
        // default: pass the request through
        nd_req_o           = gather_req_i.nd_req;
        nd_req_valid_o     = 1'b0;
        gather_req_ready_o = 1'b0;
        xfer_push          = 1'b0;
        xfer_in            = '{reject: 1'b0, num_rsp: reps_t'(1)};
        idx_word_pop       = 1'b0;

        run_d        = run_q;
        idx_cnt_d    = idx_cnt_q;
        lane_d       = lane_q;
        dst_addr_d   = dst_addr_q;
        shift_d      = shift_q;
        fetch_addr_d = fetch_addr_q;
        fetch_rem_d  = fetch_rem_q;

        if (!run_q) begin
            if (!is_gather) begin
                // passthrough: one request, one response
                nd_req_valid_o     = gather_req_valid_i & xfer_ready;
                gather_req_ready_o = nd_req_ready_i & xfer_ready;
                xfer_push          = emit_hs;
            end else if (reject) begin
                // answered locally, in order with the transfers ahead of it
                gather_req_ready_o = xfer_ready;
                xfer_push          = gather_req_valid_i;
                xfer_in            = '{reject: 1'b1, num_rsp: '0};
            end else if (gather_req_valid_i && xfer_ready) begin
                // start the gather; the request is held until the last index is emitted
                xfer_push    = 1'b1;
                xfer_in      = '{reject: 1'b0, num_rsp: num_idx};
                run_d        = 1'b1;
                idx_cnt_d    = '0;
                lane_d       = first_lane;
                dst_addr_d   = gather_req_i.nd_req.burst_req.dst_addr;
                shift_d      = stride_log2;
                fetch_addr_d = {idx_base[AddrW-1:WordOffW], WordOffW'(0)};
                fetch_rem_d  = fetch_cnt_t'(num_idx) + fetch_cnt_t'(first_lane);
            end
        end else begin
            // one 1D request per index
            nd_req_valid_o                   = idx_word_valid;
            nd_req_o.burst_req.src_addr      = gather_src;
            nd_req_o.burst_req.dst_addr      = dst_addr_q;
            for (int unsigned d = 0; d < NumDim - 1; d++) begin
                nd_req_o.d_req[d].reps = '0;
                nd_req_o.d_req[d].reps[0] = 1'b1;
            end

            if (emit_hs) begin
                idx_cnt_d  = idx_cnt_q + reps_t'(1);
                dst_addr_d = dst_addr_q + gather_req_i.nd_req.d_req[0].dst_strides;
                lane_d     = lane_q + LaneW'(1);
                // a word retires when its last lane or the last index is used
                if (lane_wrap || last_idx) begin
                    lane_d       = '0;
                    idx_word_pop = 1'b1;
                end
                if (last_idx) begin
                    gather_req_ready_o = 1'b1;
                    run_d              = 1'b0;
                end
            end
        end

        // index fetch
        if (idx_req_o && idx_gnt_i) begin
            fetch_addr_d = fetch_addr_q + addr_t'(WordBytes);
            fetch_rem_d  = (fetch_rem_q > fetch_cnt_t'(lanes_per_word)) ?
                           fetch_rem_q - fetch_cnt_t'(lanes_per_word) : '0;
        end
    end

    // words granted and not yet consumed
    always_comb begin : proc_idx_credit
        idx_credit_d = idx_credit_q;
        if (idx_req_o && idx_gnt_i) idx_credit_d = idx_credit_d + IdxCntW'(1);
        if (idx_word_pop)           idx_credit_d = idx_credit_d - IdxCntW'(1);
    end

    //--------------------------------------
    // Response path
    //--------------------------------------
    reps_t     rsp_cnt_q, rsp_cnt_d;
    logic      err_seen_q, err_seen_d;
    idma_rsp_t err_rsp_q, err_rsp_d;
    logic      last_rsp;

    assign last_rsp = rsp_cnt_q == xfer_head.num_rsp - reps_t'(1);

    always_comb begin : proc_response
        gather_rsp_o       = nd_rsp_i;
        gather_rsp_valid_o = 1'b0;
        nd_rsp_ready_o     = 1'b0;
        xfer_pop           = 1'b0;
        rsp_cnt_d          = rsp_cnt_q;
        err_seen_d         = err_seen_q;
        err_rsp_d          = err_rsp_q;

        if (xfer_valid && xfer_head.reject) begin
            gather_rsp_valid_o        = 1'b1;
            gather_rsp_o              = '0;
            gather_rsp_o.last         = 1'b1;
            gather_rsp_o.error        = 1'b1;
            gather_rsp_o.pld.err_type = idma_pkg::ND_MIDEND;
            xfer_pop                  = gather_rsp_ready_i;
        end else if (xfer_valid) begin
            // the first error of a gather is reported with its last response
            if (err_seen_q && !nd_rsp_i.error) begin
                gather_rsp_o      = err_rsp_q;
                gather_rsp_o.last = 1'b1;
            end
            gather_rsp_valid_o = nd_rsp_valid_i & last_rsp;
            nd_rsp_ready_o     = last_rsp ? gather_rsp_ready_i : 1'b1;
            if (nd_rsp_valid_i && nd_rsp_ready_o) begin
                if (last_rsp) begin
                    xfer_pop   = 1'b1;
                    rsp_cnt_d  = '0;
                    err_seen_d = 1'b0;
                end else begin
                    rsp_cnt_d = rsp_cnt_q + reps_t'(1);
                    if (nd_rsp_i.error && !err_seen_q) begin
                        err_seen_d = 1'b1;
                        err_rsp_d  = nd_rsp_i;
                    end
                end
            end
        end
    end

    assign busy_o = run_q | xfer_valid;

    //--------------------------------------
    // Registers
    //--------------------------------------
    `FF(run_q,        run_d,        1'b0, clk_i, rst_ni)
    `FF(idx_cnt_q,    idx_cnt_d,    '0,   clk_i, rst_ni)
    `FF(lane_q,       lane_d,       '0,   clk_i, rst_ni)
    `FF(dst_addr_q,   dst_addr_d,   '0,   clk_i, rst_ni)
    `FF(shift_q,      shift_d,      '0,   clk_i, rst_ni)
    `FF(fetch_addr_q, fetch_addr_d, '0,   clk_i, rst_ni)
    `FF(fetch_rem_q,  fetch_rem_d,  '0,   clk_i, rst_ni)
    `FF(idx_credit_q, idx_credit_d, '0,   clk_i, rst_ni)
    `FF(rsp_cnt_q,    rsp_cnt_d,    '0,   clk_i, rst_ni)
    `FF(err_seen_q,   err_seen_d,   1'b0, clk_i, rst_ni)
    `FF(err_rsp_q,    err_rsp_d,    '0,   clk_i, rst_ni)

    //--------------------------------------
    // Assertions
    //--------------------------------------
    `ASSERT_NEVER(IdxBufferOverflow, idx_rvalid_i & ~idx_buf_ready, clk_i, !rst_ni)
    `ASSERT_NEVER(UnexpectedResponse, nd_rsp_valid_i & ~xfer_valid, clk_i, !rst_ni)
    `ASSERT(GatherReqStable, run_q |-> gather_req_valid_i, clk_i, !rst_ni)

    `IDMA_NONSYNTH_BLOCK(
    initial begin : proc_assert_params
        num_dim : assert (NumDim >= 32'd2) else
            $fatal(1, "Parameter NumDim has to be >= 2!");
        idx_width : assert (IdxDataWidth >= 32'd64 && 2**$clog2(IdxDataWidth) == IdxDataWidth)
            else $fatal(1, "Parameter IdxDataWidth has to be a power of two >= 64!");
        idx_outstanding : assert (NumIdxOutstanding >= 32'd1) else
            $fatal(1, "Parameter NumIdxOutstanding has to be >= 1!");
        xfer_outstanding : assert (NumXferOutstanding >= 32'd1) else
            $fatal(1, "Parameter NumXferOutstanding has to be >= 1!");
    end
    )

endmodule

// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Transpose geometry expander: expands an opt.compute=TRANSPOSE request into a
/// NumDim=4 tiled ND walk for the generic idma_nd_midend. Non-transpose passes
/// through. Dimension-zero source and destination strides optionally override
/// the layout-derived row pitches. Combinational, quasi-static per request.
module idma_transpose_midend #(
    /// Number of ND dimensions (must be >= 4 to express the tiled walk)
    parameter int unsigned NumDim    = 32'd4,
    /// Write data-path width in bytes (tile side NE = StrbWidth / element bytes)
    parameter int unsigned StrbWidth = 32'd64,
    /// Address type
    parameter type addr_t        = logic,
    /// ND request type
    parameter type idma_nd_req_t = logic
)(
    input  idma_nd_req_t nd_req_i,
    input  logic         valid_i,
    output logic         ready_o,
    output idma_nd_req_t nd_req_o,
    output logic         valid_o,
    input  logic         ready_i
);

    localparam int unsigned Log2Strb = $clog2(StrbWidth);
    localparam int unsigned LenW     = $bits(nd_req_o.burst_req.length);
    localparam int unsigned RepW     = $bits(nd_req_o.d_req[0].reps);
    localparam int unsigned ModeW    = $bits(nd_req_o.burst_req.opt.compute.params.transpose.mode);
    localparam int unsigned TensorW  =
        $bits(nd_req_o.burst_req.opt.compute.params.transpose.tensor_m);
    localparam int unsigned AddrW    = $bits(addr_t);
    // working width: largest term (YT*N)<<Log2Strb, +1 for the signed rewind
    localparam int unsigned ProdW    = 2*TensorW + Log2Strb + 1;
    localparam int unsigned WorkW    = (ProdW > AddrW) ? ProdW : AddrW;

    assign valid_o = valid_i;
    assign ready_o = ready_i;

    logic is_transpose;
    assign is_transpose = nd_req_i.burst_req.opt.compute.enable &
                          (nd_req_i.burst_req.opt.compute.op == idma_pkg::COMPUTE_TRANSPOSE);

    // NE and E are powers of two: all geometry folds to shifts except the YT*N
    // stride product.
    always_comb begin : proc_expand
        logic [ModeW-1:0]        mode;
        logic [TensorW-1:0]      tm, tn;
        logic signed [WorkW-1:0] m, n, log2ne, ne, yt, nt, nxe, me, mpe;
        logic signed [WorkW-1:0] src_row_bytes, default_dst_row_bytes, dst_row_bytes;
        logic signed [WorkW-1:0] strb_c;   // NE*E == StrbWidth (mode cancels)

        nd_req_o = nd_req_i;   // passthrough
        mode = '0;
        tm = '0;
        tn = '0;
        m = '0;
        n = '0;
        log2ne = '0;
        ne = '0;
        yt = '0;
        nt = '0;
        nxe = '0;
        me = '0;
        mpe = '0;
        src_row_bytes = '0;
        default_dst_row_bytes = '0;
        dst_row_bytes = '0;
        strb_c = '0;

        if (is_transpose) begin
            mode = nd_req_i.burst_req.opt.compute.params.transpose.mode;
            tm   = nd_req_i.burst_req.opt.compute.params.transpose.tensor_m;
            tn   = nd_req_i.burst_req.opt.compute.params.transpose.tensor_n;
            // zero-extend bounded dims into the signed working width
            m      = $signed({{(WorkW-TensorW){1'b0}}, tm});   // M
            n      = $signed({{(WorkW-TensorW){1'b0}}, tn});   // N
            log2ne = $signed(WorkW'(Log2Strb)) - $signed({{(WorkW-ModeW){1'b0}}, mode});
            ne     = $signed(WorkW'(1)) <<< log2ne;            // tile side (elements)
            yt     = (m + ne - 1) >>> log2ne;                  // ceil(M/NE)
            nt     = (n + ne - 1) >>> log2ne;                  // ceil(N/NE)
            nxe    = n  <<< mode;                              // N*E  (E = 1<<mode)
            me     = m  <<< mode;                              // M*E: compact destination row size
            mpe    = yt <<< Log2Strb;                          // padded destination row size
            // Zero row strides retain the legacy compact/padded geometry. Nonzero
            // frontend strides override the source and destination row spacing.
            src_row_bytes = (nd_req_i.d_req[0].src_strides == '0) ? nxe :
                $signed(WorkW'(nd_req_i.d_req[0].src_strides));
            default_dst_row_bytes =
                nd_req_i.burst_req.opt.compute.params.transpose.compact ? me : mpe;
            dst_row_bytes = (nd_req_i.d_req[0].dst_strides == '0) ? default_dst_row_bytes :
                $signed(WorkW'(nd_req_i.d_req[0].dst_strides));
            strb_c = $signed(WorkW'(StrbWidth));               // NE*E (one tile-row = StrbWidth B)

            nd_req_o.burst_req.length     = LenW'(StrbWidth);

            // d_req[0] = local row within tile (reps NE)
            nd_req_o.d_req[0].reps        = ne[RepW-1:0];
            nd_req_o.d_req[0].src_strides = addr_t'(src_row_bytes);
            nd_req_o.d_req[0].dst_strides = addr_t'(dst_row_bytes);
            // d_req[1] advances to the next row tile and rewinds the local output-row walk.
            nd_req_o.d_req[1].reps        = yt[RepW-1:0];
            nd_req_o.d_req[1].src_strides = addr_t'(src_row_bytes);
            nd_req_o.d_req[1].dst_strides =
                addr_t'(strb_c - (dst_row_bytes <<< log2ne) + dst_row_bytes);
            // d_req[2] = col-tile (reps NT): rewind the completed YT*NE source-row walk
            //            and advance by one input tile beat. Destination output rows are
            //            dst_row_bytes apart.
            nd_req_o.d_req[2].reps        = nt[RepW-1:0];
            nd_req_o.d_req[2].src_strides =
                addr_t'(strb_c - ((yt * ne - 1) * src_row_bytes));
            nd_req_o.d_req[2].dst_strides =
                addr_t'(dst_row_bytes - (yt <<< Log2Strb) + strb_c);
            // the walk is exactly 4-D: neutralize any higher dims
            for (int unsigned d = 3; d < NumDim-1; d++) begin
                nd_req_o.d_req[d].reps        = RepW'(1);
                nd_req_o.d_req[d].src_strides = '0;
                nd_req_o.d_req[d].dst_strides = '0;
            end
        end
    end

`ifndef SYNTHESIS
    initial assert (NumDim >= 4) else
        $fatal(1, "idma_transpose_midend requires NumDim >= 4 (got %0d)", NumDim);
    // mode 0..2 needs NE >= 1, i.e. log2(StrbWidth) >= 2
    initial assert (Log2Strb >= 2) else
        $fatal(1, "idma_transpose_midend requires StrbWidth >= 4 (got %0d)", StrbWidth);
    // reps must hold tile counts (<= 2^TensorW) and ne (<= StrbWidth); length StrbWidth.
    initial assert (RepW >= TensorW && RepW > Log2Strb) else
        $fatal(1, "idma_transpose_midend: reps field %0d b too narrow (need >= %0d)",
               RepW, (TensorW > Log2Strb+1) ? TensorW : Log2Strb+1);
    initial assert (LenW > Log2Strb) else
        $fatal(1, "idma_transpose_midend: length field %0d b cannot hold StrbWidth", LenW);
    // Check only active request payloads; upstream may change or invalidate the
    // combinational payload while this module is idle.
    always_comb begin : check_domain
        logic [ModeW-1:0]   mode;
        logic [TensorW-1:0] tm, tn;
        logic [WorkW-1:0]   m, n, element_bytes;

        mode          = nd_req_i.burst_req.opt.compute.params.transpose.mode;
        tm            = nd_req_i.burst_req.opt.compute.params.transpose.tensor_m;
        tn            = nd_req_i.burst_req.opt.compute.params.transpose.tensor_n;
        m             = WorkW'(tm);
        n             = WorkW'(tn);
        element_bytes = WorkW'(1) << mode;
        if (valid_i && is_transpose) begin
            assert (nd_req_i.burst_req.opt.compute.params.transpose.tensor_m != '0 &&
                    nd_req_i.burst_req.opt.compute.params.transpose.tensor_n != '0) else
                $error("idma_transpose_midend: zero-size tensor (M or N == 0)");
            assert (element_bytes <= StrbWidth) else
                $error("idma_transpose_midend: element size exceeds the data-path width");
            assert (nd_req_i.d_req[0].src_strides == '0 ||
                    $unsigned(nd_req_i.d_req[0].src_strides) >=
                    $unsigned(n * element_bytes)) else
                $error("idma_transpose_midend: source row stride is shorter than a logical row");
            assert (nd_req_i.d_req[0].dst_strides == '0 ||
                    $unsigned(nd_req_i.d_req[0].dst_strides) >=
                    $unsigned(m * element_bytes)) else
                $error("idma_transpose_midend: destination row stride is shorter than a logical row");
        end
    end
`endif

endmodule

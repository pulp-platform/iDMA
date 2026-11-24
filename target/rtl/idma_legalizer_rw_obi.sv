// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"
`include "idma/guard.svh"

/// Legalizes a generic 1D transfer according to the rules given by the
/// used protocol.
module idma_legalizer_rw_obi #(
    /// Should both data shifts be done before the dataflow element?
    /// If this is enabled, then the data inserted into the dataflow element
    /// will no longer be word aligned, but only a single shifter is needed
    parameter bit          CombinedShifter = 1'b0,
    /// On-the-fly compute engine is elaborated in the transport layer
    parameter bit          EnableCompute   = 1'b0,
    /// Per-operation compute support mask
    parameter idma_pkg::compute_enable_t ComputeOps = '1,
    /// Data width
    parameter int unsigned DataWidth       = 32'd16,
    /// Address width
    parameter int unsigned AddrWidth       = 32'd24,
    /// Burst Len (for actual burst length do 8 byte * 2^(BurstLen))
    parameter int unsigned BurstLen = 4'd8,
    /// 1D iDMA request type:
    /// - `length`: the length of the transfer in bytes
    /// - `*_addr`: the source / target byte addresses of the transfer
    /// - `opt`: the options field
    parameter type idma_req_t        = logic,
    /// Read request type
    parameter type idma_r_req_t      = logic,
    /// Write request type
    parameter type idma_w_req_t      = logic,
    /// Mutable transfer type
    parameter type idma_mut_tf_t     = logic,
    /// Mutable options type
    parameter type idma_mut_tf_opt_t = logic
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,

    /// 1D request
    input  idma_req_t req_i,
    /// 1D request valid
    input  logic valid_i,
    /// 1D request ready
    output logic ready_o,

    /// Read request; contains datapath and meta information
    output idma_r_req_t r_req_o,
    /// Read request valid
    output logic r_valid_o,
    /// Read request ready
    input  logic r_ready_i,

    /// Write request; contains datapath and meta information
    output idma_w_req_t w_req_o,
    /// Write request valid
    output logic w_valid_o,
    /// Write request ready
    input  logic w_ready_i,

    /// Invalidate the current burst transfer, stops emission of requests
    input  logic flush_i,
    /// Kill the active 1D transfer; reload a new transfer
    input  logic kill_i,

    /// Read machine of the legalizer is busy
    output logic r_busy_o,
    /// Write machine of the legalizer is busy
    output logic w_busy_o
);
    /// Stobe width
    localparam int unsigned StrbWidth     = DataWidth / 8;
    /// Offset width
    localparam int unsigned OffsetWidth   = $clog2(StrbWidth);
    /// The size of a page in byte
    localparam int unsigned PageSize      = StrbWidth;
    /// The width of page offset byte addresses
    localparam int unsigned PageAddrWidth = $clog2(PageSize);

    /// Offset type
    typedef logic [  OffsetWidth-1:0] offset_t;
    /// Address type
    typedef logic [    AddrWidth-1:0] addr_t;
    /// Page address type
    typedef logic [PageAddrWidth-1:0] page_addr_t;
    /// Page length type
    typedef logic [  PageAddrWidth:0] page_len_t;


    // state: internally hold one transfer, this is mutated
    idma_mut_tf_t     r_tf_d,   r_tf_q;
    idma_mut_tf_t     w_tf_d,   w_tf_q;
    idma_mut_tf_opt_t opt_tf_d, opt_tf_q;
    idma_mut_tf_opt_t opt_w_d,  opt_w_q;

    // enable signals for next mutable transfer storage
    logic r_tf_ena;
    logic w_tf_ena;

    // page boundaries
    page_len_t r_page_num_bytes_to_pb;
    page_len_t r_num_bytes_to_pb;
    page_len_t w_page_num_bytes_to_pb;
    page_len_t w_num_bytes_to_pb;
    page_len_t c_num_bytes_to_pb;

    // read process
    page_len_t r_num_bytes_possible;
    page_len_t r_num_bytes;
    offset_t   r_addr_offset;
    logic      r_done;

    // write process
    page_len_t w_num_bytes_possible;
    page_len_t w_num_bytes;
    offset_t   w_addr_offset;
    logic      w_done;

    // MX: per group a data segment, then its scale chunk; the other plane waits in `mx_*_q`
    localparam int unsigned LenWidth = $bits(r_tf_q.length);
    typedef logic [LenWidth-1:0] len_t;
    // dequant read side
    typedef struct packed {
        logic  on;
        logic  g32;
        logic  scl;
        logic  half;
        addr_t daddr;
        addr_t saddr;
        len_t  drem;
    } mx_r_t;
    // quant write side
    typedef struct packed {
        logic  on;
        logic  g32;
        logic  scl;
        addr_t daddr;
        addr_t saddr;
        len_t  drem;
        len_t  sn;
    } mx_w_t;
    mx_r_t mx_r_d, mx_r_q;
    mx_w_t mx_w_d, mx_w_q;

    // requests whose W side waits while R runs ahead of an MX write side
    localparam int unsigned MxWqDepth = 32'd3;

    // data bytes of a group
    localparam int unsigned MxGrpWidth = $clog2(64 * idma_pkg::MxDataBlockBytes) + 1;
    function automatic len_t mx_grp(logic g32);
        return len_t'((g32 ? 32 : 64) * idma_pkg::MxDataBlockBytes);
    endfunction

    // data bytes of the next segment: one group or the rest
    function automatic len_t mx_seg(len_t rem, logic g32);
        return (rem > mx_grp(g32)) ? mx_grp(g32) : rem;
    endfunction

    // dequant reads the last segment as whole beats
    function automatic len_t mx_rseg(len_t rem, logic g32);
        logic [MxGrpWidth-1:0] r;
        r = rem[MxGrpWidth-1:0] + MxGrpWidth'(StrbWidth - 1);
        r = (r >> OffsetWidth) << OffsetWidth;
        return (rem > mx_grp(g32)) ? mx_grp(g32) : len_t'(r);
    endfunction

    // whole beats a scale chunk of `seg / 32` bytes at `sa` is read with (never past its 64 B slot)
    function automatic len_t mx_rchunk(addr_t sa, len_t seg);
        len_t n;
        n = len_t'(sa[OffsetWidth-1:0]) + (seg >> $clog2(idma_pkg::MxDataBlockBytes));
        return ((n + len_t'(StrbWidth - 1)) >> OffsetWidth) << OffsetWidth;
    endfunction

    // scale address step per group
    function automatic addr_t mx_sstep(logic g32);
        return g32 ? addr_t'(32) : addr_t'(64);
    endfunction


    //--------------------------------------
    // read boundary check
    //--------------------------------------
    idma_legalizer_page_splitter #(
        .BurstLen      ( BurstLen      ),
        .OffsetWidth   ( OffsetWidth   ),
        .PageAddrWidth ( PageAddrWidth ),
        .addr_t        ( addr_t        ),
        .page_len_t    ( page_len_t    ),
        .page_addr_t   ( page_addr_t   )
    ) i_read_page_splitter (
        .not_bursting_i    ( 1'b1 ),

        .reduce_len_i      ( opt_tf_q.src_reduce_len ),
        .max_llen_i        ( opt_tf_q.src_max_llen   ),

        .addr_i            ( r_tf_q.addr             ),
        .num_bytes_to_pb_o ( r_page_num_bytes_to_pb  )
    );

    assign r_num_bytes_to_pb = r_page_num_bytes_to_pb;

    //--------------------------------------
    // write boundary check
    //--------------------------------------
    idma_legalizer_page_splitter #(
        .BurstLen      ( BurstLen      ),
        .OffsetWidth   ( OffsetWidth   ),
        .PageAddrWidth ( PageAddrWidth ),
        .addr_t        ( addr_t        ),
        .page_len_t    ( page_len_t    ),
        .page_addr_t   ( page_addr_t   )
    ) i_write_page_splitter (
        .not_bursting_i    ( 1'b1 ),

        .reduce_len_i      ( opt_w_q.dst_reduce_len ),
        .max_llen_i        ( opt_w_q.dst_max_llen   ),

        .addr_i            ( w_tf_q.addr             ),
        .num_bytes_to_pb_o ( w_page_num_bytes_to_pb  )
    );

    assign w_num_bytes_to_pb = w_page_num_bytes_to_pb;

    //--------------------------------------
    // page boundary check
    //--------------------------------------
    // how many transfers are remaining when concerning both r/w pages?
    // take the boundary that is closer
    assign c_num_bytes_to_pb = (r_num_bytes_to_pb > w_num_bytes_to_pb) ?
                                w_num_bytes_to_pb : r_num_bytes_to_pb;


    //--------------------------------------
    // Synchronized R/W process
    //--------------------------------------
    always_comb begin : proc_num_bytes_possible
        // Default: Coupled
        r_num_bytes_possible = c_num_bytes_to_pb;
        w_num_bytes_possible = c_num_bytes_to_pb;

        if (opt_tf_q.decouple_rw
            || (opt_tf_q.src_protocol inside { idma_pkg::OBI })
            || (opt_w_q.dst_protocol inside { idma_pkg::OBI })) begin
            r_num_bytes_possible = r_num_bytes_to_pb;
            w_num_bytes_possible = w_num_bytes_to_pb;
        end
    end

    assign r_addr_offset = r_tf_q.addr[OffsetWidth-1:0];
    assign w_addr_offset = w_tf_q.addr[OffsetWidth-1:0];

    // state of a request: both machines, options and the MX plane state
    typedef struct packed {
        idma_mut_tf_t     r_tf;
        idma_mut_tf_t     w_tf;
        idma_mut_tf_opt_t opt;
        mx_r_t            mx_r;
        mx_w_t            mx_w;
    } load_t;

    function automatic load_t load(idma_req_t req);
        load_t l;
        l = '0;
        // load all three mutable objects (source, destination, option)
        l.r_tf = '{
            length: req.length,
            addr:   req.src_addr,
            valid:   1'b1,
            base_addr: req.src_addr,
            default: '0
        };
        // destination or write
        l.w_tf = '{
            length: req.length,
            addr:   req.dst_addr,
            valid:   1'b1,
            base_addr: req.dst_addr,
            user: req.user,
            default: '0
        };
        // size-changing compute: write length follows the per-op byte ratio
        l.mx_r = '0;
        l.mx_w = '0;
        if (EnableCompute && req.opt.compute.enable &&
            idma_pkg::compute_op_supported(ComputeOps, req.opt.compute.op)) begin
            unique case (req.opt.compute.op)
                idma_pkg::COMPUTE_MXQUANT:
                    l.w_tf.length = (req.length /
                        idma_pkg::compute_in_bytes(idma_pkg::COMPUTE_MXQUANT)) *
                        idma_pkg::compute_out_bytes(idma_pkg::COMPUTE_MXQUANT);
                idma_pkg::COMPUTE_MXQUANT_FP16:
                    l.w_tf.length = (req.length /
                        idma_pkg::compute_in_bytes(idma_pkg::COMPUTE_MXQUANT_FP16)) *
                        idma_pkg::compute_out_bytes(idma_pkg::COMPUTE_MXQUANT_FP16);
                idma_pkg::COMPUTE_MXDEQUANT:
                    l.w_tf.length = (req.length /
                        idma_pkg::compute_in_bytes(idma_pkg::COMPUTE_MXDEQUANT)) *
                        idma_pkg::compute_out_bytes(idma_pkg::COMPUTE_MXDEQUANT);
                idma_pkg::COMPUTE_MXDEQUANT_FP16:
                    l.w_tf.length = (req.length /
                        idma_pkg::compute_in_bytes(idma_pkg::COMPUTE_MXDEQUANT_FP16)) *
                        idma_pkg::compute_out_bytes(idma_pkg::COMPUTE_MXDEQUANT_FP16);
                default: ;
            endcase
        end
        // MX: quant starts with the first data segment, dequant with the first scale chunk
        if (EnableCompute && req.opt.compute.enable &&
            idma_pkg::compute_op_is_mx(req.opt.compute.op) &&
            idma_pkg::compute_op_supported(ComputeOps, req.opt.compute.op)) begin
            if (req.opt.compute.op inside {idma_pkg::COMPUTE_MXDEQUANT,
                                           idma_pkg::COMPUTE_MXDEQUANT_FP16}) begin
                l.mx_r.on     = 1'b1;
                l.mx_r.g32    = req.opt.compute.params.mx.group == idma_pkg::MX_GROUP_G32;
                l.mx_r.daddr  = req.src_addr;
                l.mx_r.saddr  = req.scale_addr;
                l.mx_r.half   = (StrbWidth == 64) & req.length[5];
                l.mx_r.drem   = len_t'(req.length);
                l.mx_r.scl    = 1'b1;
                l.r_tf.addr   = {req.scale_addr[AddrWidth-1:OffsetWidth],
                                 {OffsetWidth{1'b0}}};
                l.r_tf.length = mx_rchunk(req.scale_addr,
                                          mx_rseg(len_t'(req.length), l.mx_r.g32));
            end else begin
                l.mx_w.on     = 1'b1;
                l.mx_w.g32    = req.opt.compute.params.mx.group == idma_pkg::MX_GROUP_G32;
                l.mx_w.daddr  = req.dst_addr;
                l.mx_w.saddr  = req.scale_addr;
                l.mx_w.drem   = len_t'(l.w_tf.length);
                l.mx_w.sn     = mx_seg(len_t'(l.w_tf.length), l.mx_w.g32) >>
                                $clog2(idma_pkg::MxDataBlockBytes);
                l.w_tf.length = mx_seg(len_t'(l.w_tf.length), l.mx_w.g32);
            end
        end
        // options
        l.opt = '{
            src_protocol:   req.opt.src_protocol,
            dst_protocol:   req.opt.dst_protocol,
            src_head:       req.opt.src_head,
            dst_head:       req.opt.dst_head,
            read_shift:     '0,
            write_shift:    '0,
            decouple_rw:    req.opt.beo.decouple_rw |
                            (EnableCompute & req.opt.compute.enable),
            decouple_aw:    req.opt.beo.decouple_aw |
                            (EnableCompute & req.opt.compute.enable),
            src_max_llen:   req.opt.beo.src_max_llen,
            dst_max_llen:   req.opt.beo.dst_max_llen,
            src_reduce_len: req.opt.beo.src_reduce_len,
            dst_reduce_len: req.opt.beo.dst_reduce_len,
            axi_id:         req.opt.axi_id,
            src_axi_opt:    req.opt.src,
            dst_axi_opt:    req.opt.dst,
            super_last:     req.opt.last,
            compute:        req.opt.compute
        };
        // determine shift amount
        if (CombinedShifter) begin
            l.opt.read_shift  = req.src_addr[OffsetWidth-1:0] -
                                req.dst_addr[OffsetWidth-1:0];
            l.opt.write_shift = '0;
        end else begin
            l.opt.read_shift  =   req.src_addr[OffsetWidth-1:0];
            l.opt.write_shift = - req.dst_addr[OffsetWidth-1:0];
        end
        return l;
    endfunction

    load_t ld_in;
    assign ld_in = load(req_i);

    // R takes the next decoupled request while W still writes earlier MX transfers
    idma_req_t mx_wq_in, mx_wq_head;
    logic      mx_wq_empty, mx_wq_full, mx_wq_direct, mx_wq_push, mx_wq_pop;
    load_t     ld_wq;
    assign ld_wq = load(mx_wq_head);

    // the queue keeps the write-side fields only
    always_comb begin : proc_mx_wq_in
        mx_wq_in                        = req_i;
        mx_wq_in.src_addr               = '0;
        mx_wq_in.opt.src_protocol       = idma_pkg::protocol_e'(0);
        mx_wq_in.opt.src_head           = '0;
        mx_wq_in.opt.src                = '0;
        mx_wq_in.opt.beo.src_max_llen   = '0;
        mx_wq_in.opt.beo.src_reduce_len = 1'b0;
    end

    // legalization process -> read and write is coupled together
    always_comb begin : proc_read_write_transaction

        // default: keep state
        r_tf_d   = r_tf_q;
        w_tf_d   = w_tf_q;
        opt_tf_d = opt_tf_q;
        opt_w_d  = opt_w_q;

        // default: not done
        r_done = 1'b0;
        w_done = 1'b0;

        //--------------------------------------
        // Legalize read transaction
        //--------------------------------------
        // more bytes remaining than we can read
        if (r_tf_q.length > r_num_bytes_possible) begin
            r_num_bytes = r_num_bytes_possible;
            // calculate remainder
            r_tf_d.length = r_tf_q.length - r_num_bytes_possible;
            // next address
            r_tf_d.addr = r_tf_q.addr + r_num_bytes;

        // remaining bytes fit in one burst
        end else begin
            r_num_bytes = r_tf_q.length[PageAddrWidth:0];
            // finished
            r_tf_d.valid = 1'b0;
            r_done = 1'b1;
        end

        //--------------------------------------
        // Legalize write transaction
        //--------------------------------------
        // more bytes remaining than we can write
        if (w_tf_q.length > w_num_bytes_possible) begin
            w_num_bytes = w_num_bytes_possible;
            // calculate remainder
            w_tf_d.length = w_tf_q.length - w_num_bytes_possible;
            // next address
            w_tf_d.addr = w_tf_q.addr + w_num_bytes;

        // remaining bytes fit in one burst
        end else begin
            w_num_bytes = w_tf_q.length[PageAddrWidth:0];
            // finished
            w_tf_d.valid = 1'b0;
            w_done = 1'b1;
        end

        // MX: switch between data segments and scale chunks
        mx_r_d = mx_r_q;
        mx_w_d = mx_w_q;
        if (EnableCompute && mx_r_q.on && r_tf_q.valid && r_done) begin
            // dequant source: scale chunk, then the group's data, whole aligned beats
            if (mx_r_q.scl) begin
                r_tf_d.addr   = mx_r_q.daddr;
                r_tf_d.length = mx_rseg(mx_r_q.drem, mx_r_q.g32);
                r_tf_d.valid  = 1'b1;
                mx_r_d.drem   = (mx_r_q.drem > mx_grp(mx_r_q.g32)) ?
                                mx_r_q.drem - mx_grp(mx_r_q.g32) : '0;
                mx_r_d.saddr  = mx_r_q.saddr + mx_sstep(mx_r_q.g32);
                mx_r_d.scl    = 1'b0;
                r_done        = 1'b0;
            end else if (mx_r_q.drem != '0) begin
                mx_r_d.daddr  = mx_r_q.daddr + addr_t'(mx_grp(mx_r_q.g32));
                r_tf_d.addr   = {mx_r_q.saddr[AddrWidth-1:OffsetWidth], {OffsetWidth{1'b0}}};
                r_tf_d.length = mx_rchunk(mx_r_q.saddr, mx_rseg(mx_r_q.drem, mx_r_q.g32));
                r_tf_d.valid  = 1'b1;
                mx_r_d.scl    = 1'b1;
                r_done        = 1'b0;
            end else begin
                mx_r_d.on     = 1'b0;
            end
        end
        if (EnableCompute && mx_w_q.on && w_tf_q.valid && w_done) begin
            // quant destination: the group's data, then its scale chunk
            if (!mx_w_q.scl) begin
                mx_w_d.daddr  = mx_w_q.daddr + addr_t'(mx_grp(mx_w_q.g32));
                mx_w_d.drem   = (mx_w_q.drem > mx_grp(mx_w_q.g32)) ?
                                mx_w_q.drem - mx_grp(mx_w_q.g32) : '0;
                w_tf_d.addr   = mx_w_q.saddr;
                w_tf_d.length = mx_w_q.sn;
                w_tf_d.valid  = 1'b1;
                mx_w_d.scl    = 1'b1;
                w_done        = 1'b0;
            end else if (mx_w_q.drem != '0) begin
                w_tf_d.addr   = mx_w_q.daddr;
                w_tf_d.length = mx_seg(mx_w_q.drem, mx_w_q.g32);
                w_tf_d.valid  = 1'b1;
                mx_w_d.sn     = mx_seg(mx_w_q.drem, mx_w_q.g32) >>
                                $clog2(idma_pkg::MxDataBlockBytes);
                mx_w_d.saddr  = mx_w_q.saddr + mx_sstep(mx_w_q.g32);
                mx_w_d.scl    = 1'b0;
                w_done        = 1'b0;
            end else begin
                mx_w_d.on     = 1'b0;
            end
        end

        //--------------------------------------
        // Kill
        //--------------------------------------
        if (kill_i) begin
            // kill the current state
            r_tf_d = '0;
            w_tf_d = '0;
            r_done = 1'b1;
            w_done = 1'b1;
            mx_r_d = '0;
            mx_w_d = '0;
        end

        //--------------------------------------
        // Refill
        //--------------------------------------
        // new request is taken in if both r and w machines are ready.
        if (ready_o & valid_i) begin
            r_tf_d   = ld_in.r_tf;
            opt_tf_d = ld_in.opt;
            mx_r_d   = ld_in.mx_r;
            if (!mx_wq_push) begin
                w_tf_d  = ld_in.w_tf;
                mx_w_d  = ld_in.mx_w;
                opt_w_d = ld_in.opt;
            end
        end
        // W takes the next queued request
        if (mx_wq_pop) begin
            w_tf_d  = ld_wq.w_tf;
            mx_w_d  = ld_wq.mx_w;
            opt_w_d = ld_wq.opt;
        end
    end


    //--------------------------------------
    // Connect outputs
    //--------------------------------------

    // Read meta channel
    always_comb begin
        r_req_o.ar_req.obi.a_chan = '{
            addr: { r_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
            be: '1,
            we: 1'b0,
            wdata: '0,
            aid: opt_tf_q.axi_id,
            a_optional: '0
        };
    end

    // assign the signals needed to set-up the read data path
    assign r_req_o.r_dp_req = '{
        src_protocol: opt_tf_q.src_protocol,
        src_head:     opt_tf_q.src_head,
        offset:       r_addr_offset,
        tailer:       OffsetWidth'(r_num_bytes + r_addr_offset),
        shift:        opt_tf_q.read_shift,
        decouple_aw:  opt_tf_q.decouple_aw,
        is_single:    r_num_bytes <= StrbWidth,
        mx:           EnableCompute ? idma_pkg::mx_tag(ComputeOps, opt_tf_q.compute,
                                                       mx_r_q.on & mx_r_q.scl,
                                                       mx_r_q.half & r_done, r_done) : '0
    };

    // Write meta channel and data path
    always_comb begin
        w_req_o.aw_req.obi.a_chan = '{
            addr: { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
            be: '0,
            we: 1,
            wdata: '0,
            aid: opt_w_q.axi_id,
            a_optional: '0
        };
        w_req_o.w_dp_req = '{
            dst_protocol: opt_w_q.dst_protocol,
            dst_head:     opt_w_q.dst_head,
            offset:       w_addr_offset,
            tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
            shift:        opt_w_q.write_shift,
            num_beats:    'd0,
            is_single:    1'b1,
            compute:      opt_w_q.compute
        };
    end

    // last burst in generic 1D transfer?
    assign w_req_o.last = w_done;

    // last burst indicated by midend
    assign w_req_o.super_last = opt_w_q.super_last;

    // assign aw decouple flag
    assign w_req_o.decouple_aw = opt_w_q.decouple_aw;

    // busy output
    assign r_busy_o = r_tf_q.valid;
    assign w_busy_o = w_tf_q.valid | ~mx_wq_empty;


    //--------------------------------------
    // Flow Control
    //--------------------------------------
    // only advance to next state if:
    // * rw_coupled: both machines advance
    // * rw_decoupled: either machine advances

    always_comb begin : proc_legalizer_flow_control
        if ( opt_tf_q.decouple_rw
            || (opt_tf_q.src_protocol inside { idma_pkg::OBI })
            || (opt_w_q.dst_protocol inside { idma_pkg::OBI })) begin
            r_tf_ena  = (r_ready_i & !flush_i) | kill_i;
            w_tf_ena  = (w_ready_i & !flush_i) | kill_i;

            r_valid_o = r_tf_q.valid & r_ready_i & !flush_i;
            w_valid_o = w_tf_q.valid & w_ready_i & !flush_i;
        end else begin
            r_tf_ena  = (r_ready_i & w_ready_i & !flush_i) | kill_i;
            w_tf_ena  = (r_ready_i & w_ready_i & !flush_i) | kill_i;

            r_valid_o = r_tf_q.valid & w_ready_i & r_ready_i & !flush_i;
            w_valid_o = w_tf_q.valid & r_ready_i & w_ready_i & !flush_i;
        end
    end

    // load next idma request: if both machines are done, or into the W queue
    assign mx_wq_direct = w_done & (mx_wq_empty | kill_i);
    assign ready_o      = r_done & r_ready_i & w_ready_i & !flush_i &
                          (mx_wq_direct | (EnableCompute & ~mx_wq_full &
                           (req_i.opt.beo.decouple_rw | req_i.opt.compute.enable) &
                           (~mx_wq_empty | (opt_w_q.compute.enable &
                                            idma_pkg::compute_op_is_mx(opt_w_q.compute.op) &
                                            idma_pkg::compute_op_supported(ComputeOps,
                                                                           opt_w_q.compute.op)))));
    assign mx_wq_push   = ready_o & valid_i & ~mx_wq_direct;
    assign mx_wq_pop    = ~mx_wq_empty & w_done & w_ready_i & !flush_i & !kill_i;

    if (EnableCompute) begin : gen_mx_wq
        cc_fifo #(
            .Depth  ( MxWqDepth  ),
            .data_t ( idma_req_t )
        ) i_mx_wq (
            .clk_i,
            .rst_ni,
            .clr_i   ( 1'b0        ),
            .flush_i ( kill_i      ),
            .full_o  ( mx_wq_full  ),
            .empty_o ( mx_wq_empty ),
            .usage_o ( /* NC */    ),
            .data_i  ( mx_wq_in    ),
            .push_i  ( mx_wq_push  ),
            .data_o  ( mx_wq_head  ),
            .pop_i   ( mx_wq_pop   )
        );
        `FF(opt_w_q, opt_w_d, '0, clk_i, rst_ni)
    end else begin : gen_no_mx_wq
        assign mx_wq_full  = 1'b1;
        assign mx_wq_empty = 1'b1;
        assign mx_wq_head  = '0;
        assign opt_w_q     = opt_tf_q;
    end


    //--------------------------------------
    // State
    //--------------------------------------
    `FF (opt_tf_q, opt_tf_d,           '0, clk_i, rst_ni)
    `FFL(r_tf_q,   r_tf_d,   r_tf_ena, '0, clk_i, rst_ni)
    `FFL(w_tf_q,   w_tf_d,   w_tf_ena, '0, clk_i, rst_ni)
    `FFL(mx_r_q,   mx_r_d,   r_tf_ena, '0, clk_i, rst_ni)
    `FFL(mx_w_q,   mx_w_d,   w_tf_ena, '0, clk_i, rst_ni)


    //--------------------------------------
    // Assertions
    //--------------------------------------
    // transpose tile geometry of the presented request (the engine saturates mode at OffsetWidth)
    logic [31:0] tp_num_elem, tp_tile_bytes;
    always_comb begin : proc_transpose_shape
        automatic int unsigned eff_mode;
        eff_mode = (req_i.opt.compute.params.transpose.mode > OffsetWidth) ?
                   OffsetWidth : req_i.opt.compute.params.transpose.mode;
        tp_num_elem   = 32'(StrbWidth) >> eff_mode;
        tp_tile_bytes = tp_num_elem << OffsetWidth;
    end

    // only support the decomposition of incremental bursts
    `ASSERT_NEVER(OnlyIncrementalBurstsSRC, (ready_o & valid_i &
                  req_i.opt.src.burst != axi_pkg::BURST_INCR), clk_i, !rst_ni)
    `ASSERT_NEVER(OnlyIncrementalBurstsDST, (ready_o & valid_i &
                  req_i.opt.dst.burst != axi_pkg::BURST_INCR), clk_i, !rst_ni)

    // size-changing compute: length must be a whole multiple of the op's input granule
    `ASSERT_NEVER(ComputeSizeAligned, (ready_o & valid_i & req_i.opt.compute.enable &
                  (req_i.length %
                   idma_pkg::compute_in_bytes(req_i.opt.compute.op) != 0)), clk_i, !rst_ni)
    // size-changing compute requires beat-aligned addresses
    `ASSERT_NEVER(ComputeSrcAligned, (ready_o & valid_i & req_i.opt.compute.enable &
                  (idma_pkg::compute_in_bytes(req_i.opt.compute.op) !=
                   idma_pkg::compute_out_bytes(req_i.opt.compute.op)) &
                  (req_i.src_addr[OffsetWidth-1:0] != '0)), clk_i, !rst_ni)
    `ASSERT_NEVER(ComputeDstAligned, (ready_o & valid_i & req_i.opt.compute.enable &
                  (idma_pkg::compute_in_bytes(req_i.opt.compute.op) !=
                   idma_pkg::compute_out_bytes(req_i.opt.compute.op)) &
                  (req_i.dst_addr[OffsetWidth-1:0] != '0)), clk_i, !rst_ni)
    // E2M1 and the reserved MX element format are not elaborated
    `ASSERT_NEVER(ComputeMxElemFmt, (ready_o & valid_i & req_i.opt.compute.enable &
                  idma_pkg::compute_op_is_mx(req_i.opt.compute.op) &
                  ~idma_pkg::mx_elem_legal(req_i.opt.compute.params.mx.elem_fmt)),
                  clk_i, !rst_ni)
    // the scale plane starts on a 64 B scale line
    `ASSERT_NEVER(ComputeMxScaleAligned, (ready_o & valid_i & req_i.opt.compute.enable &
                  idma_pkg::compute_op_is_mx(req_i.opt.compute.op) &
                  (req_i.scale_addr[$clog2(idma_pkg::MxScaleSlotBytes)-1:0] != '0)),
                  clk_i, !rst_ni)
    // NOT IMPLEMENTED: dequant output length that overflows the length field
    `ASSERT_NEVER(ComputeMxdequantLengthFits, (ready_o & valid_i & req_i.opt.compute.enable &
                  ((req_i.opt.compute.op == idma_pkg::COMPUTE_MXDEQUANT) |
                   (req_i.opt.compute.op == idma_pkg::COMPUTE_MXDEQUANT_FP16)) &
                  ($bits(req_i.length) < 64) &
                  (((64'(req_i.length) / 64'(idma_pkg::compute_in_bytes(req_i.opt.compute.op))) *
                    64'(idma_pkg::compute_out_bytes(req_i.opt.compute.op))) >=
                   (65'd1 << $bits(req_i.length)))), clk_i, !rst_ni)
    // A tiled-walk strip, or one whole padded tile to a beat-aligned destination
    `ASSERT_NEVER(ComputeTransposeShape, (ready_o & valid_i & req_i.opt.compute.enable &
                  (req_i.opt.compute.op == idma_pkg::COMPUTE_TRANSPOSE) &
                  (req_i.length > StrbWidth) &
                  ~((64'(req_i.length) == 64'(tp_tile_bytes)) &
                    (req_i.dst_addr[OffsetWidth-1:0] == '0) &
                    (req_i.opt.compute.params.transpose.tensor_m <= tp_num_elem) &
                    (req_i.opt.compute.params.transpose.tensor_n <= tp_num_elem))),
                  clk_i, !rst_ni)
    // NOT IMPLEMENTED: transpose edge strobes need a mask_ext write port (AXI/OBI only)
    `ASSERT_NEVER(ComputeTransposeDstStrobe, (ready_o & valid_i & req_i.opt.compute.enable &
                  (req_i.opt.compute.op == idma_pkg::COMPUTE_TRANSPOSE) &
                  !(req_i.opt.dst_protocol inside {idma_pkg::AXI, idma_pkg::OBI})),
                  clk_i, !rst_ni)
    // NOT IMPLEMENTED: size-changing compute is validated on AXI and OBI src/dst only
    `ASSERT_NEVER(ComputeMxSrcProtocol, (ready_o & valid_i & req_i.opt.compute.enable &
                  (idma_pkg::compute_in_bytes(req_i.opt.compute.op) !=
                   idma_pkg::compute_out_bytes(req_i.opt.compute.op)) &
                  !(req_i.opt.src_protocol inside {idma_pkg::AXI, idma_pkg::OBI})),
                  clk_i, !rst_ni)
    `ASSERT_NEVER(ComputeMxDstProtocol, (ready_o & valid_i & req_i.opt.compute.enable &
                  (idma_pkg::compute_in_bytes(req_i.opt.compute.op) !=
                   idma_pkg::compute_out_bytes(req_i.opt.compute.op)) &
                  !(req_i.opt.dst_protocol inside {idma_pkg::AXI, idma_pkg::OBI})),
                  clk_i, !rst_ni)
    // the requested op must be elaborated in this configuration
    `ASSERT_NEVER(ComputeOpUnsupported, (ready_o & valid_i & req_i.opt.compute.enable &
                  ~(EnableCompute &
                    idma_pkg::compute_op_supported(ComputeOps, req_i.opt.compute.op))),
                  clk_i, !rst_ni)

endmodule


// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz <tbenz@ethz.ch>

`include "axi/typedef.svh"
`include "idma/typedef.svh"

/// Synthesis wrapper for the iDMA backend and the nd-midend combined.
/// Unpacks all the interfaces to simple logic vectors
module idma_nd_backend_synth #(
    /// Data width
    parameter int unsigned  DataWidth           = 32'd32,
    /// Address width
    parameter int unsigned  AddrWidth           = 32'd32,
    /// AXI user width
    parameter int unsigned  UserWidth           = 32'd1,
    /// AXI ID width
    parameter int unsigned  AxiIdWidth          = 32'd1,
    /// Number of transaction that can be in-flight concurrently
    parameter int unsigned  NumAxInFlight       = 32'd3,
    /// The depth of the internal reorder buffer:
    /// - '2': minimal possible configuration
    /// - '3': efficiently handle misaligned transfers (recommended)
    parameter int unsigned  BufferDepth         = 32'd3,
    /// With of a transfer: max transfer size is `2**TFLenWidth` bytes
    parameter int unsigned  TFLenWidth          = 32'd32,
    /// The depth of the memory system the backend is attached to
    parameter int unsigned  MemSysDepth         = 32'd0,
    /// The number of dimensions
    parameter int unsigned  NumDim              = 32'd4,
    /// The width of the repetition counters of all dimensions
    parameter int unsigned  RepWidth            = 32'd32,
    /// The supported stride width
    parameter int unsigned  StrideWidth         = 32'd32,
    /// Mask invalid data on the manager interface
    parameter bit           MaskInvalidData     = 1'b1,
    /// Should the `R`-`AW` coupling hardware be present? (recommended)
    parameter bit           RAWCouplingAvail    = 1'b1,
    /// Should hardware legalization be present? (recommended)
    /// If not, software legalization is required to ensure the transfers are
    /// AXI4-conformal
    parameter bit           HardwareLegalizer   = 1'b1,
    /// Reject zero-length transfers
    parameter bit           RejectZeroTransfers = 1'b1,
    /// Should the error handler be present?
    parameter bit           ErrorHandling       = 1'b1,
    // Dependent parameters; do not override!
    /// Strobe Width (do not override!)
    parameter int unsigned StrbWidth       = DataWidth / 8,
    /// Offset Width (do not override!)
    parameter int unsigned OffsetWidth     = $clog2(StrbWidth),
    /// Address type (do not override!)
    parameter type addr_t                  = logic[AddrWidth-1:0],
    /// Data type (do not override!)
    parameter type data_t                  = logic[DataWidth-1:0],
    /// Strobe type (do not override!)
    parameter type strb_t                  = logic[StrbWidth-1:0],
    /// User type (do not override!)
    parameter type user_t                  = logic[UserWidth-1:0],
    /// ID type (do not override!)
    parameter type id_t                    = logic[AxiIdWidth-1:0],
    /// Transfer length type (do not override!)
    parameter type tf_len_t                = logic[TFLenWidth-1:0],
    /// Offset type (do not override!)
    parameter type offset_t                = logic[OffsetWidth-1:0],
    /// Repetitions type (do not override!)
    parameter type reps_t                  = logic [RepWidth-1:0],
    /// Stride type (do not override!)
    parameter type strides_t               = logic [StrideWidth-1:0]
)(
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  logic                   test_i,

    input  logic                   req_valid_i,
    output logic                   req_ready_o,

    input  tf_len_t                req_length_i,
    input  addr_t                  req_src_addr_i,
    input  addr_t                  req_dst_addr_i,
    input  id_t                    req_axi_id_i,
    input  axi_pkg::burst_t        req_src_burst_i,
    input  axi_pkg::cache_t        req_src_cache_i,
    input  logic                   req_src_lock_i,
    input  axi_pkg::prot_t         req_src_prot_i,
    input  axi_pkg::qos_t          req_src_qos_i,
    input  axi_pkg::region_t       req_src_region_i,
    input  axi_pkg::burst_t        req_dst_burst_i,
    input  axi_pkg::cache_t        req_dst_cache_i,
    input  logic                   req_dst_lock_i,
    input  axi_pkg::prot_t         req_dst_prot_i,
    input  axi_pkg::qos_t          req_dst_qos_i,
    input  axi_pkg::region_t       req_dst_region_i,
    input  logic                   req_decouple_aw_i,
    input  logic                   req_decouple_rw_i,
    input  logic [2:0]             req_src_max_llen_i,
    input  logic [2:0]             req_dst_max_llen_i,
    input  logic                   req_src_reduce_len_i,
    input  logic                   req_dst_reduce_len_i,
    input  logic                   req_last_i,

    input  reps_t [NumDim-2:0]     req_reps_i,
    input  strides_t [NumDim-2:0]  req_src_strides_i,
    input  strides_t [NumDim-2:0]  req_dst_strides_i,

    output logic                   rsp_valid_o,
    input  logic                   rsp_ready_i,

    output axi_pkg::resp_t         rsp_cause_o,
    output idma_pkg::err_type_t    rsp_err_type_o,
    output addr_t                  rsp_burst_addr_o,
    output logic                   rsp_error_o,
    output logic                   rsp_last_o,

    input  logic                   eh_req_valid_i,
    output logic                   eh_req_ready_o,
    input  idma_pkg::idma_eh_req_t eh_req_i,

    output idma_pkg::idma_busy_t   idma_busy_o,
    output logic                   nd_busy_o,

    output id_t                    axi_aw_id_o,
    output addr_t                  axi_aw_addr_o,
    output axi_pkg::len_t          axi_aw_len_o,
    output axi_pkg::size_t         axi_aw_size_o,
    output axi_pkg::burst_t        axi_aw_burst_o,
    output logic                   axi_aw_lock_o,
    output axi_pkg::cache_t        axi_aw_cache_o,
    output axi_pkg::prot_t         axi_aw_prot_o,
    output axi_pkg::qos_t          axi_aw_qos_o,
    output axi_pkg::region_t       axi_aw_region_o,
    output axi_pkg::atop_t         axi_aw_atop_o,
    output user_t                  axi_aw_user_o,
    output logic                   axi_aw_valid_o,
    input  logic                   axi_aw_ready_i,
    output data_t                  axi_w_data_o,
    output strb_t                  axi_w_strb_o,
    output logic                   axi_w_last_o,
    output user_t                  axi_w_user_o,
    output logic                   axi_w_valid_o,
    input  logic                   axi_w_ready_i,
    input  id_t                    axi_b_id_i,
    input  axi_pkg::resp_t         axi_b_resp_i,
    input  user_t                  axi_b_user_i,
    input  logic                   axi_b_valid_i,
    output logic                   axi_b_ready_o,
    output id_t                    axi_ar_id_o,
    output addr_t                  axi_ar_addr_o,
    output axi_pkg::len_t          axi_ar_len_o,
    output axi_pkg::size_t         axi_ar_size_o,
    output axi_pkg::burst_t        axi_ar_burst_o,
    output logic                   axi_ar_lock_o,
    output axi_pkg::cache_t        axi_ar_cache_o,
    output axi_pkg::prot_t         axi_ar_prot_o,
    output axi_pkg::qos_t          axi_ar_qos_o,
    output axi_pkg::region_t       axi_ar_region_o,
    output user_t                  axi_ar_user_o,
    output logic                   axi_ar_valid_o,
    input  logic                   axi_ar_ready_i,
    input  id_t                    axi_r_id_i,
    input  data_t                  axi_r_data_i,
    input  axi_pkg::resp_t         axi_r_resp_i,
    input  logic                   axi_r_last_i,
    input  user_t                  axi_r_user_i,
    input  logic                   axi_r_valid_i,
    output logic                   axi_r_ready_o
);

    /// Define the error handling capability
    localparam idma_pkg::error_cap_e ErrorCap = ErrorHandling ? idma_pkg::ERROR_HANDLING :
                                                                idma_pkg::NO_ERROR_HANDLING;

    // AXI4 types
    `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
    `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)

    `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)

    `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
    `AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)

    /// Option struct: AXI4 id as well as AXI and backend options
    /// - `last`: a flag can be set if this transfer is the last of a set of transfers
    `IDMA_TYPEDEF_OPTIONS_T(options_t, id_t)

    /// 1D iDMA request type:
    /// - `length`: the length of the transfer in bytes
    /// - `*_addr`: the source / target byte addresses of the transfer
    /// - `opt`: the options field
    `IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, addr_t, options_t)

    /// 1D iDMA response payload:
    /// - `cause`: the AXI response
    /// - `err_type`: type of the error: read, write, internal, ...
    /// - `burst_addr`: the burst address where the issue error occurred
    `IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, addr_t)

    /// 1D iDMA response type:
    /// - `last`: the response of the request that was marked with the `opt.last` flag
    /// - `error`: 1 if an error occurred
    /// - `pld`: the error payload
    `IDMA_TYPEDEF_RSP_T(idma_rsp_t, err_payload_t)

    /// Sub-type: holds additional information required by one dimensions.
    /// - `reps`: The number of times this dimension needs to be repeated
    /// - `src_strides`: The source stride
    /// - `dst_strides`: The destination stride
    `IDMA_TYPEDEF_D_REQ_T(idma_d_req_t, reps_t, strides_t)

    /// ND iDMA request type. Union of a 1D iDMA request (innermost dimension) and the configuration
    /// of each additional dimension. To pass a 1D transfer just set the lowest number of
    /// repetitions to one keeping the rest to 0.
    `IDMA_TYPEDEF_ND_REQ_T(idma_nd_req_t, idma_req_t, idma_d_req_t)

    // local types
    axi_req_t     axi_req_o;
    axi_rsp_t     axi_rsp_i;

    idma_req_t    idma_req;
    logic         idma_req_valid;
    logic         idma_req_ready;
    idma_rsp_t    idma_rsp;
    logic         idma_rsp_valid;
    logic         idma_rsp_ready;

    idma_nd_req_t nd_req;
    idma_rsp_t    nd_rsp;

    // DUT instantiation
    idma_backend #(
        .DataWidth           ( DataWidth               ),
        .AddrWidth           ( AddrWidth               ),
        .AxiIdWidth          ( AxiIdWidth              ),
        .UserWidth           ( UserWidth               ),
        .TFLenWidth          ( TFLenWidth              ),
        .MaskInvalidData     ( MaskInvalidData         ),
        .BufferDepth         ( BufferDepth             ),
        .NumAxInFlight       ( NumAxInFlight           ),
        .MemSysDepth         ( MemSysDepth             ),
        .RAWCouplingAvail    ( RAWCouplingAvail        ),
        .HardwareLegalizer   ( HardwareLegalizer       ),
        .RejectZeroTransfers ( RejectZeroTransfers     ),
        .ErrorCap            ( ErrorCap                ),
        .idma_req_t          ( idma_req_t              ),
        .idma_rsp_t          ( idma_rsp_t              ),
        .idma_eh_req_t       ( idma_pkg::idma_eh_req_t ),
        .idma_busy_t         ( idma_pkg::idma_busy_t   ),
        .axi_req_t           ( axi_req_t               ),
        .axi_rsp_t           ( axi_rsp_t               )
    ) i_idma_backend (
        .clk_i           ( clk_i          ),
        .rst_ni          ( rst_ni         ),
        .testmode_i      ( test_i         ),
        .idma_req_i      ( idma_req       ),
        .req_valid_i     ( idma_req_valid ),
        .req_ready_o     ( idma_req_ready ),
        .idma_rsp_o      ( idma_rsp       ),
        .rsp_valid_o     ( idma_rsp_valid ),
        .rsp_ready_i     ( idma_rsp_ready ),
        .idma_eh_req_i   ( eh_req_i       ),
        .eh_req_valid_i  ( eh_req_valid_i ),
        .eh_req_ready_o  ( eh_req_ready_o ),
        .axi_req_o       ( axi_req_o      ),
        .axi_rsp_i       ( axi_rsp_i      ),
        .busy_o          ( idma_busy_o    )
    );

    localparam logic [NumDim-1:0][31:0] RepWidths  = '{default: RepWidth};

    // nd midend
    idma_nd_midend #(
        .NumDim        ( NumDim        ),
        .addr_t        ( addr_t        ),
        .idma_req_t    ( idma_req_t    ),
        .idma_rsp_t    ( idma_rsp_t    ),
        .idma_nd_req_t ( idma_nd_req_t ),
        .RepWidths     ( RepWidths     )
    ) i_idma_nd_midend (
        .clk_i             ( clk_i           ),
        .rst_ni            ( rst_ni          ),
        .nd_req_i          ( nd_req          ),
        .nd_req_valid_i    ( req_valid_i     ),
        .nd_req_ready_o    ( req_ready_o     ),
        .nd_rsp_o          ( nd_rsp          ),
        .nd_rsp_valid_o    ( rsp_valid_o     ),
        .nd_rsp_ready_i    ( rsp_ready_i     ),
        .burst_req_o       ( idma_req        ),
        .burst_req_valid_o ( idma_req_valid  ),
        .burst_req_ready_i ( idma_req_ready  ),
        .burst_rsp_i       ( idma_rsp        ),
        .burst_rsp_valid_i ( idma_rsp_valid  ),
        .burst_rsp_ready_o ( idma_rsp_ready  ),
        .busy_o            ( nd_busy_o       )
    );

    // flatten structs
    assign nd_req.burst_req.dst_addr               = req_dst_addr_i;
    assign nd_req.burst_req.src_addr               = req_src_addr_i;
    assign nd_req.burst_req.length                 = req_length_i;
    assign nd_req.burst_req.opt.axi_id             = req_axi_id_i;
    assign nd_req.burst_req.opt.dst.cache          = req_dst_cache_i;
    assign nd_req.burst_req.opt.dst.burst          = req_dst_burst_i;
    assign nd_req.burst_req.opt.dst.qos            = req_dst_qos_i;
    assign nd_req.burst_req.opt.dst.lock           = req_dst_lock_i;
    assign nd_req.burst_req.opt.dst.prot           = req_dst_prot_i;
    assign nd_req.burst_req.opt.dst.region         = req_dst_region_i;
    assign nd_req.burst_req.opt.src.cache          = req_src_cache_i;
    assign nd_req.burst_req.opt.src.burst          = req_src_burst_i;
    assign nd_req.burst_req.opt.src.qos            = req_src_qos_i;
    assign nd_req.burst_req.opt.src.lock           = req_src_lock_i;
    assign nd_req.burst_req.opt.src.prot           = req_src_prot_i;
    assign nd_req.burst_req.opt.src.region         = req_src_region_i;
    assign nd_req.burst_req.opt.beo.dst_reduce_len = req_dst_reduce_len_i;
    assign nd_req.burst_req.opt.beo.src_reduce_len = req_src_reduce_len_i;
    assign nd_req.burst_req.opt.beo.dst_max_llen   = req_dst_max_llen_i;
    assign nd_req.burst_req.opt.beo.src_max_llen   = req_src_max_llen_i;
    assign nd_req.burst_req.opt.beo.decouple_rw    = req_decouple_rw_i;
    assign nd_req.burst_req.opt.beo.decouple_aw    = req_decouple_aw_i;
    assign nd_req.burst_req.opt.last               = req_last_i;

    for (genvar d = 0; d < NumDim-1; d++) begin : gen_nd_connect
        // local signal
        idma_d_req_t d_req;
        assign d_req.reps        = req_reps_i[d];
        assign d_req.src_strides = req_src_strides_i[d];
        assign d_req.dst_strides = req_dst_strides_i[d];
        // connection
        assign nd_req.d_req[d]   = d_req;
    end

    assign rsp_cause_o       = nd_rsp.pld.cause;
    assign rsp_err_type_o    = nd_rsp.pld.err_type;
    assign rsp_burst_addr_o  = nd_rsp.pld.burst_addr;
    assign rsp_error_o       = nd_rsp.error;
    assign rsp_last_o        = nd_rsp.last;

    assign axi_aw_id_o     = axi_req_o.aw.id;
    assign axi_aw_addr_o   = axi_req_o.aw.addr;
    assign axi_aw_len_o    = axi_req_o.aw.len;
    assign axi_aw_size_o   = axi_req_o.aw.size;
    assign axi_aw_burst_o  = axi_req_o.aw.burst;
    assign axi_aw_lock_o   = axi_req_o.aw.lock;
    assign axi_aw_cache_o  = axi_req_o.aw.cache;
    assign axi_aw_prot_o   = axi_req_o.aw.prot;
    assign axi_aw_qos_o    = axi_req_o.aw.qos;
    assign axi_aw_region_o = axi_req_o.aw.region;
    assign axi_aw_atop_o   = axi_req_o.aw.atop;
    assign axi_aw_user_o   = axi_req_o.aw.user;
    assign axi_aw_valid_o  = axi_req_o.aw_valid;
    assign axi_w_data_o    = axi_req_o.w.data;
    assign axi_w_strb_o    = axi_req_o.w.strb;
    assign axi_w_last_o    = axi_req_o.w.last;
    assign axi_w_user_o    = axi_req_o.w.user;
    assign axi_w_valid_o   = axi_req_o.w_valid;
    assign axi_b_ready_o   = axi_req_o.b_ready;
    assign axi_ar_id_o     = axi_req_o.ar.id;
    assign axi_ar_addr_o   = axi_req_o.ar.addr;
    assign axi_ar_len_o    = axi_req_o.ar.len;
    assign axi_ar_size_o   = axi_req_o.ar.size;
    assign axi_ar_burst_o  = axi_req_o.ar.burst;
    assign axi_ar_lock_o   = axi_req_o.ar.lock;
    assign axi_ar_cache_o  = axi_req_o.ar.cache;
    assign axi_ar_prot_o   = axi_req_o.ar.prot;
    assign axi_ar_qos_o    = axi_req_o.ar.qos;
    assign axi_ar_region_o = axi_req_o.ar.region;
    assign axi_ar_user_o   = axi_req_o.ar.user;
    assign axi_ar_valid_o  = axi_req_o.ar_valid;
    assign axi_r_ready_o   = axi_req_o.r_ready;

    assign axi_rsp_i.aw_ready = axi_aw_ready_i;
    assign axi_rsp_i.w_ready  = axi_w_ready_i;
    assign axi_rsp_i.b.id     = axi_b_id_i;
    assign axi_rsp_i.b.resp   = axi_b_resp_i;
    assign axi_rsp_i.b.user   = axi_b_user_i;
    assign axi_rsp_i.b_valid  = axi_b_valid_i;
    assign axi_rsp_i.ar_ready = axi_ar_ready_i;
    assign axi_rsp_i.r.id     = axi_r_id_i;
    assign axi_rsp_i.r.data   = axi_r_data_i;
    assign axi_rsp_i.r.resp   = axi_r_resp_i;
    assign axi_rsp_i.r.last   = axi_r_last_i;
    assign axi_rsp_i.r.user   = axi_r_user_i;
    assign axi_rsp_i.r_valid  = axi_r_valid_i;

endmodule : idma_nd_backend_synth

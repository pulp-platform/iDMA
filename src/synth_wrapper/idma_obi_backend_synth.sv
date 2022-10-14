// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz  <tbenz@ethz.ch>
// Tobias Senti <tsenti@student.ethz.ch>

`include "axi/typedef.svh"
`include "idma/typedef.svh"

/// Synthesis wrapper for the iDMA backend. Unpacks all the interfaces to simple logic vectors
module idma_obi_backend_synth #(
    /// Data width
    parameter int unsigned  DataWidth           = 32'd32,
    /// Address width
    parameter int unsigned  AddrWidth           = 32'd32,
    /// AXI ID width
    parameter int unsigned  AxiIdWidth          = 32'd1,
    /// The depth of the internal reorder buffer:
    /// - '2': minimal possible configuration
    /// - '3': efficiently handle misaligned transfers (recommended)
    parameter int unsigned  BufferDepth         = 32'd3,
    /// Number of transaction that can be in-flight concurrently
    parameter int unsigned  NumAxInFlight       = 32'd3,
    /// With of a transfer: max transfer size is `2**TFLenWidth` bytes
    parameter int unsigned  TFLenWidth          = 32'd32,
    /// The depth of the memory system the backend is attached to
    parameter int unsigned  MemSysDepth         = 32'd0,
    /// Mask invalid data on the manager interface
    parameter bit           MaskInvalidData     = 1'b1,
    /// Should the `R`-`AW` coupling hardware be present? (recommended)
    parameter bit           RAWCouplingAvail    = 1'b0,
    /// Should hardware legalization be present? (recommended)
    /// If not, software legalization is required to ensure the transfers are
    /// AXI4-conformal
    parameter bit           HardwareLegalizer   = 1'b1,
    /// Reject zero-length transfers
    parameter bit           RejectZeroTransfers = 1'b1,
    /// Should the error handler be present?
    parameter bit           ErrorHandling       = 1'b0,
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
    /// Transfer length type (do not override!)
    parameter type tf_len_t                = logic[TFLenWidth-1:0],
    /// Offset type (do not override!)
    parameter type offset_t                = logic[OffsetWidth-1:0],
    /// ID type (do not override!)
    parameter type id_t                    = logic[AxiIdWidth-1:0]
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

    output logic                   obi_write_req_a_req_o,
    output addr_t                  obi_write_req_a_addr_o,
    output logic                   obi_write_req_a_we_o,
    output strb_t                  obi_write_req_a_be_o,
    output data_t                  obi_write_req_a_wdata_o,
    output logic                   obi_write_req_r_ready_o,

    output logic                   obi_read_req_a_req_o,
    output addr_t                  obi_read_req_a_addr_o,
    output logic                   obi_read_req_a_we_o,
    output strb_t                  obi_read_req_a_be_o,
    output data_t                  obi_read_req_a_wdata_o,
    output logic                   obi_read_req_r_ready_o,

    input logic                    obi_write_rsp_a_gnt_i,
    input logic                    obi_write_rsp_r_valid_i,
    input data_t                   obi_write_rsp_r_rdata_i,

    input logic                    obi_read_rsp_a_gnt_i,
    input logic                    obi_read_rsp_r_valid_i,
    input data_t                   obi_read_rsp_r_rdata_i
);

    /// Define the error handling capability
    localparam idma_pkg::error_cap_e ErrorCap = ErrorHandling ? idma_pkg::ERROR_HANDLING :
                                                                idma_pkg::NO_ERROR_HANDLING;

    // OBI types
    `IDMA_OBI_TYPEDEF_A_CHAN_T(obi_a_chan_t, addr_t, data_t, strb_t)
    `IDMA_OBI_TYPEDEF_R_CHAN_T(obi_r_chan_t, data_t)

    `IDMA_OBI_TYPEDEF_REQ_T(obi_master_req_t, obi_a_chan_t)
    `IDMA_OBI_TYPEDEF_RESP_T(obi_master_rsp_t, obi_r_chan_t)

    `IDMA_OBI_TYPEDEF_BIDIRECT_REQ_T(obi_req_t, obi_master_req_t)
    `IDMA_OBI_TYPEDEF_BIDIRECT_RESP_T(obi_rsp_t, obi_master_rsp_t)

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

    // local types
    obi_req_t               obi_req_o;
    obi_rsp_t               obi_rsp_i;
    idma_req_t              idma_req;
    idma_rsp_t              idma_rsp;

    // DUT instantiation
    idma_backend #(
        .Protocol            ( idma_pkg::OBI           ),
        .DataWidth           ( DataWidth               ),
        .AddrWidth           ( AddrWidth               ),
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
        .protocol_req_t      ( obi_req_t               ),
        .protocol_rsp_t      ( obi_rsp_t               ),
        .aw_chan_t           ( obi_a_chan_t            ),
        .ar_chan_t           ( obi_a_chan_t            )
    ) i_idma_backend (
        .clk_i           ( clk_i          ),
        .rst_ni          ( rst_ni         ),
        .testmode_i      ( test_i         ),
        .idma_req_i      ( idma_req       ),
        .req_valid_i     ( req_valid_i    ),
        .req_ready_o     ( req_ready_o    ),
        .idma_rsp_o      ( idma_rsp       ),
        .rsp_valid_o     ( rsp_valid_o    ),
        .rsp_ready_i     ( rsp_ready_i    ),
        .idma_eh_req_i   ( eh_req_i       ),
        .eh_req_valid_i  ( eh_req_valid_i ),
        .eh_req_ready_o  ( eh_req_ready_o ),
        .protocol_req_o  ( obi_req_o      ),
        .protocol_rsp_i  ( obi_rsp_i      ),
        .busy_o          ( idma_busy_o    )
    );

    // flatten structs
    assign idma_req.dst_addr               = req_dst_addr_i;
    assign idma_req.src_addr               = req_src_addr_i;
    assign idma_req.length                 = req_length_i;
    assign idma_req.opt.axi_id             = req_axi_id_i;
    assign idma_req.opt.dst.cache          = req_dst_cache_i;
    assign idma_req.opt.dst.burst          = req_dst_burst_i;
    assign idma_req.opt.dst.qos            = req_dst_qos_i;
    assign idma_req.opt.dst.lock           = req_dst_lock_i;
    assign idma_req.opt.dst.prot           = req_dst_prot_i;
    assign idma_req.opt.dst.region         = req_dst_region_i;
    assign idma_req.opt.src.cache          = req_src_cache_i;
    assign idma_req.opt.src.burst          = req_src_burst_i;
    assign idma_req.opt.src.qos            = req_src_qos_i;
    assign idma_req.opt.src.lock           = req_src_lock_i;
    assign idma_req.opt.src.prot           = req_src_prot_i;
    assign idma_req.opt.src.region         = req_src_region_i;
    assign idma_req.opt.beo.dst_reduce_len = req_dst_reduce_len_i;
    assign idma_req.opt.beo.src_reduce_len = req_src_reduce_len_i;
    assign idma_req.opt.beo.dst_max_llen   = req_dst_max_llen_i;
    assign idma_req.opt.beo.src_max_llen   = req_src_max_llen_i;
    assign idma_req.opt.beo.decouple_rw    = req_decouple_rw_i;
    assign idma_req.opt.beo.decouple_aw    = req_decouple_aw_i;
    assign idma_req.opt.last               = req_last_i;

    assign rsp_cause_o      = idma_rsp.pld.cause;
    assign rsp_err_type_o   = idma_rsp.pld.err_type;
    assign rsp_burst_addr_o = idma_rsp.pld.burst_addr;
    assign rsp_error_o      = idma_rsp.error;
    assign rsp_last_o       = idma_rsp.last;

    assign obi_read_req_a_req_o = obi_req_o.read.a_req;
    assign obi_read_req_a_addr_o = obi_req_o.read.a.addr;
    assign obi_read_req_a_we_o = obi_req_o.read.a.we;
    assign obi_read_req_a_be_o = obi_req_o.read.a.be;
    assign obi_read_req_a_wdata_o = obi_req_o.read.a.wdata;
    assign obi_read_req_r_ready_o = obi_req_o.read.r_ready;

    assign obi_write_req_a_req_o = obi_req_o.write.a_req;
    assign obi_write_req_a_addr_o = obi_req_o.write.a.addr;
    assign obi_write_req_a_we_o = obi_req_o.write.a.we;
    assign obi_write_req_a_be_o = obi_req_o.write.a.be;
    assign obi_write_req_a_wdata_o = obi_req_o.write.a.wdata;
    assign obi_write_req_r_ready_o = obi_req_o.write.r_ready;

    assign obi_rsp_i.read.a_gnt = obi_read_rsp_a_gnt_i;
    assign obi_rsp_i.read.r_valid = obi_read_rsp_r_valid_i;
    assign obi_rsp_i.read.r.rdata = obi_read_rsp_r_rdata_i;

    assign obi_rsp_i.write.a_gnt = obi_write_rsp_a_gnt_i;
    assign obi_rsp_i.write.r_valid = obi_write_rsp_r_valid_i;
    assign obi_rsp_i.write.r.rdata = obi_write_rsp_r_rdata_i;

endmodule : idma_obi_backend_synth

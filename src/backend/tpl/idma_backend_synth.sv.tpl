// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "axi/typedef.svh"
`include "axi_stream/typedef.svh"
`include "idma/typedef.svh"
`include "obi/typedef.svh"
`include "tilelink/typedef.svh"

/// Synthesis wrapper for the iDMA backend. Unpacks all the interfaces to simple logic vectors
module idma_backend_synth_${name_uniqueifier} #(
    /// Data width
    parameter int unsigned DataWidth           = 32'd32,
    /// Address width
    parameter int unsigned AddrWidth           = 32'd32,
    /// AXI user width
    parameter int unsigned UserWidth           = 32'd1,
    /// AXI ID width
    parameter int unsigned AxiIdWidth          = 32'd1,
    /// Number of transaction that can be in-flight concurrently
    parameter int unsigned NumAxInFlight       = 32'd3,
    /// The depth of the internal reorder buffer:
    /// - '2': minimal possible configuration
    /// - '3': efficiently handle misaligned transfers (recommended)
    parameter int unsigned BufferDepth         = 32'd3,
    /// With of a transfer: max transfer size is `2**TFLenWidth` bytes
    parameter int unsigned TFLenWidth          = 32'd32,
    /// The depth of the memory system the backend is attached to
    parameter int unsigned MemSysDepth         = 32'd0,
    /// Should both data shifts be done before the dataflow element?
    /// If this is enabled, then the data inserted into the dataflow element
    /// will no longer be word aligned, but only a single shifter is needed
    parameter bit          CombinedShifter     = 1'b\
% if combined_shifter:
1,
% else:
0,
% endif
    /// Mask invalid data on the manager interface
    parameter bit          MaskInvalidData     = 1'b1,
    /// Should the `R`-`AW` coupling hardware be present? (recommended)
    parameter bit          RAWCouplingAvail    = \
% if one_read_port and one_write_port and ('axi' in used_read_protocols) and ('axi' in used_write_protocols):
1,
% else:
0,
%endif
    /// Should hardware legalization be present? (recommended)
    /// If not, software legalization is required to ensure the transfers are
    /// AXI4-conformal
    parameter bit          HardwareLegalizer   = 1'b1,
    /// Reject zero-length transfers
    parameter bit          RejectZeroTransfers = 1'b1,
    /// Should the error handler be present?
    parameter bit          ErrorHandling       = 1'b\
% if one_read_port and one_write_port and ('axi' in used_read_protocols) and ('axi' in used_write_protocols):
1,
% else:
0,
%endif
    // Dependent parameters; do not override!
    /// Strobe Width (do not override!)
    parameter int unsigned StrbWidth           = DataWidth / 8,
    /// Offset Width (do not override!)
    parameter int unsigned OffsetWidth         = $clog2(StrbWidth),
    /// Address type (do not override!)
    parameter type addr_t                      = logic[AddrWidth-1:0],
    /// Data type (do not override!)
    parameter type data_t                      = logic[DataWidth-1:0],
    /// Strobe type (do not override!)
    parameter type strb_t                      = logic[StrbWidth-1:0],
    /// User type (do not override!)
    parameter type user_t                      = logic[UserWidth-1:0],
    /// ID type (do not override!)
    parameter type id_t                        = logic[AxiIdWidth-1:0],
    /// Transfer length type (do not override!)
    parameter type tf_len_t                    = logic[TFLenWidth-1:0],
    /// Offset type (do not override!)
    parameter type offset_t                    = logic[OffsetWidth-1:0]
)(
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  logic                   test_i,

    input  logic                   req_valid_i,
    output logic                   req_ready_o,

    input  tf_len_t                req_length_i,
    input  addr_t                  req_src_addr_i,
    input  addr_t                  req_dst_addr_i,
    input  idma_pkg::protocol_e    req_src_protocol_i,
    input  idma_pkg::protocol_e    req_dst_protocol_i,
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

% for protocol in used_read_protocols:
${database[protocol]['synth_wrapper_ports_read']}

% endfor
% for index, protocol in enumerate(used_write_protocols):
${database[protocol]['synth_wrapper_ports_write']}

% endfor
    output idma_pkg::idma_busy_t   idma_busy_o
);

    /// Define the error handling capability
    localparam idma_pkg::error_cap_e ErrorCap = ErrorHandling ? idma_pkg::ERROR_HANDLING :
                                                                idma_pkg::NO_ERROR_HANDLING;

% for protocol in used_protocols:
    // ${database[protocol]['full_name']} typedefs
${database[protocol]['typedefs']}

% endfor
    // Meta Channel Widths
% for protocol in used_write_protocols:
    % if 'write_meta_channel_width' in database[protocol]:
    ${database[protocol]['write_meta_channel_width']}
    % endif
% endfor
% for protocol in used_read_protocols:
    % if 'read_meta_channel_width' in database[protocol]:
    ${database[protocol]['read_meta_channel_width']}
    % endif
% endfor
% for protocol in used_protocols:
    % if 'meta_channel_width' in database[protocol]:
    ${database[protocol]['meta_channel_width']}
    % endif
% endfor

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

% if (not one_read_port) or (not one_write_port):
    function int unsigned max_width(input int unsigned a, b);
        return (a > b) ? a : b;
    endfunction
% endif

% if one_read_port:
    typedef struct packed {
        ${used_read_protocols[0]}_${database[used_read_protocols[0]]['read_meta_channel']}_t ${database[used_read_protocols[0]]['read_meta_channel']};
    } ${used_read_protocols[0]}_read_meta_channel_t;

    typedef struct packed {
        ${used_read_protocols[0]}_read_meta_channel_t ${used_read_protocols[0]};
    } read_meta_channel_t;
% else:
    % for protocol in used_read_protocols:
    typedef struct packed {
        ${protocol}_${database[protocol]['read_meta_channel']}_t ${database[protocol]['read_meta_channel']};
        logic[\
        % for index, p in enumerate(used_read_protocols):
            % if index < len(used_read_protocols)-1:
max_width(${p}_${database[p]['read_meta_channel']}_width, \
            % else:
${p}_${database[p]['read_meta_channel']}_width\
            % endif
        % endfor
        % for i in range(0, len(used_read_protocols)-1):
)\
        % endfor
-${protocol}_${database[protocol]['read_meta_channel']}_width:0] padding;
    } ${protocol}_read_${database[protocol]['read_meta_channel']}_padded_t;

    % endfor
    typedef union packed {
    % for protocol in used_read_protocols:
        ${protocol}_read_${database[protocol]['read_meta_channel']}_padded_t ${protocol};
    % endfor
    } read_meta_channel_t;
% endif

% if one_write_port:
    typedef struct packed {
        ${used_write_protocols[0]}_${database[used_write_protocols[0]]['write_meta_channel']}_t ${database[used_write_protocols[0]]['write_meta_channel']};
    } ${used_write_protocols[0]}_write_meta_channel_t;

    typedef struct packed {
        ${used_write_protocols[0]}_write_meta_channel_t ${used_write_protocols[0]};
    } write_meta_channel_t;
% else:
    % for protocol in used_write_protocols:
    typedef struct packed {
        ${protocol}_${database[protocol]['write_meta_channel']}_t ${database[protocol]['write_meta_channel']};
        logic[\
        % for index, p in enumerate(used_write_protocols):
            % if index < len(used_write_protocols)-1:
max_width(${p}_${database[p]['write_meta_channel']}_width, \
            % else:
${p}_${database[p]['write_meta_channel']}_width\
            % endif
        % endfor
        % for i in range(0, len(used_write_protocols)-1):
)\
        % endfor
-${protocol}_${database[protocol]['write_meta_channel']}_width:0] padding;
    } ${protocol}_write_${database[protocol]['write_meta_channel']}_padded_t;

    % endfor
    typedef union packed {
    % for protocol in used_write_protocols:
        ${protocol}_write_${database[protocol]['write_meta_channel']}_padded_t ${protocol};
    % endfor
    } write_meta_channel_t;
% endif

    // local types
% for protocol in used_protocols:
    // ${database[protocol]['full_name']} request and response
    % if protocol in used_read_protocols:
        % if database[protocol]['read_slave'] == 'true':
    ${protocol}_rsp_t ${protocol}_read_req;
    ${protocol}_req_t ${protocol}_read_rsp;
        % else:
    ${protocol}_req_t ${protocol}_read_req;
    ${protocol}_rsp_t ${protocol}_read_rsp;
        % endif
    % endif

    % if protocol in used_write_protocols:
    ${protocol}_req_t ${protocol}_write_req;
    ${protocol}_rsp_t ${protocol}_write_rsp;
    % endif

% endfor
    idma_req_t idma_req;
    idma_rsp_t idma_rsp;

    idma_backend_${name_uniqueifier} #(
        .CombinedShifter      ( CombinedShifter         ),
        .DataWidth            ( DataWidth               ),
        .AddrWidth            ( AddrWidth               ),
        .AxiIdWidth           ( AxiIdWidth              ),
        .UserWidth            ( UserWidth               ),
        .TFLenWidth           ( TFLenWidth              ),
        .MaskInvalidData      ( MaskInvalidData         ),
        .BufferDepth          ( BufferDepth             ),
        .NumAxInFlight        ( NumAxInFlight           ),
        .MemSysDepth          ( MemSysDepth             ),
        .RAWCouplingAvail     ( RAWCouplingAvail        ),
        .HardwareLegalizer    ( HardwareLegalizer       ),
        .RejectZeroTransfers  ( RejectZeroTransfers     ),
        .ErrorCap             ( ErrorCap                ),
        .idma_req_t           ( idma_req_t              ),
        .idma_rsp_t           ( idma_rsp_t              ),
        .idma_eh_req_t        ( idma_pkg::idma_eh_req_t ),
        .idma_busy_t          ( idma_pkg::idma_busy_t   )\
% for protocol in used_protocols:
,
    % if database[protocol]['read_slave'] == 'true':
        % if (protocol in used_read_protocols) and (protocol in used_write_protocols):
        .${protocol}_read_req_t  ( ${protocol}_rsp_t ),
        .${protocol}_read_rsp_t  ( ${protocol}_req_t ),
        .${protocol}_write_req_t ( ${protocol}_req_t ),
        .${protocol}_write_rsp_t ( ${protocol}_rsp_t )\
        % elif protocol in used_read_protocols:
        .${protocol}_read_req_t ( ${protocol}_rsp_t ),
        .${protocol}_read_rsp_t ( ${protocol}_req_t )\
        % else:
        .${protocol}_write_req_t ( ${protocol}_req_t ),
        .${protocol}_write_rsp_t ( ${protocol}_rsp_t )\
        % endif
    % else:
        .${protocol}_req_t ( ${protocol}_req_t ),
        .${protocol}_rsp_t ( ${protocol}_rsp_t )\
    % endif
% endfor
,
        .write_meta_channel_t ( write_meta_channel_t    ),
        .read_meta_channel_t  ( read_meta_channel_t     )
    ) i_idma_backend (
        .clk_i                ( clk_i          ),
        .rst_ni               ( rst_ni         ),
        .testmode_i           ( test_i         ),
        .idma_req_i           ( idma_req       ),
        .req_valid_i          ( req_valid_i    ),
        .req_ready_o          ( req_ready_o    ),
        .idma_rsp_o           ( idma_rsp       ),
        .rsp_valid_o          ( rsp_valid_o    ),
        .rsp_ready_i          ( rsp_ready_i    ),
        .idma_eh_req_i        ( eh_req_i       ),
        .eh_req_valid_i       ( eh_req_valid_i ),
        .eh_req_ready_o       ( eh_req_ready_o )\
% for protocol in used_read_protocols:
,
% if database[protocol]['passive_req'] == 'true':
        .${protocol}_read_req_i       ( ${protocol}_read_req   ),
        .${protocol}_read_rsp_o       ( ${protocol}_read_rsp   )\
% else:
        .${protocol}_read_req_o       ( ${protocol}_read_req   ),
        .${protocol}_read_rsp_i       ( ${protocol}_read_rsp   )\
% endif
% endfor
% for protocol in used_write_protocols:
,
        .${protocol}_write_req_o      ( ${protocol}_write_req  ),
        .${protocol}_write_rsp_i      ( ${protocol}_write_rsp  )\
% endfor
,
        .busy_o               ( idma_busy_o    )
    );

    // flatten structs
    assign idma_req.dst_addr               = req_dst_addr_i;
    assign idma_req.src_addr               = req_src_addr_i;
    assign idma_req.length                 = req_length_i;
    assign idma_req.opt.src_protocol       = req_src_protocol_i;
    assign idma_req.opt.dst_protocol       = req_dst_protocol_i;
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


% for protocol in used_read_protocols:
    // ${database[protocol]['full_name']} Read
${database[protocol]['synth_wrapper_assign_read']}


% endfor
% for protocol in used_write_protocols:
    // ${database[protocol]['full_name']} Write
${database[protocol]['synth_wrapper_assign_write']}


% endfor
endmodule

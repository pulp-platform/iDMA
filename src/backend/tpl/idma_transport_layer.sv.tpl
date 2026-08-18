// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "idma/guard.svh"
`include "common_cells/registers.svh"

/// Implementing the transport layer in the iDMA backend.
module idma_transport_layer_${name_uniqueifier} #(
    /// Number of transaction that can be in-flight concurrently
    parameter int unsigned NumAxInFlight = 32'd2,
    /// Data width
    parameter int unsigned DataWidth = 32'd16,
    /// The depth of the internal reorder buffer:
    /// - '2': minimal possible configuration
    /// - '3': efficiently handle misaligned transfers (recommended)
    parameter int unsigned BufferDepth = 32'd3,
    /// Mask invalid data on the manager interface
    parameter bit MaskInvalidData = 1'b1,
% if compute_eligible:
    /// Elaborate the optional on-the-fly compute engine
    parameter bit EnableCompute = 1'b0,
    /// Per-operation compute support mask
    parameter idma_pkg::compute_enable_t ComputeOps = '1,
    /// Implementation tuning knobs for the compute engines
    parameter idma_pkg::compute_tuning_t ComputeTuning = '1,
% endif
% if dual_operand_eligible:
    /// Write bursts that can be in flight; bounds the operand-only completion counter
    parameter int unsigned MetaFifoDepth = 32'd8,
% endif
    /// Print the info of the FIFO configuration
    parameter bit PrintFifoInfo = 1'b0,
    /// `r_dp_req_t` type:
    parameter type r_dp_req_t = logic,
    /// `w_dp_req_t` type:
    parameter type w_dp_req_t = logic,
    /// `r_dp_rsp_t` type:
    parameter type r_dp_rsp_t = logic,
    /// `w_dp_rsp_t` type:
    parameter type w_dp_rsp_t = logic,
    /// Write Meta channel type
    parameter type write_meta_channel_t = logic,
% if not one_write_port:
    parameter type write_meta_channel_tagged_t = logic,
% endif
    /// Read Meta channel type
    parameter type read_meta_channel_t = logic\
% if not one_read_port:
,
    parameter type read_meta_channel_tagged_t = logic\
% endif
% for protocol in used_protocols:
,
    /// ${database[protocol]['full_name']} Request and Response channel type
    % if database[protocol]['read_slave'] == 'true':
        % if (protocol in used_read_protocols) and (protocol in used_write_protocols):
    parameter type ${protocol}_read_req_t = logic,
    parameter type ${protocol}_read_rsp_t = logic,

    parameter type ${protocol}_write_req_t = logic,
    parameter type ${protocol}_write_rsp_t = logic\
        % elif protocol in used_read_protocols:
    parameter type ${protocol}_read_req_t = logic,
    parameter type ${protocol}_read_rsp_t = logic\
        % elif protocol in used_write_protocols:
    parameter type ${protocol}_write_req_t = logic,
    parameter type ${protocol}_write_rsp_t = logic\
        % endif
    % else:
    parameter type ${protocol}_req_t = logic,
    parameter type ${protocol}_rsp_t = logic\
    % endif
% endfor

)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,
% for protocol in used_read_protocols:

    /// ${database[protocol]['full_name']} read request
% if database[protocol]['passive_req'] == 'true':
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_req_t ${mh_format['ar'][protocol]}${protocol}_read_req_i,
% else:
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_req_t ${mh_format['ar'][protocol]}${protocol}_read_req_o,
% endif
    /// ${database[protocol]['full_name']} read response
% if database[protocol]['passive_req'] == 'true':
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_rsp_t ${mh_format['ar'][protocol]}${protocol}_read_rsp_o,
% else:
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_rsp_t ${mh_format['ar'][protocol]}${protocol}_read_rsp_i,
% endif
% endfor
% for protocol in used_write_protocols:

    /// ${database[protocol]['full_name']} write request
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_write\
% endif
_req_t ${mh_format['aw'][protocol]}${protocol}_write_req_o,
    /// ${database[protocol]['full_name']} write response
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_write\
% endif
_rsp_t ${mh_format['aw'][protocol]}${protocol}_write_rsp_i,
% endfor

    /// Read datapath request
    input  r_dp_req_t r_dp_req_i,
    /// Read datapath request valid
    input  logic r_dp_valid_i,
    /// Read datapath request ready
    output logic r_dp_ready_o,

    /// Read datapath response
    output r_dp_rsp_t r_dp_rsp_o,
    /// Read datapath response valid
    output logic r_dp_valid_o,
    /// Read datapath response valid
    input  logic r_dp_ready_i,

    /// Write datapath request
    input  w_dp_req_t w_dp_req_i,
    /// Write datapath request valid
    input  logic w_dp_valid_i,
    /// Write datapath request ready
    output logic w_dp_ready_o,

    /// Write datapath response
    output w_dp_rsp_t w_dp_rsp_o,
    /// Write datapath response valid
    output logic w_dp_valid_o,
    /// Write datapath response valid
    input  logic w_dp_ready_i,

    /// Read meta request
% if not one_read_port:
    input  read_meta_channel_tagged_t ar_req_i,
% else:
    input  read_meta_channel_t ar_req_i,
% endif
    /// Read meta request valid
    input  logic ar_valid_i,
    /// Read meta request ready
    output logic ar_ready_o,

    /// Write meta request
% if not one_write_port:
    input  write_meta_channel_tagged_t aw_req_i,
% else:
    input  write_meta_channel_t aw_req_i,
% endif
    /// Write meta request valid
    input  logic aw_valid_i,
    /// Write meta request ready
    output logic aw_ready_o,

    /// Datapath poison signal
    input  logic dp_poison_i,

    /// Write channel valid, ready and first
    output logic w_chan_valid_o,
    output logic w_chan_ready_o,
    output logic w_chan_first_o,

    /// Read part of the datapath is busy
    output logic r_dp_busy_o,
    /// Write part of the datapath is busy
    output logic w_dp_busy_o,
    /// Buffer is busy
    output logic buffer_busy_o
);

    /// Stobe width
    localparam int unsigned StrbWidth   = DataWidth / 8;

    /// Data type
    typedef logic [DataWidth-1:0] data_t;
    /// Offset type
    typedef logic [StrbWidth-1:0] strb_t;
    /// Byte type
    typedef logic [7:0] byte_t;

    // inbound control signals to the read buffer: controlled by the read process
% if not one_read_port:
    % for p in used_read_protocols:
    strb_t ${mh_format['ar'][p]}${p}_buffer_in_valid;
    % endfor
% endif
    strb_t buffer_in_valid;
    strb_t buffer_in_ready;

    // outbound control signals of the buffer: controlled by the write process
    strb_t buffer_out_valid;
    strb_t buffer_out_valid_shifted;
% if not one_write_port:
    % for p in used_write_protocols:
    strb_t ${mh_format['aw'][p]}${p}_buffer_out_ready;
    % endfor
% endif
    strb_t buffer_out_ready;
    strb_t buffer_out_ready_shifted;

    // shifted data flowing into the buffer
% if not one_read_port:
    % for p in used_read_protocols:
    byte_t ${mh_format['ar'][p]}[StrbWidth-1:0] ${p}_buffer_in;
    % endfor
% endif
    byte_t [StrbWidth-1:0] buffer_in;
    byte_t [StrbWidth-1:0] buffer_in_shifted;
    // Introduce this temporary signal to ease tool compatibility
    byte_t [2*StrbWidth-1:0] buffer_in_tmp;

    // aligned and coalesced data leaving the buffer
    byte_t [2*StrbWidth-1:0] buffer_out_tmp;
    byte_t [StrbWidth-1:0] buffer_out;
    byte_t [StrbWidth-1:0] buffer_out_shifted;
    byte_t [StrbWidth-1:0] wr_data;
    strb_t                 wr_valid, wr_strb, mask_ext_shifted, dataflow_ready_in;

% if not one_read_port:
    // Read multiplexed signals
    % for protocol in used_read_protocols:
    logic ${mh_format['ar'][protocol]}${protocol}_r_dp_valid;
    logic ${mh_format['ar'][protocol]}${protocol}_r_dp_ready;
    r_dp_rsp_t ${mh_format['ar'][protocol]}${protocol}_r_dp_rsp;
    logic ${mh_format['ar'][protocol]}${protocol}_ar_ready;

    % endfor
% endif
% if not one_write_port:
    // Write multiplexed signals
    % for protocol in used_write_protocols:
    logic ${mh_format['aw'][protocol]}${protocol}_w_chan_valid;
    logic ${mh_format['aw'][protocol]}${protocol}_w_chan_ready;
    logic ${mh_format['aw'][protocol]}${protocol}_w_chan_first;
    logic ${mh_format['aw'][protocol]}${protocol}_w_dp_rsp_valid;
    logic ${mh_format['aw'][protocol]}${protocol}_w_dp_rsp_ready;
    logic ${mh_format['aw'][protocol]}${protocol}_w_dp_ready;
    w_dp_rsp_t ${mh_format['aw'][protocol]}${protocol}_w_dp_rsp;
    logic ${mh_format['aw'][protocol]}${protocol}_aw_ready;

    %endfor
    logic w_dp_req_valid;
    logic w_dp_rsp_mux_valid, w_dp_rsp_mux_ready;
    logic w_dp_rsp_valid, w_dp_rsp_ready;
    w_dp_rsp_t w_dp_rsp_mux;

    // Write Response FIFO signals
    logic w_resp_fifo_in_valid, w_resp_fifo_in_ready;
    idma_pkg::protocol_e w_resp_fifo_out_protocol;
% if any_mh['aw']:
    idma_pkg::multihead_t w_resp_fifo_out_head;
% endif
    logic w_resp_fifo_out_valid, w_resp_fifo_out_ready;
% endif
    logic w_dp_req_ready;
% if one_write_port:
    assign w_dp_ready_o = w_dp_req_ready;
% endif
% if dual_operand_eligible:
<%
    drp = dual_read_protocol
    dmh = mh_format['ar'][drp]
%>
    /// Operand streams: 2 when the compute engine has the second (b) stream
    localparam int unsigned NumOperands = (EnableCompute && ComputeOps.dual) ? 32'd2 : 32'd1;

    // per-head read request handles (single-stream mux or per-head queues, see below)
    r_dp_req_t ${dmh}${drp}_r_dp_req_h;
    logic      ${dmh}${drp}_r_dp_valid_h;
    logic      ${dmh}${drp}_r_dp_rsp_ready_h;
    strb_t     ${dmh}${drp}_buffer_in_ready_h;
    logic      r_dp_queued;

    // second operand buffer output and the join with the first
    byte_t [StrbWidth-1:0] buffer_b_out;
    strb_t                 buffer_b_out_valid, buffer_b_ready;
    logic                  cmp_dual;

    // write port behind the operand-only bypass
    logic      w_port_dp_valid, w_port_dp_ready, w_port_rsp_valid, w_port_rsp_ready;
    w_dp_rsp_t w_port_dp_rsp;
% endif

    //--------------------------------------
    // Read Ports
    //--------------------------------------

% for read_port in used_read_protocols:
${rendered_read_ports[read_port]}

% endfor
% if dual_operand_eligible:
    //--------------------------------------
    // Read Multiplexers / Operand Streams
    //--------------------------------------

    always_comb begin : gen_read_meta_channel_multiplexer
        case(ar_req_i.src_protocol)
        idma_pkg::${database[drp]['protocol_enum']}: ar_ready_o = ${drp}_ar_ready [ar_req_i.src_head];
        default:       ar_ready_o = 1'b0;
        endcase
    end

    // request whose beats enter the first operand buffer (selects the read shift)
    r_dp_req_t buffer_in_req;

    if (NumOperands == 32'd2) begin : gen_operand_streams
        // per-head fall-through queues run both operands at once; a role sits on one head at a time
        logic [${dual_num_heads}-1:0] head_role_b, head_act_a, head_act_b, head_hold_a, head_hold_b;
        logic [${dual_num_heads}-1:0] head_sel, head_q_ready;
        strb_t                   buffer_b_in_valid, buffer_b_in_ready;
        byte_t [StrbWidth-1:0]   buffer_b_in, buffer_b_in_shifted;
        byte_t [2*StrbWidth-1:0] buffer_b_in_tmp;
        r_dp_req_t               buffer_b_in_req;

        for (genvar h = 0; h < ${dual_num_heads}; h++) begin : gen_head_queue
            logic [cc_pkg::cnt_width(2)-1:0] head_q_usage;
            assign head_role_b[h] = ${drp}_r_dp_req_h[h].operand_b;
            assign head_act_a[h]  = ${drp}_r_dp_valid_h[h] & ~head_role_b[h];
            assign head_act_b[h]  = ${drp}_r_dp_valid_h[h] &  head_role_b[h];
            assign head_hold_a[h] = (head_q_usage != '0) & ~head_role_b[h];
            assign head_hold_b[h] = (head_q_usage != '0) &  head_role_b[h];
            assign head_sel[h]    = r_dp_valid_i &
                (r_dp_req_i.src_protocol == idma_pkg::${database[drp]['protocol_enum']}) &
                (r_dp_req_i.src_head == h) &
                ~|((r_dp_req_i.operand_b ? head_hold_b : head_hold_a) &
                   ~(${dual_num_heads}'d1 << h));

            cc_stream_fifo #(
                .FallThrough ( 1'b1       ),
                .Depth       ( 32'd2      ),
                .data_t      ( r_dp_req_t )
            ) i_head_queue (
                .clk_i,
                .rst_ni,
                .clr_i   ( 1'b0                    ),
                .flush_i ( 1'b0                    ),
                .usage_o ( head_q_usage            ),
                .data_i  ( r_dp_req_i              ),
                .valid_i ( head_sel[h]             ),
                .ready_o ( head_q_ready[h]         ),
                .data_o  ( ${drp}_r_dp_req_h[h]    ),
                .valid_o ( ${drp}_r_dp_valid_h[h]  ),
                .ready_i ( ${drp}_r_dp_ready[h]    )
            );

            assign ${drp}_r_dp_rsp_ready_h[h] = r_dp_ready_i;
            assign ${drp}_buffer_in_ready_h[h] = head_role_b[h] ? buffer_b_in_ready
                                                                : buffer_in_ready;
        end

        assign r_dp_ready_o = |(head_sel & head_q_ready);
        assign r_dp_queued  = |${drp}_r_dp_valid_h;

        // read responses are only consumed by the error handler, which compute excludes
        always_comb begin : gen_read_response_multiplexer
            r_dp_valid_o = 1'b0;
            r_dp_rsp_o   = '0;
            for (int unsigned h = 0; h < ${dual_num_heads}; h++) begin
                if (${drp}_r_dp_valid[h]) begin
                    r_dp_valid_o = 1'b1;
                    r_dp_rsp_o   = ${drp}_r_dp_rsp[h];
                end
            end
        end

        // the a-role head feeds the first buffer, the b-role head the second
        always_comb begin : gen_operand_multiplexer
            buffer_in         = '0;
            buffer_in_valid   = '0;
            buffer_in_req     = '0;
            buffer_b_in       = '0;
            buffer_b_in_valid = '0;
            buffer_b_in_req   = '0;
            for (int unsigned h = 0; h < ${dual_num_heads}; h++) begin
                if (head_act_a[h]) begin
                    buffer_in       = ${drp}_buffer_in[h];
                    buffer_in_valid = ${drp}_buffer_in_valid[h];
                    buffer_in_req   = ${drp}_r_dp_req_h[h];
                end
                if (head_act_b[h]) begin
                    buffer_b_in       = ${drp}_buffer_in[h];
                    buffer_b_in_valid = ${drp}_buffer_in_valid[h];
                    buffer_b_in_req   = ${drp}_r_dp_req_h[h];
                end
            end
        end

        assign buffer_b_in_tmp     = {buffer_b_in, buffer_b_in} >> (buffer_b_in_req.shift * 8);
        assign buffer_b_in_shifted = buffer_b_in_tmp[$bits(buffer_b_in_shifted)/8-1:0];

        idma_dataflow_element #(
            .BufferDepth   ( BufferDepth   ),
            .StrbWidth     ( StrbWidth     ),
            .PrintFifoInfo ( PrintFifoInfo ),
            .strb_t        ( strb_t        ),
            .byte_t        ( byte_t        )
        ) i_dataflow_element_b (
            .clk_i       ( clk_i               ),
            .rst_ni      ( rst_ni              ),
            .data_i      ( buffer_b_in_shifted ),
            .valid_i     ( buffer_b_in_valid   ),
            .ready_o     ( buffer_b_in_ready   ),
            .data_o      ( buffer_b_out        ),
            .valid_o     ( buffer_b_out_valid  ),
            .ready_i     ( buffer_b_ready      )
        );

        assign cmp_dual = idma_pkg::compute_operands(w_dp_req_i.compute) == 32'd2;
    end else begin : gen_read_multiplexer
        for (genvar h = 0; h < ${dual_num_heads}; h++) begin : gen_head_handle
            assign ${drp}_r_dp_req_h[h]       = r_dp_req_i;
            assign ${drp}_r_dp_valid_h[h]     =
                (r_dp_req_i.src_protocol == idma_pkg::${database[drp]['protocol_enum']}) &
                (r_dp_req_i.src_head == h) & r_dp_valid_i;
            assign ${drp}_r_dp_rsp_ready_h[h] =
                (r_dp_req_i.src_protocol == idma_pkg::${database[drp]['protocol_enum']}) &
                (r_dp_req_i.src_head == h) & r_dp_ready_i;
            assign ${drp}_buffer_in_ready_h[h] = buffer_in_ready;
        end
        assign r_dp_queued       = 1'b0;
        assign buffer_in_req     = r_dp_req_i;
        assign buffer_b_out      = '0;
        assign buffer_b_out_valid = '0;
        assign cmp_dual          = 1'b0;

        always_comb begin
            if (r_dp_valid_i) begin
                case(r_dp_req_i.src_protocol)
                idma_pkg::${database[drp]['protocol_enum']}: begin
                    r_dp_ready_o    = ${drp}_r_dp_ready [r_dp_req_i.src_head];
                    r_dp_rsp_o      = ${drp}_r_dp_rsp [r_dp_req_i.src_head];
                    r_dp_valid_o    = ${drp}_r_dp_valid [r_dp_req_i.src_head];

                    buffer_in       = ${drp}_buffer_in [r_dp_req_i.src_head];
                    buffer_in_valid = ${drp}_buffer_in_valid [r_dp_req_i.src_head];
                end
                default: begin
                    r_dp_ready_o    = 1'b0;
                    r_dp_rsp_o      = '0;
                    r_dp_valid_o    = 1'b0;

                    buffer_in       = '0;
                    buffer_in_valid = '0;
                end
                endcase
            end else begin
                r_dp_ready_o    = 1'b0;
                r_dp_rsp_o      = '0;
                r_dp_valid_o    = 1'b0;

                buffer_in       = '0;
                buffer_in_valid = '0;
            end
        end
    end

% elif not one_read_port:
    //--------------------------------------
    // Read Multiplexers
    //--------------------------------------

    always_comb begin : gen_read_meta_channel_multiplexer
        case(ar_req_i.src_protocol)
% for rp in used_read_protocols:
    % if mh_format['ar'][rp] == '':
        idma_pkg::${database[rp]['protocol_enum']}: ar_ready_o = ${rp}_ar_ready;
    % else:
        idma_pkg::${database[rp]['protocol_enum']}: ar_ready_o = ${rp}_ar_ready [ar_req_i.src_head];
    % endif
% endfor
        default:       ar_ready_o = 1'b0;
        endcase
    end

    always_comb begin : gen_read_multiplexer
        if (r_dp_valid_i) begin
            case(r_dp_req_i.src_protocol)
% for rp in used_read_protocols:
    % if mh_format['ar'][rp] == '':
            idma_pkg::${database[rp]['protocol_enum']}: begin
                r_dp_ready_o    = ${rp}_r_dp_ready;
                r_dp_rsp_o      = ${rp}_r_dp_rsp;
                r_dp_valid_o    = ${rp}_r_dp_valid;

                buffer_in       = ${rp}_buffer_in;
                buffer_in_valid = ${rp}_buffer_in_valid;
            end
    % else:
            idma_pkg::${database[rp]['protocol_enum']}: begin
                r_dp_ready_o    = ${rp}_r_dp_ready [r_dp_req_i.src_head];
                r_dp_rsp_o      = ${rp}_r_dp_rsp [r_dp_req_i.src_head];
                r_dp_valid_o    = ${rp}_r_dp_valid [r_dp_req_i.src_head];

                buffer_in       = ${rp}_buffer_in [r_dp_req_i.src_head];
                buffer_in_valid = ${rp}_buffer_in_valid [r_dp_req_i.src_head];
            end
    % endif
% endfor
            default: begin
                r_dp_ready_o    = 1'b0;
                r_dp_rsp_o      = '0;
                r_dp_valid_o    = 1'b0;

                buffer_in       = '0;
                buffer_in_valid = '0;
            end
            endcase
        end else begin
            r_dp_ready_o    = 1'b0;
            r_dp_rsp_o      = '0;
            r_dp_valid_o    = 1'b0;

            buffer_in       = '0;
            buffer_in_valid = '0;
        end
    end

% endif
    //--------------------------------------
    // Read Barrel shifter
    //--------------------------------------

% if dual_operand_eligible:
    assign buffer_in_tmp = {buffer_in, buffer_in} >> (buffer_in_req.shift * 8);
% else:
    assign buffer_in_tmp = {buffer_in, buffer_in} >> (r_dp_req_i.shift * 8);
% endif
    assign buffer_in_shifted = buffer_in_tmp[$bits(buffer_in_shifted)/8-1:0];

    //--------------------------------------
    // Buffer
    //--------------------------------------

    idma_dataflow_element #(
        .BufferDepth   ( BufferDepth   ),
        .StrbWidth     ( StrbWidth     ),
        .PrintFifoInfo ( PrintFifoInfo ),
        .strb_t        ( strb_t        ),
        .byte_t        ( byte_t        )
    ) i_dataflow_element (
        .clk_i       ( clk_i                    ),
        .rst_ni      ( rst_ni                   ),
        .data_i      ( buffer_in_shifted        ),
        .valid_i     ( buffer_in_valid          ),
        .ready_o     ( buffer_in_ready          ),
        .data_o      ( buffer_out               ),
        .valid_o     ( buffer_out_valid         ),
        .ready_i     ( dataflow_ready_in        )
    );

    //--------------------------------------
    // On-the-fly compute
    //--------------------------------------

% if dual_operand_eligible:
    if (EnableCompute) begin : gen_compute
        logic                  cmp_active;
        byte_t [StrbWidth-1:0] cmp_data_o;
        strb_t                 cmp_strb_o, cmp_lane_valid, cmp_lane_ready, cmp_lane_valid_i;
        byte_t [NumOperands*StrbWidth-1:0] cmp_data_i;

        if (NumOperands == 32'd2) begin : gen_two_operands
            assign cmp_data_i = {buffer_b_out, buffer_out};
        end else begin : gen_one_operand
            assign cmp_data_i = buffer_out;
        end

        idma_otf_compute #(
            .StrbWidth           ( StrbWidth          ),
            .ComputeEnable       ( ComputeOps         ),
            .ComputeTuning       ( ComputeTuning      ),
            .NumOperands         ( NumOperands        )
        ) i_idma_otf_compute (
            .clk_i,
            .rst_ni,
            .compute_i   ( w_dp_req_i.compute ),
            .cfg_valid_i ( w_dp_valid_i        ),
            .active_o    ( cmp_active          ),
            .data_i       ( cmp_data_i          ),
            .lane_valid_i ( cmp_lane_valid_i    ),
            .lane_ready_o ( cmp_lane_ready      ),
            .data_o       ( cmp_data_o          ),
            .strb_o       ( cmp_strb_o          ),
            .lane_valid_o ( cmp_lane_valid      ),
            .ready_i      ( w_dp_req_ready      ),
            .lane_ready_i ( buffer_out_ready_shifted )
        );

        // join: a two-operand op sees a lane once both buffers hold it and pops both
        assign cmp_lane_valid_i  = cmp_dual ? buffer_out_valid & buffer_b_out_valid
                                            : buffer_out_valid;
        assign wr_data           = cmp_active ? cmp_data_o : buffer_out;
        assign wr_valid          = cmp_active ? cmp_lane_valid : buffer_out_valid;
        assign wr_strb           = cmp_active ? cmp_strb_o : '1;
        assign dataflow_ready_in = cmp_active ? (cmp_dual ? cmp_lane_ready & buffer_b_out_valid
                                                          : cmp_lane_ready)
                                              : buffer_out_ready_shifted;
        assign buffer_b_ready    = (cmp_active & cmp_dual) ? cmp_lane_ready & buffer_out_valid : '0;
    end else begin : gen_no_compute
        assign wr_data           = buffer_out;
        assign wr_valid          = buffer_out_valid;
        assign wr_strb           = '1;
        assign dataflow_ready_in = buffer_out_ready_shifted;
        assign buffer_b_ready    = '0;
    end
% elif compute_eligible:
    if (EnableCompute) begin : gen_compute
        logic                  cmp_active;
        byte_t [StrbWidth-1:0] cmp_data_o;
        strb_t                 cmp_strb_o, cmp_lane_valid, cmp_lane_ready;

        idma_otf_compute #(
            .StrbWidth           ( StrbWidth          ),
            .ComputeEnable       ( ComputeOps         ),
            .ComputeTuning       ( ComputeTuning      )
        ) i_idma_otf_compute (
            .clk_i,
            .rst_ni,
            .compute_i   ( w_dp_req_i.compute ),
            .cfg_valid_i ( w_dp_valid_i        ),
            .active_o    ( cmp_active          ),
            .data_i       ( buffer_out          ),
            .lane_valid_i ( buffer_out_valid    ),
            .lane_ready_o ( cmp_lane_ready      ),
            .data_o       ( cmp_data_o          ),
            .strb_o       ( cmp_strb_o          ),
            .lane_valid_o ( cmp_lane_valid      ),
            .ready_i      ( w_dp_req_ready      ),
            .lane_ready_i ( buffer_out_ready_shifted )
        );

        assign wr_data           = cmp_active ? cmp_data_o : buffer_out;
        assign wr_valid          = cmp_active ? cmp_lane_valid : buffer_out_valid;
        assign wr_strb           = cmp_active ? cmp_strb_o : '1;
        assign dataflow_ready_in = cmp_active ? cmp_lane_ready : buffer_out_ready_shifted;
    end else begin : gen_no_compute
        assign wr_data           = buffer_out;
        assign wr_valid          = buffer_out_valid;
        assign wr_strb           = '1;
        assign dataflow_ready_in = buffer_out_ready_shifted;
    end
% else:
    assign wr_data           = buffer_out;
    assign wr_valid          = buffer_out_valid;
    assign wr_strb           = '1;
    assign dataflow_ready_in = buffer_out_ready_shifted;
% endif

    //--------------------------------------
    // Write Barrel shifter
    //--------------------------------------

    assign buffer_out_tmp           = {wr_data, wr_data} >> (w_dp_req_i.shift*8);
    assign buffer_out_shifted       = buffer_out_tmp[$bits(buffer_out_shifted)/8-1:0];
    assign buffer_out_valid_shifted = strb_t'({wr_valid, wr_valid} >>   w_dp_req_i.shift);
    assign mask_ext_shifted         = strb_t'({wr_strb, wr_strb} >>   w_dp_req_i.shift);
    assign buffer_out_ready_shifted = strb_t'({buffer_out_ready, buffer_out_ready} >> - w_dp_req_i.shift);

% if not one_write_port:
    //--------------------------------------
    // Write Request Demultiplexer
    //--------------------------------------

    // Split write request to write response fifo and write ports
    cc_stream_fork #(
        .NumOup ( 2 )
    ) i_write_stream_fork (
        .clk_i   ( clk_i                                    ),
        .rst_ni  ( rst_ni                                   ),
        .clr_i   ( 1'b0                                     ),
        .valid_i ( w_dp_valid_i                             ),
        .ready_o ( w_dp_ready_o                             ),
        .valid_o ( { w_resp_fifo_in_valid, w_dp_req_valid } ),
        .ready_i ( { w_resp_fifo_in_ready, w_dp_req_ready } )
    );

    // Demux write request to correct write port
    always_comb begin : gen_write_multiplexer
        case(w_dp_req_i.dst_protocol)
% for wp in used_write_protocols:
        idma_pkg::${database[wp]['protocol_enum']}: begin
    % if mh_format['aw'][wp] == '':
            w_dp_req_ready   = ${wp}_w_dp_ready;
            buffer_out_ready = ${wp}_buffer_out_ready;
            w_chan_valid_o   = ${wp}_w_chan_valid;
            w_chan_ready_o   = ${wp}_w_chan_ready;
            w_chan_first_o   = ${wp}_w_chan_first;
    % else:
            w_dp_req_ready   = ${wp}_w_dp_ready [w_dp_req_i.dst_head];
            buffer_out_ready = ${wp}_buffer_out_ready [w_dp_req_i.dst_head];
            w_chan_valid_o   = ${wp}_w_chan_valid [w_dp_req_i.dst_head];
            w_chan_ready_o   = ${wp}_w_chan_ready [w_dp_req_i.dst_head];
            w_chan_first_o   = ${wp}_w_chan_first [w_dp_req_i.dst_head];
    % endif
        end
% endfor
        default: begin
            w_dp_req_ready   = 1'b0;
            buffer_out_ready = '0;
            w_chan_valid_o   = 1'b0;
            w_chan_ready_o   = 1'b0;
            w_chan_first_o   = 1'b0;
        end
        endcase
    end

    // Demux write meta channel to correct write port
    always_comb begin : gen_write_meta_channel_multiplexer
        case(aw_req_i.dst_protocol)
% for wp in used_write_protocols:
    % if mh_format['aw'][wp] == '':
        idma_pkg::${database[wp]['protocol_enum']}: aw_ready_o = ${wp}_aw_ready;
    % else:
        idma_pkg::${database[wp]['protocol_enum']}: aw_ready_o = ${wp}_aw_ready [aw_req_i.dst_head];
    % endif
% endfor
        default:       aw_ready_o = 1'b0;
        endcase
    end

% endif
% if dual_operand_eligible:
    //--------------------------------------
    // Operand-only write bypass
    //--------------------------------------

    if (NumOperands == 32'd2) begin : gen_operand_only_write
        // an operand-only burst writes nothing; its response follows every pending B
        logic [cc_pkg::cnt_width(MetaFifoDepth)-1:0] b_pending_d, b_pending_q;
        logic ghost, ghost_fire;

        assign ghost      = w_dp_valid_i & w_dp_req_i.operand_only;
        assign ghost_fire = ghost & (b_pending_q == '0);

        assign w_port_dp_valid  = w_dp_valid_i & ~ghost;
        assign w_dp_req_ready   = ghost ? ghost_fire & w_dp_ready_i : w_port_dp_ready;
        assign w_dp_valid_o     = ghost_fire | w_port_rsp_valid;
        assign w_dp_rsp_o       = ghost_fire ? '0 : w_port_dp_rsp;
        assign w_port_rsp_ready = w_dp_ready_i & ~ghost_fire;

        always_comb begin
            b_pending_d = b_pending_q;
            if (w_port_dp_valid & w_port_dp_ready)   b_pending_d = b_pending_d + 1'b1;
            if (w_port_rsp_valid & w_port_rsp_ready) b_pending_d = b_pending_d - 1'b1;
        end
        `FF(b_pending_q, b_pending_d, '0, clk_i, rst_ni)
    end else begin : gen_no_operand_only_write
        assign w_port_dp_valid  = w_dp_valid_i;
        assign w_dp_req_ready   = w_port_dp_ready;
        assign w_dp_valid_o     = w_port_rsp_valid;
        assign w_dp_rsp_o       = w_port_dp_rsp;
        assign w_port_rsp_ready = w_dp_ready_i;
    end

% endif
    //--------------------------------------
    // Write Ports
    //--------------------------------------

% for write_port in used_write_protocols:
${rendered_write_ports[write_port]}

% endfor
%if not one_write_port:
    //--------------------------------------
    // Write Response FIFO
    //--------------------------------------
    // Needed to be able to route the write responses properly
    // Insert when data write happens
    // Remove when write response comes

    cc_stream_fifo_optimal_wrap #(
        .Depth        ( NumAxInFlight        ),
        .data_t       ( idma_pkg::protocol_e ),
        .PrintInfo    ( PrintFifoInfo        )
    ) i_write_response_fifo (
        .clk_i      ( clk_i                                          ),
        .rst_ni     ( rst_ni                                         ),
        .clr_i      ( 1'b0                                           ),
        .flush_i    ( 1'b0                                           ),
        .usage_o    ( /* NOT CONNECTED */                            ),
        .data_i     ( w_dp_req_i.dst_protocol                        ),
        .valid_i    ( w_resp_fifo_in_valid && w_resp_fifo_in_ready   ),
        .ready_o    ( w_resp_fifo_in_ready                           ),
        .data_o     ( w_resp_fifo_out_protocol                       ),
        .valid_o    ( w_resp_fifo_out_valid                          ),
        .ready_i    ( w_resp_fifo_out_ready && w_resp_fifo_out_valid )
    );

% if not mh_format['aw'][wp] == '':
    cc_stream_fifo_optimal_wrap #(
        .Depth        ( NumAxInFlight         ),
        .data_t       ( idma_pkg::multihead_t ),
        .PrintInfo    ( PrintFifoInfo         )
    ) i_write_response_fifo_multihead (
        .clk_i      ( clk_i                                          ),
        .rst_ni     ( rst_ni                                         ),
        .clr_i      ( 1'b0                                           ),
        .flush_i    ( 1'b0                                           ),
        .usage_o    ( /* NOT CONNECTED */                            ),
        .data_i     ( w_dp_req_i.dst_head                            ),
        .valid_i    ( w_resp_fifo_in_valid && w_resp_fifo_in_ready   ),
        .ready_o    ( /* NOT CONNECTED */                            ),
        .data_o     ( w_resp_fifo_out_head                      ),
        .valid_o    ( /* NOT CONNECTED */                            ),
        .ready_i    ( w_resp_fifo_out_ready && w_resp_fifo_out_valid )
    );

% endif
    //--------------------------------------
    // Write Request Demultiplexer
    //--------------------------------------

    // Mux write port responses
    always_comb begin : gen_write_reponse_multiplexer
        w_dp_rsp_mux       = '0;
        w_dp_rsp_mux_valid = 1'b0;
% for wp in used_write_protocols:
    % if mh_format['aw'][wp] == '':
        ${wp}_w_dp_rsp_ready = 1'b0;
    % else:
        ${wp}_w_dp_rsp_ready = '0;
    % endif
% endfor
        if ( w_resp_fifo_out_valid ) begin
            case(w_resp_fifo_out_protocol)
% for wp in used_write_protocols:
            idma_pkg::${database[wp]['protocol_enum']}: begin
    % if mh_format['aw'][wp] == '':
                w_dp_rsp_mux_valid = ${wp}_w_dp_rsp_valid;
                w_dp_rsp_mux       = ${wp}_w_dp_rsp;
                ${wp}_w_dp_rsp_ready = w_dp_rsp_mux_ready;
    % else:
                w_dp_rsp_mux_valid = ${wp}_w_dp_rsp_valid [w_resp_fifo_out_head];
                w_dp_rsp_mux       = ${wp}_w_dp_rsp [w_resp_fifo_out_head];
                ${wp}_w_dp_rsp_ready [w_resp_fifo_out_head] = w_dp_rsp_mux_ready;
    % endif
            end
% endfor
            default: begin
                w_dp_rsp_mux_valid = 1'b0;
                w_dp_rsp_mux       = '0;
            end
            endcase
        end
    end

    // Fall through register for the write response to be ready
    cc_fall_through_register #(
        .data_t ( w_dp_rsp_t )
    ) i_write_rsp_channel_reg (
        .clk_i      ( clk_i      ),
        .rst_ni     ( rst_ni     ),
        .clr_i      ( 1'b0       ),

        .valid_i ( w_dp_rsp_mux_valid ),
        .ready_o ( w_dp_rsp_mux_ready ),
        .data_i  ( w_dp_rsp_mux       ),

        .valid_o ( w_dp_rsp_valid ),
        .ready_i ( w_dp_rsp_ready ),
        .data_o  ( w_dp_rsp_o     )
    );

    // Join write response fifo and write port responses
    cc_stream_join #(
        .NumInp ( 2 )
    ) i_write_stream_join (
        .inp_valid_i ( { w_resp_fifo_out_valid, w_dp_rsp_valid } ),
        .inp_ready_o ( { w_resp_fifo_out_ready, w_dp_rsp_ready } ),

        .oup_valid_o ( w_dp_valid_o ),
        .oup_ready_i ( w_dp_ready_i )
    );

% endif
    //--------------------------------------
    // Module Control
    //--------------------------------------
% if dual_operand_eligible:
    assign r_dp_busy_o   = r_dp_valid_i | r_dp_queued;
    assign w_dp_busy_o   = w_dp_valid_i | w_dp_ready_o;
    assign buffer_busy_o = |buffer_out_valid | |buffer_b_out_valid;
% else:
    assign r_dp_busy_o   = r_dp_valid_i;
    assign w_dp_busy_o   = w_dp_valid_i | w_dp_ready_o;
    assign buffer_busy_o = |buffer_out_valid;
% endif

endmodule

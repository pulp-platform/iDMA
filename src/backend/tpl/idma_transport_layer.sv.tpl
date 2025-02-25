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
    /// Testmode in
    input  logic testmode_i,
% for protocol in used_read_protocols:

    /// ${database[protocol]['full_name']} read request
% if database[protocol]['passive_req'] == 'true':
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_req_t ${protocol}_read_req_i,
% else:
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_req_t ${protocol}_read_req_o,
% endif
    /// ${database[protocol]['full_name']} read response
% if database[protocol]['passive_req'] == 'true':
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_rsp_t ${protocol}_read_rsp_o,
% else:
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_rsp_t ${protocol}_read_rsp_i,
% endif
% endfor
% for protocol in used_write_protocols:

    /// ${database[protocol]['full_name']} write request
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_write\
% endif
_req_t ${protocol}_write_req_o,
    /// ${database[protocol]['full_name']} write response
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_write\
% endif
_rsp_t ${protocol}_write_rsp_i,
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

    /// Response channel valid and ready
    output logic r_chan_ready_o,
    output logic r_chan_valid_o,

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
    strb_t\
% if not one_read_port:
    % for p in used_read_protocols:
 ${p}_buffer_in_valid,\
    % endfor
% endif
 buffer_in_valid;

    strb_t buffer_in_ready;
    // outbound control signals of the buffer: controlled by the write process
    strb_t buffer_out_valid, buffer_out_valid_shifted;
    strb_t\
% if not one_write_port:
    % for p in used_write_protocols:
 ${p}_buffer_out_ready,\
    % endfor
% endif

        buffer_out_ready, buffer_out_ready_shifted;

    // shifted data flowing into the buffer
    byte_t [StrbWidth-1:0]\
% if not one_read_port:
    % for p in used_read_protocols:
 ${p}_buffer_in,\
    % endfor
% endif

        buffer_in, buffer_in_shifted;
    // aligned and coalesced data leaving the buffer
    byte_t [StrbWidth-1:0] buffer_out, buffer_out_shifted;
% if not one_read_port:

    // Read multiplexed signals
    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_chan_valid\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_chan_ready\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_dp_valid\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_dp_ready\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    r_dp_rsp_t\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_r_dp_rsp\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor

    logic\
    % for index, protocol in enumerate(used_read_protocols):
 ${protocol}_ar_ready\
        % if index == len(used_read_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
% endif
% if not one_write_port:

    // Write multiplexed signals
    logic\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_w_dp_rsp_valid\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_w_dp_rsp_ready\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    logic\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_w_dp_ready\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
    w_dp_rsp_t\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_w_dp_rsp\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor

    logic\
    % for index, protocol in enumerate(used_write_protocols):
 ${protocol}_aw_ready\
        % if index == len(used_write_protocols)-1:
;
        % else:
,\
        % endif
    %endfor
% endif
% if not one_write_port:
    logic w_dp_req_valid, w_dp_req_ready;
    logic w_dp_rsp_mux_valid, w_dp_rsp_mux_ready;
    logic w_dp_rsp_valid, w_dp_rsp_ready;
    w_dp_rsp_t w_dp_rsp_mux;

    // Write Response FIFO signals
    logic w_resp_fifo_in_valid, w_resp_fifo_in_ready;
    idma_pkg::protocol_e w_resp_fifo_out_protocol;
    logic w_resp_fifo_out_valid, w_resp_fifo_out_ready;
% endif

    //--------------------------------------
    // Read Ports
    //--------------------------------------

% for read_port in used_read_protocols:
${rendered_read_ports[read_port]}

% endfor
% if not one_read_port:
    //--------------------------------------
    // Read Multiplexers
    //--------------------------------------

    always_comb begin : gen_read_meta_channel_multiplexer
        case(ar_req_i.src_protocol)
% for rp in used_read_protocols:
        idma_pkg::${database[rp]['protocol_enum']}: ar_ready_o = ${rp}_ar_ready;
% endfor
        default:       ar_ready_o = 1'b0;
        endcase
    end

    always_comb begin : gen_read_multiplexer
        if (r_dp_valid_i) begin
            case(r_dp_req_i.src_protocol)
% for rp in used_read_protocols:
            idma_pkg::${database[rp]['protocol_enum']}: begin
                r_chan_valid_o  = ${rp}_r_chan_valid;
                r_chan_ready_o  = ${rp}_r_chan_ready;

                r_dp_ready_o    = ${rp}_r_dp_ready;
                r_dp_rsp_o      = ${rp}_r_dp_rsp;
                r_dp_valid_o    = ${rp}_r_dp_valid;

                buffer_in       = ${rp}_buffer_in;
                buffer_in_valid = ${rp}_buffer_in_valid;
            end
% endfor
            default: begin
                r_chan_valid_o  = 1'b0;
                r_chan_ready_o  = 1'b0;

                r_dp_ready_o    = 1'b0;
                r_dp_rsp_o      = '0;
                r_dp_valid_o    = 1'b0;

                buffer_in       = '0;
                buffer_in_valid = '0;
            end
            endcase
        end else begin
            r_chan_valid_o  = 1'b0;
            r_chan_ready_o  = 1'b0;

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

    assign buffer_in_shifted = {buffer_in, buffer_in} >> (r_dp_req_i.shift * 8);

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
        .testmode_i  ( testmode_i               ),
        .data_i      ( buffer_in_shifted        ),
        .valid_i     ( buffer_in_valid          ),
        .ready_o     ( buffer_in_ready          ),
        .data_o      ( buffer_out               ),
        .valid_o     ( buffer_out_valid         ),
        .ready_i     ( buffer_out_ready_shifted )
    );

    //--------------------------------------
    // Write Barrel shifter
    //--------------------------------------

    assign buffer_out_shifted       = {buffer_out, buffer_out}             >>  (w_dp_req_i.shift*8);
    assign buffer_out_valid_shifted = {buffer_out_valid, buffer_out_valid} >>   w_dp_req_i.shift;
    assign buffer_out_ready_shifted = {buffer_out_ready, buffer_out_ready} >> - w_dp_req_i.shift;

% if not one_write_port:
    //--------------------------------------
    // Write Request Demultiplexer
    //--------------------------------------

    // Split write request to write response fifo and write ports
    stream_fork #(
        .N_OUP ( 2 )
    ) i_write_stream_fork (
        .clk_i   ( clk_i                                    ),
        .rst_ni  ( rst_ni                                   ),
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
            w_dp_req_ready   = ${wp}_w_dp_ready;
            buffer_out_ready = ${wp}_buffer_out_ready;
        end
% endfor
        default: begin
            w_dp_req_ready   = 1'b0;
            buffer_out_ready = '0;
        end
        endcase
    end

    // Demux write meta channel to correct write port
    always_comb begin : gen_write_meta_channel_multiplexer
        case(aw_req_i.dst_protocol)
% for wp in used_write_protocols:
        idma_pkg::${database[wp]['protocol_enum']}: aw_ready_o = ${wp}_aw_ready;
% endfor
        default:       aw_ready_o = 1'b0;
        endcase
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
    // Needed to be able to route the write reponses properly
    // Insert when data write happens
    // Remove when write response comes

    stream_fifo_optimal_wrap #(
        .Depth        ( NumAxInFlight        ),
        .type_t       ( idma_pkg::protocol_e ),
        .PrintInfo    ( PrintFifoInfo        )
    ) i_write_response_fifo (
        .clk_i      ( clk_i                                          ),
        .rst_ni     ( rst_ni                                         ),
        .testmode_i ( testmode_i                                     ),
        .flush_i    ( 1'b0                                           ),
        .usage_o    ( /* NOT CONNECTED */                            ),
        .data_i     ( w_dp_req_i.dst_protocol                        ),
        .valid_i    ( w_resp_fifo_in_valid && w_resp_fifo_in_ready   ),
        .ready_o    ( w_resp_fifo_in_ready                           ),
        .data_o     ( w_resp_fifo_out_protocol                       ),
        .valid_o    ( w_resp_fifo_out_valid                          ),
        .ready_i    ( w_resp_fifo_out_ready && w_resp_fifo_out_valid )
    );

    //--------------------------------------
    // Write Request Demultiplexer
    //--------------------------------------

    // Mux write port responses
    always_comb begin : gen_write_reponse_multiplexer
        w_dp_rsp_mux       = '0;
        w_dp_rsp_mux_valid = 1'b0;
% for wp in used_write_protocols:
        ${wp}_w_dp_rsp_ready = 1'b0;
% endfor
        if ( w_resp_fifo_out_valid ) begin
            case(w_resp_fifo_out_protocol)
% for wp in used_write_protocols:
            idma_pkg::${database[wp]['protocol_enum']}: begin
                w_dp_rsp_mux_valid = ${wp}_w_dp_rsp_valid;
                w_dp_rsp_mux       = ${wp}_w_dp_rsp;
                ${wp}_w_dp_rsp_ready = w_dp_rsp_mux_ready;
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
    fall_through_register #(
        .T ( w_dp_rsp_t )
    ) i_write_rsp_channel_reg (
        .clk_i      ( clk_i      ),
        .rst_ni     ( rst_ni     ),
        .clr_i      ( 1'b0       ),
        .testmode_i ( testmode_i ),

        .valid_i ( w_dp_rsp_mux_valid ),
        .ready_o ( w_dp_rsp_mux_ready ),
        .data_i  ( w_dp_rsp_mux       ),

        .valid_o ( w_dp_rsp_valid ),
        .ready_i ( w_dp_rsp_ready ),
        .data_o  ( w_dp_rsp_o     )
    );

    // Join write response fifo and write port responses
    stream_join #(
        .N_INP ( 2 )
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
    assign r_dp_busy_o   = r_dp_valid_i;
    assign w_dp_busy_o   = w_dp_valid_i | w_dp_ready_o;
    assign buffer_busy_o = |buffer_out_valid;

endmodule

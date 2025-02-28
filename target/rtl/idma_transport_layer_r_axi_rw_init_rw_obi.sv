// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "idma/guard.svh"
`include "common_cells/registers.svh"

/// Implementing the transport layer in the iDMA backend.
module idma_transport_layer_r_axi_rw_init_rw_obi #(
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
    parameter type write_meta_channel_tagged_t = logic,
    /// Read Meta channel type
    parameter type read_meta_channel_t = logic,
    parameter type read_meta_channel_tagged_t = logic,
    /// AXI4+ATOP Request and Response channel type
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic,
    /// Memory Init Request and Response channel type
    parameter type init_req_t = logic,
    parameter type init_rsp_t = logic,
    /// OBI Request and Response channel type
    parameter type obi_req_t = logic,
    parameter type obi_rsp_t = logic
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,
    /// Testmode in
    input  logic testmode_i,

    /// AXI4+ATOP read request
    output axi_req_t axi_read_req_o,
    /// AXI4+ATOP read response
    input  axi_rsp_t axi_read_rsp_i,

    /// Memory Init read request
    output init_req_t init_read_req_o,
    /// Memory Init read response
    input  init_rsp_t init_read_rsp_i,

    /// OBI read request
    output obi_req_t obi_read_req_o,
    /// OBI read response
    input  obi_rsp_t obi_read_rsp_i,

    /// Memory Init write request
    output init_req_t init_write_req_o,
    /// Memory Init write response
    input  init_rsp_t init_write_rsp_i,

    /// OBI write request
    output obi_req_t obi_write_req_o,
    /// OBI write response
    input  obi_rsp_t obi_write_rsp_i,

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
    input  read_meta_channel_tagged_t ar_req_i,
    /// Read meta request valid
    input  logic ar_valid_i,
    /// Read meta request ready
    output logic ar_ready_o,

    /// Write meta request
    input  write_meta_channel_tagged_t aw_req_i,
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
    strb_t axi_buffer_in_valid, init_buffer_in_valid, obi_buffer_in_valid, buffer_in_valid;

    strb_t buffer_in_ready;
    // outbound control signals of the buffer: controlled by the write process
    strb_t buffer_out_valid, buffer_out_valid_shifted;
    strb_t init_buffer_out_ready, obi_buffer_out_ready,
        buffer_out_ready, buffer_out_ready_shifted;

    // shifted data flowing into the buffer
    byte_t [StrbWidth-1:0] axi_buffer_in, init_buffer_in, obi_buffer_in,
        buffer_in, buffer_in_shifted;
    // aligned and coalesced data leaving the buffer
    byte_t [StrbWidth-1:0] buffer_out, buffer_out_shifted;

    // Read multiplexed signals
    logic axi_r_chan_valid, init_r_chan_valid, obi_r_chan_valid;
    logic axi_r_chan_ready, init_r_chan_ready, obi_r_chan_ready;
    logic axi_r_dp_valid, init_r_dp_valid, obi_r_dp_valid;
    logic axi_r_dp_ready, init_r_dp_ready, obi_r_dp_ready;
    r_dp_rsp_t axi_r_dp_rsp, init_r_dp_rsp, obi_r_dp_rsp;

    logic axi_ar_ready, init_ar_ready, obi_ar_ready;

    // Write multiplexed signals
    logic init_w_dp_rsp_valid, obi_w_dp_rsp_valid;
    logic init_w_dp_rsp_ready, obi_w_dp_rsp_ready;
    logic init_w_dp_ready, obi_w_dp_ready;
    w_dp_rsp_t init_w_dp_rsp, obi_w_dp_rsp;

    logic init_aw_ready, obi_aw_ready;
    logic w_dp_req_valid, w_dp_req_ready;
    logic w_dp_rsp_mux_valid, w_dp_rsp_mux_ready;
    logic w_dp_rsp_valid, w_dp_rsp_ready;
    w_dp_rsp_t w_dp_rsp_mux;

    // Write Response FIFO signals
    logic w_resp_fifo_in_valid, w_resp_fifo_in_ready;
    idma_pkg::protocol_e w_resp_fifo_out_protocol;
    logic w_resp_fifo_out_valid, w_resp_fifo_out_ready;

    //--------------------------------------
    // Read Ports
    //--------------------------------------

    idma_axi_read #(
        .StrbWidth  ( StrbWidth           ),
        .byte_t     ( byte_t              ),
        .strb_t     ( strb_t              ),
        .r_dp_req_t ( r_dp_req_t          ),
        .r_dp_rsp_t ( r_dp_rsp_t          ),
        .ar_chan_t  ( read_meta_channel_t ),
        .read_req_t ( axi_req_t           ),
        .read_rsp_t ( axi_rsp_t           )
    ) i_idma_axi_read (
        .clk_i             ( clk_i      ),
        .rst_ni            ( rst_ni     ),
        .r_dp_req_i        ( r_dp_req_i ),
        .r_dp_valid_i      ( (r_dp_req_i.src_protocol == idma_pkg::AXI) & r_dp_valid_i ),
        .r_dp_ready_o      ( axi_r_dp_ready ),
        .r_dp_rsp_o        ( axi_r_dp_rsp ),
        .r_dp_valid_o      ( axi_r_dp_valid ),
        .r_dp_ready_i      ( (r_dp_req_i.src_protocol == idma_pkg::AXI) & r_dp_ready_i ),
        .ar_req_i          ( ar_req_i.ar_req ),
        .ar_valid_i        ( (ar_req_i.src_protocol == idma_pkg::AXI) & ar_valid_i ),
        .ar_ready_o        ( axi_ar_ready ),
        .read_req_o        ( axi_read_req_o ),
        .read_rsp_i        ( axi_read_rsp_i ),
        .r_chan_valid_o    ( axi_r_chan_valid ),
        .r_chan_ready_o    ( axi_r_chan_ready ),
        .buffer_in_o       ( axi_buffer_in ),
        .buffer_in_valid_o ( axi_buffer_in_valid ),
        .buffer_in_ready_i ( buffer_in_ready )
    );

    idma_init_read #(
        .StrbWidth        ( StrbWidth           ),
        .byte_t           ( byte_t              ),
        .strb_t           ( strb_t              ),
        .r_dp_req_t       ( r_dp_req_t          ),
        .r_dp_rsp_t       ( r_dp_rsp_t          ),
        .read_meta_chan_t ( read_meta_channel_t ),
        .read_req_t       ( init_req_t           ),
        .read_rsp_t       ( init_rsp_t           )
    ) i_idma_init_read (
        .r_dp_req_i        ( r_dp_req_i ),
        .r_dp_valid_i      ( (r_dp_req_i.src_protocol == idma_pkg::INIT) & r_dp_valid_i ),
        .r_dp_ready_o      ( init_r_dp_ready ),
        .r_dp_rsp_o        ( init_r_dp_rsp ),
        .r_dp_valid_o      ( init_r_dp_valid ),
        .r_dp_ready_i      ( (r_dp_req_i.src_protocol == idma_pkg::INIT) & r_dp_ready_i ),
        .read_meta_req_i   ( ar_req_i.ar_req ),
        .read_meta_valid_i ( (ar_req_i.src_protocol == idma_pkg::INIT) & ar_valid_i ),
        .read_meta_ready_o ( init_ar_ready ),
        .read_req_o        ( init_read_req_o ),
        .read_rsp_i        ( init_read_rsp_i ),
        .r_chan_valid_o    ( init_r_chan_valid ),
        .r_chan_ready_o    ( init_r_chan_ready ),
        .buffer_in_o       ( init_buffer_in ),
        .buffer_in_valid_o ( init_buffer_in_valid ),
        .buffer_in_ready_i ( buffer_in_ready )
    );

    idma_obi_read #(
        .StrbWidth        ( StrbWidth           ),
        .byte_t           ( byte_t              ),
        .strb_t           ( strb_t              ),
        .r_dp_req_t       ( r_dp_req_t          ),
        .r_dp_rsp_t       ( r_dp_rsp_t          ),
        .read_meta_chan_t ( read_meta_channel_t ),
        .read_req_t       ( obi_req_t           ),
        .read_rsp_t       ( obi_rsp_t           )
    ) i_idma_obi_read (
        .r_dp_req_i        ( r_dp_req_i ),
        .r_dp_valid_i      ( (r_dp_req_i.src_protocol == idma_pkg::OBI) & r_dp_valid_i ),
        .r_dp_ready_o      ( obi_r_dp_ready ),
        .r_dp_rsp_o        ( obi_r_dp_rsp ),
        .r_dp_valid_o      ( obi_r_dp_valid ),
        .r_dp_ready_i      ( (r_dp_req_i.src_protocol == idma_pkg::OBI) & r_dp_ready_i ),
        .read_meta_req_i   ( ar_req_i.ar_req ),
        .read_meta_valid_i ( (ar_req_i.src_protocol == idma_pkg::OBI) & ar_valid_i ),
        .read_meta_ready_o ( obi_ar_ready ),
        .read_req_o        ( obi_read_req_o ),
        .read_rsp_i        ( obi_read_rsp_i ),
        .r_chan_valid_o    ( obi_r_chan_valid ),
        .r_chan_ready_o    ( obi_r_chan_ready ),
        .buffer_in_o       ( obi_buffer_in ),
        .buffer_in_valid_o ( obi_buffer_in_valid ),
        .buffer_in_ready_i ( buffer_in_ready )
    );

    //--------------------------------------
    // Read Multiplexers
    //--------------------------------------

    always_comb begin : gen_read_meta_channel_multiplexer
        case(ar_req_i.src_protocol)
        idma_pkg::AXI: ar_ready_o = axi_ar_ready;
        idma_pkg::INIT: ar_ready_o = init_ar_ready;
        idma_pkg::OBI: ar_ready_o = obi_ar_ready;
        default:       ar_ready_o = 1'b0;
        endcase
    end

    always_comb begin : gen_read_multiplexer
        if (r_dp_valid_i) begin
            case(r_dp_req_i.src_protocol)
            idma_pkg::AXI: begin
                r_chan_valid_o  = axi_r_chan_valid;
                r_chan_ready_o  = axi_r_chan_ready;

                r_dp_ready_o    = axi_r_dp_ready;
                r_dp_rsp_o      = axi_r_dp_rsp;
                r_dp_valid_o    = axi_r_dp_valid;

                buffer_in       = axi_buffer_in;
                buffer_in_valid = axi_buffer_in_valid;
            end
            idma_pkg::INIT: begin
                r_chan_valid_o  = init_r_chan_valid;
                r_chan_ready_o  = init_r_chan_ready;

                r_dp_ready_o    = init_r_dp_ready;
                r_dp_rsp_o      = init_r_dp_rsp;
                r_dp_valid_o    = init_r_dp_valid;

                buffer_in       = init_buffer_in;
                buffer_in_valid = init_buffer_in_valid;
            end
            idma_pkg::OBI: begin
                r_chan_valid_o  = obi_r_chan_valid;
                r_chan_ready_o  = obi_r_chan_ready;

                r_dp_ready_o    = obi_r_dp_ready;
                r_dp_rsp_o      = obi_r_dp_rsp;
                r_dp_valid_o    = obi_r_dp_valid;

                buffer_in       = obi_buffer_in;
                buffer_in_valid = obi_buffer_in_valid;
            end
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
        idma_pkg::INIT: begin
            w_dp_req_ready   = init_w_dp_ready;
            buffer_out_ready = init_buffer_out_ready;
        end
        idma_pkg::OBI: begin
            w_dp_req_ready   = obi_w_dp_ready;
            buffer_out_ready = obi_buffer_out_ready;
        end
        default: begin
            w_dp_req_ready   = 1'b0;
            buffer_out_ready = '0;
        end
        endcase
    end

    // Demux write meta channel to correct write port
    always_comb begin : gen_write_meta_channel_multiplexer
        case(aw_req_i.dst_protocol)
        idma_pkg::INIT: aw_ready_o = init_aw_ready;
        idma_pkg::OBI: aw_ready_o = obi_aw_ready;
        default:       aw_ready_o = 1'b0;
        endcase
    end

    //--------------------------------------
    // Write Ports
    //--------------------------------------

    idma_init_write #(
        .StrbWidth            ( StrbWidth            ),
        .byte_t               ( byte_t               ),
        .data_t               ( data_t               ),
        .strb_t               ( strb_t               ),
        .w_dp_req_t           ( w_dp_req_t           ),
        .w_dp_rsp_t           ( w_dp_rsp_t           ),
        .write_meta_channel_t ( write_meta_channel_t ),
        .write_req_t          ( init_req_t            ),
        .write_rsp_t          ( init_rsp_t            )
    ) i_idma_init_write (
        .w_dp_req_i         ( w_dp_req_i ),
        .w_dp_valid_i       ( (w_dp_req_i.dst_protocol == idma_pkg::INIT) & w_dp_req_valid ),
        .w_dp_ready_o       ( init_w_dp_ready ),
        .dp_poison_i        ( dp_poison_i ),
        .w_dp_rsp_o         ( init_w_dp_rsp ),
        .w_dp_valid_o       ( init_w_dp_rsp_valid ),
        .w_dp_ready_i       ( init_w_dp_rsp_ready ),
        .write_meta_req_i   ( aw_req_i.aw_req ),
        .write_meta_valid_i ( (aw_req_i.dst_protocol == idma_pkg::INIT) & aw_valid_i ),
        .write_meta_ready_o ( init_aw_ready  ),
        .write_req_o        ( init_write_req_o ),
        .write_rsp_i        ( init_write_rsp_i ),
        .buffer_out_i       ( buffer_out_shifted ),
        .buffer_out_valid_i ( buffer_out_valid_shifted ),
        .buffer_out_ready_o ( init_buffer_out_ready )
    );

    idma_obi_write #(
        .StrbWidth            ( StrbWidth            ),
        .MaskInvalidData      ( MaskInvalidData      ),
        .byte_t               ( byte_t               ),
        .data_t               ( data_t               ),
        .strb_t               ( strb_t               ),
        .w_dp_req_t           ( w_dp_req_t           ),
        .w_dp_rsp_t           ( w_dp_rsp_t           ),
        .write_meta_channel_t ( write_meta_channel_t ),
        .write_req_t          ( obi_req_t            ),
        .write_rsp_t          ( obi_rsp_t            )
    ) i_idma_obi_write (
        .w_dp_req_i         ( w_dp_req_i ),
        .w_dp_valid_i       ( (w_dp_req_i.dst_protocol == idma_pkg::OBI) & w_dp_req_valid ),
        .w_dp_ready_o       ( obi_w_dp_ready ),
        .dp_poison_i        ( dp_poison_i ),
        .w_dp_rsp_o         ( obi_w_dp_rsp ),
        .w_dp_valid_o       ( obi_w_dp_rsp_valid ),
        .w_dp_ready_i       ( obi_w_dp_rsp_ready ),
        .aw_req_i           ( aw_req_i.aw_req ),
        .aw_valid_i         ( (aw_req_i.dst_protocol == idma_pkg::OBI) & aw_valid_i ),
        .aw_ready_o         ( obi_aw_ready  ),
        .write_req_o        ( obi_write_req_o ),
        .write_rsp_i        ( obi_write_rsp_i ),
        .buffer_out_i       ( buffer_out_shifted ),
        .buffer_out_valid_i ( buffer_out_valid_shifted ),
        .buffer_out_ready_o ( obi_buffer_out_ready )
    );

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
        init_w_dp_rsp_ready = 1'b0;
        obi_w_dp_rsp_ready = 1'b0;
        if ( w_resp_fifo_out_valid ) begin
            case(w_resp_fifo_out_protocol)
            idma_pkg::INIT: begin
                w_dp_rsp_mux_valid = init_w_dp_rsp_valid;
                w_dp_rsp_mux       = init_w_dp_rsp;
                init_w_dp_rsp_ready = w_dp_rsp_mux_ready;
            end
            idma_pkg::OBI: begin
                w_dp_rsp_mux_valid = obi_w_dp_rsp_valid;
                w_dp_rsp_mux       = obi_w_dp_rsp;
                obi_w_dp_rsp_ready = w_dp_rsp_mux_ready;
            end
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

    //--------------------------------------
    // Module Control
    //--------------------------------------
    assign r_dp_busy_o   = r_dp_valid_i;
    assign w_dp_busy_o   = w_dp_valid_i | w_dp_ready_o;
    assign buffer_busy_o = |buffer_out_valid;

endmodule


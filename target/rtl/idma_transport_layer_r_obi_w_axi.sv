// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "idma/guard.svh"
`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

/// Implementing the transport layer in the iDMA backend.
module idma_transport_layer_r_obi_w_axi #(
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
    /// Elaborate the optional on-the-fly compute engine
    parameter bit EnableCompute = 1'b0,
    /// Per-operation compute support mask
    parameter idma_pkg::compute_enable_t ComputeOps = '1,
    /// Implementation tuning knobs for the compute engines
    parameter idma_pkg::compute_tuning_t ComputeTuning = '1,
    /// Opt-in timing cuts
    parameter idma_pkg::timing_cuts_t TimingCuts = '0,
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
    /// Read Meta channel type
    parameter type read_meta_channel_t = logic,
    /// AXI4+ATOP Request and Response channel type
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic,
    /// OBI Request and Response channel type
    parameter type obi_req_t = logic,
    parameter type obi_rsp_t = logic
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,

    /// OBI read request
    output obi_req_t obi_read_req_o,
    /// OBI read response
    input  obi_rsp_t obi_read_rsp_i,

    /// AXI4+ATOP write request
    output axi_req_t axi_write_req_o,
    /// AXI4+ATOP write response
    input  axi_rsp_t axi_write_rsp_i,

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
    input  read_meta_channel_t ar_req_i,
    /// Read meta request valid
    input  logic ar_valid_i,
    /// Read meta request ready
    output logic ar_ready_o,

    /// Write meta request
    input  write_meta_channel_t aw_req_i,
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
    /// Dataflow element lanes with registered flags
    localparam bit DfeRegFlags = TimingCuts.dfe_ready_cut | TimingCuts.dfe_reg_flags;
    /// Dataflow element ready from flops, refilled while the write side reads it
    localparam bit DfeReadyCut = TimingCuts.dfe_ready_cut | TimingCuts.dfe_ready_ahead;

    /// Data type
    typedef logic [DataWidth-1:0] data_t;
    /// Offset type
    typedef logic [StrbWidth-1:0] strb_t;
    /// Byte type
    typedef logic [7:0] byte_t;

    // inbound control signals to the read buffer: controlled by the read process
    strb_t buffer_in_valid;
    strb_t buffer_in_ready;
    // a read beat before the buffer masks
    logic  buffer_in_beat;

    // outbound control signals of the buffer: controlled by the write process
    strb_t buffer_out_valid;
    strb_t buffer_out_valid_shifted;
    strb_t buffer_out_ready;
    strb_t buffer_out_ready_shifted;
    strb_t buffer_out_consumed;
    strb_t buffer_out_consumed_shifted;
    // lanes the offered write beat pops, and the dataflow lanes that may take their extra entry
    strb_t buffer_out_offer, buffer_out_offer_shifted, dfe_ahead;

    // shifted data flowing into the buffer
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
    // write-shifter output before the compute write-source select
    byte_t [StrbWidth-1:0] wr_beat;
    strb_t                 wr_beat_valid, wr_beat_mask;
    logic                  cmp_busy;

    logic w_dp_req_ready;
    assign w_dp_ready_o = w_dp_req_ready;

    //--------------------------------------
    // Read Ports
    //--------------------------------------

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
        .r_dp_valid_i      ( r_dp_valid_i ),
        .r_dp_ready_o      ( r_dp_ready_o ),
        .r_dp_rsp_o        ( r_dp_rsp_o ),
        .r_dp_valid_o      ( r_dp_valid_o ),
        .r_dp_ready_i      ( r_dp_ready_i ),
        .read_meta_req_i   ( ar_req_i ),
        .read_meta_valid_i ( ar_valid_i ),
        .read_meta_ready_o ( ar_ready_o ),
        .read_req_o        ( obi_read_req_o ),
        .read_rsp_i        ( obi_read_rsp_i ),
        .buffer_in_o       ( buffer_in ),
        .buffer_in_valid_o ( buffer_in_valid ),
        .buffer_in_beat_o  ( buffer_in_beat ),
        .buffer_in_ready_i ( buffer_in_ready )
    );

    //--------------------------------------
    // Read Barrel shifter
    //--------------------------------------

    assign buffer_in_tmp = {buffer_in, buffer_in} >> (r_dp_req_i.shift * 8);
    assign buffer_in_shifted = buffer_in_tmp[$bits(buffer_in_shifted)/8-1:0];

    //--------------------------------------
    // Buffer
    //--------------------------------------

    // compute builds: MX beats go from the read side to their engine, past the dataflow element
    strb_t dfe_in_valid, dfe_in_ready;
    logic  cmp_mx_ready, mx_push;

    if (EnableCompute) begin : gen_dataflow_mx
        assign dfe_in_valid    = r_dp_req_i.mx.mx ? '0 : buffer_in_valid;
        assign buffer_in_ready = r_dp_req_i.mx.mx ? {StrbWidth{cmp_mx_ready}} : dfe_in_ready;
    end else begin : gen_dataflow
        assign dfe_in_valid    = buffer_in_valid;
        assign buffer_in_ready = dfe_in_ready;
    end

    idma_dataflow_element #(
        .BufferDepth   ( BufferDepth   ),
        .SameCycleRW   ( !DfeReadyCut  ),
        .RegFlags      ( DfeRegFlags   ),
        .AheadSlot     ( TimingCuts.dfe_ready_ahead ),
        .StrbWidth     ( StrbWidth     ),
        .PrintFifoInfo ( PrintFifoInfo ),
        .strb_t        ( strb_t        ),
        .byte_t        ( byte_t        )
    ) i_dataflow_element (
        .clk_i       ( clk_i                    ),
        .rst_ni      ( rst_ni                   ),
        .data_i      ( buffer_in_shifted        ),
        .valid_i     ( dfe_in_valid             ),
        .ready_o     ( dfe_in_ready             ),
        .ahead_i     ( dfe_ahead                ),
        .data_o      ( buffer_out               ),
        .valid_o     ( buffer_out_valid         ),
        .ready_i     ( dataflow_ready_in        )
    );

    //--------------------------------------
    // On-the-fly compute
    //--------------------------------------

    if (EnableCompute) begin : gen_compute
        logic                  cmp_active;
        logic                  cmp_in_ready, cmp_beat_valid, cmp_beat_ready;
        byte_t [StrbWidth-1:0] cmp_data_o;
        strb_t                 cmp_strb_o, cmp_lane_valid;
        strb_t                 cmp_consumed_d, cmp_consumed_q;
        strb_t                 cmp_consumed_this_cycle;

        logic                  cmp_w_mx;
        idma_pkg::mx_tag_t     cmp_tag;

        // MX beats are whole beats: the beat push may skip the byte-lane masks
        if (TimingCuts.mx_beat_push) begin : gen_mx_beat_push
            assign mx_push = buffer_in_beat & cmp_mx_ready & r_dp_req_i.mx.mx;
        end else begin : gen_mx_masked_push
            assign mx_push = buffer_in_valid[0] & r_dp_req_i.mx.mx;
        end

        // the MX tag rides with each read beat
        always_comb begin
            cmp_tag      = r_dp_req_i.mx;
            cmp_tag.last = r_dp_req_i.mx.last & r_dp_rsp_o.last;
            cmp_tag.half = r_dp_req_i.mx.half & r_dp_rsp_o.last;
        end

        idma_otf_compute #(
            .StrbWidth           ( StrbWidth          ),
            .ComputeEnable       ( ComputeOps         ),
            .ComputeTuning       ( ComputeTuning      ),
            .BufferDepth         ( BufferDepth - 32'(TimingCuts.dfe_ready_ahead) ),
            .InReg               ( TimingCuts.mx_in_reg     )
        ) i_idma_otf_compute (
            .clk_i,
            .rst_ni,
            .compute_i    ( w_dp_req_i.compute       ),
            .cfg_valid_i  ( w_dp_valid_i             ),
            .active_o     ( cmp_active               ),
            .data_i       ( buffer_out               ),
            .valid_i      ( &buffer_out_valid        ),
            .in_ready_o   ( cmp_in_ready             ),
            .data_o       ( cmp_data_o               ),
            .strb_o       ( cmp_strb_o               ),
            .beat_valid_o ( cmp_beat_valid           ),
            .beat_ready_i ( cmp_beat_ready           ),
            .lane_valid_o ( cmp_lane_valid           ),
            .mx_data_i    ( buffer_in                ),
            .mx_tag_i     ( cmp_tag                  ),
            .mx_push_i    ( mx_push                  ),
            .mx_ready_o   ( cmp_mx_ready             ),
            .w_data_i     ( wr_beat                  ),
            .w_valid_i    ( wr_beat_valid            ),
            .w_mask_i     ( wr_beat_mask             ),
            .w_data_o     ( buffer_out_shifted       ),
            .w_valid_o    ( buffer_out_valid_shifted ),
            .w_mask_o     ( mask_ext_shifted         ),
            .w_mx_o       ( cmp_w_mx                 ),
            .w_ready_i    ( w_chan_valid_o & w_chan_ready_o ),
            .busy_o       ( cmp_busy                 )
        );

        // Transpose produces atomic beats, but the legalizer may split one beat into multiple
        // writes at a 4 KiB boundary. Track the logical byte positions covered by those writes and
        // retire the transpose beat only after all positions have been consumed. MX engines use
        // their independent lane handshake and therefore leave cmp_beat_valid deasserted.
        assign cmp_consumed_this_cycle =
            cmp_beat_valid ? buffer_out_consumed_shifted : '0;
        assign cmp_beat_ready = &(cmp_consumed_q | cmp_consumed_this_cycle);

        always_comb begin : proc_compute_consumed
            cmp_consumed_d = cmp_consumed_q | cmp_consumed_this_cycle;
            if (cmp_beat_valid && cmp_beat_ready) begin
                cmp_consumed_d = '0;
            end
        end

        `FF(cmp_consumed_q, cmp_consumed_d, '0, clk_i, rst_ni)

        assign wr_data           = cmp_active ? cmp_data_o : buffer_out;
        assign wr_valid          = cmp_active ? cmp_lane_valid : buffer_out_valid;
        assign wr_strb           = cmp_active ? cmp_strb_o : '1;
        for (genvar i = 0; i < StrbWidth; i++) begin : gen_dataflow_ready
            assign dataflow_ready_in[i] = cmp_active ? (&buffer_out_valid) & cmp_in_ready :
                                          ~cmp_w_mx & buffer_out_ready_shifted[i];
            // a lane the pending pop reads, without the write handshake
            assign dfe_ahead[i]         = cmp_active ? (&buffer_out_valid) & cmp_in_ready :
                                          ~cmp_w_mx & buffer_out_offer_shifted[i];
        end

        `ASSERT(ComputeConsumeValid, cmp_consumed_this_cycle != '0 |-> cmp_beat_valid, clk_i, !rst_ni, "Write datapath consumed bytes without a valid atomic compute result")
        `ASSERT(ComputeBeatAllLanesValid, cmp_beat_valid |-> &cmp_lane_valid, clk_i, !rst_ni, "Scalar compute beat handshake requires all output lanes to be valid")
        `ASSERT(ComputeMxWholeBeat, r_dp_req_i.mx.mx & (|buffer_in_valid) |-> &buffer_in_valid,
                clk_i, !rst_ni, "MX beats are read whole")
        `ASSERT(ComputeMxNoShift, cmp_w_mx |-> w_dp_req_i.shift == '0, clk_i, !rst_ni,
                "MX output bypasses the write shifter")
        `ASSERT(ComputeMxBeatPush, mx_push == (buffer_in_valid[0] & r_dp_req_i.mx.mx), clk_i,
                !rst_ni, "MX push differs from the masked read beat")
        `ASSERT(ComputeMxPushBusy, mx_push |-> r_dp_busy_o, clk_i, !rst_ni,
                "MX beat pushed while the read datapath is not busy")
        `ASSERT(ComputeMxNoReadShift, r_dp_req_i.mx.mx & (|buffer_in_valid) |->
                r_dp_req_i.shift == '0, clk_i, !rst_ni, "MX input bypasses the read shifter")
        `ASSERT(ComputeMxWPop, cmp_w_mx & w_chan_valid_o & w_chan_ready_o |->
                buffer_out_valid_shifted[0], clk_i, !rst_ni, "MX W beat without an engine beat")
    end else begin : gen_no_compute
        assign wr_data                  = buffer_out;
        assign wr_valid                 = buffer_out_valid;
        assign wr_strb                  = '1;
        assign dataflow_ready_in        = buffer_out_ready_shifted;
        assign buffer_out_shifted       = wr_beat;
        assign buffer_out_valid_shifted = wr_beat_valid;
        assign mask_ext_shifted         = wr_beat_mask;
        assign cmp_busy                 = 1'b0;
        assign cmp_mx_ready             = 1'b0;
        assign dfe_ahead                = buffer_out_offer_shifted;
    end

    //--------------------------------------
    // Write Barrel shifter
    //--------------------------------------

    assign buffer_out_tmp           = {wr_data, wr_data} >> (w_dp_req_i.shift*8);
    assign wr_beat                  = buffer_out_tmp[$bits(wr_beat)/8-1:0];
    assign wr_beat_valid            = strb_t'({wr_valid, wr_valid} >>   w_dp_req_i.shift);
    assign wr_beat_mask             = strb_t'({wr_strb, wr_strb} >>   w_dp_req_i.shift);
    assign buffer_out_ready_shifted = strb_t'({buffer_out_ready, buffer_out_ready} >> - w_dp_req_i.shift);
    assign buffer_out_offer_shifted =
        strb_t'({buffer_out_offer, buffer_out_offer} >> - w_dp_req_i.shift);
    assign buffer_out_consumed_shifted =
        strb_t'({buffer_out_consumed, buffer_out_consumed} >> -w_dp_req_i.shift);

    //--------------------------------------
    // Write Ports
    //--------------------------------------

    idma_axi_write #(
        .StrbWidth       ( StrbWidth            ),
        .MaskInvalidData ( MaskInvalidData      ),
        .byte_t          ( byte_t               ),
        .data_t          ( data_t               ),
        .strb_t          ( strb_t               ),
        .w_dp_req_t      ( w_dp_req_t           ),
        .w_dp_rsp_t      ( w_dp_rsp_t           ),
        .aw_chan_t       ( write_meta_channel_t ),
        .write_req_t     ( axi_req_t ),
        .write_rsp_t     ( axi_rsp_t )
    ) i_idma_axi_write (
        .clk_i              ( clk_i      ),
        .rst_ni             ( rst_ni     ),
        .w_dp_req_i         ( w_dp_req_i ),
        .w_dp_valid_i       ( w_dp_valid_i ),
        .w_dp_ready_o       ( w_dp_req_ready ),
        .dp_poison_i        ( dp_poison_i ),
        .w_dp_rsp_o         ( w_dp_rsp_o ),
        .w_dp_valid_o       ( w_dp_valid_o ),
        .w_dp_ready_i       ( w_dp_ready_i ),
        .aw_req_i           ( aw_req_i ),
        .aw_valid_i         ( aw_valid_i ),
        .aw_ready_o         ( aw_ready_o ),
        .write_req_o        ( axi_write_req_o ),
        .write_rsp_i        ( axi_write_rsp_i ),
        .w_chan_valid_o     ( w_chan_valid_o ),
        .w_chan_ready_o     ( w_chan_ready_o ),
        .w_chan_first_o     ( w_chan_first_o ),
        .buffer_out_i       ( buffer_out_shifted ),
        .buffer_out_valid_i ( buffer_out_valid_shifted ),
        .buffer_out_ready_o ( buffer_out_ready ),
        .buffer_out_offer_o ( buffer_out_offer ),
        .buffer_out_consumed_o ( buffer_out_consumed ),
        .mask_ext_i         ( mask_ext_shifted )
    );

    //--------------------------------------
    // Module Control
    //--------------------------------------
    assign r_dp_busy_o   = r_dp_valid_i;
    assign w_dp_busy_o   = w_dp_valid_i;
    assign buffer_busy_o = |buffer_out_valid | cmp_busy;

endmodule


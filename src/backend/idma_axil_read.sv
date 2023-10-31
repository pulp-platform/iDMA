// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

/// Implementing the AXI Lite read task in the iDMA transport layer.
module idma_axil_read #(
    /// Stobe width
    parameter int unsigned StrbWidth = 32'd16,

    /// Byte type
    parameter type byte_t = logic,
    /// Offset type
    parameter type strb_t = logic,

    /// AXI 4 Request channel type
    parameter type read_req_t = logic,
    /// AXI 4 Response channel type
    parameter type read_rsp_t = logic,

    /// `r_dp_req_t` type:
    parameter type r_dp_req_t = logic,
    /// `r_dp_rsp_t` type:
    parameter type r_dp_rsp_t = logic,
    /// AXI Lite `AR` channel type
    parameter type ar_chan_t = logic
)(
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

    /// Read meta request
    input  ar_chan_t ar_req_i,
    /// Read meta request valid
    input  logic ar_valid_i,
    /// Read meta request ready
    output logic ar_ready_o,

    /// AXI Lite read manager port request
    output read_req_t read_req_o,
    /// AXI Lite read manager port response
    input  read_rsp_t read_rsp_i,

    /// Response channel valid and ready
    output logic r_chan_ready_o,
    output logic r_chan_valid_o,

    /// Data to Buffer
    output byte_t [StrbWidth-1:0] buffer_in_o,
    /// Valid to Buffer
    output strb_t buffer_in_valid_o,
    /// Ready from Buffer
    input  strb_t buffer_in_ready_i
);
    // read aligned in mask. needs to be shifted together with the data before
    // it can be used to mask valid data flowing into the buffer
    strb_t read_aligned_in_mask;

    // in mask is write aligned: it is the result of the read aligned in mask
    // that is shifted together with the data in the barrel shifter
    strb_t mask_in;

    // inbound control signals to the read buffer: controlled by the read process
    logic  in_valid;
    logic  in_ready;

    //--------------------------------------
    // Read meta channel
    //--------------------------------------
    // connect the ar requests to the AXI bus
    assign read_req_o.ar       = ar_req_i.axi_lite.ar_chan;
    assign read_req_o.ar_valid = ar_valid_i;
    assign ar_ready_o          = read_rsp_i.ar_ready;

    //--------------------------------------
    // Mask pre-calculation
    //--------------------------------------
    // in contiguous transfers that are unaligned, there will be some
    // invalid bytes at the beginning and the end of the stream
    // example: 25B in 64 bit system
    //  iiiivvvv|vvvvvvvv|vvvvvvvv|vvvvviii
    // first msk|----full mask----|last msk

    assign read_aligned_in_mask = ('1 << r_dp_req_i.offset) &
        ((r_dp_req_i.tailer != '0) ? ('1 >> (StrbWidth - r_dp_req_i.tailer)) : '1);


    //--------------------------------------
    // Barrel shifter
    //--------------------------------------
    // data arrives in chunks of length DATA_WDITH, the buffer will be filled with
    // the realigned data. StrbWidth bytes will be inserted starting from the
    // provided address, overflows will naturally wrap

    // a barrel shifter is a concatenation of the same array with twice and a normal
    // shift. Optimized for Synopsys DesignWare.
    assign buffer_in_o = read_rsp_i.r.data;
    assign mask_in     = {read_aligned_in_mask, read_aligned_in_mask} >> r_dp_req_i.shift;


    //--------------------------------------
    // Read control
    //--------------------------------------
    // the buffer can be pushed to if all the masked FIFO buffers (mask_in) are ready.
    assign in_ready = &(buffer_in_ready_i | ~mask_in);
    // the read can accept data if the buffer is ready and the response channel is ready
    assign read_req_o.r_ready = in_ready & r_dp_ready_i;

    // once valid data is applied, it can be pushed in all the selected (mask_in) buffers
    // be sure the response channel is ready
    assign in_valid          = read_rsp_i.r_valid & in_ready & r_dp_ready_i;
    assign buffer_in_valid_o = in_valid ? mask_in : '0;

    // r_dp_ready_o is triggered by the last element arriving from the read
    assign r_dp_ready_o = r_dp_valid_i & r_dp_ready_i & read_rsp_i.r_valid & in_ready;

    // connect r_dp response payload
    assign r_dp_rsp_o.resp  = read_rsp_i.r.resp;
    assign r_dp_rsp_o.last  = 1'b1;
    assign r_dp_rsp_o.first = 1'b1;

    // r_dp_valid_o is triggered once the last element is here or an error occurs
    assign r_dp_valid_o   = read_rsp_i.r_valid & in_ready;
    assign r_chan_ready_o = read_req_o.r_ready;
    assign r_chan_valid_o = read_rsp_i.r_valid;

    //--------------------------------------
    // Unused AXI Lite signals
    //--------------------------------------
    assign read_req_o.aw_valid = 1'b0;
    assign read_req_o.w_valid  = 1'b0;
    assign read_req_o.b_ready  = 1'b0;

    assign read_req_o.aw = '0;
    assign read_req_o.w  = '0;

endmodule

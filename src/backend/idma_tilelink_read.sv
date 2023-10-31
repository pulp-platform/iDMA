// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "common_cells/registers.svh"

/// Implementing the TileLink read task in the iDMA transport layer.
module idma_tilelink_read #(
    /// Stobe width
    parameter int unsigned StrbWidth = 32'd16,
    /// Max Burst Length in bytes
    parameter int unsigned BurstLength = 32'd8,

    /// Byte type
    parameter type byte_t = logic,
    /// Offset type
    parameter type strb_t = logic,

    /// TileLink Request channel type
    parameter type read_req_t = logic,
    /// TileLink Response channel type
    parameter type read_rsp_t = logic,

    /// `r_dp_req_t` type:
    parameter type r_dp_req_t = logic,
    /// `r_dp_rsp_t` type:
    parameter type r_dp_rsp_t = logic,
    /// TileLink `A` channel type
    parameter type read_meta_chan_t = logic
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,

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
    input  read_meta_chan_t read_meta_req_i,
    /// Read meta request valid
    input  logic read_meta_valid_i,
    /// Read meta request ready
    output logic read_meta_ready_o,

    /// TileLink read manager port request
    output read_req_t read_req_o,
    /// TileLink read manager port response
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
    // offsets needed for masks to empty buffer
    strb_t r_first_mask;
    strb_t r_last_mask;

    // read aligned in mask. needs to be shifted together with the data before
    // it can be used to mask valid data flowing into the buffer
    strb_t read_aligned_in_mask;

    // Is this the first read in the burst?
    logic first_r_d, first_r_q;

    // Is this the last read in the burst?
    logic last;

    // How Many beats are left inside burst
    logic [$clog2(BurstLength / StrbWidth)-1:0] counter_r_d, counter_r_q;

    // in mask is write aligned: it is the result of the read aligned in mask
    // that is shifted together with the data in the barrel shifter
    strb_t mask_in;

    // inbound control signals to the read buffer: controlled by the read process
    logic  in_valid;
    logic  in_ready;

    //--------------------------------------
    // Mask pre-calculation
    //--------------------------------------
    // in contiguous transfers that are unaligned, there will be some
    // invalid bytes at the beginning and the end of the stream
    // example: 25B in 64 bit system
    //  iiiivvvv|vvvvvvvv|vvvvvvvv|vvvvviii
    // first msk|----full mask----|last msk

    // read align masks
    assign r_first_mask = '1 << r_dp_req_i.offset;
    assign r_last_mask  = '1 >> (StrbWidth - r_dp_req_i.tailer);

    //--------------------------------------
    // Read meta channel
    //--------------------------------------
    // connect the a requests to the TileLink bus
    assign read_req_o.a       = read_meta_req_i.tilelink.a_chan;
    assign read_req_o.a_valid = read_meta_valid_i;
    assign read_meta_ready_o  = read_rsp_i.a_ready;


    //--------------------------------------
    // In mask generation
    //--------------------------------------
    // in the case of unaligned reads -> not all data is valid
    always_comb begin : proc_in_mask_generator
        // default case: all ones
        read_aligned_in_mask = '1;
        // is first word: some bytes at the beginning may be invalid
        read_aligned_in_mask = first_r_q ?
            read_aligned_in_mask & r_first_mask : read_aligned_in_mask;
        // is last word in write burst: some bytes at the end may be invalid
        if (r_dp_req_i.tailer != '0) begin
            read_aligned_in_mask = last ?
                read_aligned_in_mask & r_last_mask : read_aligned_in_mask;
        end
    end


    //--------------------------------------
    // Barrel shifter
    //--------------------------------------
    // data arrives in chunks of length DATA_WDITH, the buffer will be filled with
    // the realigned data. StrbWidth bytes will be inserted starting from the
    // provided address, overflows will naturally wrap

    // a barrel shifter is a concatenation of the same array with twice and a normal
    // shift. Optimized for Synopsys DesignWare.
    assign buffer_in_o = read_rsp_i.d.data;
    assign mask_in     = {read_aligned_in_mask, read_aligned_in_mask} >> r_dp_req_i.shift;


    //--------------------------------------
    // Read control
    //--------------------------------------
    // controls the next state of the read flag

    assign last = (!first_r_q && (counter_r_q == 'd2)) | r_dp_req_i.is_single;

    always_comb begin : proc_first_read
        // Default
        first_r_d   = first_r_q;
        counter_r_d = counter_r_q;

        // Check for response handshake
        if (read_rsp_i.d_valid && read_req_o.d_ready) begin
            if (last) begin
                // Set first flag
                first_r_d = 1'b1;
            end else begin
                // Reset first flag
                first_r_d = 1'b0;
                // Set counter
                if (first_r_q) begin
                    // How many beats left
                    counter_r_d = ('d1 << read_rsp_i.d.size) >> $clog2(StrbWidth);
                end else begin
                    // Decrement counter
                    counter_r_d = counter_r_q - 'd1;
                end
            end
        end
    end

    // the buffer can be pushed to if all the masked FIFO buffers (mask_in) are ready.
    assign in_ready = &(buffer_in_ready_i | ~mask_in);
    // the read can accept data if the buffer is ready and the response channel is ready
    assign read_req_o.d_ready = in_ready & r_dp_ready_i;

    // once valid data is applied, it can be pushed in all the selected (mask_in) buffers
    // be sure the response channel is ready
    assign in_valid          = read_rsp_i.d_valid & in_ready & r_dp_ready_i;
    assign buffer_in_valid_o = in_valid ? mask_in : '0;

    // r_dp_ready_o is triggered by the last element arriving from the read
    assign r_dp_ready_o = r_dp_valid_i & r_dp_ready_i &
                          last & read_rsp_i.d_valid & in_ready;

    // connect r_dp response payload
    assign r_dp_rsp_o.resp  = {read_rsp_i.d.corrupt, read_rsp_i.d.denied};
    assign r_dp_rsp_o.last  = last;
    assign r_dp_rsp_o.first = first_r_q;

    // r_dp_valid_o is triggered once the last element is here or an error occurs
    assign r_dp_valid_o = read_rsp_i.d_valid & in_ready & (last
        | read_rsp_i.d.corrupt | read_rsp_i.d.denied);

    assign r_chan_ready_o = read_req_o.d_ready;
    assign r_chan_valid_o = read_rsp_i.d_valid;

    //--------------------------------------
    // State
    //--------------------------------------
    `FF(first_r_q,     first_r_d,     '1, clk_i, rst_ni)
    `FF(counter_r_q, counter_r_d,     '0, clk_i, rst_ni)

endmodule

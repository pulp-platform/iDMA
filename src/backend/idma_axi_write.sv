// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "common_cells/registers.svh"

/// Implementing the AXI4 write task in the iDMA transport layer.
module idma_axi_write #(
    /// Stobe width
    parameter int unsigned StrbWidth = 32'd16,
    /// Mask invalid data on the manager interface
    parameter bit MaskInvalidData = 1'b1,

    /// Byte type
    parameter type byte_t = logic,
    /// Data type
    parameter type data_t = logic,
    /// Offset type
    parameter type strb_t = logic,

    /// AXI 4 Request channel type
    parameter type write_req_t = logic,
    /// AXI 4 Response channel type
    parameter type write_rsp_t = logic,

    /// `w_dp_req_t` type:
    parameter type w_dp_req_t = logic,
    /// `w_dp_rsp_t` type:
    parameter type w_dp_rsp_t = logic,
    /// AXI 4 `AW` channel type
    parameter type aw_chan_t = logic
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,

    /// Write datapath request
    input  w_dp_req_t w_dp_req_i,
    /// Write datapath request valid
    input  logic w_dp_valid_i,
    /// Write datapath request ready
    output logic w_dp_ready_o,

    /// Datapath poison signal
    input  logic dp_poison_i,

    /// Write datapath response
    output w_dp_rsp_t w_dp_rsp_o,
    /// Write datapath response valid
    output logic w_dp_valid_o,
    /// Write datapath response valid
    input  logic w_dp_ready_i,

    /// Write meta request
    input  aw_chan_t aw_req_i,
    /// Write meta request valid
    input  logic aw_valid_i,
    /// Write meta request ready
    output logic aw_ready_o,

    /// AXI4+ATOP write manager port request
    output write_req_t write_req_o,
    /// AXI4+ATOP write manager port response
    input  write_rsp_t write_rsp_i,

    /// Data from buffer
    input  byte_t [StrbWidth-1:0] buffer_out_i,
    /// Valid from buffer
    input  strb_t buffer_out_valid_i,
    /// Ready to buffer
    output strb_t buffer_out_ready_o
);
    // offsets needed for masks to empty buffer
    strb_t w_first_mask;
    strb_t w_last_mask;

    // corresponds to the strobe: the write aligned data that is currently valid in the buffer
    strb_t mask_out;

    // write signals: is this the first / last element in a burst?
    logic first_w;
    logic last_w;

    // buffer is ready to write the requested data
    logic ready_to_write;
    // first transfer is possible - this signal is used to detect
    // the first write transfer in a burst
    logic first_possible;
    // buffer is completely empty
    logic buffer_clean;
    // write happens
    logic write_happening;

    // A temporary signal required to write the output of the buffer to before assigning it to
    // the AXI bus. This is required to be compatible with some of the Questasim Versions and some
    // of the parametrizations (e.g. DataWidth = 16)
    data_t buffer_data_masked;

    // we require a counter to hold the current beat in the write burst
    logic [7:0] w_num_beats_d, w_num_beats_q;
    logic       w_cnt_valid_d, w_cnt_valid_q;

    //--------------------------------------
    // Mask pre-calculation
    //--------------------------------------
    // in contiguous transfers that are unaligned, there will be some
    // invalid bytes at the beginning and the end of the stream
    // example: 25B in 64 bit system
    //  iiiivvvv|vvvvvvvv|vvvvvvvv|vvvvviii
    // first msk|----full mask----|last msk

    // write align masks
    assign w_first_mask = '1 << w_dp_req_i.offset;
    assign w_last_mask  = '1 >> (StrbWidth - w_dp_req_i.tailer);

    //--------------------------------------
    // Write meta channel
    //--------------------------------------
    // connect the aw requests to the AXI bus
    assign write_req_o.aw       = aw_req_i.axi.aw_chan;
    assign write_req_o.aw_valid = aw_valid_i;
    assign aw_ready_o           = write_rsp_i.aw_ready;


    //--------------------------------------
    // Out mask generation -> (wstrb mask)
    //--------------------------------------
    // only pop the data actually needed for write from the buffer,
    // determine valid data to pop by calculation the wstrb
    always_comb begin : proc_out_mask_generator
        // default case: all ones
        mask_out = '1;
        // is first word: some bytes at the beginning may be invalid
        mask_out = first_w ? (mask_out & w_first_mask) : mask_out;
        // is last word in write burst: some bytes at the end may be invalid
        if (w_dp_req_i.tailer != '0 & last_w) begin
            mask_out = mask_out & w_last_mask;
        end
    end


    //--------------------------------------
    // Write control
    //--------------------------------------
    // write is decoupled from read, due to misalignment in the read/write
    // addresses, page crossing can be encountered at any time.
    // To handle this efficiently, a 2-to-1 or 1-to-2 mapping of r/w beats
    // is required. The write unit needs to keep track of progress through
    // a counter and cannot use `r last` for that.

    // Once buffer contains a full line -> all FIFOs are non-empty push it out.

    // all elements needed (defined by the mask) are in the buffer and the buffer is non-empty
    assign ready_to_write = w_dp_valid_i & ((buffer_out_valid_i & mask_out) == mask_out)
        & (buffer_out_valid_i != '0);

    // data needed by the first mask is available in the buffer -> r_first happened for sure
    // this signal can be high during a transfer as well, it needs to be masked
    assign first_possible = ((buffer_out_valid_i & w_first_mask) == w_first_mask) &
                            (buffer_out_valid_i != '0);

    // the buffer is completely empty and idle
    assign buffer_clean = &(~buffer_out_valid_i);

    // write happening: both the bus (w_ready) and the buffer (ready_to_write) is high
    assign write_happening = ready_to_write & write_rsp_i.w_ready;

    // the main buffer is conditionally to the write mask popped
    assign buffer_out_ready_o = write_happening ? mask_out : '0;

    // signal the bus that we are ready
    assign write_req_o.w_valid = ready_to_write;

    // connect data and strobe either directly or mask invalid data
    if (MaskInvalidData) begin : gen_mask_invalid_data

        // always_comb process implements masking of invalid data
        always_comb begin : proc_mask
            // defaults
            write_req_o.w.data = '0;
            write_req_o.w.strb = '0;
            buffer_data_masked = '0;
            // control the write to the bus apply data to the bus only if data should be written
            if (ready_to_write == 1'b1 & !dp_poison_i) begin
                // assign data from buffers, mask non valid entries
                for (int i = 0; i < StrbWidth; i++) begin
                    buffer_data_masked[i*8 +: 8] = mask_out[i] ? buffer_out_i[i] : 8'b0;
                end
                // assign the output
                write_req_o.w.data = buffer_data_masked;
                // assign the out mask to the strobe
                write_req_o.w.strb = mask_out;
            end
        end

    end else begin : gen_direct_connect
        // not used signal
        assign buffer_data_masked = '0;
        // simpler: direct connection
        assign write_req_o.w.data = buffer_out_i;
        assign write_req_o.w.strb = dp_poison_i ? '0 : mask_out;
    end

    // the w last signal should only be applied to the bus if an actual transfer happens
    assign write_req_o.w.last = last_w & ready_to_write;

    // we are ready for the next transfer internally, once the w last signal is applied
    assign w_dp_ready_o = last_w & write_happening;

    // the write process: keeps track of remaining beats in burst
    always_comb begin : proc_write_control
        // defaults:
        // beat counter
        w_num_beats_d = w_num_beats_q;
        w_cnt_valid_d = w_cnt_valid_q;
        // mask control
        first_w = 1'b0;
        last_w  = 1'b0;

        // differentiate between the burst and non-burst case. If a transfer
        // consists just of one beat the counters are disabled
        if (w_dp_req_i.is_single) begin
            // in the single case the transfer is both first and last.
            first_w = 1'b1;
            last_w  = 1'b1;

        // in the burst case the counters are needed to keep track of the progress of sending
        // beats. The w_last_o depends on the state of the counter
        end else begin
            // first transfer happens as soon as a) the buffer is ready for a first transfer and b)
            // the counter is currently invalid
            first_w = first_possible & ~w_cnt_valid_q;

            // last happens as soon as a) the counter is valid and b) the counter is now down to 1
            last_w  = w_cnt_valid_q & (w_num_beats_q == 8'h01);

            // load the counter with data in a first cycle, only modifying state if bus is ready
            if (first_w && write_happening) begin
                w_num_beats_d = w_dp_req_i.num_beats;
                w_cnt_valid_d = 1'b1;
            end

            // if we hit the last element, invalidate the counter, only modifying state
            // if bus is ready
            if (last_w && write_happening) begin
                w_cnt_valid_d = 1'b0;
            end

            // count down the beats if the counter is valid and valid data is written to the bus
            if (w_cnt_valid_q && write_happening) w_num_beats_d = w_num_beats_q - 8'h01;
        end
    end


    //--------------------------------------
    // Write response
    //--------------------------------------
    // connect w_dp response payload
    assign w_dp_rsp_o.resp = write_rsp_i.b.resp;
    assign w_dp_rsp_o.user = write_rsp_i.b.user;

    // w_dp_valid_o is triggered once the write answer is here
    assign w_dp_valid_o = write_rsp_i.b_valid;

    // create back pressure on the b channel if the higher parts of the DMA cannot accept more
    // write responses
    assign write_req_o.b_ready = w_dp_ready_i;


    //--------------------------------------
    // Write user signals
    //--------------------------------------
    // in the default implementation: no need for the write user signals
    assign write_req_o.w.user = '0;

    //--------------------------------------
    // Unused AXI signals
    //--------------------------------------
    assign write_req_o.ar       = '0;
    assign write_req_o.ar_valid = 1'b0;
    assign write_req_o.r_ready  = 1'b0;

    //--------------------------------------
    // State
    //--------------------------------------
    `FF(w_cnt_valid_q, w_cnt_valid_d, '0, clk_i, rst_ni)
    `FF(w_num_beats_q, w_num_beats_d, '0, clk_i, rst_ni)

endmodule

// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

/// Implementing the AXI Lite write task in the iDMA transport layer.
module idma_axil_write #(
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

    /// AXI Lite Request channel type
    parameter type write_req_t = logic,
    /// AXI Lite Response channel type
    parameter type write_rsp_t = logic,

    /// `w_dp_req_t` type:
    parameter type w_dp_req_t = logic,
    /// `w_dp_rsp_t` type:
    parameter type w_dp_rsp_t = logic,
    /// AXI Lite `AW` channel type
    parameter type aw_chan_t = logic
) (
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

    /// AXI Lite write manager port request
    output write_req_t write_req_o,
    /// AXI Lite write manager port response
    input  write_rsp_t write_rsp_i,

    /// Data from buffer
    input  byte_t [StrbWidth-1:0] buffer_out_i,
    /// Valid from buffer
    input  strb_t buffer_out_valid_i,
    /// Ready to buffer
    output strb_t buffer_out_ready_o
);
    // corresponds to the strobe: the write aligned data that is currently valid in the buffer
    strb_t mask_out;

    // buffer is ready to write the requested data
    logic ready_to_write;
    // buffer is completely empty
    logic buffer_clean;
    // write happens
    logic write_happening;

    // A temporary signal required to write the output of the buffer to before assigning it to
    // the AXI bus. This is required to be compatible with some of the Questasim Versions and some
    // of the parametrizations (e.g. DataWidth = 16)
    data_t buffer_data_masked;

    //--------------------------------------
    // Write meta channel
    //--------------------------------------
    // connect the aw requests to the AXI bus
    assign write_req_o.aw       = aw_req_i.axi_lite.aw_chan;
    assign write_req_o.aw_valid = aw_valid_i;
    assign aw_ready_o           = write_rsp_i.aw_ready;


    //--------------------------------------
    // Out mask generation -> (wstrb mask)
    //--------------------------------------
    // only pop the data actually needed for write from the buffer,
    // determine valid data to pop by calculation the wstrb

    assign mask_out = ('1 << w_dp_req_i.offset) &
        ((w_dp_req_i.tailer != '0) ? ('1 >> (StrbWidth - w_dp_req_i.tailer)) : '1);

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
    assign ready_to_write = w_dp_valid_i
        & ((buffer_out_valid_i & mask_out) == mask_out) & (buffer_out_valid_i != '0);

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

    // we are ready for the next transfer internally, once the w last signal is applied
    assign w_dp_ready_o = write_happening;

    //--------------------------------------
    // Write response
    //--------------------------------------
    // connect w_dp response payload
    assign w_dp_rsp_o.resp = write_rsp_i.b.resp;

    // w_dp_valid_o is triggered once the write answer is here
    assign w_dp_valid_o = write_rsp_i.b_valid;

    // create back pressure on the b channel if the higher parts of the DMA cannot accept more
    // write responses
    assign write_req_o.b_ready = w_dp_ready_i;

    //--------------------------------------
    // Unused AXI Lite signals
    //--------------------------------------
    assign write_req_o.ar       = '0;
    assign write_req_o.ar_valid = 1'b0;
    assign write_req_o.r_ready  = 1'b0;

endmodule

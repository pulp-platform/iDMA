// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz  <tbenz@ethz.ch>
// Tobias Senti <tsenti@student.ethz.ch>

`include "common_cells/registers.svh"

/// Implementing the OBI transport layer in the iDMA backend.
module idma_obi_transport_layer #(
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
    /// OBI `A` channel type
    parameter type obi_a_chan_t = logic,
    /// OBI Request channel type
    parameter type obi_req_t = logic,
    /// OBI Response channel type
    parameter type obi_rsp_t = logic
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,
    /// Testmode in
    input  logic testmode_i,

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
    input  obi_a_chan_t read_meta_req_i,
    /// Read meta request valid
    input  logic read_meta_valid_i,
    /// Read meta request ready
    output logic read_meta_ready_o,

    /// Datapath poison signal
    input  logic dp_poison_i,

    /// Read part of the datapath is busy
    output logic r_dp_busy_o,
    /// Write part of the datapath is busy
    output logic w_dp_busy_o,
    /// Buffer is busy
    output logic buffer_busy_o,

    /// OBI manager port request
    output obi_req_t obi_req_o,
    /// OBI manager port response
    input obi_rsp_t obi_rsp_i
);

    /// Stobe width
    localparam int unsigned StrbWidth   = DataWidth / 8;

    /// Data type
    typedef logic [DataWidth-1:0] data_t;
    /// Offset type
    typedef logic [StrbWidth-1:0] strb_t;
    /// Byte type
    typedef logic [7:0] byte_t;

    // shifted data flowing into the buffer
    byte_t [StrbWidth-1:0] buffer_in;

    // read aligned in mask. needs to be shifted together with the data before
    // it can be used to mask valid data flowing into the buffer
    strb_t read_aligned_in_mask;

    // in mask is write aligned: it is the result of the read aligned in mask
    // that is shifted together with the data in the barrel shifter
    strb_t mask_in;

    // inbound control signals to the read buffer: controlled by the read process
    strb_t buffer_in_valid;
    strb_t buffer_in_ready;
    logic  in_valid;
    logic  in_ready;

    // corresponds to the strobe: the write aligned data that is currently valid in the buffer
    strb_t mask_out;

    // aligned and coalesced data leaving the buffer
    byte_t [StrbWidth-1:0] buffer_out;

    // A temporary signal required to write the output of the buffer to before assigning it to
    // the OBI bus. This is required to be compatible with some of the Questasim Versions and some
    // of the parametrizations (e.g. DataWidth = 16)
    data_t buffer_data_masked;

    // outbound control signals of the buffer: controlled by the write process
    strb_t buffer_out_valid;
    strb_t buffer_out_ready;

    // write happens
    logic write_happening;
    // buffer is ready to write the requested data
    logic ready_to_write;
    // buffer is completely empty
    logic buffer_clean;

    //--------------------------------------
    // Read meta channel
    //--------------------------------------
    // connect the read requests to the OBI bus
    assign obi_req_o.read.a = read_meta_req_i;
    assign obi_req_o.read.a_req = read_meta_valid_i;
    assign read_meta_ready_o = obi_rsp_i.read.a_gnt;

    //--------------------------------------
    // In mask generation
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
    assign buffer_in = {obi_rsp_i.read.r.rdata, obi_rsp_i.read.r.rdata} >> (r_dp_req_i.shift * 8);
    assign mask_in   = {read_aligned_in_mask, read_aligned_in_mask}  >> r_dp_req_i.shift;


    //--------------------------------------
    // Read control
    //--------------------------------------
    // the buffer can be pushed to if all the masked FIFO buffers (mask_in) are ready.
    assign in_ready = &(buffer_in_ready | ~mask_in);
    // the read can accept data if the buffer is ready and the response channel is ready
    assign obi_req_o.read.r_ready = in_ready & r_dp_ready_i;

    // once valid data is applied, it can be pushed in all the selected (mask_in) buffers
    // be sure the response channel is ready
    assign in_valid        = obi_rsp_i.read.r_valid & r_dp_ready_i;
    assign buffer_in_valid = in_valid ? mask_in : '0;

    // r_dp_ready_o is triggered by the element arriving from the read
    assign r_dp_ready_o = r_dp_valid_i & r_dp_ready_i & obi_rsp_i.read.r_valid & in_ready;

    // connect r_dp response payload
    assign r_dp_rsp_o.resp  = '0;
    assign r_dp_rsp_o.last  = 1'b1;
    assign r_dp_rsp_o.first = 1'b1;

    // r_dp_valid_o is triggered once the element is here
    assign r_dp_valid_o = obi_rsp_i.read.r_valid & in_ready;

    //--------------------------------------
    // Out mask generation -> (be mask)
    //--------------------------------------
    // only pop the data actually needed for write from the buffer,
    // determine valid data to pop by calculation the be

    assign mask_out = ('1 << w_dp_req_i.w_dp_req.offset) &
        ((w_dp_req_i.w_dp_req.tailer != '0) ? ('1 >> (StrbWidth - w_dp_req_i.w_dp_req.tailer))
        : '1);

    //--------------------------------------
    // Write control
    //--------------------------------------

    // all elements needed (defined by the mask) are in the buffer and the buffer is non-empty
    assign ready_to_write = ((buffer_out_valid & mask_out) == mask_out) & (buffer_out_valid != '0);

    // the buffer is completely empty and idle
    assign buffer_clean = &(~buffer_out_valid);

    // write happening: both the bus (a_gnt) and the buffer (ready_to_write) is high
    assign write_happening = ready_to_write & obi_rsp_i.write.a_gnt;

    // the main buffer is conditionally to the write mask popped
    assign buffer_out_ready = write_happening ? mask_out : '0;

    // signal the bus that we are ready
    assign obi_req_o.write.a_req = ready_to_write;

    // connect data and strobe either directly or mask invalid data
    if (MaskInvalidData) begin : gen_mask_invalid_data

        // always_comb process implements masking of invalid data
        always_comb begin : proc_mask
            // defaults
            obi_req_o.write.a.addr  = w_dp_req_i.aw_req.addr;
            obi_req_o.write.a.we    = 1'b1;
            obi_req_o.write.a.wdata = '0;
            obi_req_o.write.a.be    = '0;
            buffer_data_masked      = '0;
            // control the write to the bus apply data to the bus only if data should be written
            if (ready_to_write == 1'b1 & !dp_poison_i) begin
                // assign data from buffers, mask non valid entries
                for (int i = 0; i < StrbWidth; i++) begin
                    buffer_data_masked[i*8 +: 8] = mask_out[i] ? buffer_out[i] : 8'b0;
                end
                // assign the output
                obi_req_o.write.a.wdata = buffer_data_masked;
                // assign the out mask to the strobe
                obi_req_o.write.a.be = mask_out;
            end
        end

    end else begin : gen_direct_connect
        // not used signal
        assign buffer_data_masked = '0;
        // simpler: direct connection
        assign obi_req_o.write.a.wdata = buffer_out;
        assign obi_req_o.write.a.be    = dp_poison_i ? '0 : mask_out;
    end

    // we are ready for the next transfer internally, once a write is happening
    assign w_dp_ready_o = write_happening;

    //--------------------------------------
    // Write response
    //--------------------------------------
    // connect w_dp response payload
    assign w_dp_rsp_o.resp = '0;

    // w_dp_valid_o is triggered once the write answer is here
    assign w_dp_valid_o = obi_rsp_i.write.r_valid;

    // create back pressure on the r channel if the higher parts of the DMA cannot accept more
    // write responses
    assign obi_req_o.write.r_ready = w_dp_ready_i;

    //--------------------------------------
    // Buffer
    //--------------------------------------
    idma_buffer #(
        .BufferDepth   ( BufferDepth   ),
        .StrbWidth     ( StrbWidth     ),
        .PrintFifoInfo ( PrintFifoInfo ),
        .strb_t        ( strb_t        ),
        .byte_t        ( byte_t        )
    ) i_idma_buffer (
        .clk_i,
        .rst_ni,
        .testmode_i,
        .data_i      ( buffer_in        ),
        .valid_i     ( buffer_in_valid  ),
        .ready_o     ( buffer_in_ready  ),
        .data_o      ( buffer_out       ),
        .valid_o     ( buffer_out_valid ),
        .ready_i     ( buffer_out_ready )
    );


    //--------------------------------------
    // Module Control
    //--------------------------------------
    assign r_dp_busy_o   = r_dp_valid_i | r_dp_ready_o;
    assign w_dp_busy_o   = w_dp_valid_i | w_dp_ready_o;
    assign buffer_busy_o = !buffer_clean;

endmodule : idma_obi_transport_layer

// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Thomas Benz <tbenz@ethz.ch>

// Sample implementation to report errors from the AXI bus.
// This module provides the address of errors on a handshaked interface

module axi_dma_error_handler #(
    parameter int unsigned ADDR_WIDTH         = -1,
    parameter int unsigned BUFFER_DEPTH       = -1,
    parameter int unsigned AXI_REQ_FIFO_DEPTH = -1,
    parameter bit          WAIT_FOR_READ      =  1,
    parameter type         axi_req_t          = logic,
    parameter type         axi_res_t          = logic
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    // AXI4 to/from SoC
    output axi_req_t                 axi_dma_req_o,
    input  axi_res_t                 axi_dma_res_i,
    // AXI4 to/from DMA backend
    input  axi_req_t                 axi_dma_req_i,
    output axi_res_t                 axi_dma_res_o,
    // write error
    output logic [ADDR_WIDTH-1:0]    w_error_addr_o,
    output logic                     w_error_valid_o,
    input  logic                     w_error_ready_i,
    // read error
    output logic [ADDR_WIDTH-1:0]    r_error_addr_o,
    output logic                     r_error_valid_o,
    input  logic                     r_error_ready_i
);

    logic mask_write;

    //--------------------------------------
    // AR buffer
    //--------------------------------------
    // the units needs to keep track of the reads issued
    // to the system. Important information to keep is only the address
    logic [ADDR_WIDTH-1:0] current_ar_addr;
    // control signals
    logic ar_queue_push;
    logic ar_queue_pop;

    // instanciate a fifo to buffer the address read requests
    fifo_v3 #(
        .FALL_THROUGH  ( 1'b0                 ),
        .DATA_WIDTH    ( ADDR_WIDTH           ),
        .DEPTH         ( AXI_REQ_FIFO_DEPTH   )
    ) i_fifo_ar_queue (
        .clk_i         ( clk_i                  ),
        .rst_ni        ( rst_ni                 ),
        .flush_i       ( 1'b0                   ),
        .testmode_i    ( 1'b0                   ),
        .full_o        ( ),
        .empty_o       ( ),
        .usage_o       ( ),
        .data_i        ( axi_dma_req_i.ar.addr  ),
        .push_i        ( ar_queue_push          ),
        .data_o        ( current_ar_addr        ),
        .pop_i         ( ar_queue_pop           )
    );

    // this fifo is working in tandem with the ar emittor in the main
    // dma core. Therefore is should never overflow...
    assign ar_queue_push = axi_dma_req_o.ar_valid && axi_dma_res_o.ar_ready;
    assign ar_queue_pop  = axi_dma_req_o.r_ready  && axi_dma_res_o.r_valid && axi_dma_res_o.r.last;

    //--------------------------------------
    // AW buffer
    //--------------------------------------
    // the units needs to keep track of the writes issued
    // to the system. Important information to keep is only the address
    logic [ADDR_WIDTH-1:0] current_aw_addr;
    // control signals
    logic aw_queue_push;
    logic aw_queue_pop;

    // instanciate a fifo to buffer the address write requests
    fifo_v3 #(
        .FALL_THROUGH  ( 1'b0                 ),
        .DATA_WIDTH    ( ADDR_WIDTH           ),
        .DEPTH         ( AXI_REQ_FIFO_DEPTH   )
    ) i_fifo_aw_queue (
        .clk_i         ( clk_i                  ),
        .rst_ni        ( rst_ni                 ),
        .flush_i       ( 1'b0                   ),
        .testmode_i    ( 1'b0                   ),
        .full_o        ( ),
        .empty_o       ( ),
        .usage_o       ( ),
        .data_i        ( axi_dma_req_i.aw.addr  ),
        .push_i        ( aw_queue_push          ),
        .data_o        ( current_aw_addr        ),
        .pop_i         ( aw_queue_pop           )
    );

    // this fifo is working in tandem with the aw emittor in the main
    // dma core. Therefore is should never overflow...
    assign aw_queue_push = axi_dma_req_o.aw_valid && axi_dma_res_o.aw_ready;
    assign aw_queue_pop  = axi_dma_req_o.b_ready  && axi_dma_res_o.b_valid;

    //--------------------------------------
    // Read Errors
    //--------------------------------------
    logic read_error;

    always_comb begin : proc_read_errors

        // defaults: mask signals
        r_error_addr_o  =  '0;
        r_error_valid_o = 1'b0;

        // read errors -> r.resp is != 2'b00;
        read_error = axi_dma_req_o.r_ready &
            axi_dma_res_o.r_valid & (axi_dma_res_o.r.resp != 2'b00);

        // report read error
        if (read_error == 1'b1) begin
            r_error_valid_o = 1'b1;
            r_error_addr_o  = current_ar_addr;
        end

    end

    //--------------------------------------
    // Write Errors
    //--------------------------------------
    logic write_error;

    always_comb begin : proc_write_errors

        // defaults: mask signals
        w_error_addr_o  =  '0;
        w_error_valid_o = 1'b0;

        // write errors -> b.resp is != 2'b00;
        write_error =
          axi_dma_req_o.b_ready & axi_dma_res_o.b_valid & (axi_dma_res_o.b.resp != 2'b00);

        // report write error
        if (write_error == 1'b1) begin
            w_error_valid_o = 1'b1;
            w_error_addr_o  = current_aw_addr;
        end

    end

    //--------------------------------------
    // Request Modifier
    //--------------------------------------
    always_comb begin : proc_req_modifier

        // default: just feed signals through
        axi_dma_req_o = axi_dma_req_i;

        // set strobe to 0 if write is blocked
        if (mask_write == 1'b1) axi_dma_req_o.w.strb = '0;

        // aw_valid from the DMA core should be masked until
        // the DMA core is ready to write (w_valid)
        if (WAIT_FOR_READ == 1'b1) begin
            axi_dma_req_o.aw_valid = axi_dma_req_i.aw_valid && axi_dma_req_i.w_valid;
        end

        // R's will be blocked if no more read errors can be reported
        axi_dma_req_o.r_ready  = axi_dma_req_i.r_ready  && r_error_ready_i;

        // B's will be blocked if no more write errors can be reported
        axi_dma_req_o.b_ready = w_error_ready_i;

    end

    //--------------------------------------
    // Response Modifier
    //--------------------------------------
    always_comb begin : proc_res_modifier

        // default: just feed signals through
        axi_dma_res_o = axi_dma_res_i;

        // aw_ready to the DMA core should be masked until
        // the DMA core is ready to write (w_valid)
        if (WAIT_FOR_READ == 1'b1) begin
            axi_dma_res_o.aw_ready = axi_dma_res_i.aw_ready && axi_dma_req_i.w_valid;
        end

        // R's will be blocked if no more read errors can be reported
        axi_dma_res_o.r_valid  = axi_dma_res_i.r_valid  && r_error_ready_i;

    end

endmodule

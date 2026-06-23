// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Recycled from the vidma inst64 verification harness
// (idma_alu_vec/test/frontend/idma_inst64_drv_if.sv). Faithful copy of the
// copy/status tasks; the vidma-only DMOPC/multi-head/immediate tasks are
// dropped to match the clean single-head upstream idma_inst64_top.
//
// One correctness fix vs the source: the handshake drops acc_req_valid the
// cycle the request is accepted (sampling ready at AcqDelay) instead of holding
// it one extra cycle. The source held valid past grant, which double-issues the
// request to a still-ready frontend FIFO — harmless for idempotent copies but
// corrupts non-idempotent transfers (transpose).

interface idma_inst64_drv_if (
    input logic clk,
    input logic rst_n
);
    import idma_inst64_tb_pkg::*;
    import idma_inst64_snitch_pkg::*;

    // Accelerator Interface Signals
    acc_req_t  acc_req;
    logic      acc_req_valid;
    logic      acc_req_ready;

    acc_res_t  acc_res;
    logic      acc_res_valid;
    logic      acc_res_ready;

    // Internal State for BFM
    logic [31:0] req_id_counter;

    // Performance Counters
    longint unsigned dma_start_cycle;
    longint unsigned dma_end_cycle;
    longint unsigned dma_cycles;
    longint unsigned cycle_counter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle_counter <= 0;
        else cycle_counter <= cycle_counter + 1;
    end

    // Initialization
    initial begin
        acc_req_valid = 1'b0;
        acc_res_ready = 1'b1;
        acc_req = '0;
        req_id_counter = '0;
        dma_start_cycle = 0;
        dma_end_cycle = 0;
        dma_cycles = 0;
    end

    // Drive one accelerator instruction; valid is asserted in the apply region
    // and dropped the cycle the request is accepted (ready sampled at AcqDelay).
    task automatic drive(input logic [31:0] op, input logic [63:0] arga, input logic [63:0] argb);
        @(posedge clk);
        #(ApplDelay);
        acc_req.id        = req_id_counter++;
        acc_req.data_op   = op;
        acc_req.data_arga = arga;
        acc_req.data_argb = argb;
        acc_req_valid     = 1'b1;
        do begin
            @(posedge clk);
            #(AcqDelay);
        end while (!acc_req_ready);
        acc_req_valid = 1'b0;
    endtask

    //--------------------------------------
    // C-like API for DMA Programming
    //--------------------------------------

    task automatic dma_set_source(input addr_t addr);
        drive(DMSRC, addr[31:0], {{(64-AxiAddrWidth){1'b0}}, addr[AxiAddrWidth-1:32]});
    endtask

    task automatic dma_set_dest(input addr_t addr);
        drive(DMDST, addr[31:0], {{(64-AxiAddrWidth){1'b0}}, addr[AxiAddrWidth-1:32]});
    endtask

    task automatic dma_set_strides(input logic [31:0] src_stride, input logic [31:0] dst_stride);
        drive(DMSTR, src_stride, dst_stride);
    endtask

    task automatic dma_set_reps(input logic [31:0] reps);
        drive(DMREP, reps, '0);
    endtask

    // Launch a copy. cfg[1] = 2D enable; channel selects the AXI manager.
    // Reads back the transfer id from the response.
    task automatic dma_start_copy(
        input  addr_t      length,
        input  logic [1:0] cfg,
        input  logic [2:0] channel,
        output tf_id_t     transfer_id
    );
        drive(DMCPY, length, {59'b0, channel, cfg});
        while (!acc_res_valid) @(posedge clk);
        transfer_id = acc_res.data[31:0];
    endtask

    // Launch a transpose. Encodes {enable, mode, M, N} into the spare DMCPY argb
    // bits (argb[1:0]=cfg, [4:2]=channel, [5]=transpose, [7:6]=mode,
    // [19:8]=tensor_m, [31:20]=tensor_n). Length is derived by the midend.
    task automatic dma_transpose(
        input  addr_t       src,
        input  addr_t       dst,
        input  logic [11:0] tensor_m,
        input  logic [11:0] tensor_n,
        input  logic [1:0]  mode,
        input  logic [2:0]  channel,
        output tf_id_t      transfer_id
    );
        logic [63:0] argb;
        dma_set_source(src);
        dma_set_dest(dst);
        argb          = '0;
        argb[4:2]     = channel;
        argb[5]       = 1'b1;
        argb[7:6]     = mode;
        argb[19:8]    = tensor_m;
        argb[31:20]   = tensor_n;
        drive(DMCPY, '0, argb);
        while (!acc_res_valid) @(posedge clk);
        transfer_id = acc_res.data[31:0];
    endtask

    // issue a transpose DMCPY and return the response error bit (negative tests)
    task automatic dma_transpose_err(
        input  addr_t       src,
        input  addr_t       dst,
        input  logic [11:0] tensor_m,
        input  logic [11:0] tensor_n,
        input  logic [1:0]  mode,
        input  logic [2:0]  channel,
        output logic        error
    );
        logic [63:0] argb;
        dma_set_source(src);
        dma_set_dest(dst);
        argb        = '0;
        argb[4:2]   = channel;
        argb[5]     = 1'b1;
        argb[7:6]   = mode;
        argb[19:8]  = tensor_m;
        argb[31:20] = tensor_n;
        drive(DMCPY, '0, argb);
        while (!acc_res_valid) @(posedge clk);
        error = acc_res.error;
    endtask

    task automatic dma_poll_status(
        input  logic [1:0]  status_idx,
        input  logic [2:0]  channel,
        output logic [63:0] status_value
    );
        drive(DMSTAT, '0, {59'b0, channel, status_idx});
        while (!acc_res_valid) @(posedge clk);
        status_value = acc_res.data;
    endtask

    task automatic dma_wait(input tf_id_t transfer_id, input logic [2:0] channel);
        logic [63:0] completed_id;
        $display("[%0t] dma_wait(ID=%0d, chan=%0d) - waiting...", $time, transfer_id, channel);
        forever begin
            dma_poll_status(2'b00, channel, completed_id);
            if (completed_id >= transfer_id) begin
                dma_end_cycle = cycle_counter;
                dma_cycles = dma_end_cycle - dma_start_cycle;
                break;
            end
            repeat(10) @(posedge clk);
        end
    endtask

    task automatic dma_wait_idle(input logic [2:0] channel);
        logic [63:0] busy_status;
        $display("[%0t] dma_wait_idle(chan=%0d) - waiting...", $time, channel);
        forever begin
            dma_poll_status(2'b10, channel, busy_status);
            if (busy_status[0] == 1'b0) break;
            repeat(5) @(posedge clk);
        end
    endtask

endinterface

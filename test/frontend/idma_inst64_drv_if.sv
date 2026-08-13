// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Snitch accelerator-bus driver for `idma_inst64_top`, covering the inst64 ISA
/// (DMSRC/DMDST/DMSTR/DMREP/DMCPY/DMCPYI/DMSTAT).
interface idma_inst64_drv_if #(
    /// Poll budget for `dma_wait`/`dma_wait_idle` before the wait is declared a deadlock
    parameter int unsigned MaxPolls = 32'd10000,
    /// Cycle budget for an outstanding accelerator response
    parameter int unsigned RspTimeoutCycles = 32'd10000
) (
    input logic clk,
    input logic rst_n
);
    import idma_inst64_tb_pkg::*;

    // Accelerator interface signals
    acc_req_t acc_req;
    logic     acc_req_valid;
    logic     acc_req_ready;

    acc_res_t acc_res;
    logic     acc_res_valid;
    logic     acc_res_ready;

    // Driver state
    logic [31:0] req_id_counter;

    // Last observed response (checked by the tests)
    logic [31:0] last_req_id;
    logic [31:0] last_rsp_id;
    logic [63:0] last_rsp_data;
    logic        last_rsp_error;

    longint unsigned cycle_counter;
    longint unsigned dma_start_cycle;
    longint unsigned dma_end_cycle;
    longint unsigned dma_cycles;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle_counter <= '0;
        else        cycle_counter <= cycle_counter + 1;
    end

    initial begin
        acc_req_valid   = 1'b0;
        acc_res_ready   = 1'b1;
        acc_req         = '0;
        req_id_counter  = '0;
        last_req_id     = '0;
        last_rsp_id     = '0;
        last_rsp_data   = '0;
        last_rsp_error  = 1'b0;
        dma_start_cycle = '0;
        dma_end_cycle   = '0;
        dma_cycles      = '0;
    end

    //--------------------------------------
    // Response capture
    //--------------------------------------
    // acc_res_o comes out of a 2-deep cc_spill_register; with acc_res_ready_i tied high
    // it pops on the posedge, so sample it in a clocked process instead of reading it
    // combinationally from a task.
    acc_rsp_item_t rsp_queue [$];

    always_ff @(posedge clk) begin : proc_capture_rsp
        // built in a variable first: verilator rejects an assignment pattern as an argument
        automatic acc_rsp_item_t rsp_item;
        if (rst_n && acc_res_valid && acc_res_ready) begin
            // typed pattern: verilator rejects a bare assignment pattern as a call argument
            rsp_queue.push_back(
                acc_rsp_item_t'{id: acc_res.id, data: acc_res.data, error: acc_res.error});
        end
    end

    function automatic int unsigned rsp_pending();
        return rsp_queue.size();
    endfunction

    //--------------------------------------
    // Low-level accelerator request driver
    //--------------------------------------
    // Drive at ApplDelay, sample ready at AcqDelay of the SAME cycle, then release on the
    // handshake edge. Sampling ready in the same delta as the drive reads the stale value
    // and holds valid across two edges, which issues every instruction twice.
    task automatic acc_issue(
        input logic [31:0] data_op,
        input logic [63:0] data_arga,
        input logic [63:0] data_argb
    );
        @(posedge clk);
        #(ApplDelay);
        last_req_id       = req_id_counter;
        acc_req.id        = req_id_counter;
        acc_req.data_op   = data_op;
        acc_req.data_arga = data_arga;
        acc_req.data_argb = data_argb;
        acc_req_valid     = 1'b1;
        req_id_counter    = req_id_counter + 1;

        #(AcqDelay - ApplDelay);
        while (!acc_req_ready) begin
            @(posedge clk);
            #(AcqDelay);
        end

        @(posedge clk);
        #(ApplDelay);
        acc_req_valid = 1'b0;
    endtask

    /// Pop the response the DUT produced for the last issued request; fails on timeout,
    /// on an id mismatch or on a flagged error.
    task automatic acc_get_rsp(output acc_rsp_item_t item);
        int unsigned waited;
        waited = 0;
        // Resample at AcqDelay so the queue push (active region) is visible to this task
        while (rsp_queue.size() == 0) begin
            @(posedge clk);
            #(AcqDelay);
            waited++;
            if (waited > RspTimeoutCycles) begin
                $fatal(1, "[DRV] no accelerator response for req id %0d within %0d cycles",
                       last_req_id, RspTimeoutCycles);
            end
        end
        item           = rsp_queue.pop_front();
        last_rsp_id    = item.id;
        last_rsp_data  = item.data;
        last_rsp_error = item.error;
        if (item.id !== last_req_id) begin
            $fatal(1, "[DRV] response id mismatch: expected %0d, got %0d", last_req_id, item.id);
        end
        if (item.error !== 1'b0) begin
            $fatal(1, "[DRV] response for req id %0d flags an error", last_req_id);
        end
    endtask

    //--------------------------------------
    // C-like API for DMA programming
    //--------------------------------------

    task automatic dma_set_source(input addr_t addr);
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMSRC),
                  {32'b0, addr[31:0]},
                  {{(64-(AxiAddrWidth-32)){1'b0}}, addr[AxiAddrWidth-1:32]});
    endtask

    task automatic dma_set_dest(input addr_t addr);
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMDST),
                  {32'b0, addr[31:0]},
                  {{(64-(AxiAddrWidth-32)){1'b0}}, addr[AxiAddrWidth-1:32]});
    endtask

    task automatic dma_set_strides(
        input logic [31:0] src_stride,
        input logic [31:0] dst_stride
    );
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMSTR),
                  {32'b0, src_stride}, {32'b0, dst_stride});
    endtask

    task automatic dma_set_reps(input logic [31:0] reps);
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMREP), {32'b0, reps}, 64'b0);
    endtask

    /// Register-form copy; argb[1:0] = cfg, argb[4:2] = channel
    task automatic dma_start_copy(
        input  addr_t      length,
        input  logic [1:0] cfg,
        input  logic [2:0] channel,
        output tf_id_t     transfer_id
    );
        acc_rsp_item_t item;
        if (length == '0) $fatal(1, "[DRV] zero-length DMCPY: the backend rejects it silently");
        dma_start_cycle = cycle_counter;
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMCPY),
                  length, {59'b0, channel, cfg});
        acc_get_rsp(item);
        transfer_id = item.data[31:0];
    endtask

    /// Immediate-form copy; data_op[21:20] = cfg, data_op[24:22] = channel
    task automatic dma_start_copy_imm(
        input  addr_t      length,
        input  logic [1:0] cfg,
        input  logic [2:0] channel,
        output tf_id_t     transfer_id
    );
        acc_rsp_item_t item;
        logic [31:0]   encoding;
        if (length == '0) $fatal(1, "[DRV] zero-length DMCPYI: the backend rejects it silently");
        encoding        = inst_encoding(idma_inst64_snitch_pkg::DMCPYI);
        encoding[21:20] = cfg;
        encoding[24:22] = channel;
        dma_start_cycle = cycle_counter;
        acc_issue(encoding, length, 64'b0);
        acc_get_rsp(item);
        transfer_id = item.data[31:0];
    endtask

    /// Register-form status read; argb[1:0] = index, argb[4:2] = channel.
    /// index 0 = completed_id, 1 = next_id, 2 = busy, 3 = fifo full
    task automatic dma_poll_status(
        input  logic [1:0]  status_idx,
        input  logic [2:0]  channel,
        output logic [63:0] status_value
    );
        acc_rsp_item_t item;
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMSTAT),
                  64'b0, {59'b0, channel, status_idx});
        acc_get_rsp(item);
        status_value = item.data;
    endtask

    /// Wait for `transfer_id` to retire. The id generator resets to next=2/completed=1, so
    /// the first transfer gets id 2 and the compare below is not vacuous.
    task automatic dma_wait(
        input tf_id_t     transfer_id,
        input logic [2:0] channel
    );
        logic [63:0] completed_id;
        int unsigned polls;
        polls = 0;
        forever begin
            dma_poll_status(2'b00, channel, completed_id);
            if (completed_id >= transfer_id) begin
                dma_end_cycle = cycle_counter;
                dma_cycles    = dma_end_cycle - dma_start_cycle;
                break;
            end
            polls++;
            if (polls > MaxPolls) begin
                $fatal(1, "[DRV] dma_wait(id=%0d, chan=%0d) stuck after %0d polls (completed=%0d)",
                       transfer_id, channel, MaxPolls, completed_id);
            end
            repeat (10) @(posedge clk);
        end
    endtask

    task automatic dma_wait_idle(input logic [2:0] channel);
        logic [63:0] busy_status;
        int unsigned polls;
        polls = 0;
        forever begin
            dma_poll_status(2'b10, channel, busy_status);
            if (busy_status[0] == 1'b0) break;
            polls++;
            if (polls > MaxPolls) begin
                $fatal(1, "[DRV] dma_wait_idle(chan=%0d) timed out after %0d polls",
                       channel, MaxPolls);
            end
            repeat (5) @(posedge clk);
        end
    endtask

endinterface

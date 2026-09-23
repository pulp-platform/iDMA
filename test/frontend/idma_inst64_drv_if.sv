// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Snitch accelerator-bus or CV-X-IF driver for `idma_inst64_top`, covering the inst64 ISA
/// (DMSRC/DMDST/DMSTR/DMREP/DMCPY/DMCPYI/DMSTAT/DMINIT/DMOPC).
interface idma_inst64_drv_if #(
    /// Drive the CV-X-IF port the way Snitch does instead of the accelerator bus
    parameter bit          Xif = 1'b0,
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

    // CV-X-IF signals
    x_issue_req_t  x_issue_req;
    x_issue_resp_t x_issue_resp;
    logic          x_issue_valid;
    logic          x_issue_ready;
    x_register_t   x_register;
    logic          x_register_valid;
    logic          x_register_ready;
    x_commit_t     x_commit;
    logic          x_commit_valid;
    x_result_t     x_result;
    logic          x_result_valid;
    logic          x_result_ready;

    // CV-X-IF knobs: commit latency (0 as Snitch), kill, rs_valid delay, result stalls
    int unsigned   xif_commit_delay;
    bit            xif_kill;
    int unsigned   xif_rs_delay;
    bit            xif_res_backpressure;
    bit            xif_res_hold;

    // CV-X-IF observations of the last issue, and running totals
    logic            last_accept;
    logic            last_writeback;
    int unsigned     last_issue_wait;
    longint unsigned last_issue_cycle;
    longint unsigned xif_result_cycle;
    longint unsigned acc_rsp_cycle;
    int unsigned     xif_accepted;
    int unsigned     xif_rejected;
    int unsigned     xif_killed;
    int unsigned     xif_results;

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
        x_issue_valid        = 1'b0;
        x_register_valid     = 1'b0;
        x_issue_req          = '0;
        x_register           = '0;
        xif_commit_delay     = '0;
        xif_kill             = 1'b0;
        xif_rs_delay         = '0;
        xif_res_backpressure = 1'b0;
        xif_res_hold         = 1'b0;
        last_accept          = 1'b0;
        last_writeback       = 1'b0;
        last_issue_wait      = '0;
        last_issue_cycle     = '0;
        xif_result_cycle     = '0;
        xif_accepted         = '0;
        xif_rejected         = '0;
        xif_killed           = '0;
        xif_results          = '0;
    end

    //--------------------------------------
    // Response capture
    //--------------------------------------
    // acc_res_o pops on the posedge, so sample it in a clocked process
    acc_rsp_item_t rsp_queue [$];

    always_ff @(posedge clk) begin : proc_capture_rsp
        // built in a variable first: verilator rejects an assignment pattern as an argument
        automatic acc_rsp_item_t rsp_item;
        if (rst_n && acc_res_valid && acc_res_ready) begin
            // typed pattern: verilator rejects a bare assignment pattern as a call argument
            rsp_queue.push_back(
                acc_rsp_item_t'{id: acc_res.id, data: acc_res.data, error: acc_res.error});
            acc_rsp_cycle <= cycle_counter;
        end
    end

    //--------------------------------------
    // CV-X-IF model of Snitch
    //--------------------------------------
    // In-flight accepted instructions: writeback and committed flags, by id
    logic [1:0] xif_inflight [xif_id_t];
    xif_id_t    xif_id_counter;

    typedef struct {
        longint unsigned due;
        xif_id_t         id;
        bit              kill;
    } xif_commit_item_t;
    xif_commit_item_t xif_commit_queue [$];

    logic      xif_commit_drv_valid;
    x_commit_t xif_commit_drv;
    logic      xif_stall_rand;

    initial begin
        xif_id_counter       = '0;
        xif_commit_drv_valid = 1'b0;
        xif_commit_drv       = '0;
        xif_stall_rand       = 1'b0;
    end

    // Delay 0 commits combinationally in the issue handshake, exactly as snitch.sv does
    always_comb begin : proc_xif_commit
        if (xif_commit_delay == 0) begin
            x_commit_valid       = x_issue_valid & x_issue_ready;
            x_commit             = '0;
            x_commit.hartid      = x_issue_req.hartid;
            x_commit.id          = x_issue_req.id;
            x_commit.commit_kill = xif_kill;
        end else begin
            x_commit_valid = xif_commit_drv_valid;
            x_commit       = xif_commit_drv;
        end
    end

    // Snitch always takes a result without writeback; one with writeback may be stalled
    assign x_result_ready = !x_result.we ||
                            !((xif_res_backpressure && xif_stall_rand) || xif_res_hold);

    always @(posedge clk) begin : proc_xif_commit_drv
        #(ApplDelay);
        xif_stall_rand = $urandom_range(0, 1);
        xif_commit_drv_valid = 1'b0;
        if (xif_commit_queue.size() != 0 && xif_commit_queue[0].due <= cycle_counter) begin
            automatic xif_commit_item_t item = xif_commit_queue.pop_front();
            xif_commit_drv             = '0;
            xif_commit_drv.id          = item.id;
            xif_commit_drv.commit_kill = item.kill;
            xif_commit_drv_valid       = 1'b1;
            if (xif_inflight.exists(item.id)) begin
                if (item.kill) begin
                    xif_inflight.delete(item.id);
                    xif_killed++;
                end else begin
                    xif_inflight[item.id][1] = 1'b1;
                end
            end
        end
    end

    // Each result must match an accepted, committed instruction exactly once
    always @(posedge clk) begin : proc_capture_result
        if (rst_n && x_result_valid && x_result_ready) begin
            if (!xif_inflight.exists(x_result.id)) begin
                $fatal(1, "[DRV] XIF result for id %0d that is not in flight", x_result.id);
            end
            if (!xif_inflight[x_result.id][1]) begin
                $fatal(1, "[DRV] XIF result for id %0d before its commit", x_result.id);
            end
            if (x_result.we !== xif_inflight[x_result.id][0]) begin
                $fatal(1, "[DRV] XIF result we=%0b for id %0d, issue said writeback=%0b",
                       x_result.we, x_result.id, xif_inflight[x_result.id][0]);
            end
            xif_inflight.delete(x_result.id);
            xif_results++;
            xif_result_cycle = cycle_counter;
            if (x_result.we) begin
                rsp_queue.push_back(acc_rsp_item_t'{id: 32'(x_result.id),
                                                    data: 64'(x_result.data), error: 1'b0});
            end
        end
    end

    /// Cycle of the last response or result handshake
    function automatic longint unsigned last_result_cycle();
        return Xif ? xif_result_cycle : acc_rsp_cycle;
    endfunction

    function automatic int unsigned xif_pending();
        return xif_inflight.num();
    endfunction

    // A rejected DMA instruction stands in for Snitch's illegal-instruction trap
    function automatic bit expects_rsp(input logic [31:0] instr);
        return (instr ==? idma_inst64_snitch_pkg::DMCPY)   ||
               (instr ==? idma_inst64_snitch_pkg::DMCPYI)  ||
               (instr ==? idma_inst64_snitch_pkg::DMSTAT)  ||
               (instr ==? idma_inst64_snitch_pkg::DMSTATI) ||
               (instr ==? idma_inst64_snitch_pkg::DMINIT);
    endfunction

    /// Issue one instruction; register and issue share the handshake, as with Snitch
    task automatic xif_issue(
        input logic [31:0] instr,
        input logic [31:0] rs1,
        input logic [31:0] rs2
    );
        int unsigned waited;
        xif_id_t     id;
        @(posedge clk);
        #(ApplDelay);
        id                     = xif_id_counter;
        last_req_id            = 32'(id);
        x_issue_req            = '0;
        x_issue_req.instr      = instr;
        x_issue_req.id         = id;
        x_register             = '0;
        x_register.id          = id;
        x_register.rs          = {32'b0, rs2, rs1};
        x_register.rs_valid    = (xif_rs_delay == 0) ? 3'b111 : 3'b000;
        x_issue_valid          = 1'b1;
        x_register_valid       = 1'b1;
        waited                 = 0;

        #(AcqDelay - ApplDelay);
        while (!x_issue_ready) begin
            @(posedge clk);
            #(ApplDelay);
            waited++;
            if (waited >= xif_rs_delay) x_register.rs_valid = 3'b111;
            #(AcqDelay - ApplDelay);
            if (waited > RspTimeoutCycles) begin
                $fatal(1, "[DRV] XIF issue of %08h not ready within %0d cycles", instr, waited);
            end
        end
        // Snitch completes issue and register together, so the readys must agree
        if (x_register_ready !== x_issue_resp.accept) begin
            $fatal(1, "[DRV] register_ready %0b disagrees with accept %0b for %08h",
                   x_register_ready, x_issue_resp.accept, instr);
        end
        last_accept      = x_issue_resp.accept;
        last_writeback   = x_issue_resp.writeback;
        last_issue_wait  = waited;
        last_issue_cycle = cycle_counter;
        xif_id_counter   = xif_id_counter + 1;
        if (x_issue_resp.accept) begin
            xif_accepted++;
            if (xif_commit_delay == 0) begin
                if (xif_kill) xif_killed++;
                else xif_inflight[id] = {1'b1, x_issue_resp.writeback};
            end else begin
                xif_inflight[id] = {1'b0, x_issue_resp.writeback};
            end
        end else begin
            xif_rejected++;
            if (expects_rsp(instr)) begin
                rsp_queue.push_back(acc_rsp_item_t'{id: 32'(id), data: '0, error: 1'b1});
            end
        end
        // Snitch commits every issue, rejected ones included
        if (xif_commit_delay != 0) begin
            xif_commit_queue.push_back(xif_commit_item_t'{
                due: cycle_counter + xif_commit_delay, id: id, kill: xif_kill});
        end

        @(posedge clk);
        #(ApplDelay);
        x_issue_valid    = 1'b0;
        x_register_valid = 1'b0;
    endtask

    function automatic int unsigned rsp_pending();
        return rsp_queue.size();
    endfunction

    //--------------------------------------
    // Low-level accelerator request driver
    //--------------------------------------
    // Sampling ready in the drive delta issues every instruction twice
    task automatic acc_issue(
        input logic [31:0] data_op,
        input logic [63:0] data_arga,
        input logic [63:0] data_argb
    );
        if (Xif) begin
            xif_issue(data_op, data_arga[31:0], data_argb[31:0]);
            return;
        end
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
        last_issue_cycle = cycle_counter;

        @(posedge clk);
        #(ApplDelay);
        acc_req_valid = 1'b0;
    endtask

    // / Pop the response for the last request; fails on timeout or id mismatch
    task automatic acc_get_rsp_raw(output acc_rsp_item_t item);
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
    endtask

    // / Same, but an error response is fatal; use `acc_get_rsp_raw` for a negative test
    task automatic acc_get_rsp(output acc_rsp_item_t item);
        acc_get_rsp_raw(item);
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

    /// DMOPC; both operands are sign-extended from bit 31 as an RV32 core drives them.
    task automatic dma_set_compute(input logic [31:0] opcode, input logic [31:0] params = 32'b0);
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMOPC),
                  {{32{opcode[31]}}, opcode}, {{32{params[31]}}, params});
    endtask

    /// DMSTR; both strides are sign-extended from bit 31 as an RV32 core drives them.
    task automatic dma_set_strides(
        input logic [31:0] src_stride,
        input logic [31:0] dst_stride
    );
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMSTR),
                  {{32{src_stride[31]}}, src_stride}, {{32{dst_stride[31]}}, dst_stride});
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

    /// Memset the destination via the INIT read port; data_op[21:20] = cfg, [24:22] = channel
    task automatic dma_start_memset(
        input  addr_t      length,
        input  logic [1:0] cfg,
        input  logic [2:0] channel,
        output tf_id_t     transfer_id
    );
        acc_rsp_item_t item;
        if (length == '0) $fatal(1, "[DRV] zero-length DMINIT: the backend rejects it silently");
        dma_start_cycle = cycle_counter;
        acc_issue(memset_encoding(cfg, channel), length, 64'b0);
        acc_get_rsp(item);
        transfer_id = item.data[31:0];
    endtask

    /// Same, but returns the raw response so the caller can check a rejection
    task automatic dma_try_memset(
        input  addr_t          length,
        input  logic [1:0]     cfg,
        input  logic [2:0]     channel,
        output acc_rsp_item_t  item
    );
        acc_issue(memset_encoding(cfg, channel), length, 64'b0);
        acc_get_rsp_raw(item);
    endtask

    function automatic logic [31:0] memset_encoding(
        input logic [1:0] cfg,
        input logic [2:0] channel
    );
        memset_encoding        = inst_encoding(idma_inst64_snitch_pkg::DMINIT);
        memset_encoding[21:20] = cfg;
        memset_encoding[24:22] = channel;
    endfunction

    // / Status read; index 0 = completed_id, 1 = next_id, 2 = busy, 3 = fifo full
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

    // / Wait for retire; ids start at 2, so the compare is not vacuous
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

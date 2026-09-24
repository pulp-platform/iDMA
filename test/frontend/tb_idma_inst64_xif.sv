// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// CV-X-IF port of the `inst64` frontend. Runs 1D, immediate, 2D, and AXI-user copies
/// byte-exact, and with `FrontendXif` the protocol cases: foreign and unsupported encodings
/// rejected without a stall, killed instructions leaving no trace, late commits, operand
/// gating, and exactly one result per accepted instruction. `FrontendXif` 0 runs the copies
/// over the accelerator bus, so the issue-to-launch latency of both ports can be compared.
module tb_idma_inst64_xif #(
    /// Drive the CV-X-IF port; 0 runs the positive cases over the accelerator bus
    parameter bit FrontendXif = 1'b1
);
    import idma_inst64_tb_pkg::*;

    // EnableCompute 0, so DMOPC must be rejected; the TCDM topology, so DMINIT is accepted
    idma_inst64_base #(
        .EnableTcdmObi ( 1'b1        ),
        .EnableCompute ( 1'b0        ),
        .FrontendXif   ( FrontendXif )
    ) harness ();

    localparam int unsigned TimeoutCycles = 32'd400000;
    localparam logic [7:0]  Sentinel      = 8'h5A;

    // 1D copies
    localparam addr_t       SrcAddr  = 64'h8000_0000;
    localparam addr_t       DstAddr  = 64'h9000_0000;
    localparam addr_t       KillAddr = 64'hB000_0000;
    localparam int unsigned CopySize = 32'd512;

    // 2D copy: Reps rows of RowBytes, strided on both sides
    localparam addr_t       Src2d     = 64'hC000_0000;
    localparam addr_t       Dst2d     = 64'hD000_0000;
    localparam int unsigned RowBytes  = 32'd64;
    localparam int unsigned Reps      = 32'd4;
    localparam int unsigned SrcStride = 32'd256;
    localparam int unsigned DstStride = 32'd128;

    // Bulk copies that fill the request queue
    localparam addr_t       BulkSrc   = 64'h4000_0000;
    localparam addr_t       BulkDst   = 64'h5000_0000;
    localparam int unsigned BulkSize  = 32'd32768;
    localparam int unsigned MaxBulk   = 32'd16;

    int unsigned errors = 0;

    //--------------------------------------
    // Monitors
    //--------------------------------------
    // Transfer launches into the channel request queue, and AXI user and AR traffic
    longint unsigned launch_cycle;
    int unsigned     launches;
    int unsigned     ar_count;
    logic            last_aw_user;

    initial begin
        launch_cycle = '0;
        launches     = '0;
        ar_count     = '0;
        last_aw_user = 1'b0;
    end

    // The commit buffer only exists behind the CV-X-IF port
    logic xif_parked;
    if (FrontendXif) begin : gen_parked
        assign xif_parked = harness.i_dut.gen_xif.i_idma_inst64_xif.buf_valid_q;
    end else begin : gen_no_parked
        assign xif_parked = 1'b0;
    end

    always @(posedge harness.clk) begin : proc_monitor
        #(AcqDelay);
        if (harness.rst_n) begin
            if (harness.i_dut.idma_fe_req_valid[0] && harness.i_dut.idma_fe_req_ready[0]) begin
                launch_cycle = harness.drv_if.cycle_counter;
                launches++;
            end
            if (harness.axi_req[0].aw_valid && harness.axi_res[0].aw_ready) begin
                last_aw_user = harness.axi_req[0].aw.user[0];
            end
            if (harness.axi_req[0].ar_valid && harness.axi_res[0].ar_ready) ar_count++;
        end
    end

    //--------------------------------------
    // Memory helpers
    //--------------------------------------
    function automatic logic [7:0] pattern(input addr_t base, input int unsigned i);
        return 8'(base[27:20] + i * 7 + 3);
    endfunction

    task automatic seed(input addr_t base, input int unsigned bytes);
        for (int unsigned i = 0; i < bytes; i++) harness.mem_write_byte(base + i, pattern(base, i));
    endtask

    task automatic poison(input addr_t base, input int unsigned bytes);
        for (int unsigned i = 0; i < bytes; i++) harness.mem_write_byte(base + i, Sentinel);
    endtask

    task automatic expect_copy(input addr_t src, input addr_t dst, input int unsigned bytes,
                               input string what);
        int unsigned bad = 0;
        for (int unsigned i = 0; i < bytes; i++) begin
            if (harness.mem_read_byte(dst + i) !== pattern(src, i)) bad++;
        end
        // one sentinel past the end, so an overrun fails too
        if (harness.mem_read_byte(dst + bytes) !== Sentinel) bad++;
        if (bad != 0) begin
            $error("%s: %0d of %0d bytes wrong", what, bad, bytes);
            errors++;
        end
    endtask

    task automatic expect_untouched(input addr_t base, input int unsigned bytes,
                                    input string what);
        for (int unsigned i = 0; i < bytes; i++) begin
            if (harness.mem_read_byte(base + i) !== Sentinel) begin
                $error("%s: byte %0d written", what, i);
                errors++;
                break;
            end
        end
    endtask

    task automatic expect_2d(input addr_t dst, input string what);
        int unsigned bad = 0;
        for (int unsigned r = 0; r < Reps; r++) begin
            for (int unsigned i = 0; i < DstStride; i++) begin
                logic [7:0] got;
                got = harness.mem_read_byte(dst + r * DstStride + i);
                if (i < RowBytes && got !== pattern(Src2d, r * SrcStride + i)) bad++;
                if (i >= RowBytes && got !== Sentinel) bad++;
            end
        end
        if (bad != 0) begin
            $error("%s: %0d bytes wrong in the %0dx%0d B layout", what, bad, Reps, RowBytes);
            errors++;
        end
    endtask

    //--------------------------------------
    // Driver helpers
    //--------------------------------------
    function automatic logic [31:0] imm_form(input logic [31:0] pat, input logic [1:0] cfg,
                                             input logic [2:0] chan);
        imm_form = inst_encoding(pat);
        imm_form[idma_inst64_snitch_pkg::ImmCfgLsb +: 2]  = cfg;
        imm_form[idma_inst64_snitch_pkg::ImmChanLsb +: 3] = chan;
    endfunction

    function automatic logic [63:0] next_id();
        return harness.i_dut.next_id[0];
    endfunction

    task automatic copy_1d(input addr_t src, input addr_t dst, input string what);
        tf_id_t tid;
        harness.drv_if.dma_set_source(src);
        harness.drv_if.dma_set_dest(dst);
        harness.drv_if.dma_start_copy(addr_t'(CopySize), 2'b00, 3'd0, tid);
        harness.drv_if.dma_wait(tid, 3'd0);
        expect_copy(src, dst, CopySize, what);
    endtask

    /// A foreign or unsupported encoding: rejected in its first cycle, no result, no launch
    task automatic expect_reject(input logic [31:0] instr, input string what,
                                 input bit quiet = 1'b1);
        acc_rsp_item_t item;
        int unsigned   results;
        int unsigned   launched;
        results  = harness.drv_if.xif_results;
        launched = launches;
        harness.drv_if.acc_issue(instr, 64'h0, 64'h1);
        if (harness.drv_if.last_accept !== 1'b0) begin
            $error("%s (%08h) was accepted", what, instr);
            errors++;
        end
        if (harness.drv_if.last_issue_wait != 0) begin
            $error("%s (%08h) stalled issue for %0d cycles", what, instr,
                   harness.drv_if.last_issue_wait);
            errors++;
        end
        if (harness.drv_if.expects_rsp(instr)) begin
            harness.drv_if.acc_get_rsp_raw(item);
        end
        repeat (8) @(posedge harness.clk);
        if (quiet && (harness.drv_if.xif_results != results || launches != launched)) begin
            $error("%s (%08h) produced a result or a launch", what, instr);
            errors++;
        end
    endtask

    //--------------------------------------
    // Positive cases, both ports
    //--------------------------------------
    task automatic run_copies();
        tf_id_t          tid;
        longint unsigned issue_cycle;

        // 1D register form, with the latency of the launching instruction
        seed(SrcAddr, CopySize);
        poison(DstAddr, CopySize + 64);
        harness.drv_if.dma_set_source(SrcAddr);
        harness.drv_if.dma_set_dest(DstAddr);
        harness.drv_if.dma_start_copy(addr_t'(CopySize), 2'b00, 3'd0, tid);
        issue_cycle = harness.drv_if.last_issue_cycle;
        $display("[TB] %s DMCPY latency: issue->launch %0d cycles, issue->result %0d cycles",
                 FrontendXif ? "XIF" : "ACC", launch_cycle - issue_cycle,
                 harness.drv_if.last_result_cycle() - issue_cycle);
        harness.drv_if.dma_wait(tid, 3'd0);
        expect_copy(SrcAddr, DstAddr, CopySize, "1D DMCPY");

        // 1D immediate form
        poison(DstAddr, CopySize + 64);
        harness.drv_if.dma_start_copy_imm(addr_t'(CopySize), 2'b00, 3'd0, tid);
        harness.drv_if.dma_wait(tid, 3'd0);
        expect_copy(SrcAddr, DstAddr, CopySize, "1D DMCPYI");

        // 2D: Reps rows, strided on both sides
        seed(Src2d, Reps * SrcStride);
        poison(Dst2d, Reps * DstStride);
        harness.drv_if.dma_set_source(Src2d);
        harness.drv_if.dma_set_dest(Dst2d);
        harness.drv_if.dma_set_strides(SrcStride, DstStride);
        harness.drv_if.dma_set_reps(Reps);
        harness.drv_if.dma_start_copy(addr_t'(RowBytes), 2'b10, 3'd0, tid);
        harness.drv_if.dma_wait(tid, 3'd0);
        expect_2d(Dst2d, "2D DMCPY");

        // Negative strides exercise the RV32 sign extension; rows land as in the case above
        poison(Dst2d + 64'h10_0000, Reps * DstStride);
        harness.drv_if.dma_set_source(Src2d + (Reps - 1) * SrcStride);
        harness.drv_if.dma_set_dest(Dst2d + 64'h10_0000 + (Reps - 1) * DstStride);
        harness.drv_if.dma_set_strides(-SrcStride, -DstStride);
        harness.drv_if.dma_start_copy(addr_t'(RowBytes), 2'b10, 3'd0, tid);
        harness.drv_if.dma_wait(tid, 3'd0);
        expect_2d(Dst2d + 64'h10_0000, "2D DMCPY, negative strides");
        harness.drv_if.dma_set_strides(SrcStride, DstStride);

        // DMUSER lands on the AW user bits
        harness.drv_if.acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMUSER), 64'h1, 64'h0);
        poison(DstAddr, CopySize + 64);
        copy_1d(SrcAddr, DstAddr, "1D copy after DMUSER");
        if (last_aw_user !== 1'b1) begin
            $error("DMUSER 1 did not reach aw.user");
            errors++;
        end
        $display("[TB] 1D, immediate, 2D up and down, and AXI-user copies byte-exact");
    endtask

    //--------------------------------------
    // CV-X-IF protocol cases
    //--------------------------------------
    task automatic run_rejects();
        // Foreign encodings: an OP add, custom-0, custom-1 with funct3 1, an unused funct7
        expect_reject(32'h00b5_0533, "add");
        expect_reject(32'h0000_000b, "custom-0");
        expect_reject(32'h00c5_902b, "custom-1 funct3=1");
        expect_reject(32'hfec5_802b, "custom-1 funct7=0x7f");
        // A DMA encoding with a nonzero reserved slot is not a DMA instruction
        expect_reject(inst_encoding(idma_inst64_snitch_pkg::DMSRC) | 32'h0000_0080,
                      "DMSRC with rd set");
        // No compute datapath: the whole DMOPC encoding is rejected
        expect_reject(inst_encoding(idma_inst64_snitch_pkg::DMOPC), "DMOPC without compute");
        // One channel: a channel immediate of 1 names nothing
        expect_reject(imm_form(idma_inst64_snitch_pkg::DMCPYI, 2'b00, 3'd1), "DMCPYI chan 1");
        expect_reject(imm_form(idma_inst64_snitch_pkg::DMSTATI, 2'b00, 3'd1), "DMSTATI chan 1");
        expect_reject(imm_form(idma_inst64_snitch_pkg::DMINIT, 2'b00, 3'd7), "DMINIT chan 7");
        $display("[TB] %0d foreign or unsupported encodings rejected in their issue cycle",
                 harness.drv_if.xif_rejected);
    endtask

    task automatic run_kills();
        acc_rsp_item_t   item;
        logic [63:0]     id_before;
        int unsigned     ar_before;

        // Killed config instructions: the next copies must still use the old configuration
        seed(SrcAddr, CopySize);
        seed(KillAddr, CopySize);
        poison(DstAddr, CopySize + 64);
        poison(KillAddr + 64'h10_0000, CopySize + 64);
        harness.drv_if.dma_set_source(SrcAddr);
        harness.drv_if.dma_set_dest(DstAddr);
        harness.drv_if.xif_kill = 1'b1;
        harness.drv_if.dma_set_source(KillAddr);
        harness.drv_if.dma_set_dest(KillAddr + 64'h10_0000);
        harness.drv_if.acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMUSER), 64'h0, 64'h0);
        harness.drv_if.dma_set_strides(32'd16, 32'd16);
        harness.drv_if.dma_set_reps(32'd2);
        harness.drv_if.xif_kill = 1'b0;
        copy_1d(SrcAddr, DstAddr, "copy after killed DMSRC/DMDST");
        expect_untouched(KillAddr + 64'h10_0000, CopySize, "killed DMDST target");
        if (last_aw_user !== 1'b1) begin
            $error("a killed DMUSER 0 changed aw.user");
            errors++;
        end
        poison(Dst2d, Reps * DstStride);
        harness.drv_if.dma_set_source(Src2d);
        harness.drv_if.dma_set_dest(Dst2d);
        begin
            tf_id_t tid;
            harness.drv_if.dma_start_copy(addr_t'(RowBytes), 2'b10, 3'd0, tid);
            harness.drv_if.dma_wait(tid, 3'd0);
        end
        expect_2d(Dst2d, "2D copy after killed DMSTR/DMREP");

        // A killed DMCPY launches nothing and returns nothing
        id_before = next_id();
        ar_before = ar_count;
        harness.drv_if.xif_kill = 1'b1;
        harness.drv_if.acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMCPY),
                                 64'(CopySize), 64'h0);
        harness.drv_if.xif_kill = 1'b0;
        repeat (50) @(posedge harness.clk);
        if (next_id() !== id_before || ar_count != ar_before ||
            harness.drv_if.rsp_pending() != 0) begin
            $error("killed DMCPY left a trace: next_id %0d -> %0d, %0d reads, %0d results",
                   id_before, next_id(), ar_count - ar_before, harness.drv_if.rsp_pending());
            errors++;
        end

        // Late commits: the instruction parks until its commit, a late kill drops it
        harness.drv_if.xif_commit_delay     = 3;
        harness.drv_if.xif_res_backpressure = 1'b1;
        poison(DstAddr, CopySize + 64);
        copy_1d(SrcAddr, DstAddr, "copy with commits 3 cycles late");
        harness.drv_if.xif_kill = 1'b1;
        harness.drv_if.dma_set_source(KillAddr);
        harness.drv_if.xif_kill = 1'b0;
        poison(DstAddr, CopySize + 64);
        copy_1d(SrcAddr, DstAddr, "late-commit copy after a late-killed DMSRC");
        id_before = next_id();
        harness.drv_if.xif_kill = 1'b1;
        harness.drv_if.acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMCPY),
                                 64'(CopySize), 64'h0);
        harness.drv_if.xif_kill = 1'b0;
        repeat (50) @(posedge harness.clk);
        if (next_id() !== id_before || harness.drv_if.rsp_pending() != 0) begin
            $error("late-killed DMCPY launched or answered");
            errors++;
        end
        harness.drv_if.xif_commit_delay     = 0;
        harness.drv_if.xif_res_backpressure = 1'b0;
        $display("[TB] %0d killed instructions left no trace", harness.drv_if.xif_killed);
    endtask

    task automatic run_operand_gating();
        logic [63:0] status;
        // DMSRC reads rs1 and rs2: issue waits for them
        harness.drv_if.xif_rs_delay = 5;
        harness.drv_if.dma_set_source(SrcAddr);
        if (harness.drv_if.last_issue_wait != 5) begin
            $error("DMSRC issued after %0d cycles, operands arrived after 5",
                   harness.drv_if.last_issue_wait);
            errors++;
        end
        // DMSTATI reads no register: operand validity must not hold it
        harness.drv_if.acc_issue(imm_form(idma_inst64_snitch_pkg::DMSTATI, 2'b01, 3'd0),
                                 64'h0, 64'h0);
        if (harness.drv_if.last_issue_wait != 0 || !harness.drv_if.last_accept) begin
            $error("DMSTATI waited %0d cycles for operands it does not read",
                   harness.drv_if.last_issue_wait);
            errors++;
        end
        begin
            acc_rsp_item_t item;
            harness.drv_if.acc_get_rsp(item);
            if (item.data !== next_id()) begin
                $error("DMSTATI next_id returned %0d, expected %0d", item.data, next_id());
                errors++;
            end
        end
        harness.drv_if.xif_rs_delay = 0;
        harness.drv_if.dma_poll_status(2'b01, 3'd0, status);
        $display("[TB] issue waits for the operands an instruction reads, and only those");
    endtask

    /// With the commit buffer full, a foreign instruction is still rejected at once
    task automatic run_structural();
        int unsigned n;
        logic        parked;
        logic [31:0] first_id;
        acc_rsp_item_t item;

        harness.drv_if.dma_set_source(BulkSrc);
        harness.drv_if.dma_set_dest(BulkDst);
        n      = 0;
        parked = 1'b0;
        while (!parked && n < MaxBulk) begin
            harness.drv_if.acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMCPY),
                                     64'(BulkSize), 64'h0);
            n++;
            #(1ns);
            // parked because the request queue is full, not for a moment behind a result
            parked = xif_parked && !harness.i_dut.idma_fe_req_ready[0];
        end
        if (!parked) begin
            $error("%0d bulk copies never filled the request queue", n);
            errors++;
        end
        // Other transfers may retire meanwhile, so only the stall and accept are checked
        expect_reject(32'h00b5_0533, "add while the DMA stalls", 1'b0);
        harness.drv_if.acc_issue(imm_form(idma_inst64_snitch_pkg::DMSTATI, 2'b10, 3'd0),
                                 64'h0, 64'h0);
        if (harness.drv_if.last_issue_wait == 0) begin
            $error("DMSTATI issued past a parked DMCPY without waiting");
            errors++;
        end
        $display("[TB] %0d bulk copies queued; foreign issue not stalled, DMSTATI waited %0d",
                 n, harness.drv_if.last_issue_wait);
        // n DMCPY results, then the DMSTATI busy flag, in issue order
        while (harness.drv_if.rsp_pending() < n + 1) @(posedge harness.clk);
        first_id = harness.drv_if.rsp_queue[0].id;
        for (int unsigned i = 0; i < n; i++) begin
            item = harness.drv_if.rsp_queue.pop_front();
            if (item.id !== 32'(xif_id_t'(first_id + i))) begin
                $error("bulk copy %0d answered with id %0d, expected %0d", i, item.id,
                       xif_id_t'(first_id + i));
                errors++;
            end
        end
        item = harness.drv_if.rsp_queue.pop_front();
        if (item.data !== 64'd1) begin
            $error("DMSTATI busy read %0d while bulk copies were queued", item.data);
            errors++;
        end
        harness.drv_if.dma_wait_idle(3'd0);
    endtask

    /// A stalled writeback result blocks the result register; config results queue behind it
    task automatic run_result_stall();
        acc_rsp_item_t item;
        int unsigned   results;
        results = harness.drv_if.xif_results;
        harness.drv_if.xif_res_hold = 1'b1;
        harness.drv_if.acc_issue(imm_form(idma_inst64_snitch_pkg::DMSTATI, 2'b01, 3'd0),
                                 64'h0, 64'h0);
        // One result behind the stalled one fits, the next parks, the third waits
        harness.drv_if.dma_set_strides(SrcStride, DstStride);
        harness.drv_if.dma_set_strides(SrcStride, DstStride);
        fork
            begin
                for (int unsigned c = 0; c < 20; c++) @(posedge harness.clk);
                harness.drv_if.xif_res_hold = 1'b0;
            end
        join_none
        harness.drv_if.dma_set_strides(SrcStride, DstStride);
        if (harness.drv_if.last_issue_wait < 15) begin
            $error("config issue waited %0d cycles behind a full result register",
                   harness.drv_if.last_issue_wait);
            errors++;
        end
        repeat (10) @(posedge harness.clk);
        if (harness.drv_if.rsp_pending() != 1) begin
            $error("%0d writeback results pending, expected the DMSTATI one",
                   harness.drv_if.rsp_pending());
            errors++;
        end
        item = harness.drv_if.rsp_queue.pop_front();
        if (harness.drv_if.xif_results != results + 4) begin
            $error("%0d results for 4 instructions behind a stalled result",
                   harness.drv_if.xif_results - results);
            errors++;
        end
        $display("[TB] config results queue behind a stalled writeback result, none dropped");
    endtask

    initial begin : test_sequence
        @(posedge harness.rst_n);
        repeat (10) @(posedge harness.clk);
        $display("[TB] inst64 over %s", FrontendXif ? "CV-X-IF" : "the accelerator bus");

        run_copies();
        if (FrontendXif) begin
            run_rejects();
            run_kills();
            run_operand_gating();
            run_structural();
            run_result_stall();
            repeat (20) @(posedge harness.clk);
            if (harness.drv_if.xif_pending() != 0) begin
                $error("%0d accepted instructions never returned a result",
                       harness.drv_if.xif_pending());
                errors++;
            end
            if (harness.drv_if.xif_results !=
                harness.drv_if.xif_accepted - harness.drv_if.xif_killed) begin
                $error("%0d results for %0d accepted and %0d killed instructions",
                       harness.drv_if.xif_results, harness.drv_if.xif_accepted,
                       harness.drv_if.xif_killed);
                errors++;
            end
            $display("[TB] %0d accepted, %0d killed, %0d results, %0d rejected",
                     harness.drv_if.xif_accepted, harness.drv_if.xif_killed,
                     harness.drv_if.xif_results, harness.drv_if.xif_rejected);
        end
        if (harness.drv_if.rsp_pending() != 0) begin
            $error("%0d unexpected responses left over", harness.drv_if.rsp_pending());
            errors++;
        end

        if (errors != 0) $fatal(1, "TEST FAILED: %0d errors", errors);
        $display("[TB] TEST PASSED");
        $finish;
    end

    initial begin : watchdog
        repeat (TimeoutCycles) @(posedge harness.clk);
        $fatal(1, "simulation timeout after %0d cycles", TimeoutCycles);
    end

endmodule

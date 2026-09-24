// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Transfer ids of the `inst64` frontend with the request queue full.
/// Queues `DMAReqFifoDepth + 3` large DMCPY/DMCPYI per channel back-to-back, checks the
/// returned ids are consecutive per channel, then waits on each id through DMSTAT and
/// requires that transfer's destination to be fully written when the wait returns.
module tb_idma_inst64_txid #(
    parameter int unsigned NumChannels     = 32'd1,
    parameter int unsigned DMAReqFifoDepth = 32'd3
);
    import idma_inst64_tb_pkg::*;

    idma_inst64_base #(
        .NumChannels     ( NumChannels     ),
        .DMAReqFifoDepth ( DMAReqFifoDepth )
    ) harness ();

    // The memory accessors below reach channel 0 and NumChannels-1 only
    if (NumChannels > 2) begin : gen_num_channels_check
        $fatal(1, "tb_idma_inst64_txid: NumChannels %0d > 2 is not supported", NumChannels);
    end

    localparam int unsigned TimeoutCycles = 32'd2000000;
    // 32 KiB takes hundreds of beats, so the queue stays full while the core issues
    localparam int unsigned XferSize      = 32'h8000;
    localparam addr_t       XferLen       = addr_t'(XferSize);
    localparam int unsigned NumXfers      = DMAReqFifoDepth + 32'd3;
    // Ids restart at 2 after reset
    localparam tf_id_t      FirstId       = 32'd2;
    localparam tf_id_t      LastId        = FirstId + tf_id_t'(NumXfers) - 32'd1;
    localparam addr_t       SrcBase       = 64'h8000_0000;
    localparam addr_t       DstBase       = 64'h9000_0000;

    int unsigned errors = 0;
    tf_id_t      ids       [NumChannels][NumXfers];
    int unsigned full_seen [NumChannels];

    function automatic addr_t src_addr(input int unsigned k);
        return SrcBase + addr_t'(k) * addr_t'(XferSize);
    endfunction

    function automatic addr_t dst_addr(input int unsigned k);
        return DstBase + addr_t'(k) * addr_t'(XferSize);
    endfunction

    // Distinct per channel and transfer, so a copy of the wrong source also fails
    function automatic logic [7:0] pattern(
        input int unsigned c,
        input int unsigned k,
        input int unsigned i
    );
        return 8'(i + 8'd13 * k + 8'd101 * c) ^ 8'(i >> 8);
    endfunction

    task automatic mem_write(input int unsigned c, input addr_t addr, input logic [7:0] data);
        if (c == 0) harness.gen_mem_ch[0].i_axi_sim_mem.mem[addr] = data;
        else        harness.gen_mem_ch[NumChannels-1].i_axi_sim_mem.mem[addr] = data;
    endtask

    function automatic logic [7:0] mem_read(input int unsigned c, input addr_t addr);
        if (c == 0) begin
            if (harness.gen_mem_ch[0].i_axi_sim_mem.mem.exists(addr)) begin
                return harness.gen_mem_ch[0].i_axi_sim_mem.mem[addr];
            end
        end else begin
            if (harness.gen_mem_ch[NumChannels-1].i_axi_sim_mem.mem.exists(addr)) begin
                return harness.gen_mem_ch[NumChannels-1].i_axi_sim_mem.mem[addr];
            end
        end
        return 8'hXX;
    endfunction

    task automatic check_dst(input int unsigned c, input int unsigned k);
        int unsigned bad;
        bad = 0;
        for (int unsigned i = 0; i < XferSize; i++) begin
            if (mem_read(c, dst_addr(k) + addr_t'(i)) !== pattern(c, k, i)) bad++;
        end
        if (bad != 0) begin
            $error("chan %0d xfer %0d (id %0d): %0d of %0d B not written when its wait returned",
                   c, k, ids[c][k], bad, XferSize);
            errors++;
        end
    endtask

    initial begin : test_sequence
        logic [63:0] status;

        @(posedge harness.rst_n);
        repeat (10) @(posedge harness.clk);

        $display("[TB] inst64 txid: NumChannels=%0d DMAReqFifoDepth=%0d, %0d x %0d B each",
                 NumChannels, DMAReqFifoDepth, NumXfers, XferSize);

        for (int unsigned c = 0; c < NumChannels; c++) begin
            full_seen[c] = 0;
            for (int unsigned k = 0; k < NumXfers; k++) begin
                for (int unsigned i = 0; i < XferSize; i++) begin
                    mem_write(c, src_addr(k) + addr_t'(i), pattern(c, k, i));
                end
            end
        end

        // Interleave the channels so every queue fills; DMCPY blocks while its queue is full
        for (int unsigned k = 0; k < NumXfers; k++) begin
            for (int unsigned c = 0; c < NumChannels; c++) begin
                harness.drv_if.dma_poll_status(2'b11, 3'(c), status);
                if (status[0]) full_seen[c]++;
                harness.drv_if.dma_set_source(src_addr(k));
                harness.drv_if.dma_set_dest(dst_addr(k));
                if (k[0]) begin
                    harness.drv_if.dma_start_copy_imm(XferLen, 2'b00, 3'(c), ids[c][k]);
                end else begin
                    harness.drv_if.dma_start_copy(XferLen, 2'b00, 3'(c), ids[c][k]);
                end
            end
        end

        for (int unsigned c = 0; c < NumChannels; c++) begin
            string id_list;
            id_list = "";
            for (int unsigned k = 0; k < NumXfers; k++) begin
                id_list = {id_list, $sformatf(" %0d", ids[c][k])};
            end
            $display("[TB] chan %0d returned ids:%s", c, id_list);

            // Non-vacuity: the bug needs requests waiting in the queue at DMCPY time
            if (full_seen[c] < 2) begin
                $fatal(1, "chan %0d: queue seen full before only %0d DMCPYs", c, full_seen[c]);
            end

            if (ids[c][0] !== FirstId) begin
                $error("chan %0d: first id %0d, expected %0d", c, ids[c][0], FirstId);
                errors++;
            end
            for (int unsigned k = 1; k < NumXfers; k++) begin
                if (ids[c][k] !== ids[c][k-1] + 1) begin
                    $error("chan %0d: xfer %0d got id %0d after id %0d", c, k, ids[c][k],
                           ids[c][k-1]);
                    errors++;
                end
            end

            // DMSTAT next_id is the id the next DMCPY on this channel will return
            harness.drv_if.dma_poll_status(2'b01, 3'(c), status);
            if (status !== 64'(ids[c][NumXfers-1]) + 1) begin
                $error("chan %0d: DMSTAT next_id %0d, expected %0d", c, status,
                       ids[c][NumXfers-1] + 1);
                errors++;
            end
        end

        // Waiting on an id must imply that transfer is complete
        for (int unsigned k = 0; k < NumXfers; k++) begin
            for (int unsigned c = 0; c < NumChannels; c++) begin
                harness.drv_if.dma_wait(ids[c][k], 3'(c));
                check_dst(c, k);
            end
        end

        for (int unsigned c = 0; c < NumChannels; c++) begin
            harness.drv_if.dma_wait_idle(3'(c));
            harness.drv_if.dma_poll_status(2'b00, 3'(c), status);
            if (status !== 64'(LastId)) begin
                $error("chan %0d: completed_id %0d after %0d transfers, expected %0d", c,
                       status, NumXfers, LastId);
                errors++;
            end
            $display("[TB] chan %0d: queue seen full before %0d of %0d DMCPYs", c,
                     full_seen[c], NumXfers);
        end

        if (harness.drv_if.rsp_pending() != 0) begin
            $fatal(1, "%0d unexpected accelerator responses left over",
                   harness.drv_if.rsp_pending());
        end
        if (errors != 0) $fatal(1, "TEST FAILED: %0d errors", errors);
        $display("[TB] TEST PASSED: %0d channel(s) x %0d transfers, ids and payloads match",
                 NumChannels, NumXfers);
        $finish;
    end

    initial begin : watchdog
        repeat (TimeoutCycles) @(posedge harness.clk);
        $fatal(1, "simulation timeout after %0d cycles", TimeoutCycles);
    end

endmodule

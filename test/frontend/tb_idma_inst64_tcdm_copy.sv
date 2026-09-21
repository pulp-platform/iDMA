// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Exercises the TCDM (OBI) leg of the `inst64` frontend at `EnableTcdmObi = 1`.
/// Stages an AXI buffer through the TCDM window and back, so OBI write and read
/// beats both flow, and memsets the window through the INIT port. Every check
/// reads the AXI memory, so a lost or corrupted OBI beat fails the compare.
module tb_idma_inst64_tcdm_copy;
    import idma_inst64_tb_pkg::*;

    idma_inst64_base #(.EnableTcdmObi(1'b1)) harness ();

    localparam int unsigned CopySize     = 32'd1024;
    localparam int unsigned BytesPerBeat = AxiDataWidth / 32'd8;
    localparam int unsigned ExpObiBeats  = CopySize / BytesPerBeat;
    localparam int unsigned GuardBytes   = 32'd64;
    localparam logic [7:0]  Sentinel     = 8'h5A;
    localparam logic [7:0]  PatternStart = 8'hA0;
    // DMINIT cfg 2'b01 sets src_addr to 8'hFF, which the INIT port replicates per byte
    localparam logic [1:0]  MemsetCfg    = 2'b01;
    localparam logic [7:0]  MemsetByte   = 8'hFF;

    // Inside the TCDM window, so the decode picks OBI; the AXI ends sit outside it
    localparam addr_t TcdmBuf = addr_t'(TcdmStart + 64'h1000);
    localparam addr_t AxiSrc  = 64'h8000_0000;
    localparam addr_t AxiDst  = 64'h9000_0000;
    localparam addr_t AxiInit = 64'h9001_0000;

    int unsigned errors        = 0;
    int unsigned obi_rd_beats  = 0;
    int unsigned obi_wr_beats  = 0;
    int unsigned ev_rd_beats   = 0;
    int unsigned ev_wr_beats   = 0;

    dma_events_t ev;
    obi_req_t    obi_req;
    obi_res_t    obi_res;
    assign ev      = harness.events[0];
    assign obi_req = harness.obi_req[0];
    assign obi_res = harness.obi_res[0];

    // The event fields recode the OBI pins, so the TB rebuilds them from those pins
    logic exp_obi_wr_req, exp_obi_rd_req;
    assign exp_obi_wr_req = obi_req.req && obi_res.gnt &&  obi_req.a.we;
    assign exp_obi_rd_req = obi_req.req && obi_res.gnt && !obi_req.a.we;

    a_obi_wr_req_field : assert property (
        @(posedge harness.clk) disable iff (!harness.rst_n) ev.obi_wr_req === exp_obi_wr_req
    ) else $fatal(1, "events.obi_wr_req disagrees with the OBI pins");

    a_obi_rd_req_field : assert property (
        @(posedge harness.clk) disable iff (!harness.rst_n) ev.obi_rd_req === exp_obi_rd_req
    ) else $fatal(1, "events.obi_rd_req disagrees with the OBI pins");

    // A request outside the window would mean the decode routed an AXI address to OBI
    a_obi_in_window : assert property (
        @(posedge harness.clk) disable iff (!harness.rst_n)
        obi_req.req |-> (obi_req.a.addr >= TcdmStart && obi_req.a.addr < TcdmEnd)
    ) else $fatal(1, "OBI request at 0x%0h leaves the TCDM window", obi_req.a.addr);

    always_ff @(posedge harness.clk) begin : proc_count_obi
        if (harness.rst_n) begin
            if (exp_obi_wr_req) obi_wr_beats++;
            if (exp_obi_rd_req) obi_rd_beats++;
            if (ev.obi_wr_req)  ev_wr_beats++;
            if (ev.obi_rd_req)  ev_rd_beats++;
        end
    end

    task automatic seed_axi(input addr_t base, input int num_bytes);
        for (int i = 0; i < num_bytes; i++) begin
            harness.mem_write_byte(base + i, PatternStart + i);
        end
    endtask

    task automatic sentinel_axi(input addr_t base, input int num_bytes);
        for (int i = 0; i < num_bytes + 2*GuardBytes; i++) begin
            harness.mem_write_byte(base - GuardBytes + i, Sentinel);
        end
    endtask

    /// Compares `num_bytes` at `base`; `expected` of 'x means the seeded pattern
    task automatic check_axi(
        input addr_t      base,
        input int         num_bytes,
        input logic [8:0] expected
    );
        for (int i = 0; i < num_bytes; i++) begin
            logic [7:0] want;
            logic [7:0] got;
            want = expected[8] ? (PatternStart + i) : expected[7:0];
            got  = harness.mem_read_byte(base + i);
            if (got !== want) begin
                if (errors < 10) begin
                    $error("mismatch at 0x%0h + %0d: expected 0x%02x, got 0x%02x",
                           base, i, want, got);
                end
                errors++;
            end
        end
        for (int unsigned i = 1; i <= GuardBytes; i++) begin
            if (harness.mem_read_byte(base - i) !== Sentinel) begin
                $error("underrun at 0x%0h - %0d", base, i);
                errors++;
            end
            if (harness.mem_read_byte(base + num_bytes + i - 1) !== Sentinel) begin
                $error("overrun at 0x%0h + %0d", base, num_bytes + i - 1);
                errors++;
            end
        end
    endtask

    task automatic run_copy(input addr_t src, input addr_t dst);
        tf_id_t tid;
        harness.drv_if.dma_set_source(src);
        harness.drv_if.dma_set_dest(dst);
        harness.drv_if.dma_start_copy(CopySize, 2'b00, 3'd0, tid);
        harness.drv_if.dma_wait(tid, 3'd0);
    endtask

    initial begin : test_sequence
        tf_id_t      tid;
        int unsigned wr_after_stage;
        int unsigned rd_after_stage;

        @(posedge harness.rst_n);
        repeat (10) @(posedge harness.clk);

        $display("[TB] inst64 TCDM stage: 0x%0h -> 0x%0h -> 0x%0h, %0d B",
                 AxiSrc, TcdmBuf, AxiDst, CopySize);

        // Stage into the TCDM window: the write leg must go out over OBI
        seed_axi(AxiSrc, CopySize);
        run_copy(AxiSrc, TcdmBuf);
        wr_after_stage = obi_wr_beats;
        rd_after_stage = obi_rd_beats;
        if (wr_after_stage != ExpObiBeats) begin
            $fatal(1, "staging wrote %0d OBI beats, expected %0d", wr_after_stage, ExpObiBeats);
        end
        if (rd_after_stage != 0) $fatal(1, "staging read %0d OBI beats", rd_after_stage);

        // Read it back out: the read leg must come in over OBI
        sentinel_axi(AxiDst, CopySize);
        run_copy(TcdmBuf, AxiDst);
        check_axi(AxiDst, CopySize, 9'h100);
        if (obi_rd_beats != ExpObiBeats) begin
            $fatal(1, "read-back took %0d OBI beats, expected %0d", obi_rd_beats, ExpObiBeats);
        end
        if (obi_wr_beats != wr_after_stage) begin
            $fatal(1, "read-back issued %0d extra OBI writes", obi_wr_beats - wr_after_stage);
        end

        // Memset the window through the INIT port, then read it back over OBI
        $display("[TB] inst64 TCDM memset: 0x%0h, %0d B of 0x%02x",
                 TcdmBuf, CopySize, MemsetByte);
        harness.drv_if.dma_set_dest(TcdmBuf);
        harness.drv_if.dma_start_memset(CopySize, MemsetCfg, 3'd0, tid);
        harness.drv_if.dma_wait(tid, 3'd0);
        sentinel_axi(AxiInit, CopySize);
        run_copy(TcdmBuf, AxiInit);
        check_axi(AxiInit, CopySize, {1'b0, MemsetByte});

        // The counters must have moved, otherwise every compare above was vacuous
        if (obi_wr_beats != 2*ExpObiBeats) begin
            $fatal(1, "OBI writes total %0d, expected %0d", obi_wr_beats, 2*ExpObiBeats);
        end
        if (obi_rd_beats != 2*ExpObiBeats) begin
            $fatal(1, "OBI reads total %0d, expected %0d", obi_rd_beats, 2*ExpObiBeats);
        end
        if (ev_wr_beats != obi_wr_beats || ev_rd_beats != obi_rd_beats) begin
            $fatal(1, "events counted %0d/%0d OBI wr/rd, the bus sniff saw %0d/%0d",
                   ev_wr_beats, ev_rd_beats, obi_wr_beats, obi_rd_beats);
        end
        if (harness.drv_if.rsp_pending() != 0) begin
            $fatal(1, "%0d unexpected accelerator responses left over",
                   harness.drv_if.rsp_pending());
        end

        if (errors != 0) $fatal(1, "TEST FAILED: %0d errors", errors);
        $display("[TB] TEST PASSED: %0d OBI write and %0d OBI read beats, memset 0x%02x verified",
                 obi_wr_beats, obi_rd_beats, MemsetByte);
        $finish;
    end

    initial begin : test_timeout
        repeat (32'd400000) @(posedge harness.clk);
        $fatal(1, "timeout: the TCDM transfer never retired");
    end

endmodule

// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Two-rule address decode through the tightly-coupled `inst64` frontend. Proves that a
/// second TCDM window (the alias region every real integration enables) reaches the OBI
/// leg, that the primary window still does, and that an unmapped address still falls back
/// to AXI.
module tb_idma_inst64_alias_copy;
    import idma_inst64_tb_pkg::*;

    localparam logic [63:0] TcdmStart      = 64'h0000_0000_1000_0000;
    localparam logic [63:0] TcdmEnd        = 64'h0000_0000_1001_0000;
    localparam logic [63:0] TcdmAliasStart = 64'h0000_0000_2000_0000;
    localparam logic [63:0] TcdmAliasEnd   = 64'h0000_0000_2001_0000;

    idma_inst64_base #(
        .TcdmStart     ( TcdmStart      ),
        .TcdmEnd       ( TcdmEnd        ),
        .TcdmAliasStart( TcdmAliasStart ),
        .TcdmAliasEnd  ( TcdmAliasEnd   )
    ) harness ();

    localparam int unsigned TimeoutCycles = 32'd200000;
    localparam int unsigned CopySize      = 32'd1024;
    localparam int unsigned GuardBytes    = 32'd64;
    localparam logic [7:0]  Sentinel      = 8'h5A;
    localparam logic [7:0]  PatternStart  = 8'hA0;

    // Source and the AXI control destination sit outside both TCDM windows
    localparam addr_t SrcAddr      = 64'h8000_0000;
    localparam addr_t AliasDstAddr = TcdmAliasStart + 64'h100;
    localparam addr_t TcdmDstAddr  = TcdmStart + 64'h100;
    localparam addr_t AxiDstAddr   = 64'h9000_0000;

    int unsigned errors        = 0;
    int unsigned axi_ar_beats  = 0;
    int unsigned axi_aw_beats  = 0;
    int unsigned obi_wr_beats  = 0;
    int unsigned bytes_checked = 0;

    // Snapshots taken around each transfer; the per-transfer deltas are the real check
    int unsigned aw_before, aw_after;
    int unsigned obi_before, obi_after;

    always_ff @(posedge harness.clk) begin : proc_count_bus
        if (harness.rst_n) begin
            if (harness.axi_req[0].ar_valid && harness.axi_res[0].ar_ready) axi_ar_beats++;
            if (harness.axi_req[0].aw_valid && harness.axi_res[0].aw_ready) axi_aw_beats++;
            if (harness.obi_req[0].req && harness.obi_res[0].gnt &&
                harness.obi_req[0].a.we) obi_wr_beats++;
        end
    end

    // The decode must not go metastable; an X index would match every compare vacuously
    a_decode_known : assert property (
        @(posedge harness.clk) disable iff (!harness.rst_n)
        !$isunknown({harness.i_dut.idx_src, harness.i_dut.idx_dst})
    ) else $fatal(1, "address decode index is X: the protocol choice is undefined");

    task automatic seed_source();
        for (int i = 0; i < CopySize; i++) begin
            harness.mem_write_byte(SrcAddr + i, PatternStart + i);
        end
    endtask

    task automatic sentinel_obi(input addr_t base);
        for (int unsigned i = 0; i < CopySize + 2*GuardBytes; i++) begin
            harness.obi_mem_write_byte(base - GuardBytes + i, Sentinel);
        end
    endtask

    task automatic sentinel_axi(input addr_t base);
        for (int unsigned i = 0; i < CopySize + 2*GuardBytes; i++) begin
            harness.mem_write_byte(base - GuardBytes + i, Sentinel);
        end
    endtask

    // `obi` selects which memory the payload is expected in; the other one is not read
    task automatic check_payload(input addr_t base, input bit obi, input string what);
        for (int i = 0; i < CopySize; i++) begin
            logic [7:0] expected;
            logic [7:0] actual;
            expected = PatternStart + i;
            actual   = obi ? harness.obi_mem_read_byte(base + i) : harness.mem_read_byte(base + i);
            bytes_checked++;
            if (actual !== expected) begin
                if (errors < 10) begin
                    $error("%s payload mismatch at offset %0d: expected 0x%02x, got 0x%02x",
                           what, i, expected, actual);
                end
                errors++;
            end
        end
    endtask

    task automatic check_guard_bands(input addr_t base, input bit obi, input string what);
        for (int unsigned i = 1; i <= GuardBytes; i++) begin
            logic [7:0] lo;
            logic [7:0] hi;
            lo = obi ? harness.obi_mem_read_byte(base - i)
                     : harness.mem_read_byte(base - i);
            hi = obi ? harness.obi_mem_read_byte(base + CopySize + i - 1)
                     : harness.mem_read_byte(base + CopySize + i - 1);
            if (lo !== Sentinel) begin
                $error("%s destination underrun at -%0d: got 0x%02x", what, i, lo);
                errors++;
            end
            if (hi !== Sentinel) begin
                $error("%s destination overrun at +%0d: got 0x%02x", what, i, hi);
                errors++;
            end
        end
    endtask

    task automatic run_copy(input addr_t dst);
        tf_id_t tid;
        harness.drv_if.dma_set_source(SrcAddr);
        harness.drv_if.dma_set_dest(dst);
        harness.drv_if.dma_start_copy(CopySize, 2'b00, 3'd0, tid);
        if (harness.drv_if.last_rsp_error !== 1'b0) $fatal(1, "DMCPY response flagged an error");
        harness.drv_if.dma_wait(tid, 3'd0);
    endtask

    initial begin : test_sequence
        @(posedge harness.rst_n);
        repeat (10) @(posedge harness.clk);

        if (harness.NumAddrRules != 32'd2) begin
            $fatal(1, "harness built %0d rules, the alias test needs 2", harness.NumAddrRules);
        end
        // cc_addr_decode allows at most one matching rule
        if (TcdmAliasStart < TcdmEnd && TcdmAliasEnd > TcdmStart) begin
            $fatal(1, "the TCDM and alias windows overlap");
        end

        seed_source();
        sentinel_obi(AliasDstAddr);
        sentinel_obi(TcdmDstAddr);
        sentinel_axi(AxiDstAddr);

        // 1. Alias window: only rule 1 can route this to OBI
        $display("[TB] alias window copy: 0x%0h -> 0x%0h, %0d B", SrcAddr, AliasDstAddr, CopySize);
        aw_before  = axi_aw_beats;
        obi_before = obi_wr_beats;
        run_copy(AliasDstAddr);
        aw_after  = axi_aw_beats;
        obi_after = obi_wr_beats;
        check_payload(AliasDstAddr, 1'b1, "alias");
        check_guard_bands(AliasDstAddr, 1'b1, "alias");
        if (obi_after == obi_before) begin
            $fatal(1, "alias destination issued no OBI write: rule 1 did not decode");
        end
        if (aw_after != aw_before) begin
            $fatal(1, "alias destination issued %0d AXI AW bursts: it escaped to the SoC port",
                   aw_after - aw_before);
        end

        // 2. Primary window still decodes with a second rule present
        $display("[TB] tcdm window copy: 0x%0h -> 0x%0h, %0d B", SrcAddr, TcdmDstAddr, CopySize);
        aw_before  = axi_aw_beats;
        obi_before = obi_wr_beats;
        run_copy(TcdmDstAddr);
        aw_after  = axi_aw_beats;
        obi_after = obi_wr_beats;
        check_payload(TcdmDstAddr, 1'b1, "tcdm");
        check_guard_bands(TcdmDstAddr, 1'b1, "tcdm");
        if (obi_after == obi_before) $fatal(1, "tcdm destination issued no OBI write");
        if (aw_after != aw_before) $fatal(1, "tcdm destination escaped to the SoC port");

        // 3. Unmapped address still falls back to the AXI default index
        $display("[TB] soc copy: 0x%0h -> 0x%0h, %0d B", SrcAddr, AxiDstAddr, CopySize);
        aw_before  = axi_aw_beats;
        obi_before = obi_wr_beats;
        run_copy(AxiDstAddr);
        aw_after  = axi_aw_beats;
        obi_after = obi_wr_beats;
        check_payload(AxiDstAddr, 1'b0, "soc");
        check_guard_bands(AxiDstAddr, 1'b0, "soc");
        if (aw_after == aw_before) $fatal(1, "unmapped destination issued no AXI AW burst");
        if (obi_after != obi_before) begin
            $fatal(1, "unmapped destination issued %0d OBI writes: the default index is wrong",
                   obi_after - obi_before);
        end

        if (bytes_checked != 3*CopySize) begin
            $fatal(1, "compare loop ran %0d times, expected %0d", bytes_checked, 3*CopySize);
        end
        if (axi_ar_beats == 0) $fatal(1, "no AXI read bursts: the source never left the SoC port");
        if (harness.drv_if.rsp_pending() != 0) begin
            $fatal(1, "%0d unexpected accelerator responses left over",
                   harness.drv_if.rsp_pending());
        end

        if (errors != 0) $fatal(1, "TEST FAILED: %0d errors", errors);
        $display({"[TB] TEST PASSED: %0d rules, %0d B compared, ar=%0d aw=%0d AXI bursts, ",
                  "%0d OBI write grants"}, harness.NumAddrRules, bytes_checked, axi_ar_beats,
                 axi_aw_beats, obi_wr_beats);
        $finish;
    end

    initial begin : watchdog
        repeat (TimeoutCycles) @(posedge harness.clk);
        $fatal(1, "simulation timeout after %0d cycles", TimeoutCycles);
    end

endmodule

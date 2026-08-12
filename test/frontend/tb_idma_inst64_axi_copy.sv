// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Single-channel AXI-to-AXI copy through the tightly-coupled `inst64` frontend.
/// Proves the accelerator-bus programming sequence, that exactly one transfer is
/// launched, and that the payload lands byte-exact without overrunning the destination.
module tb_idma_inst64_axi_copy;
    import idma_inst64_tb_pkg::*;

    idma_inst64_base harness ();

    localparam int unsigned TimeoutCycles  = 32'd200000;
    localparam int unsigned CopySize       = 32'd4096;
    localparam int unsigned BytesPerBeat   = AxiDataWidth / 32'd8;
    // Keep the beat rounding: MaskInvalidData is 0 in the inst64 backend, so the full
    // beat-rounded source range must be initialized once CopySize stops being a multiple.
    localparam int unsigned CopyPadBytes   =
        ((CopySize + BytesPerBeat - 1) / BytesPerBeat) * BytesPerBeat;
    localparam int unsigned GuardBytes     = 32'd64;
    localparam logic [7:0]  Sentinel       = 8'h5A;
    localparam logic [7:0]  PatternStart   = 8'hA0;

    localparam addr_t SrcAddr = 64'h8000_0000;
    localparam addr_t DstAddr = 64'h9000_0000;

    int unsigned errors       = 0;
    int unsigned bytes_checked = 0;
    int unsigned axi_ar_beats = 0;
    int unsigned axi_aw_beats = 0;

    // Count AXI address handshakes; a green OBI-never-asserted check is only meaningful
    // if the transfer actually went somewhere.
    always_ff @(posedge harness.clk) begin : proc_count_axi
        if (harness.rst_n) begin
            if (harness.axi_req[0].ar_valid && harness.axi_res[0].ar_ready) axi_ar_beats++;
            if (harness.axi_req[0].aw_valid && harness.axi_res[0].aw_ready) axi_aw_beats++;
        end
    end

    // Both endpoints sit outside the harness TCDM window, so the decoder must fall back to
    // ToSoC/AXI. A rising OBI request means the protocol decode is wrong.
    a_no_obi_traffic : assert property (
        @(posedge harness.clk) disable iff (!harness.rst_n) !harness.obi_req[0].req
    ) else $fatal(1, "OBI leg requested during an AXI-to-AXI transfer: bad protocol decode");

    task automatic seed_memories();
        for (int i = 0; i < CopyPadBytes; i++) begin
            harness.mem_write_byte(SrcAddr + i, (i < CopySize) ? (PatternStart + i) : 8'h00);
        end
        // Sentinel over the destination and its guard bands: an unwritten byte must fail
        // the compare rather than accidentally match, and an overrun must be visible.
        // Offsets stay non-negative; a signed offset added to a 64-bit unsigned address is
        // zero-extended, not sign-extended.
        for (int unsigned i = 0; i < CopySize + 2*GuardBytes; i++) begin
            harness.mem_write_byte(DstAddr - GuardBytes + i, Sentinel);
        end
    endtask

    task automatic check_payload();
        for (int i = 0; i < CopySize; i++) begin
            logic [7:0] expected;
            logic [7:0] actual;
            expected = PatternStart + i;
            actual   = harness.mem_read_byte(DstAddr + i);
            bytes_checked++;
            if (actual !== expected) begin
                if (errors < 10) begin
                    $error("payload mismatch at offset %0d: expected 0x%02x, got 0x%02x",
                           i, expected, actual);
                end
                errors++;
            end
        end
    endtask

    task automatic check_guard_bands();
        for (int unsigned i = 1; i <= GuardBytes; i++) begin
            logic [7:0] lo;
            logic [7:0] hi;
            lo = harness.mem_read_byte(DstAddr - i);
            hi = harness.mem_read_byte(DstAddr + CopySize + i - 1);
            if (lo !== Sentinel) begin
                $error("destination underrun at -%0d: got 0x%02x", i, lo);
                errors++;
            end
            if (hi !== Sentinel) begin
                $error("destination overrun at +%0d: got 0x%02x", i, hi);
                errors++;
            end
        end
    endtask

    initial begin : test_sequence
        tf_id_t      tid;
        logic [63:0] next_id_before;
        logic [63:0] next_id_after;
        logic [31:0] issued_req_id;

        @(posedge harness.rst_n);
        repeat (10) @(posedge harness.clk);

        $display("[TB] inst64 AXI-to-AXI copy: 0x%0h -> 0x%0h, %0d B", SrcAddr, DstAddr, CopySize);
        seed_memories();

        harness.drv_if.dma_poll_status(2'b01, 3'd0, next_id_before);

        harness.drv_if.dma_set_source(SrcAddr);
        harness.drv_if.dma_set_dest(DstAddr);
        harness.drv_if.dma_start_copy(CopySize, 2'b00, 3'd0, tid);
        issued_req_id = harness.drv_if.last_req_id;

        // The driver already fails hard on a bad response; re-check here so the TB states
        // the contract it relies on.
        if (harness.drv_if.last_rsp_error !== 1'b0) begin
            $fatal(1, "DMCPY response flagged an error");
        end
        if (harness.drv_if.last_rsp_id !== issued_req_id) begin
            $fatal(1, "DMCPY response id %0d does not match request id %0d",
                   harness.drv_if.last_rsp_id, issued_req_id);
        end

        harness.drv_if.dma_wait(tid, 3'd0);
        $display("[TB] transfer %0d retired after %0d cycles", tid, harness.drv_if.dma_cycles);

        check_payload();
        check_guard_bands();

        if (bytes_checked != CopySize) begin
            $fatal(1, "compare loop ran %0d times, expected %0d", bytes_checked, CopySize);
        end
        if (CopySize == 0) $fatal(1, "zero-byte golden compare");

        // Exactly one transfer must have been launched. A driver that holds acc_req_valid
        // one cycle too long issues the DMCPY twice; the memory image would look identical.
        harness.drv_if.dma_poll_status(2'b01, 3'd0, next_id_after);
        if (next_id_after !== next_id_before + 1) begin
            $fatal(1, "next_id moved %0d -> %0d, expected exactly one transfer",
                   next_id_before, next_id_after);
        end

        if (axi_ar_beats == 0 || axi_aw_beats == 0) begin
            $fatal(1, "no AXI address handshakes observed (ar=%0d, aw=%0d)",
                   axi_ar_beats, axi_aw_beats);
        end
        if (harness.drv_if.rsp_pending() != 0) begin
            $fatal(1, "%0d unexpected accelerator responses left over",
                   harness.drv_if.rsp_pending());
        end

        if (errors != 0) $fatal(1, "TEST FAILED: %0d errors", errors);
        $display("[TB] TEST PASSED: %0d B copied, ar=%0d aw=%0d beats",
                 bytes_checked, axi_ar_beats, axi_aw_beats);
        $finish;
    end

    initial begin : watchdog
        repeat (TimeoutCycles) @(posedge harness.clk);
        $fatal(1, "simulation timeout after %0d cycles", TimeoutCycles);
    end

endmodule

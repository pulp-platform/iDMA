// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Single-channel AXI-to-AXI copy through the tightly-coupled `inst64` frontend.
/// Proves the accelerator-bus programming sequence, that exactly one transfer is
/// launched, that the payload lands byte-exact without overrunning the destination, and
/// that the exported `dma_events_t` performance counters agree with the bus traffic.
module tb_idma_inst64_axi_copy;
    import idma_inst64_tb_pkg::*;

    idma_inst64_base harness ();

    localparam int unsigned TimeoutCycles  = 32'd200000;
    localparam int unsigned CopySize       = 32'd4096;
    localparam int unsigned BytesPerBeat   = AxiDataWidth / 32'd8;
    // MaskInvalidData is 0 here, so the full beat-rounded range is read
    localparam int unsigned CopyPadBytes   =
        ((CopySize + BytesPerBeat - 1) / BytesPerBeat) * BytesPerBeat;
    localparam int unsigned GuardBytes     = 32'd64;
    localparam logic [7:0]  Sentinel       = 8'h5A;
    localparam logic [7:0]  PatternStart   = 8'hA0;

    // One burst per direction: the copy is 64 B aligned and a whole beat
    localparam int unsigned    ExpDataBeats = CopyPadBytes / BytesPerBeat;
    localparam axi_pkg::len_t  ExpAxLen     = axi_pkg::len_t'(ExpDataBeats - 1);
    localparam axi_pkg::size_t ExpAxSize    = axi_pkg::size_t'($clog2(BytesPerBeat));

    localparam addr_t SrcAddr = 64'h8000_0000;
    localparam addr_t DstAddr = 64'h9000_0000;

    int unsigned errors       = 0;
    int unsigned bytes_checked = 0;
    int unsigned axi_ar_beats = 0;
    int unsigned axi_aw_beats = 0;

    //--------------------------------------
    // DUT event cross-check
    //--------------------------------------
    // Each field recodes a DUT pin, so the TB rebuilds it from those pins
    typedef enum int unsigned {
        EvAwValid, EvAwReady, EvAwDone, EvAwStall, EvAwLen, EvAwSize,
        EvArValid, EvArReady, EvArDone, EvArStall, EvArLen, EvArSize,
        EvRValid,  EvRReady,  EvRDone,  EvRBw,     EvRStall,
        EvWValid,  EvWReady,  EvWDone,  EvWStall,  EvBytes,
        EvBValid,  EvBReady,  EvBDone,  EvBusy,
        EvNumFields
    } ev_field_e;

    localparam int unsigned NumEvFields = EvNumFields;

    // Aliases of the very nets the sniff above reads; they only keep the table readable.
    dma_events_t ev;
    axi_req_t    bus_req;
    axi_resp_t   bus_res;
    assign ev      = harness.events[0];
    assign bus_req = harness.axi_req[0];
    assign bus_res = harness.axi_res[0];

    logic [NumEvFields-1:0] ev_field_ok;

    // len/size compared every cycle, so a stale value fails immediately
    always_comb begin : proc_ev_field_ok
        automatic logic aw_hs = bus_req.aw_valid && bus_res.aw_ready;
        automatic logic ar_hs = bus_req.ar_valid && bus_res.ar_ready;
        automatic logic w_hs  = bus_req.w_valid  && bus_res.w_ready;

        ev_field_ok[EvAwValid] = ev.aw_valid === bus_req.aw_valid;
        ev_field_ok[EvAwReady] = ev.aw_ready === bus_res.aw_ready;
        ev_field_ok[EvAwDone ] = ev.aw_done  === aw_hs;
        ev_field_ok[EvAwStall] = ev.aw_stall === (bus_req.aw_valid && !bus_res.aw_ready);
        ev_field_ok[EvAwLen  ] = ev.aw_len   === (aw_hs ? bus_req.aw.len  : 8'd0);
        ev_field_ok[EvAwSize ] = ev.aw_size  === (aw_hs ? bus_req.aw.size : 3'd0);

        ev_field_ok[EvArValid] = ev.ar_valid === bus_req.ar_valid;
        ev_field_ok[EvArReady] = ev.ar_ready === bus_res.ar_ready;
        ev_field_ok[EvArDone ] = ev.ar_done  === ar_hs;
        ev_field_ok[EvArStall] = ev.ar_stall === (bus_req.ar_valid && !bus_res.ar_ready);
        ev_field_ok[EvArLen  ] = ev.ar_len   === (ar_hs ? bus_req.ar.len  : 8'd0);
        ev_field_ok[EvArSize ] = ev.ar_size  === (ar_hs ? bus_req.ar.size : 3'd0);

        ev_field_ok[EvRValid ] = ev.r_valid  === bus_res.r_valid;
        ev_field_ok[EvRReady ] = ev.r_ready  === bus_req.r_ready;
        ev_field_ok[EvRDone  ] = ev.r_done   === (bus_req.r_ready && bus_res.r_valid);
        // r_bw duplicates r_done in the RTL; compare it to the pins, never to ev.r_done.
        ev_field_ok[EvRBw    ] = ev.r_bw     === (bus_req.r_ready && bus_res.r_valid);
        ev_field_ok[EvRStall ] = ev.r_stall  === (bus_req.r_ready && !bus_res.r_valid);

        ev_field_ok[EvWValid ] = ev.w_valid  === bus_req.w_valid;
        ev_field_ok[EvWReady ] = ev.w_ready  === bus_res.w_ready;
        ev_field_ok[EvWDone  ] = ev.w_done   === w_hs;
        ev_field_ok[EvWStall ] = ev.w_stall  === (bus_req.w_valid && !bus_res.w_ready);
        ev_field_ok[EvBytes  ] = ev.num_bytes_written ===
                                 (w_hs ? 32'($countones(bus_req.w.strb)) : 32'd0);

        ev_field_ok[EvBValid ] = ev.b_valid  === bus_res.b_valid;
        ev_field_ok[EvBReady ] = ev.b_ready  === bus_req.b_ready;
        ev_field_ok[EvBDone  ] = ev.b_done   === (bus_req.b_ready && bus_res.b_valid);

        ev_field_ok[EvBusy   ] = ev.dma_busy === harness.busy[0];
    end

    // One assertion per field so a failure names it
    for (genvar f = 0; f < NumEvFields; f++) begin : gen_ev_field_check
        localparam ev_field_e Field = ev_field_e'(f);
        a_ev_field : assert property (
            @(posedge harness.clk) disable iff (!harness.rst_n) ev_field_ok[f]
        ) else $fatal(1, "events.%s disagrees with the AXI pins", Field.name());
    end

    // events_o has no reset, so an X on both sides would match vacuously
    a_ev_pins_known : assert property (
        @(posedge harness.clk) disable iff (!harness.rst_n)
        !$isunknown({bus_req.aw_valid, bus_req.ar_valid, bus_req.w_valid, bus_req.r_ready,
                     bus_req.b_ready,  bus_res.aw_ready, bus_res.ar_ready, bus_res.w_ready,
                     bus_res.r_valid,  bus_res.b_valid,  harness.busy[0]})
    ) else $fatal(1, "AXI handshake pin is X: the events comparison would match vacuously");

    int unsigned ev_ar_beats      = 0;
    int unsigned ev_aw_beats      = 0;
    int unsigned ev_r_beats       = 0;
    int unsigned ev_r_bw_beats    = 0;
    int unsigned ev_w_beats       = 0;
    int unsigned ev_b_beats       = 0;
    int unsigned ev_busy_cycles   = 0;
    int unsigned ev_bytes_written = 0;
    axi_pkg::len_t  ev_ar_len_seen,  ev_aw_len_seen;
    axi_pkg::size_t ev_ar_size_seen, ev_aw_size_seen;

    // Count AXI handshakes; the OBI-never-asserted check needs real traffic
    always_ff @(posedge harness.clk) begin : proc_count_axi
        if (harness.rst_n) begin
            if (harness.axi_req[0].ar_valid && harness.axi_res[0].ar_ready) axi_ar_beats++;
            if (harness.axi_req[0].aw_valid && harness.axi_res[0].aw_ready) axi_aw_beats++;
            if (ev.ar_done) begin
                ev_ar_beats++;
                ev_ar_len_seen  <= ev.ar_len;
                ev_ar_size_seen <= ev.ar_size;
            end
            if (ev.aw_done) begin
                ev_aw_beats++;
                ev_aw_len_seen  <= ev.aw_len;
                ev_aw_size_seen <= ev.aw_size;
            end
            if (ev.r_done)   ev_r_beats++;
            if (ev.r_bw)     ev_r_bw_beats++;
            if (ev.w_done)   ev_w_beats++;
            if (ev.b_done)   ev_b_beats++;
            if (ev.dma_busy) ev_busy_cycles++;
            ev_bytes_written += ev.num_bytes_written;
        end
    end

    // Both endpoints sit outside the TCDM window, so the decoder picks AXI
    a_no_obi_traffic : assert property (
        @(posedge harness.clk) disable iff (!harness.rst_n) !harness.obi_req[0].req
    ) else $fatal(1, "OBI leg requested during an AXI-to-AXI transfer: bad protocol decode");

    task automatic seed_memories();
        for (int i = 0; i < CopyPadBytes; i++) begin
            harness.mem_write_byte(SrcAddr + i, (i < CopySize) ? (PatternStart + i) : 8'h00);
        end
        // Sentinel the destination and guard bands so an overrun fails the compare
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

        // Re-checked here so the TB states the contract it relies on
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

        // Exactly one launch; a stuck acc_req_valid would issue two
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

        // Event totals against the independent sniff, then the transfer geometry
        if (ev_ar_beats != axi_ar_beats || ev_aw_beats != axi_aw_beats) begin
            $fatal(1, "events ar/aw done (%0d/%0d) disagree with the bus sniff (%0d/%0d)",
                   ev_ar_beats, ev_aw_beats, axi_ar_beats, axi_aw_beats);
        end
        if (ev_b_beats != axi_aw_beats) begin
            $fatal(1, "events counted %0d B responses for %0d AW bursts",
                   ev_b_beats, axi_aw_beats);
        end
        if (ev_r_beats != ExpDataBeats || ev_r_bw_beats != ExpDataBeats ||
            ev_w_beats != ExpDataBeats) begin
            $fatal(1, "events data beats r=%0d r_bw=%0d w=%0d, expected %0d each",
                   ev_r_beats, ev_r_bw_beats, ev_w_beats, ExpDataBeats);
        end
        if (ev_bytes_written != bytes_checked) begin
            $fatal(1, "events reported %0d B written, TB verified %0d B",
                   ev_bytes_written, bytes_checked);
        end
        if (ev_ar_len_seen !== ExpAxLen || ev_aw_len_seen !== ExpAxLen ||
            ev_ar_size_seen !== ExpAxSize || ev_aw_size_seen !== ExpAxSize) begin
            $fatal(1, "events ax len/size ar=%0d/%0d aw=%0d/%0d, expected %0d/%0d",
                   ev_ar_len_seen, ev_ar_size_seen, ev_aw_len_seen, ev_aw_size_seen,
                   ExpAxLen, ExpAxSize);
        end
        if (ev_busy_cycles == 0) $fatal(1, "events never reported the DMA busy");

        if (errors != 0) $fatal(1, "TEST FAILED: %0d errors", errors);
        $display("[TB] TEST PASSED: %0d B copied, ar=%0d aw=%0d beats", bytes_checked,
                 axi_ar_beats, axi_aw_beats);
        $display({"[TB] events cross-checked vs bus pins: %0d fields every cycle; totals ",
                  "ar=%0d aw=%0d b=%0d r=%0d r_bw=%0d w=%0d beats, len=%0d size=%0d, ",
                  "%0d B written, busy %0d cycles"},
                 NumEvFields, ev_ar_beats, ev_aw_beats, ev_b_beats, ev_r_beats,
                 ev_r_bw_beats, ev_w_beats, ev_aw_len_seen, ev_aw_size_seen,
                 ev_bytes_written, ev_busy_cycles);
        $finish;
    end

    initial begin : watchdog
        repeat (TimeoutCycles) @(posedge harness.clk);
        $fatal(1, "simulation timeout after %0d cycles", TimeoutCycles);
    end

endmodule

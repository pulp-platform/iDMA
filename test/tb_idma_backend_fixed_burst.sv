// Copyright 2026 Mosaic SoC.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Luca Rufer <luca@mosaic-soc.com>

// Testbench for AXI FIXED-burst support on the single-port AXI backend (idma_backend_rw_axi).
// Three burst-type scenarios are checked:
// - FIXED src -> INCR dst: every read beat targets the same source
//   word, so the one word is copied out to `num_beats` sequential
//   destination copies.
// - INCR src -> FIXED dst: every write beat targets the same
//   destination word, so the sequential source words are gathered down to
//   whichever one is written *last*, which is the only one that survives.
// - FIXED src -> FIXED dst: every beat is from the same to the same address.
// On these scenarios, the following kind of tests are performed:
// - Simple single-burst tests: transfers below the 16-beat FIXED-burst limit
// - Multi-burst tests: transfers above the 16-beat FIXED-burst limit, checking
//   that the burst is correctly split into multiple bursts.
// - Page-boundary split tests: transfers that cross a 4K page boundary on the
//   non-FIXED side, checking that the FIXED burst is also correctly split into
//   multiple bursts.
// - user-constrained llen tests: transfers that are split due to the
//   user-specified max_llen, checking that the llen reduction is correctly
//   applied to the FIXED bursts.
// - Narrow tests: transfers that are narrower than the bus width
// - Partial tests: transfers that are not a multiple of the bus width, so the
//   last beat is partial and the second-to-last beat is the last full beat.

`timescale 1ns/1ns
`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_backend_fixed_burst import idma_pkg::*; #(
    parameter int unsigned BufferDepth      = 3,
    parameter int unsigned NumAxInFlight    = 3,
    parameter int unsigned DataWidth        = 32,
    parameter int unsigned AddrWidth        = 32,
    parameter int unsigned UserWidth        = 1,
    parameter int unsigned AxiIdWidth       = 3,
    parameter int unsigned TFLenWidth       = 32,
    parameter int unsigned MemSysDepth      = 0,
    parameter bit          CombinedShifter  = 1'b0,
    parameter int unsigned WatchDogNumCycles = 2000
);

    localparam time TA  = 1ns;
    localparam time TT  = 9ns;
    localparam time TCK = 10ns;

    localparam int unsigned StrbWidth   = DataWidth / 8;
    localparam idma_pkg::error_cap_e ErrorCap = idma_pkg::NO_ERROR_HANDLING;

    typedef logic [7:0]             byte_t;
    typedef logic [AddrWidth-1:0]   addr_t;
    typedef logic [DataWidth-1:0]   data_t;
    typedef logic [StrbWidth-1:0]   strb_t;
    typedef logic [UserWidth-1:0]   user_t;
    typedef logic [AxiIdWidth-1:0]  id_t;
    typedef logic [TFLenWidth-1:0]  tf_len_t;

    `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
    `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)
    `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)
    `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
    `AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)

    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

    typedef struct packed { axi_ar_chan_t ar_chan; } axi_read_meta_channel_t;
    typedef struct packed { axi_read_meta_channel_t axi; } read_meta_channel_t;
    typedef struct packed { axi_aw_chan_t aw_chan; } axi_write_meta_channel_t;
    typedef struct packed { axi_write_meta_channel_t axi; } write_meta_channel_t;

    // Clock / reset
    logic clk;
    logic rst_n;

    // DMA request / response
    idma_req_t idma_req;
    logic req_valid, req_ready;
    idma_rsp_t idma_rsp;
    logic rsp_valid, rsp_ready;
    idma_eh_req_t idma_eh_req;
    logic eh_req_valid, eh_req_ready;
    idma_busy_t busy;

    // Single read master bus, single write master bus
    axi_req_t axi_read_req, axi_write_req;
    axi_rsp_t axi_read_rsp, axi_write_rsp;

    // Driver
    IDMA_DV #(
        .DataWidth  (DataWidth),
        .AddrWidth  (AddrWidth),
        .UserWidth  (UserWidth),
        .AxiIdWidth (AxiIdWidth),
        .TFLenWidth (TFLenWidth)
    ) idma_dv (clk);

    typedef idma_test::idma_driver #(
        .DataWidth  (DataWidth),
        .AddrWidth  (AddrWidth),
        .UserWidth  (UserWidth),
        .AxiIdWidth (AxiIdWidth),
        .TFLenWidth (TFLenWidth),
        .TA         (TA),
        .TT         (TT)
    ) drv_t;
    drv_t drv = new(idma_dv);

    assign idma_req         = idma_dv.req;
    assign req_valid        = idma_dv.req_valid;
    // TB only inspects the written memory; keep rsp_ready asserted so the read
    // datapath can drain R into the buffer.
    assign rsp_ready        = 1'b1;
    assign idma_eh_req      = idma_dv.eh_req;
    assign eh_req_valid     = idma_dv.eh_req_valid;
    assign idma_dv.req_ready    = req_ready;
    assign idma_dv.rsp          = idma_rsp;
    assign idma_dv.rsp_valid    = rsp_valid;
    assign idma_dv.eh_req_ready = eh_req_ready;

    clk_rst_gen #(
        .ClkPeriod    (TCK),
        .RstClkCycles (1)
    ) i_clk_rst_gen (
        .clk_o  (clk),
        .rst_no (rst_n)
    );

    // Monitor taps used to check the FIXED side's beat count and address
    // constancy. Transaction (burst) counts are derived from the AR/AW
    // handshakes directly below instead, since they're immune to W-channel
    // stalls and don't depend on axi_sim_mem's `last` monitor output.
    logic          mon_r_valid;
    addr_t         mon_r_addr;
    logic          mon_w_valid;
    addr_t         mon_w_addr;

    // Read-side memory (Source)
    axi_sim_mem #(
        .AddrWidth         (AddrWidth),
        .DataWidth         (DataWidth),
        .IdWidth           (AxiIdWidth),
        .UserWidth         (UserWidth),
        .axi_req_t         (axi_req_t),
        .axi_rsp_t         (axi_rsp_t),
        .WarnUninitialized (1'b0),
        .ClearErrOnAccess  (1'b1),
        .ApplDelay         (TA),
        .AcqDelay          (TT)
    ) i_read_mem (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .axi_req_i          (axi_read_req),
        .axi_rsp_o          (axi_read_rsp),
        .mon_r_valid_o      (mon_r_valid),
        .mon_r_addr_o       (mon_r_addr),
        .mon_r_last_o       (),
        .mon_r_beat_count_o (),
        .mon_r_user_o       (),
        .mon_r_id_o         (),
        .mon_r_data_o       (),
        .mon_w_last_o       (),
        .mon_w_beat_count_o (),
        .mon_w_user_o       (),
        .mon_w_id_o         (),
        .mon_w_data_o       (),
        .mon_w_addr_o       (),
        .mon_w_valid_o      ()
    );

    // Write-side memory (Destination)
    axi_sim_mem #(
        .AddrWidth         (AddrWidth),
        .DataWidth         (DataWidth),
        .IdWidth           (AxiIdWidth),
        .UserWidth         (UserWidth),
        .axi_req_t         (axi_req_t),
        .axi_rsp_t         (axi_rsp_t),
        .WarnUninitialized (1'b0),
        .ClearErrOnAccess  (1'b1),
        .ApplDelay         (TA),
        .AcqDelay          (TT)
    ) i_write_mem (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .axi_req_i          (axi_write_req),
        .axi_rsp_o          (axi_write_rsp),
        .mon_r_last_o       (),
        .mon_r_beat_count_o (),
        .mon_r_user_o       (),
        .mon_r_id_o         (),
        .mon_r_data_o       (),
        .mon_r_addr_o       (),
        .mon_r_valid_o      (),
        .mon_w_valid_o      (mon_w_valid),
        .mon_w_addr_o       (mon_w_addr),
        .mon_w_last_o       (),
        .mon_w_beat_count_o (),
        .mon_w_user_o       (),
        .mon_w_id_o         (),
        .mon_w_data_o       ()
    );

    idma_backend_rw_axi #(
        .CombinedShifter      (CombinedShifter),
        .DataWidth            (DataWidth),
        .AddrWidth            (AddrWidth),
        .AxiIdWidth           (AxiIdWidth),
        .UserWidth            (UserWidth),
        .TFLenWidth           (TFLenWidth),
        .BufferDepth          (BufferDepth),
        .RAWCouplingAvail     (1'b0),
        .MaskInvalidData      (1'b1),
        .HardwareLegalizer    (1'b1),
        .RejectZeroTransfers  (1'b1),
        .ErrorCap             (ErrorCap),
        .PrintFifoInfo        (1'b0),
        .NumAxInFlight        (NumAxInFlight),
        .MemSysDepth          (MemSysDepth),
        .idma_req_t           (idma_req_t),
        .idma_rsp_t           (idma_rsp_t),
        .idma_eh_req_t        (idma_eh_req_t),
        .idma_busy_t          (idma_busy_t),
        .axi_req_t            (axi_req_t),
        .axi_rsp_t            (axi_rsp_t),
        .write_meta_channel_t (write_meta_channel_t),
        .read_meta_channel_t  (read_meta_channel_t)
    ) i_idma_backend (
        .clk_i           (clk),
        .rst_ni          (rst_n),
        .idma_req_i      (idma_req),
        .req_valid_i     (req_valid),
        .req_ready_o     (req_ready),
        .idma_rsp_o      (idma_rsp),
        .rsp_valid_o     (rsp_valid),
        .rsp_ready_i     (rsp_ready),
        .idma_eh_req_i   (idma_eh_req),
        .eh_req_valid_i  (eh_req_valid),
        .eh_req_ready_o  (eh_req_ready),
        .axi_read_req_o  (axi_read_req),
        .axi_read_rsp_i  (axi_read_rsp),
        .axi_write_req_o (axi_write_req),
        .axi_write_rsp_i (axi_write_rsp),
        .busy_o          (busy)
    );

    // ----------------------------------------------------------------------
    // Stimulus
    // ----------------------------------------------------------------------
    int unsigned errors = 0;

    // Test number used to generate a unique seed for each test
    int unsigned test_no = 1;

    // Clear both simulation memories
    task automatic clear_mem ();
        i_read_mem.mem.delete();
        i_write_mem.mem.delete();
    endtask

    function automatic byte_t gen_data(input addr_t addr, input byte seed);
        return seed ^ addr[7:0];
    endfunction

    // Preload read memory with a deterministic pattern
    task automatic preload (input addr_t base, input int unsigned len, input byte_t seed);
        for (int unsigned i = 0; i < len; i++)
            i_read_mem.mem[base + i] = gen_data(i, seed);
    endtask

    // Check that write memory at `base` expected pattern for an continuous write
    task automatic check_fixed_to_fixed (input string label, input addr_t base,
                                         input int unsigned len, input byte_t seed);
        byte_t got, exp;
        for (int unsigned i = 0; i < len; i++) begin
            exp = gen_data(i, seed);
            if (!i_write_mem.mem.exists(base + i)) begin
                errors++;
                $error("[%s] Write @0x%h: Address never written", label, base + i);
                continue;
            end
            got = i_write_mem.mem[base + i];
            if (got !== exp) begin
                errors++;
                $error("[%s] Write @0x%h: got 0x%h exp 0x%h", label, base + i, got, exp);
            end
        end
        $display("[%s] Write @0x%h len %0d: OK", label, base, len);
    endtask

    // Check that write memory at `base` holds the expected pattern for a FIXED write, a repeating
    // pattern of `StrbWidth` bytes.
    task automatic check_fixed_to_incr (input string label, input addr_t base,
                                        input int unsigned length, input byte_t seed);
        byte_t got, exp;
        for (int unsigned i = 0; i < length; i++) begin
            exp = gen_data(i % StrbWidth, seed);
            if (!i_write_mem.mem.exists(base + i)) begin
                errors++;
                $error("[%s] Write @0x%h: Address never written", label, base + i);
                continue;
            end
            got = i_write_mem.mem[base + i];
            if (got !== exp) begin
                errors++;
                $error("[%s] Write @0x%h: got 0x%h exp 0x%h", label, base + i, got, exp);
            end
        end
        $display("[%s] Write @0x%h len %0d: OK", label, base, length);
    endtask

    // Check that write memory at `base` holds the expected pattern for a FIXED
    // write fed by an INCR source of `length` bytes.
    // The expected pattern is the last beat of the INCR source, and possibly
    // the second-to-last beat if the last beat is partial.
    task automatic check_incr_to_fixed (input string label, input addr_t base,
                                        input int unsigned length, input byte_t seed);
        int unsigned exp_beats, tailer, checked_len;
        byte_t got, exp;
        exp_beats   = (length + StrbWidth - 1) / StrbWidth;
        tailer      = length % StrbWidth;
        checked_len = (tailer == 0) ? StrbWidth : ((exp_beats == 1) ? tailer : StrbWidth);
        for (int unsigned i = 0; i < checked_len; i++) begin
            int unsigned from_beat = (tailer == 0 || i < tailer) ? exp_beats - 1 : exp_beats - 2;
            exp = gen_data(from_beat * StrbWidth + i, seed);
            if (!i_write_mem.mem.exists(base + i)) begin
                errors++;
                $error("[%s] Write @0x%h: Address never written", label, base + i);
                continue;
            end
            got = i_write_mem.mem[base + i];
            if (got !== exp) begin
                errors++;
                $error("[%s] Write @0x%h: got 0x%h exp 0x%h", label, base + i, got, exp);
            end
        end
        $display("[%s] Write @0x%h len %0d: OK", label, base, checked_len);
    endtask

    // Background monitors to check beat count, transaction count, and
    // addresses for FIXED side bursts.
    int unsigned r_beats, w_beats;
    int unsigned r_txns, w_txns;
    logic        r_addr_ok, w_addr_ok;
    addr_t       r_exp_addr, w_exp_addr;

    function automatic void reset_read_monitor (input addr_t exp_addr);
        r_beats    = 0;
        r_txns     = 0;
        r_addr_ok  = 1'b1;
        r_exp_addr = exp_addr;
    endfunction

    function automatic void reset_write_monitor (input addr_t exp_addr);
        w_beats    = 0;
        w_txns     = 0;
        w_addr_ok  = 1'b1;
        w_exp_addr = exp_addr;
    endfunction

    initial begin
        r_beats   = 0;
        r_txns    = 0;
        r_addr_ok = 1'b1;

        @(posedge rst_n);

        forever begin
            @(posedge clk);
            if (axi_read_req.ar_valid && axi_read_rsp.ar_ready) r_txns++;
            #(TT);
            if (mon_r_valid) begin
                r_beats++;
                if (mon_r_addr != r_exp_addr) r_addr_ok = 1'b0;
            end
        end
    end

    initial begin
        w_beats   = 0;
        w_txns    = 0;
        w_addr_ok = 1'b1;

        @(posedge rst_n);

        forever begin
            @(posedge clk);
            if (axi_write_req.aw_valid && axi_write_rsp.aw_ready) w_txns++;
            #(TT);
            if (mon_w_valid) begin
                w_beats++;
                if (mon_w_addr != w_exp_addr) w_addr_ok = 1'b0;
            end
        end
    end

    // Wait for the transfer to finish. When `mon_read` (resp. `mon_write`) is
    // set, checks that the read (resp. write) monitor saw exactly `exp_beats`
    // FIXED-side beats, split into exactly `exp_txns` AR/AW transactions, with
    // the address held constant throughout.
    task automatic wait_done (input string label = "", input int unsigned exp_beats = 0,
                              input bit mon_read = 1'b0, input bit mon_write = 1'b0,
                              input int unsigned exp_txns = 1);
        @(posedge clk);
        while (busy != '0) @(posedge clk);
        repeat (5) @(posedge clk);

        if (mon_read) begin
            if (r_beats !== exp_beats) begin
                errors++;
                $error("[%s] AR: got %0d beats, exp %0d", label, r_beats, exp_beats);
            end
            if (r_txns !== exp_txns) begin
                errors++;
                $error("[%s] AR: got %0d transaction(s), exp %0d", label, r_txns, exp_txns);
            end
            if (!r_addr_ok) begin
                errors++;
                $error("[%s] AR: address was not constant across the FIXED burst", label);
            end
        end
        if (mon_write) begin
            if (w_beats !== exp_beats) begin
                errors++;
                $error("[%s] AW: got %0d beats, exp %0d", label, w_beats, exp_beats);
            end
            if (w_txns !== exp_txns) begin
                errors++;
                $error("[%s] AW: got %0d transaction(s), exp %0d", label, w_txns, exp_txns);
            end
            if (!w_addr_ok) begin
                errors++;
                $error("[%s] AW: address was not constant across the FIXED burst", label);
            end
        end
    endtask

    // FIXED src (one word, repeatedly read) -> INCR dst (length bytes, sequential).
    task automatic fixed_to_incr_test (input string label, input int unsigned length,
                                       input addr_t src = 32'h0000_1000,
                                       input addr_t dst = 32'h0000_2000,
                                       input int unsigned exp_txns = 1,
                                       input logic [2:0] src_max_llen = 3'd0,
                                       input bit src_reduce_len = 1'b0);
        int unsigned exp_beats;
        byte_t seed;
        seed = byte_t'(test_no++);
        exp_beats = (length + StrbWidth - 1) / StrbWidth;
        clear_mem();
        preload(src, StrbWidth, seed);
        reset_read_monitor(src);
        drv.launch_tf(.length (length), .src_addr (src), .dst_addr (dst),
                      .src_protocol (idma_pkg::AXI), .dst_protocol (idma_pkg::AXI),
                      .decouple_aw (1'b0), .decouple_rw (1'b0),
                      .src_max_llen (src_max_llen), .dst_max_llen (3'd0),
                      .src_reduce_len (src_reduce_len), .dst_reduce_len (1'b0), .id ('0),
                      .src_burst (axi_pkg::BURST_FIXED), .dst_burst (axi_pkg::BURST_INCR));
        wait_done(.label (label), .exp_beats (exp_beats), .mon_read (1'b1), .exp_txns (exp_txns));
        check_fixed_to_incr(label, dst, length, seed);
    endtask

    // INCR src (length bytes, sequential) -> FIXED dst (one word: last beat remains).
    task automatic incr_to_fixed_test (input string label, input int unsigned length,
                                       input addr_t src = 32'h0000_1000,
                                       input addr_t dst = 32'h0000_2000,
                                       input int unsigned exp_txns = 1,
                                       input logic [2:0] dst_max_llen = 3'd0,
                                       input bit dst_reduce_len = 1'b0);
        int unsigned exp_beats;
        byte_t seed;
        seed = byte_t'(test_no++);
        exp_beats = (length + StrbWidth - 1) / StrbWidth;
        clear_mem();
        preload(src, length, seed);
        reset_write_monitor(dst);
        drv.launch_tf(.length (length), .src_addr (src), .dst_addr (dst),
                      .src_protocol (idma_pkg::AXI), .dst_protocol (idma_pkg::AXI),
                      .decouple_aw (1'b0), .decouple_rw (1'b0),
                      .src_max_llen (3'd0), .dst_max_llen (dst_max_llen),
                      .src_reduce_len (1'b0), .dst_reduce_len (dst_reduce_len), .id ('0),
                      .src_burst (axi_pkg::BURST_INCR), .dst_burst (axi_pkg::BURST_FIXED));
        wait_done(.label (label), .exp_beats (exp_beats), .mon_write (1'b1), .exp_txns (exp_txns));
        check_incr_to_fixed(label, dst, length, seed);
    endtask

    // FIXED src -> FIXED dst: same one word on both ends, repeated length/StrbWidth times.
    task automatic fixed_to_fixed_test (input string label, input int unsigned length,
                                        input addr_t src = 32'h0000_1000,
                                        input addr_t dst = 32'h0000_2000,
                                        input int unsigned exp_txns = 1,
                                        input logic [2:0] src_max_llen = 3'd0,
                                        input bit src_reduce_len = 1'b0,
                                        input logic [2:0] dst_max_llen = 3'd0,
                                        input bit dst_reduce_len = 1'b0);
        int unsigned exp_beats;
        byte_t seed;
        seed = byte_t'(test_no++);
        exp_beats = (length + StrbWidth - 1) / StrbWidth;
        clear_mem();
        preload(src, StrbWidth, seed);
        reset_read_monitor(src);
        reset_write_monitor(dst);
        drv.launch_tf(.length (length), .src_addr (src), .dst_addr (dst),
                      .src_protocol (idma_pkg::AXI), .dst_protocol (idma_pkg::AXI),
                      .decouple_aw (1'b0), .decouple_rw (1'b0),
                      .src_max_llen (src_max_llen), .dst_max_llen (dst_max_llen),
                      .src_reduce_len (src_reduce_len), .dst_reduce_len (dst_reduce_len), .id ('0),
                      .src_burst (axi_pkg::BURST_FIXED), .dst_burst (axi_pkg::BURST_FIXED));
        wait_done(.label (label), .exp_beats (exp_beats), .mon_read (1'b1), .mon_write (1'b1),
                  .exp_txns (exp_txns));
        check_fixed_to_fixed(label, dst, StrbWidth, seed);
    endtask

    // AXI4 caps a FIXED burst at 16 beats; use more to force the legalizer
    // to split into multiple same-address sub-bursts instead of a single burst.
    localparam int unsigned NumBeatsMulti = 40;

    // llen reduction used in the llen reduction tests.
    localparam logic [2:0] MaxLlenReduce = 3'd2; // 4 beats

    initial begin
        drv.reset_driver();
        @(posedge rst_n);
        repeat (4) @(posedge clk);

        // Single sub-burst smoke tests
        fixed_to_incr_test("fixed_to_incr_small", 4 * StrbWidth);
        incr_to_fixed_test("incr_to_fixed_small", 4 * StrbWidth);
        fixed_to_fixed_test("fixed_to_fixed", 4 * StrbWidth);

        // Multi sub-burst: exercises the burst length limiting for the FIXED side
        fixed_to_incr_test("fixed_to_incr_multi", NumBeatsMulti * StrbWidth,
                           .exp_txns ((NumBeatsMulti + 15) / 16));
        incr_to_fixed_test("incr_to_fixed_multi", NumBeatsMulti * StrbWidth,
                           .exp_txns ((NumBeatsMulti + 15) / 16));

        // Page-boundary split: the INCR side starts 2 beats before a 4K page
        // boundary, so 4 beats force the legalizer's page splitter to split the
        // burst, exercising that split against a FIXED side that must hold its
        // address across it.
        fixed_to_incr_test("fixed_to_incr_pagesplit", 4 * StrbWidth,
                           .src (32'h0000_1000), .dst (32'h0000_2000 - 2 * StrbWidth),
                           .exp_txns (2));
        incr_to_fixed_test("incr_to_fixed_pagesplit", 4 * StrbWidth,
                           .src (32'h0000_1000 - 2 * StrbWidth), .dst (32'h0000_2000),
                           .exp_txns (2));

        // llen reduction on the FIXED side
        fixed_to_incr_test("fixed_to_incr_llen_reduce", 8 * StrbWidth,
                           .exp_txns (8 / (1 << MaxLlenReduce)),
                           .src_max_llen (MaxLlenReduce), .src_reduce_len (1'b1));
        incr_to_fixed_test("incr_to_fixed_llen_reduce", 8 * StrbWidth,
                           .exp_txns (8 / (1 << MaxLlenReduce)),
                           .dst_max_llen (MaxLlenReduce), .dst_reduce_len (1'b1));

        // Narrow tests where length < StrbWidth
        for (int unsigned i = 1; i < StrbWidth; i++) begin
            fixed_to_incr_test($sformatf("fixed_to_incr_narrow_%0d", i), i);
            incr_to_fixed_test($sformatf("incr_to_fixed_narrow_%0d", i), i);
        end

        // Partial tests where the length is not a multiple of StrbWidth
        fixed_to_incr_test("fixed_to_incr_partial", 2 * StrbWidth - 1);
        incr_to_fixed_test("incr_to_fixed_partial", 2 * StrbWidth - 1);

        if (errors == 0)
            $display("[tb_idma_backend_fixed_burst] ALL CHECKS PASSED");
        else
            $fatal(1, "[tb_idma_backend_fixed_burst] %0d errors", errors);
        $finish;
    end

    // Global watchdog
    initial begin
        repeat (WatchDogNumCycles * 5) @(posedge clk);
        $fatal(1, "[tb_idma_backend_fixed_burst] watchdog timeout");
    end

endmodule

// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "axi/typedef.svh"

/// The `inst64` busy status (DMSTAT 2) must stay set until the last write response returns.
/// B responses return one at a time, at least `BLatency` cycles apart; a multi-burst 1D copy
/// and a 2D copy with one short burst per row are each waited on through the busy poll alone.
module tb_idma_inst64_busy #(
    parameter int unsigned AxiDataWidth  = 32'd512,
    parameter int unsigned NumAxInFlight = 32'd24,
    parameter int unsigned BLatency      = 32'd200
);

    localparam int unsigned AxiAddrWidth = 32'd48;
    localparam int unsigned AxiUserWidth = 32'd1;
    localparam int unsigned AxiIdWidth   = 32'd4;
    localparam int unsigned StrbWidth    = AxiDataWidth / 32'd8;

    localparam time         Period       = 10ns;
    localparam time         ApplDelay    = Period / 4;
    localparam time         AcqDelay     = Period * 3 / 4;
    localparam int unsigned ResetCycles  = 32'd10;
    localparam int unsigned HangCycles   = 32'd400000;
    localparam int unsigned MaxPolls     = 32'd20000;
    localparam int unsigned RspTimeout   = 32'd10000;

    typedef logic [AxiAddrWidth-1:0] addr_t;
    typedef logic [AxiDataWidth-1:0] data_t;
    typedef logic [StrbWidth-1:0]    strb_t;
    typedef logic [AxiUserWidth-1:0] user_t;
    typedef logic [AxiIdWidth-1:0]   id_t;

    localparam addr_t       SrcAddr    = 48'h0000_8000_0003;
    localparam addr_t       DstAddr    = 48'h0000_9000_0041;
    localparam addr_t       Dst2dAddr  = 48'h0000_a000_0000;
    localparam int unsigned CopyBytes  = 32'd12388;
    localparam int unsigned NumRows    = NumAxInFlight + 32'd8;
    localparam int unsigned RowBytes   = 32'd64;
    localparam int unsigned RowStride  = 32'd256;
    localparam int unsigned InitBytes  = NumRows * RowStride + CopyBytes + 32'd1024;

    `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)

    // Snitch accelerator bus
    typedef struct packed {
        logic [31:0] id;
        logic [31:0] data_op;
        logic [63:0] data_arga;
        logic [63:0] data_argb;
    } acc_req_t;

    typedef struct packed {
        logic [31:0] id;
        logic [63:0] data;
        logic        error;
    } acc_res_t;

    typedef struct packed {
        logic                       aw_stall, ar_stall, r_stall, w_stall;
        logic                       buf_w_stall, buf_r_stall;
        logic                       aw_valid, aw_ready, aw_done;
        logic                       ar_valid, ar_ready, ar_done;
        logic                       r_valid, r_ready, r_done, r_bw;
        logic                       w_valid, w_ready, w_done;
        logic                       b_valid, b_ready, b_done;
        logic                       dma_busy;
        axi_pkg::len_t              aw_len, ar_len;
        axi_pkg::size_t             aw_size, ar_size;
        logic [$clog2(StrbWidth):0] num_bytes_written;
    } dma_events_t;

    logic clk, rst_n;

    clk_rst_gen #(
        .ClkPeriod    ( Period      ),
        .RstClkCycles ( ResetCycles )
    ) i_clk_rst_gen (
        .clk_o  ( clk   ),
        .rst_no ( rst_n )
    );

    axi_req_t    dma_req, mem_req;
    axi_resp_t   dma_rsp, mem_rsp;
    dma_events_t events;
    logic        busy;

    acc_req_t acc_req;
    acc_res_t acc_res;
    logic     acc_req_valid, acc_req_ready;
    logic     acc_res_valid, acc_res_ready;

    idma_inst64_top #(
        .AxiDataWidth    ( AxiDataWidth  ),
        .AxiAddrWidth    ( AxiAddrWidth  ),
        .AxiUserWidth    ( AxiUserWidth  ),
        .AxiIdWidth      ( AxiIdWidth    ),
        .NumAxInFlight   ( NumAxInFlight ),
        .DMAReqFifoDepth ( 32'd3         ),
        .NumChannels     ( 32'd1         ),
        .DMATracing      ( 32'd0         ),
        .axi_ar_chan_t   ( axi_ar_chan_t ),
        .axi_aw_chan_t   ( axi_aw_chan_t ),
        .axi_req_t       ( axi_req_t     ),
        .axi_res_t       ( axi_resp_t    ),
        .acc_req_t       ( acc_req_t     ),
        .acc_res_t       ( acc_res_t     ),
        .dma_events_t    ( dma_events_t  )
    ) i_dut (
        .clk_i           ( clk           ),
        .rst_ni          ( rst_n         ),
        .testmode_i      ( 1'b0          ),
        .axi_req_o       ( dma_req       ),
        .axi_res_i       ( dma_rsp       ),
        .busy_o          ( busy          ),
        .acc_req_i       ( acc_req       ),
        .acc_req_valid_i ( acc_req_valid ),
        .acc_req_ready_o ( acc_req_ready ),
        .acc_res_o       ( acc_res       ),
        .acc_res_valid_o ( acc_res_valid ),
        .acc_res_ready_i ( acc_res_ready ),
        .hart_id_i       ( 32'h0         ),
        .events_o        ( events        )
    );

    // B responses return one at a time, at least BLatency cycles apart
    axi_b_chan_t dly_b;
    logic        dly_b_valid, mem_b_ready;

    stream_delay #(
        .StallRandom ( 1'b0           ),
        .FixedDelay  ( int'(BLatency) ),
        .payload_t   ( axi_b_chan_t   )
    ) i_b_delay (
        .clk_i     ( clk             ),
        .rst_ni    ( rst_n           ),
        .payload_i ( mem_rsp.b       ),
        .ready_o   ( mem_b_ready     ),
        .valid_i   ( mem_rsp.b_valid ),
        .payload_o ( dly_b           ),
        .ready_i   ( dma_req.b_ready ),
        .valid_o   ( dly_b_valid     )
    );

    always_comb begin : proc_b_delay
        mem_req         = dma_req;
        mem_req.b_ready = mem_b_ready;
        dma_rsp         = mem_rsp;
        dma_rsp.b       = dly_b;
        dma_rsp.b_valid = dly_b_valid;
    end

    axi_sim_mem #(
        .AddrWidth         ( AxiAddrWidth ),
        .DataWidth         ( AxiDataWidth ),
        .IdWidth           ( AxiIdWidth   ),
        .UserWidth         ( AxiUserWidth ),
        .axi_req_t         ( axi_req_t    ),
        .axi_rsp_t         ( axi_resp_t   ),
        .WarnUninitialized ( 1'b0         ),
        .ClearErrOnAccess  ( 1'b1         ),
        .ApplDelay         ( ApplDelay    ),
        .AcqDelay          ( AcqDelay     )
    ) i_mem (
        .clk_i              ( clk      ),
        .rst_ni             ( rst_n    ),
        .axi_req_i          ( mem_req  ),
        .axi_rsp_o          ( mem_rsp  ),
        .mon_w_valid_o      ( /* NC */ ),
        .mon_w_addr_o       ( /* NC */ ),
        .mon_w_data_o       ( /* NC */ ),
        .mon_w_id_o         ( /* NC */ ),
        .mon_w_user_o       ( /* NC */ ),
        .mon_w_beat_count_o ( /* NC */ ),
        .mon_w_last_o       ( /* NC */ ),
        .mon_r_valid_o      ( /* NC */ ),
        .mon_r_addr_o       ( /* NC */ ),
        .mon_r_data_o       ( /* NC */ ),
        .mon_r_id_o         ( /* NC */ ),
        .mon_r_user_o       ( /* NC */ ),
        .mon_r_beat_count_o ( /* NC */ ),
        .mon_r_last_o       ( /* NC */ )
    );

    //--------------------------------------
    // Busy against the open writes at the port
    //--------------------------------------
    int unsigned b_pending, b_pending_max, num_aw, num_b;

    always_ff @(posedge clk or negedge rst_n) begin : proc_b_pending
        if (!rst_n) begin
            b_pending     <= 0;
            b_pending_max <= 0;
            num_aw        <= 0;
            num_b         <= 0;
        end else begin
            b_pending <= b_pending + int'(dma_req.aw_valid && dma_rsp.aw_ready)
                                   - int'(dma_rsp.b_valid  && dma_req.b_ready);
            if (b_pending > b_pending_max) b_pending_max <= b_pending;
            if (dma_req.aw_valid && dma_rsp.aw_ready) num_aw <= num_aw + 1;
            if (dma_rsp.b_valid  && dma_req.b_ready)  num_b  <= num_b + 1;
            if (dma_req.aw_valid && dma_req.aw.id != '0) $fatal(1, "[BUSY] AW id is not 0");
        end
    end

    a_busy_covers_b : assert property (@(posedge clk) disable iff (!rst_n)
        (b_pending != 0) |-> busy
    ) else $fatal(1, "[BUSY] busy low with %0d B outstanding", $sampled(b_pending));

    //--------------------------------------
    // Accelerator bus driver
    //--------------------------------------
    // casez patterns of the opcode package with the don't-care bits zeroed
    function automatic logic [31:0] inst_encoding(input logic [31:0] pattern);
        for (int unsigned i = 0; i < 32; i++) begin
            inst_encoding[i] = (pattern[i] === 1'b1) ? 1'b1 : 1'b0;
        end
    endfunction

    logic [31:0] req_id;
    acc_res_t    rsp_queue [$];

    always @(posedge clk) begin : proc_capture_rsp
        if (rst_n && acc_res_valid && acc_res_ready) rsp_queue.push_back(acc_res);
    end

    task automatic acc_issue(
        input logic [31:0] data_op,
        input logic [63:0] data_arga,
        input logic [63:0] data_argb
    );
        @(posedge clk);
        #(ApplDelay);
        req_id            = req_id + 1;
        acc_req.id        = req_id;
        acc_req.data_op   = data_op;
        acc_req.data_arga = data_arga;
        acc_req.data_argb = data_argb;
        acc_req_valid     = 1'b1;
        #(AcqDelay - ApplDelay);
        while (!acc_req_ready) begin
            @(posedge clk);
            #(AcqDelay);
        end
        @(posedge clk);
        #(ApplDelay);
        acc_req_valid = 1'b0;
    endtask

    task automatic acc_get_rsp(output logic [63:0] data);
        acc_res_t    item;
        int unsigned waited;
        waited = 0;
        while (rsp_queue.size() == 0) begin
            @(posedge clk);
            #(AcqDelay);
            waited++;
            if (waited > RspTimeout) $fatal(1, "[BUSY] no response for request %0d", req_id);
        end
        item = rsp_queue.pop_front();
        if (item.id !== req_id) $fatal(1, "[BUSY] response id %0d, expected %0d", item.id, req_id);
        if (item.error !== 1'b0) $fatal(1, "[BUSY] request %0d returned an error", req_id);
        data = item.data;
    endtask

    task automatic dma_set_addr(input addr_t src, input addr_t dst);
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMSRC), 64'(src[31:0]), 64'(src >> 32));
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMDST), 64'(dst[31:0]), 64'(dst >> 32));
    endtask

    // Register-form copy on channel 0; cfg[1] selects 2D
    task automatic dma_start_copy(input int unsigned length, input logic [1:0] cfg);
        logic [63:0] tid;
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMCPY), 64'(length), 64'(cfg));
        acc_get_rsp(tid);
    endtask

    // Wait through the busy poll only, then the port must be quiet
    task automatic wait_idle_and_check(input string name, input int unsigned min_b);
        logic [63:0] status;
        int unsigned polls;
        polls = 0;
        forever begin
            acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMSTAT), 64'd0, 64'd2);
            acc_get_rsp(status);
            if (status[0] == 1'b0) break;
            polls++;
            if (polls > MaxPolls) $fatal(1, "[BUSY] %s: still busy after %0d polls", name, polls);
            repeat (5) @(posedge clk);
        end
        if (b_pending != 0) begin
            $fatal(1, "[BUSY] %s: busy poll idle with %0d B outstanding", name, b_pending);
        end
        if (num_b != num_aw || num_b < min_b) begin
            $fatal(1, "[BUSY] %s: %0d AW, %0d B, min %0d", name, num_aw, num_b, min_b);
        end
        repeat (2 * BLatency) @(posedge clk);
        if (busy !== 1'b0) $fatal(1, "[BUSY] %s: busy did not stay low", name);
        $display("[BUSY] %s: idle after %0d B, peak %0d outstanding", name, num_b, b_pending_max);
    endtask

    //--------------------------------------
    // Stimulus
    //--------------------------------------
    int unsigned errors = 0;

    function automatic logic [7:0] pattern(input addr_t a);
        return a[7:0] ^ a[15:8] ^ 8'h3c;
    endfunction

    task automatic check_bytes(input addr_t src, input addr_t dst, input int unsigned len);
        for (int unsigned i = 0; i < len; i++) begin
            logic [7:0] got;
            got = i_mem.mem.exists(dst + i) ? i_mem.mem[dst + i] : 8'hxx;
            if (got !== pattern(src + i)) begin
                if (errors < 10) $error("[BUSY] 0x%0h: got 0x%02x", dst + i, got);
                errors++;
            end
        end
    endtask

    // Fewest write bursts AXI allows; a burst ends at a 4 KiB page or after 256 beats
    function automatic int unsigned min_bursts(input addr_t dst, input int unsigned len);
        addr_t       a, page_end, burst_end;
        int unsigned n;
        a = dst;
        n = 0;
        while (a < dst + len) begin
            page_end  = (a & ~addr_t'(4095)) + 4096;
            burst_end = (a & ~addr_t'(StrbWidth - 1)) + 256 * StrbWidth;
            a         = (page_end < burst_end) ? page_end : burst_end;
            n++;
        end
        return n;
    endfunction

    initial begin : test_sequence
        int unsigned min_b;
        acc_req_valid = 1'b0;
        acc_res_ready = 1'b1;
        acc_req       = '0;
        req_id        = '0;
        @(posedge rst_n);
        repeat (10) @(posedge clk);
        for (int unsigned i = 0; i < InitBytes; i++) begin
            i_mem.mem[SrcAddr - 512 + i] = pattern(SrcAddr - 512 + i);
        end

        min_b = min_bursts(DstAddr, CopyBytes);
        if (min_b < 2) $fatal(1, "[BUSY] the 1D copy must span several bursts");
        dma_set_addr(SrcAddr, DstAddr);
        dma_start_copy(CopyBytes, 2'b00);
        wait_idle_and_check("1d", min_b);
        check_bytes(SrcAddr, DstAddr, CopyBytes);

        // One short burst per row
        min_b = num_b + NumRows * min_bursts(Dst2dAddr, RowBytes);
        dma_set_addr(SrcAddr, Dst2dAddr);
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMSTR), 64'(RowStride), 64'(RowStride));
        acc_issue(inst_encoding(idma_inst64_snitch_pkg::DMREP), 64'(NumRows), 64'd0);
        dma_start_copy(RowBytes, 2'b10);
        wait_idle_and_check("2d", min_b);
        for (int unsigned r = 0; r < NumRows; r++) begin
            check_bytes(SrcAddr + r * RowStride, Dst2dAddr + r * RowStride, RowBytes);
        end

        if (b_pending_max < 2) $fatal(1, "[BUSY] never more than one B outstanding");
        if (errors != 0) $fatal(1, "[BUSY] TEST FAILED: %0d byte mismatches", errors);
        $display("[BUSY] TEST PASSED");
        $finish;
    end

    initial begin : watchdog
        repeat (HangCycles) @(posedge clk);
        $fatal(1, "[BUSY] simulation timeout after %0d cycles", HangCycles);
    end

endmodule

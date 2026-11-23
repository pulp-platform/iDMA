// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// The `inst64` busy status (DMSTAT 2, what `snrt_dma_wait_all` polls) must stay set until the
/// last write response returns. B responses return one at a time, at least `BLatency` cycles
/// apart. A 1D copy and a 2D copy of `NumRows` single-beat bursts are each waited on through
/// the busy poll alone; the 2D copy is also polled with every row written and all `NumRows`
/// responses held back.
module tb_idma_inst64_busy #(
    parameter int unsigned BLatency      = 32'd200,
    parameter int unsigned NumAxInFlight = idma_inst64_tb_pkg::NumAxInFlight
);
    import idma_inst64_tb_pkg::*;

    localparam addr_t       SrcAddr    = 64'h8000_0000;
    localparam addr_t       DstAddr    = 64'h9000_0000;
    localparam int unsigned CopyBytes  = 32'd4096;
    localparam int unsigned RowBytes   = 32'd64;
    localparam int unsigned RowStride  = 32'd256;
    // open writes: a power of two above NumAxInFlight, capped to the backend write tracking depth
    localparam int unsigned RowsPow2   = 32'd1 << $clog2(NumAxInFlight + 32'd1);
    localparam int unsigned RowsFit    = NumAxInFlight + 32'd16;
    localparam int unsigned NumRows    = (RowsPow2 < RowsFit) ? RowsPow2 : RowsFit;
    localparam int unsigned RowsBytes  = NumRows * RowStride;
    localparam int unsigned SrcBytes   = (RowsBytes > CopyBytes) ? RowsBytes : CopyBytes;
    localparam int unsigned HoldCycles = 32'd32;
    localparam int unsigned HangCycles = 32'd20000 + 32'd2 * (NumRows + 32'd1) * (BLatency + 32'd8);

    logic clk, rst_n;

    clk_rst_gen #(
        .ClkPeriod    ( Period      ),
        .RstClkCycles ( ResetCycles )
    ) i_clk_rst_gen (
        .clk_o  ( clk   ),
        .rst_no ( rst_n )
    );

    idma_inst64_drv_if #(
        .MaxPolls ( HangCycles )
    ) drv_if (
        .clk   ( clk   ),
        .rst_n ( rst_n )
    );

    axi_req_t    dma_req, mem_req;
    axi_resp_t   dma_rsp, mem_rsp;
    obi_req_t    obi_req;
    obi_res_t    obi_res;
    dma_events_t events;
    logic        busy;
    addr_rule_t  addr_map;

    assign obi_res  = '0;
    assign addr_map = '{idx: idma_pkg::TCDMDMA, start_addr: TcdmStart, end_addr: TcdmEnd};

    idma_inst64_top #(
        .AxiDataWidth    ( AxiDataWidth    ),
        .AxiAddrWidth    ( AxiAddrWidth    ),
        .AxiUserWidth    ( AxiUserWidth    ),
        .AxiIdWidth      ( AxiIdWidth      ),
        .NumAxInFlight   ( NumAxInFlight   ),
        .DMAReqFifoDepth ( DMAReqFifoDepth ),
        .NumChannels     ( 32'd1           ),
        .NumAddrRules    ( 32'd1           ),
        .EnableTcdmObi   ( 1'b0            ),
        .DMATracing      ( 32'd0           ),
        .axi_ar_chan_t   ( axi_ar_chan_t   ),
        .axi_aw_chan_t   ( axi_aw_chan_t   ),
        .axi_req_t       ( axi_req_t       ),
        .axi_res_t       ( axi_resp_t      ),
        .init_req_chan_t ( init_req_chan_t ),
        .init_rsp_chan_t ( init_rsp_chan_t ),
        .init_req_t      ( init_req_t      ),
        .init_rsp_t      ( init_rsp_t      ),
        .obi_a_chan_t    ( obi_a_chan_t    ),
        .obi_r_chan_t    ( obi_r_chan_t    ),
        .obi_req_t       ( obi_req_t       ),
        .obi_res_t       ( obi_res_t       ),
        .acc_req_t       ( acc_req_t       ),
        .acc_res_t       ( acc_res_t       ),
        .dma_events_t    ( dma_events_t    ),
        .addr_rule_t     ( addr_rule_t     )
    ) i_dut (
        .clk_i           ( clk                  ),
        .rst_ni          ( rst_n                ),
        .axi_req_o       ( dma_req              ),
        .axi_res_i       ( dma_rsp              ),
        .obi_req_o       ( obi_req              ),
        .obi_res_i       ( obi_res              ),
        .busy_o          ( busy                 ),
        .acc_req_i       ( drv_if.acc_req       ),
        .acc_req_valid_i ( drv_if.acc_req_valid ),
        .acc_req_ready_o ( drv_if.acc_req_ready ),
        .acc_res_o       ( drv_if.acc_res       ),
        .acc_res_valid_o ( drv_if.acc_res_valid ),
        .acc_res_ready_i ( drv_if.acc_res_ready ),
        .hart_id_i       ( 32'h0                ),
        .events_o        ( events               ),
        .addr_map_i      ( addr_map             )
    );

    // B responses return one at a time, at least BLatency cycles apart; b_hold keeps them all back
    axi_b_chan_t dly_b;
    logic        dly_b_valid, mem_b_ready, b_hold;

    cc_stream_delay #(
        .FixedDelay ( BLatency     ),
        .payload_t  ( axi_b_chan_t )
    ) i_b_delay (
        .clk_i     ( clk                       ),
        .rst_ni    ( rst_n                     ),
        .clr_i     ( 1'b0                      ),
        .payload_i ( mem_rsp.b                 ),
        .ready_o   ( mem_b_ready               ),
        .valid_i   ( mem_rsp.b_valid           ),
        .payload_o ( dly_b                     ),
        .ready_i   ( dma_req.b_ready & ~b_hold ),
        .valid_o   ( dly_b_valid               )
    );

    always_comb begin : proc_b_delay
        mem_req         = dma_req;
        mem_req.b_ready = mem_b_ready;
        dma_rsp         = mem_rsp;
        dma_rsp.b       = dly_b;
        dma_rsp.b_valid = dly_b_valid & ~b_hold;
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
    int unsigned b_pending, num_b;

    always_ff @(posedge clk or negedge rst_n) begin : proc_b_pending
        if (!rst_n) begin
            b_pending <= '0;
            num_b     <= '0;
        end else begin
            b_pending <= b_pending + int'(dma_req.aw_valid && dma_rsp.aw_ready)
                                   - int'(dma_rsp.b_valid  && dma_req.b_ready);
            if (dma_rsp.b_valid && dma_req.b_ready) num_b <= num_b + 1;
        end
    end

    a_busy_covers_b : assert property (@(posedge clk) disable iff (!rst_n)
        (b_pending != '0) |-> busy
    ) else $fatal(1, "[BUSY] busy low with %0d B outstanding", $sampled(b_pending));

    // An issued transfer holds busy until it retires
    a_busy_covers_tf : assert property (@(posedge clk) disable iff (!rst_n)
        (i_dut.next_id[0] - i_dut.completed_id[0] != 32'd1) |-> busy
    ) else $fatal(1, "[BUSY] busy low with a transfer in flight");

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

    // Wait through the busy poll only, then the port must be quiet
    task automatic wait_idle_and_check(input string name, input int unsigned exp_b);
        drv_if.dma_wait_idle(3'd0);
        if (b_pending != '0) begin
            $fatal(1, "[BUSY] %s: busy poll idle with %0d B outstanding", name, b_pending);
        end
        $display("[BUSY] %s: idle after %0d B", name, num_b);
        if (num_b < exp_b) $fatal(1, "[BUSY] %s: %0d B, expected %0d", name, num_b, exp_b);
    endtask

    initial begin : test_sequence
        tf_id_t      tid;
        logic [63:0] status;
        b_hold = 1'b0;
        @(posedge rst_n);
        repeat (10) @(posedge clk);
        for (int unsigned i = 0; i < SrcBytes; i++) begin
            i_mem.mem[SrcAddr + i] = pattern(SrcAddr + i);
        end

        drv_if.dma_set_source(SrcAddr);
        drv_if.dma_set_dest(DstAddr);
        drv_if.dma_start_copy(addr_t'(CopyBytes), 2'b00, 3'd0, tid);
        wait_idle_and_check("1d", 1);
        check_bytes(SrcAddr, DstAddr, CopyBytes);

        // One burst per row; poll with the datapath drained and every response still open
        b_hold = 1'b1;
        drv_if.dma_set_source(SrcAddr);
        drv_if.dma_set_dest(DstAddr + 64'h10000);
        drv_if.dma_set_strides(RowStride, RowStride);
        drv_if.dma_set_reps(NumRows);
        drv_if.dma_start_copy(addr_t'(RowBytes), 2'b10, 3'd0, tid);
        while (b_pending != NumRows) @(posedge clk);
        repeat (HoldCycles) @(posedge clk);
        drv_if.dma_poll_status(2'b10, 3'd0, status);
        if (!status[0]) $fatal(1, "[BUSY] 2d: busy poll idle with %0d B outstanding", b_pending);
        $display("[BUSY] 2d: busy with %0d B outstanding", b_pending);
        @(posedge clk);
        #(ApplDelay);
        b_hold = 1'b0;
        wait_idle_and_check("2d", 1 + NumRows);
        for (int unsigned r = 0; r < NumRows; r++) begin
            check_bytes(SrcAddr + r * RowStride, DstAddr + 64'h10000 + r * RowStride, RowBytes);
        end

        if (errors != 0) $fatal(1, "[BUSY] TEST FAILED: %0d byte mismatches", errors);
        $display("[BUSY] TEST PASSED");
        $finish;
    end

    initial begin : watchdog
        repeat (HangCycles) @(posedge clk);
        $fatal(1, "[BUSY] simulation timeout after %0d cycles", HangCycles);
    end

endmodule

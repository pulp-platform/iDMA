// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Directed self-checking testbench for the multi-head AXI backend
// (idma_backend_2r_axi_w_axi: 2 read heads, 1 write head). Each read head drives
// its own axi_sim_mem so read-head routing is observable: src_head selects which
// read memory a transfer sources from, while all writes land in the single write
// memory. Preloading distinct data per read head and checking the write memory
// catches a backend that ignores or mis-routes src_head. Recycles the per-head
// memory harness pattern from the vidma inst64 verification harness.

`timescale 1ns/1ns
`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_backend_multihead import idma_pkg::*; #(
    parameter int unsigned NumReadHeads = 2,
    parameter int unsigned BufferDepth  = 3,
    parameter int unsigned NumAxInFlight = 3,
    parameter int unsigned DataWidth    = 32,
    parameter int unsigned AddrWidth    = 32,
    parameter int unsigned UserWidth    = 1,
    parameter int unsigned AxiIdWidth   = 12,
    parameter int unsigned TFLenWidth   = 32,
    parameter int unsigned MemSysDepth  = 0,
    parameter bit          CombinedShifter   = 1'b0,
    parameter int unsigned WatchDogNumCycles = 1000
);

    localparam time TA  = 1ns;
    localparam time TT  = 9ns;
    localparam time TCK = 10ns;

    localparam int unsigned StrbWidth   = DataWidth / 8;
    localparam int unsigned OffsetWidth = $clog2(StrbWidth);
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

    // clock / reset
    logic clk;
    logic rst_n;

    // dma request / response
    idma_req_t idma_req;
    logic req_valid, req_ready;
    idma_rsp_t idma_rsp;
    logic rsp_valid, rsp_ready;
    idma_eh_req_t idma_eh_req;
    logic eh_req_valid, eh_req_ready;
    idma_busy_t busy;

    // 2 read master buses (one per read head), 1 write master bus
    axi_req_t [NumReadHeads-1:0] axi_read_req;
    axi_rsp_t [NumReadHeads-1:0] axi_read_rsp;
    axi_req_t axi_write_req;
    axi_rsp_t axi_write_rsp;

    // driver
    IDMA_DV #(
        .DataWidth (DataWidth), .AddrWidth (AddrWidth), .UserWidth (UserWidth),
        .AxiIdWidth (AxiIdWidth), .TFLenWidth (TFLenWidth)
    ) idma_dv (clk);

    typedef idma_test::idma_driver #(
        .DataWidth (DataWidth), .AddrWidth (AddrWidth), .UserWidth (UserWidth),
        .AxiIdWidth (AxiIdWidth), .TFLenWidth (TFLenWidth), .TA (TA), .TT (TT)
    ) drv_t;
    drv_t drv = new(idma_dv);

    assign idma_req         = idma_dv.req;
    assign req_valid        = idma_dv.req_valid;
    // TB never inspects the completion response, only the written memory; keep
    // rsp_ready asserted so the AXI read datapath can drain R into the buffer.
    assign rsp_ready        = 1'b1;
    assign idma_eh_req      = idma_dv.eh_req;
    assign eh_req_valid     = idma_dv.eh_req_valid;
    assign idma_dv.req_ready    = req_ready;
    assign idma_dv.rsp          = idma_rsp;
    assign idma_dv.rsp_valid    = rsp_valid;
    assign idma_dv.eh_req_ready = eh_req_ready;

    clk_rst_gen #(.ClkPeriod (TCK), .RstClkCycles (1)) i_clk_rst_gen (
        .clk_o (clk), .rst_no (rst_n)
    );

    // one dedicated read memory per read head
    for (genvar h = 0; h < NumReadHeads; h++) begin : gen_rmem
        axi_sim_mem #(
            .AddrWidth (AddrWidth), .DataWidth (DataWidth), .IdWidth (AxiIdWidth),
            .UserWidth (UserWidth), .axi_req_t (axi_req_t), .axi_rsp_t (axi_rsp_t),
            .WarnUninitialized (1'b0), .ClearErrOnAccess (1'b1),
            .ApplDelay (TA), .AcqDelay (TT)
        ) i_axi_sim_mem (
            .clk_i (clk), .rst_ni (rst_n),
            .axi_req_i (axi_read_req[h]), .axi_rsp_o (axi_read_rsp[h]),
            .mon_r_last_o (), .mon_r_beat_count_o (), .mon_r_user_o (), .mon_r_id_o (),
            .mon_r_data_o (), .mon_r_addr_o (), .mon_r_valid_o (),
            .mon_w_last_o (), .mon_w_beat_count_o (), .mon_w_user_o (), .mon_w_id_o (),
            .mon_w_data_o (), .mon_w_addr_o (), .mon_w_valid_o ()
        );
    end

    // single write memory
    axi_sim_mem #(
        .AddrWidth (AddrWidth), .DataWidth (DataWidth), .IdWidth (AxiIdWidth),
        .UserWidth (UserWidth), .axi_req_t (axi_req_t), .axi_rsp_t (axi_rsp_t),
        .WarnUninitialized (1'b0), .ClearErrOnAccess (1'b1),
        .ApplDelay (TA), .AcqDelay (TT)
    ) i_write_mem (
        .clk_i (clk), .rst_ni (rst_n),
        .axi_req_i (axi_write_req), .axi_rsp_o (axi_write_rsp),
        .mon_r_last_o (), .mon_r_beat_count_o (), .mon_r_user_o (), .mon_r_id_o (),
        .mon_r_data_o (), .mon_r_addr_o (), .mon_r_valid_o (),
        .mon_w_last_o (), .mon_w_beat_count_o (), .mon_w_user_o (), .mon_w_id_o (),
        .mon_w_data_o (), .mon_w_addr_o (), .mon_w_valid_o ()
    );

    idma_backend_2r_axi_w_axi #(
        .CombinedShifter (CombinedShifter), .DataWidth (DataWidth), .AddrWidth (AddrWidth),
        .AxiIdWidth (AxiIdWidth), .UserWidth (UserWidth), .TFLenWidth (TFLenWidth),
        .BufferDepth (BufferDepth), .RAWCouplingAvail (1'b0), .MaskInvalidData (1'b1),
        .HardwareLegalizer (1'b1), .RejectZeroTransfers (1'b1), .ErrorCap (ErrorCap),
        .PrintFifoInfo (1'b0), .NumAxInFlight (NumAxInFlight), .MemSysDepth (MemSysDepth),
        .idma_req_t (idma_req_t), .idma_rsp_t (idma_rsp_t), .idma_eh_req_t (idma_eh_req_t),
        .idma_busy_t (idma_busy_t), .axi_req_t (axi_req_t), .axi_rsp_t (axi_rsp_t),
        .write_meta_channel_t (write_meta_channel_t), .read_meta_channel_t (read_meta_channel_t)
    ) i_idma_backend (
        .clk_i (clk), .rst_ni (rst_n),
        .idma_req_i (idma_req), .req_valid_i (req_valid), .req_ready_o (req_ready),
        .idma_rsp_o (idma_rsp), .rsp_valid_o (rsp_valid), .rsp_ready_i (rsp_ready),
        .idma_eh_req_i (idma_eh_req), .eh_req_valid_i (eh_req_valid), .eh_req_ready_o (eh_req_ready),
        .axi_read_req_o (axi_read_req), .axi_read_rsp_i (axi_read_rsp),
        .axi_write_req_o (axi_write_req), .axi_write_rsp_i (axi_write_rsp),
        .busy_o (busy)
    );

    // ----------------------------------------------------------------------
    // Stimulus
    // ----------------------------------------------------------------------
    int unsigned errors = 0;

    // Generate-block instances cannot be variable-indexed; 2 read heads here.
    task automatic rmem_set (input int unsigned head, input addr_t a, input byte_t d);
        case (head)
            0: gen_rmem[0].i_axi_sim_mem.mem[a] = d;
            1: gen_rmem[1].i_axi_sim_mem.mem[a] = d;
            default: $fatal(1, "read head %0d out of range", head);
        endcase
    endtask

    // preload `len` bytes into read head `head`'s memory at `base`
    task automatic preload (input int unsigned head, input addr_t base,
                            input int unsigned len, input byte_t seed);
        for (int unsigned i = 0; i < len; i++)
            rmem_set(head, base + i, seed + i[7:0]);
    endtask

    // check the single write memory at `base` holds the seeded pattern
    task automatic check (input string label, input addr_t base,
                          input int unsigned len, input byte_t seed);
        byte_t got, exp;
        for (int unsigned i = 0; i < len; i++) begin
            exp = seed + i[7:0];
            got = i_write_mem.mem.exists(base + i) ? i_write_mem.mem[base + i] : 8'hxx;
            if (got !== exp) begin
                errors++;
                $error("[%s] wmem @0x%h: got 0x%h exp 0x%h", label, base + i, got, exp);
                if (i > 4) return;
            end
        end
        $display("[%s] wmem @0x%h len %0d: OK", label, base, len);
    endtask

    // launch one copy (read head = src_head, single write head) and wait
    task automatic do_copy (input int unsigned len, input addr_t src, input addr_t dst,
                            input multihead_t src_head, input id_t id);
        drv.launch_tf(len, src, dst, idma_pkg::AXI, idma_pkg::AXI, 1'b0, 1'b0,
                      3'd0, 3'd0, 1'b1, 1'b1, id, src_head, '0);
        @(posedge clk);
        while (busy != '0) @(posedge clk);
        repeat (5) @(posedge clk);
    endtask

    localparam int unsigned LEN = 64;

    initial begin
        automatic byte_t s0 = 8'h10;
        automatic byte_t s1 = 8'ha0;
        drv.reset_driver();
        @(posedge rst_n);
        repeat (4) @(posedge clk);

        // distinct source data per read head, same source address
        preload(0, 32'h0000_1000, LEN, s0);
        preload(1, 32'h0000_1000, LEN, s1);

        // read head 0 -> write memory: data must be head-0's pattern
        do_copy(LEN, 32'h0000_1000, 32'h0000_2000, 0, 'd1);
        check("rhead0", 32'h0000_2000, LEN, s0);

        // read head 1 -> write memory: data must be head-1's pattern.
        // If src_head routing is broken, this reads head 0 and the check fails.
        do_copy(LEN, 32'h0000_1000, 32'h0000_3000, 1, 'd2);
        check("rhead1", 32'h0000_3000, LEN, s1);

        if (errors == 0)
            $display("[tb_idma_backend_multihead] ALL CHECKS PASSED");
        else
            $fatal(1, "[tb_idma_backend_multihead] %0d byte mismatches", errors);
        $finish;
    end

    // global watchdog
    initial begin
        repeat (WatchDogNumCycles * 5) @(posedge clk);
        $fatal(1, "[tb_idma_backend_multihead] watchdog timeout");
    end

endmodule

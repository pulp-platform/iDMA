// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Plain `DMCPY`s through the gather midend. `Case` 0: a 2D copy with more repetitions than
/// `NumAxInFlight`; 1: a 2D copy with zero repetitions; 2: a zero-repetition copy queued
/// behind a gather. `EnableGather = 0` runs cases 0 and 1 without the gather midend.
module tb_idma_inst64_gather_plain #(
    parameter bit          EnableGather = 1'b1,
    parameter int unsigned Case         = 32'd0
);
    import idma_inst64_tb_pkg::*;

    idma_inst64_base #(
        .EnableTcdmObi ( 1'b0         ),
        .EnableGather  ( EnableGather )
    ) harness ();

    localparam int unsigned RowBytes = 32'd64;
    localparam int unsigned NumRows  = 32'd64;
    localparam int unsigned Timeout  = 32'd50000;
    localparam logic [7:0]  Sentinel = 8'h5A;

    localparam addr_t SrcBase = 64'h8000_0000;
    localparam addr_t IdxBase = 64'h0000_2000;
    localparam addr_t DstBase = 64'h9000_0000;
    localparam addr_t CpyBase = 64'hA000_0000;

    int unsigned errors = 0;
    string       step   = "reset";

    function automatic logic [7:0] pattern(input addr_t addr);
        return addr[7:0] ^ addr[15:8] ^ 8'h3C;
    endfunction

    task automatic seed();
        for (int unsigned i = 0; i < NumRows * RowBytes; i++) begin
            harness.mem_write_byte(SrcBase + i, pattern(SrcBase + i));
            harness.mem_write_byte(DstBase + i, Sentinel);
        end
    endtask

    /// Slot `s` of `dst` must hold source row `rows[s]`
    task automatic check_rows(input string name, input addr_t dst, input int unsigned rows [$]);
        int unsigned bad;
        bad = 0;
        for (int unsigned s = 0; s < rows.size(); s++) begin
            for (int unsigned o = 0; o < RowBytes; o++) begin
                if (harness.mem_read_byte(dst + s*RowBytes + o) !==
                    pattern(SrcBase + rows[s]*RowBytes + o)) bad++;
            end
        end
        if (bad != 0) $error("[TB] %s: %0d byte errors", name, bad);
        errors += bad;
    endtask

    task automatic copy_2d(input addr_t dst, input int unsigned reps, output tf_id_t tid);
        harness.drv_if.dma_set_source(SrcBase);
        harness.drv_if.dma_set_dest(dst);
        harness.drv_if.dma_set_strides(RowBytes, RowBytes);
        harness.drv_if.dma_set_reps(reps);
        harness.drv_if.dma_start_copy(addr_t'(RowBytes), 2'b10, 3'd0, tid);
    endtask

    // merged responses leaving the gather midend, in order
    logic                 rsp_err  [$];
    idma_pkg::err_type_e  rsp_type [$];

    if (EnableGather) begin : gen_rsp_probe
        always @(posedge harness.clk) begin
            if (harness.i_dut.gen_nd_midend[0].gen_gather.i_idma_gather_midend.gather_rsp_valid_o &&
                harness.i_dut.gen_nd_midend[0].gen_gather.i_idma_gather_midend.gather_rsp_ready_i)
            begin
                rsp_err.push_back(harness.i_dut.gen_nd_midend[0]
                                  .gen_gather.i_idma_gather_midend.gather_rsp_o.error);
                rsp_type.push_back(idma_pkg::err_type_e'(harness.i_dut.gen_nd_midend[0]
                                   .gen_gather.i_idma_gather_midend.gather_rsp_o.pld.err_type));
            end
        end
    end

    initial begin : test_sequence
        int unsigned rows [$];
        tf_id_t      tid, tid2;

        @(posedge harness.rst_n);
        repeat (10) @(posedge harness.clk);
        seed();

        case (Case)
            0: begin
                step = $sformatf("2D copy, DMREP %0d > NumAxInFlight %0d",
                                 NumAxInFlight + 2, NumAxInFlight);
                for (int unsigned r = 0; r < NumAxInFlight + 2; r++) rows.push_back(r);
                copy_2d(DstBase, NumAxInFlight + 2, tid);
                harness.drv_if.dma_wait(tid, 3'd0);
                check_rows(step, DstBase, rows);
            end
            1: begin
                step = "2D copy, DMREP 0";
                copy_2d(DstBase, 0, tid);
                harness.drv_if.dma_wait(tid, 3'd0);
                step = "1D copy after the DMREP 0 copy";
                rows.push_back(0);
                copy_2d(DstBase, 1, tid);
                harness.drv_if.dma_wait(tid, 3'd0);
                check_rows(step, DstBase, rows);
            end
            2: begin
                if (!EnableGather) $fatal(1, "[TB] case 2 needs EnableGather");
                step = "DMREP 0 copy behind a gather";
                for (int unsigned i = 0; i < NumRows; i++) begin
                    rows.push_back(NumRows - 1 - i);
                    harness.gen_idx_access.idx_mem_write_byte(IdxBase + 2*i, byte'(rows[i]));
                    harness.gen_idx_access.idx_mem_write_byte(IdxBase + 2*i + 1, 8'h00);
                end
                harness.drv_if.dma_set_index(IdxBase[31:0], 2'b01, 1'b1);
                copy_2d(DstBase, NumRows, tid);
                harness.drv_if.dma_set_index('0, 2'b00, 1'b0);
                copy_2d(CpyBase, 0, tid2);
                harness.drv_if.dma_wait(tid2, 3'd0);
                check_rows("gather", DstBase, rows);
                if (rsp_err.size() != 2) begin
                    $error("[TB] %0d gather midend responses, expected 2", rsp_err.size());
                    errors++;
                end else begin
                    if (rsp_err[0] !== 1'b0) begin
                        $error("[TB] gather response flags an error (type %s), it had none",
                               rsp_type[0].name());
                        errors++;
                    end
                    if (rsp_err[1] !== 1'b1 || rsp_type[1] !== idma_pkg::ND_MIDEND) begin
                        $error("[TB] DMREP 0 copy response carries %s, expected ND_MIDEND",
                               rsp_err[1] ? rsp_type[1].name() : "no error");
                        errors++;
                    end
                end
            end
            default: $fatal(1, "[TB] unknown case %0d", Case);
        endcase

        harness.drv_if.dma_wait_idle(3'd0);
        if (errors != 0) $fatal(1, "[TB] TEST FAILED: %s: %0d errors", step, errors);
        $display("[TB] TEST PASSED");
        $finish;
    end

    initial begin : test_timeout
        repeat (Timeout) @(posedge harness.clk);
        $fatal(1, "[TB] HANG: %s did not retire within %0d cycles", step, Timeout);
    end

endmodule

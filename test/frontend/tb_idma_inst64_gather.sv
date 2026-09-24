// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Bowen Wang <bowwang@iis.ee.ethz.ch>

/// Indexed gather through the tightly-coupled `inst64` frontend. A `DMIDX` arms the gather,
/// the following `DMCPY` copies `DMREP` rows of the source matrix, selected by the index
/// stream, to consecutive destination slots. Every index width, a misaligned index base, rows
/// that are not a bus beat, destination gaps, a copy queued behind a gather, a rejected
/// zero-index gather and (with `EnableTcdmObi`) a TCDM destination and a memset while armed
/// are checked byte-exact.
module tb_idma_inst64_gather #(
    /// Topology under test; 1 also lands one gather in the TCDM window
    parameter bit          EnableTcdmObi     = 1'b0,
    /// Index words in flight or buffered
    parameter int unsigned NumIdxOutstanding = 32'd2,
    parameter int unsigned DMATracing        = idma_inst64_tb_pkg::DMATracing
);
    import idma_inst64_tb_pkg::*;

    idma_inst64_base #(
        .EnableTcdmObi     ( EnableTcdmObi     ),
        .EnableGather      ( 1'b1              ),
        .NumIdxOutstanding ( NumIdxOutstanding ),
        .DMATracing        ( DMATracing        )
    ) harness ();

    localparam int unsigned NumRows    = 32'd256;
    localparam int unsigned GuardBytes = 32'd64;
    localparam logic [7:0]  Sentinel   = 8'h5A;

    localparam addr_t SrcBase = 64'h8000_0000;
    localparam addr_t IdxBase = 64'h0000_2000;
    localparam addr_t DstBase = 64'h9000_0000;
    localparam addr_t CpyBase = 64'hA000_0000;
    localparam addr_t TcdmDst = addr_t'(TcdmStart + 64'h400);

    int unsigned errors = 0;

    function automatic logic [7:0] pattern(input addr_t addr);
        return addr[7:0] ^ addr[15:8] ^ 8'h3C;
    endfunction

    function automatic logic [7:0] read_byte(input addr_t addr, input bit tcdm);
        if (tcdm) return harness.gen_obi_access.obi_mem_read_byte(addr);
        return harness.mem_read_byte(addr);
    endfunction

    task automatic seed_source(input addr_t stride, input int unsigned len);
        for (int unsigned r = 0; r < NumRows; r++) begin
            for (int unsigned b = 0; b < len; b++) begin
                harness.mem_write_byte(SrcBase + r*stride + b, pattern(SrcBase + r*stride + b));
            end
        end
    endtask

    task automatic fill_sentinel(input addr_t base, input int unsigned num_bytes, input bit tcdm);
        for (int unsigned i = 0; i < num_bytes + 2*GuardBytes; i++) begin
            if (tcdm) harness.gen_obi_access.obi_mem_write_byte(base - GuardBytes + i, Sentinel);
            else      harness.mem_write_byte(base - GuardBytes + i, Sentinel);
        end
    endtask

    /// Write `num_idx` random row indices of `1 << width` bytes starting at `idx_addr`
    task automatic write_indices(
        input  addr_t       idx_addr,
        input  int unsigned width,
        input  int unsigned num_idx,
        output int unsigned idx [$]
    );
        idx = {};
        for (int unsigned i = 0; i < num_idx; i++) begin
            int unsigned v;
            v = $urandom % NumRows;
            idx.push_back(v);
            for (int unsigned b = 0; b < (1 << width); b++) begin
                harness.gen_idx_access.idx_mem_write_byte(idx_addr + i*(1 << width) + b,
                                                          (b < 4) ? byte'(v >> (8*b)) : 8'h00);
            end
        end
    endtask

    /// Every slot must hold its source row; the gaps and guards must keep the sentinel
    task automatic check_gather(
        input string       name,
        input int unsigned idx [$],
        input int unsigned len,
        input addr_t       src_stride,
        input addr_t       dst,
        input addr_t       dst_stride,
        input bit          tcdm
    );
        int unsigned span;
        int unsigned local_errors;
        local_errors = 0;
        span = (idx.size() - 1) * dst_stride + len;
        for (int unsigned o = 0; o < span + GuardBytes; o++) begin
            logic [7:0] want, got;
            int unsigned slot, off;
            slot = o / dst_stride;
            off  = o % dst_stride;
            if (o < span && slot < idx.size() && off < len) begin
                want = pattern(SrcBase + idx[slot]*src_stride + off);
            end else begin
                want = Sentinel;
            end
            got = read_byte(dst + o, tcdm);
            if (got !== want) begin
                if (local_errors < 8) begin
                    $error("[TB] %s: byte %0d (slot %0d + %0d): expected 0x%02x, got 0x%02x",
                           name, o, slot, off, want, got);
                end
                local_errors++;
            end
        end
        for (int unsigned i = 1; i <= GuardBytes; i++) begin
            if (read_byte(dst - i, tcdm) !== Sentinel) local_errors++;
        end
        errors += local_errors;
        $display("[TB] %s: %0d rows of %0d B, %0d errors", name, idx.size(), len, local_errors);
    endtask

    /// Arm a gather, launch it and return its transfer id
    task automatic launch_gather(
        input  addr_t       idx_addr,
        input  int unsigned width,
        input  int unsigned num_idx,
        input  int unsigned len,
        input  addr_t       src_stride,
        input  addr_t       dst,
        input  addr_t       dst_stride,
        output tf_id_t      tid
    );
        harness.drv_if.dma_set_index(idx_addr[31:0], 2'(width), 1'b1);
        harness.drv_if.dma_set_source(SrcBase);
        harness.drv_if.dma_set_dest(dst);
        harness.drv_if.dma_set_strides(src_stride[31:0], dst_stride[31:0]);
        harness.drv_if.dma_set_reps(num_idx);
        harness.drv_if.dma_start_copy(addr_t'(len), 2'b00, 3'd0, tid);
    endtask

    task automatic run_gather(
        input string       name,
        input int unsigned width,
        input int unsigned num_idx,
        input int unsigned lane_off,
        input int unsigned len,
        input addr_t       src_stride,
        input addr_t       dst,
        input addr_t       dst_stride,
        input bit          tcdm
    );
        int unsigned idx [$];
        addr_t       idx_addr;
        tf_id_t      tid;
        idx_addr = IdxBase + lane_off * (1 << width);
        seed_source(src_stride, len);
        write_indices(idx_addr, width, num_idx, idx);
        fill_sentinel(dst, (num_idx - 1) * dst_stride + len, tcdm);
        launch_gather(idx_addr, width, num_idx, len, src_stride, dst, dst_stride, tid);
        harness.drv_if.dma_wait(tid, 3'd0);
        check_gather(name, idx, len, src_stride, dst, dst_stride, tcdm);
    endtask

    initial begin : test_sequence
        int unsigned idx [$];
        tf_id_t      tid_gather, tid_copy;
        logic [63:0] status;

        @(posedge harness.rst_n);
        repeat (10) @(posedge harness.clk);

        // index widths, word-boundary counts and a misaligned index base
        run_gather("u16 packed",      1, 37, 0, 64,  64,  DstBase, 64, 1'b0);
        run_gather("u8 misaligned",   0, 70, 3, 24,  32,  DstBase, 40, 1'b0);
        run_gather("u32 lane 1",      2, 5,  1, 128, 128, DstBase, 128, 1'b0);
        run_gather("u64 short rows",  3, 9,  0, 8,   256, DstBase, 16, 1'b0);

        // a plain copy queued behind a gather, with the gather disarmed in between
        seed_source(64, 64);
        write_indices(IdxBase, 1, 48, idx);
        fill_sentinel(DstBase, 48*64, 1'b0);
        fill_sentinel(CpyBase, 256, 1'b0);
        launch_gather(IdxBase, 1, 48, 64, 64, DstBase, 64, tid_gather);
        harness.drv_if.dma_set_index('0, 2'b00, 1'b0);
        harness.drv_if.dma_set_source(SrcBase);
        harness.drv_if.dma_set_dest(CpyBase);
        harness.drv_if.dma_start_copy(addr_t'(256), 2'b00, 3'd0, tid_copy);
        if (tid_copy != tid_gather + 1) $fatal(1, "[TB] copy id %0d after gather id %0d",
                                               tid_copy, tid_gather);
        harness.drv_if.dma_wait(tid_copy, 3'd0);
        check_gather("gather before copy", idx, 64, 64, DstBase, 64, 1'b0);
        for (int unsigned i = 0; i < 256; i++) begin
            if (harness.mem_read_byte(CpyBase + i) !== pattern(SrcBase + i)) errors++;
        end
        $display("[TB] copy behind gather checked");

        // zero indices: rejected, but the transfer still retires and writes nothing
        fill_sentinel(DstBase, 64, 1'b0);
        launch_gather(IdxBase, 1, 0, 64, 64, DstBase, 64, tid_gather);
        harness.drv_if.dma_wait(tid_gather, 3'd0);
        for (int unsigned i = 0; i < 64; i++) begin
            if (harness.mem_read_byte(DstBase + i) !== Sentinel) errors++;
        end
        $display("[TB] zero-index gather retired without writing");

        if (EnableTcdmObi) begin : tcdm_legs
            // the gathered rows land in the TCDM window over OBI
            run_gather("u16 to TCDM", 1, 20, 2, 64, 64, TcdmDst, 64, 1'b1);
            // a memset while a gather is armed stays a memset
            harness.drv_if.dma_set_index(IdxBase[31:0], 2'b01, 1'b1);
            harness.drv_if.dma_set_dest(TcdmDst);
            harness.drv_if.dma_start_memset(addr_t'(128), 2'b01, 3'd0, tid_gather);
            harness.drv_if.dma_wait(tid_gather, 3'd0);
            for (int unsigned i = 0; i < 128; i++) begin
                if (harness.gen_obi_access.obi_mem_read_byte(TcdmDst + i) !== 8'hFF) errors++;
            end
            $display("[TB] memset with an armed gather checked");
        end

        harness.drv_if.dma_wait_idle(3'd0);
        harness.drv_if.dma_poll_status(2'b10, 3'd0, status);
        if (status[0] !== 1'b0) $fatal(1, "[TB] channel still busy after the last retire");
        if (harness.drv_if.rsp_pending() != 0) begin
            $fatal(1, "[TB] %0d unexpected accelerator responses left over",
                   harness.drv_if.rsp_pending());
        end

        if (errors != 0) $fatal(1, "[TB] TEST FAILED: %0d errors", errors);
        $display("[TB] TEST PASSED");
        $finish;
    end

    initial begin : test_timeout
        repeat (32'd2000000) @(posedge harness.clk);
        $fatal(1, "[TB] timeout: a gather never retired");
    end

endmodule

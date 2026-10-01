// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// On-the-fly compute through the tightly-coupled `inst64` frontend. A `DMOPC` selects
/// MX quantization, the following `DMCPY` is checked byte-exact against the DPI-C golden,
/// and a second `DMOPC` returns the frontend to a plain copy. With `EnableTcdmObi` the TCDM
/// legs then quantize into and dequantize out of the TCDM (OBI) window and transpose a padded
/// edge tile into and out of it, so partial and all-zero write strobes reach the OBI port.
/// `NegCase` 1 proves the unknown-opcode guard fires instead of silently degrading to a copy.
module tb_idma_inst64_compute #(
    /// Elaborate the backend compute datapath; 0 must fail the golden compare
    parameter bit          EnableCompute = 1'b1,
    /// Topology under test; 0 runs the AXI legs only
    parameter bit          EnableTcdmObi = 1'b1,
    /// 0 runs the compute test; 1 latches an undecodable DMOPC byte
    parameter int unsigned NegCase       = 32'd0,
    parameter int unsigned DMATracing    = idma_inst64_tb_pkg::DMATracing
);
    import idma_inst64_tb_pkg::*;

    import "DPI-C" function void gm_load(input int idx, input int val);
    import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
    import "DPI-C" function void gm_mxdequant(input int num_blocks);
    import "DPI-C" function int  gm_get(input int idx);
    import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

    idma_inst64_base #(
        .EnableCompute ( EnableCompute ),
        .EnableTcdmObi ( EnableTcdmObi ),
        .DMATracing    ( DMATracing    )
    ) harness ();

    localparam int unsigned TimeoutCycles = 32'd200000;

    // OCP MX geometry; the FP32 source granule is 128 B, the compressed block 33 B
    localparam int unsigned NumBlocks   = 32'd8;
    localparam int unsigned BlkInBytes  = 32'd128;
    localparam int unsigned BlkOutBytes = 32'd33;
    localparam int unsigned SrcBytes    = NumBlocks * BlkInBytes;
    localparam int unsigned QuantBytes  = NumBlocks * BlkOutBytes;

    localparam int unsigned GuardBytes = 32'd64;
    localparam logic [7:0]  Sentinel   = 8'h5A;

    // Outside the TCDM window in both topologies, so every endpoint decodes to AXI
    localparam addr_t SrcAddr   = 64'h8000_0000;
    localparam addr_t QuantAddr = 64'h9000_0000;
    localparam addr_t CopyAddr  = 64'hA000_0000;

    // TCDM legs: dequant input must be a whole number of beats of blocks
    localparam int unsigned StrbBytes    = AxiDataWidth / 32'd8;
    localparam int unsigned RtBlocks     = StrbBytes;
    localparam int unsigned RtSrcBytes   = RtBlocks * BlkInBytes;
    localparam int unsigned RtQuantBytes = RtBlocks * BlkOutBytes;
    localparam addr_t RtSrcAddr   = 64'hB000_0000;
    localparam addr_t TcdmQuant   = addr_t'(TcdmStart + 64'h0100);
    localparam addr_t TcdmDequant = addr_t'(TcdmStart + 64'h2000);
    localparam addr_t AxiDequant  = 64'hC000_0000;

    // Transpose leg: one padded FP32 tile, edges masked on both axes
    localparam int unsigned TpMode      = 32'd2;
    localparam int unsigned TpElemBytes = 32'd1 << TpMode;
    localparam int unsigned TpNe        = StrbBytes / TpElemBytes;
    localparam int unsigned TpTileBytes = TpNe * StrbBytes;
    localparam int unsigned TpM         = TpNe - 32'd5;
    localparam int unsigned TpN         = TpNe - 32'd11;
    localparam addr_t TpAxiSrc  = 64'hD000_0000;
    localparam addr_t TpTcdmDst = addr_t'(TcdmStart + 64'h5000);
    localparam addr_t TpTcdmSrc = addr_t'(TcdmStart + 64'h7000);
    localparam addr_t TpAxiDst  = 64'hE000_0000;

    int unsigned errors        = 0;
    int unsigned bytes_checked = 0;
    int unsigned bytes_differ  = 0;
    bit          axi_done      = 1'b0;
    bit          tcdm_done     = 1'b0;

    task automatic seed_source();
        logic [31:0] w;
        for (int unsigned el = 0; el < NumBlocks * 32; el++) begin
            w = 32'(gm_stim_fp32(int'(el), int'(NumBlocks * 32), 0));
            for (int unsigned b = 0; b < 4; b++) begin
                harness.mem_write_byte(SrcAddr + el*4 + b, w[b*8 +: 8]);
                gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
            end
        end
        gm_mxquant_fp32(int'(NumBlocks));
    endtask

    /// Sentinel the source-sized window; a copy that ignored the op overruns the golden.
    task automatic poison_destination(input addr_t base);
        for (int unsigned i = 0; i < SrcBytes + 2*GuardBytes; i++) begin
            harness.mem_write_byte(base - GuardBytes + i, Sentinel);
        end
    endtask

    task automatic check_quant_payload();
        logic [7:0] actual;
        logic [7:0] expected;
        for (int unsigned i = 0; i < QuantBytes; i++) begin
            actual   = harness.mem_read_byte(QuantAddr + i);
            expected = 8'(gm_get(int'(i)));
            bytes_checked++;
            if (actual !== expected) begin
                if (errors < 10) begin
                    $error("mxquant mismatch at %0d (blk%0d.%0d): expected 0x%02x, got 0x%02x",
                           i, i/BlkOutBytes, i%BlkOutBytes, expected, actual);
                end
                errors++;
            end
            // a plain copy would land the source byte here instead
            if (actual !== harness.mem_read_byte(SrcAddr + i)) bytes_differ++;
        end
    endtask

    /// Everything past the compressed length must still hold the sentinel.
    task automatic check_quant_extent();
        logic [7:0] tail;
        for (int unsigned i = QuantBytes; i < SrcBytes + GuardBytes; i++) begin
            tail = harness.mem_read_byte(QuantAddr + i);
            if (tail !== Sentinel) begin
                if (errors < 20) $error("mxquant wrote past %0d B at +%0d: 0x%02x",
                                        QuantBytes, i, tail);
                errors++;
            end
        end
        for (int unsigned i = 1; i <= GuardBytes; i++) begin
            tail = harness.mem_read_byte(QuantAddr - i);
            if (tail !== Sentinel) begin
                $error("mxquant underrun at -%0d: 0x%02x", i, tail);
                errors++;
            end
        end
    endtask

    /// Latch a transpose DMOPC and read back what the frontend decoded.
    task automatic check_transpose_cfg(
        input logic [idma_inst64_compute_pkg::TpModeWidth-1:0] mode,
        input logic [idma_pkg::TransposeDimWidth-1:0]          tensor_m,
        input logic [idma_pkg::TransposeDimWidth-1:0]          tensor_n
    );
        idma_pkg::compute_options_t got;
        harness.drv_if.dma_set_compute(
            32'(idma_inst64_compute_pkg::OpcTranspose) |
                (32'(mode) << idma_inst64_compute_pkg::Rs1TpModeLsb),
            (32'(tensor_m) << idma_inst64_compute_pkg::Rs2TpTensorMLsb) |
                (32'(tensor_n) << idma_inst64_compute_pkg::Rs2TpTensorNLsb));
        repeat (4) @(posedge harness.clk);
        got = harness.i_dut.idma_fe_compute_q;
        if (!got.enable || got.op !== idma_pkg::COMPUTE_TRANSPOSE) begin
            $error("DMOPC transpose did not latch: enable=%0b op=%0d", got.enable, got.op);
            errors++;
        end
        if (got.params.transpose.mode !== mode) begin
            $error("transpose mode: expected %0d, got %0d", mode, got.params.transpose.mode);
            errors++;
        end
        if (got.params.transpose.tensor_m !== tensor_m) begin
            $error("transpose tensor_m: expected %0d, got %0d",
                   tensor_m, got.params.transpose.tensor_m);
            errors++;
        end
        if (got.params.transpose.tensor_n !== tensor_n) begin
            $error("transpose tensor_n: expected %0d, got %0d",
                   tensor_n, got.params.transpose.tensor_n);
            errors++;
        end
    endtask

    task automatic check_copy_payload();
        logic [7:0] actual;
        logic [7:0] expected;
        for (int unsigned i = 0; i < SrcBytes; i++) begin
            actual   = harness.mem_read_byte(CopyAddr + i);
            expected = harness.mem_read_byte(SrcAddr + i);
            if (actual !== expected) begin
                if (errors < 20) begin
                    $error("passthrough mismatch at %0d: expected 0x%02x, got 0x%02x",
                           i, expected, actual);
                end
                errors++;
            end
        end
        for (int unsigned i = 1; i <= GuardBytes; i++) begin
            if (harness.mem_read_byte(CopyAddr + SrcBytes + i - 1) !== Sentinel) begin
                $error("passthrough overrun at +%0d", i);
                errors++;
            end
        end
    endtask

    initial begin : test_sequence
        tf_id_t      quant_id;
        tf_id_t      copy_id;
        logic [63:0] next_id_before;
        logic [63:0] next_id_opc;
        logic [63:0] next_id_after;

        @(posedge harness.rst_n);
        repeat (10) @(posedge harness.clk);

        if (NegCase != 32'd0) begin
            $display("[TB] inst64 DMOPC negative case %0d", NegCase);
            // 0x7f decodes to nothing; the frontend must flag it, not fall back silently
            harness.drv_if.dma_set_compute(32'h7f);
            repeat (20) @(posedge harness.clk);
            // the caller greps the transcript for the guard name, as tb_idma_mxneg does
            $display("[TB] DMOPC 0x7f issued");
            $finish;
        end

        // Walking ones over both dimensions; a truncated or aliased bit cannot survive this
        for (int unsigned i = 0; i < idma_pkg::TransposeDimWidth; i++) begin
            check_transpose_cfg(
                idma_inst64_compute_pkg::TpModeWidth'(i),
                idma_pkg::TransposeDimWidth'(32'd1 << i),
                idma_pkg::TransposeDimWidth'(~(32'd1 << i))
            );
        end
        check_transpose_cfg('1, '1, '1);
        if (errors != 0) $fatal(1, "TEST FAILED: %0d DMOPC transpose decode errors", errors);
        $display("[TB] DMOPC transpose operands round-trip over the full %0d-bit range",
                 idma_pkg::TransposeDimWidth);

        $display("[TB] inst64 DMOPC mxquant (EnableCompute=%0d, EnableTcdmObi=%0d): %0d B -> %0d B",
                 EnableCompute, EnableTcdmObi, SrcBytes, QuantBytes);
        seed_source();
        poison_destination(QuantAddr);
        poison_destination(CopyAddr);

        harness.drv_if.dma_poll_status(2'b01, 3'd0, next_id_before);

        harness.drv_if.dma_set_compute(32'(idma_inst64_compute_pkg::OpcMxQuant));
        // DMOPC only latches state; it must not launch a transfer of its own
        harness.drv_if.dma_poll_status(2'b01, 3'd0, next_id_opc);
        if (next_id_opc !== next_id_before) begin
            $fatal(1, "DMOPC launched a transfer: next_id %0d -> %0d",
                   next_id_before, next_id_opc);
        end

        harness.drv_if.dma_set_source(SrcAddr);
        harness.drv_if.dma_set_dest(QuantAddr);
        harness.drv_if.dma_start_copy(addr_t'(SrcBytes), 2'b00, 3'd0, quant_id);
        harness.drv_if.dma_wait(quant_id, 3'd0);

        check_quant_payload();
        check_quant_extent();

        // A bypassed compute path leaves the source bytes; name that instead of a diff dump.
        if (bytes_differ == 0) begin
            $fatal(1, "quantized block is byte-identical to the source: compute did not run");
        end
        if (bytes_checked != QuantBytes) begin
            $fatal(1, "compare loop ran %0d times, expected %0d", bytes_checked, QuantBytes);
        end

        // Back to a plain copy: the latched op must not leak into the next transfer
        harness.drv_if.dma_set_compute(32'(idma_inst64_compute_pkg::OpcPassthrough));
        harness.drv_if.dma_set_dest(CopyAddr);
        harness.drv_if.dma_start_copy(addr_t'(SrcBytes), 2'b00, 3'd0, copy_id);
        harness.drv_if.dma_wait(copy_id, 3'd0);

        check_copy_payload();

        harness.drv_if.dma_poll_status(2'b01, 3'd0, next_id_after);
        if (next_id_after !== next_id_before + 2) begin
            $fatal(1, "next_id moved %0d -> %0d, expected exactly two transfers",
                   next_id_before, next_id_after);
        end
        if (harness.drv_if.rsp_pending() != 0) begin
            $fatal(1, "%0d unexpected accelerator responses left over",
                   harness.drv_if.rsp_pending());
        end

        if (errors != 0) $fatal(1, "TEST FAILED: %0d errors", errors);

        axi_done = 1'b1;
        wait (tcdm_done);

        if (errors != 0) $fatal(1, "TEST FAILED: %0d errors", errors);
        $display({"[TB] TEST PASSED: %0d B quantized byte-exact (%0d of them differ from the ",
                  "source), %0d B copied back through a passthrough DMOPC"},
                 bytes_checked, bytes_differ, SrcBytes);
        $finish;
    end

    // The OBI memory and its accessors only exist in the TCDM topology
    if (EnableTcdmObi) begin : gen_tcdm_legs
        function automatic bit in_tcdm(input addr_t a);
            return (a >= addr_t'(TcdmStart)) && (a < addr_t'(TcdmEnd));
        endfunction

        task automatic wr_byte(input addr_t a, input logic [7:0] d);
            if (in_tcdm(a)) harness.gen_obi_access.obi_mem_write_byte(a, d);
            else            harness.mem_write_byte(a, d);
        endtask

        function automatic logic [7:0] rd_byte(input addr_t a);
            return in_tcdm(a) ? harness.gen_obi_access.obi_mem_read_byte(a)
                              : harness.mem_read_byte(a);
        endfunction

        task automatic fill(input addr_t base, input int unsigned n, input logic [7:0] d);
            for (int unsigned i = 0; i < n; i++) wr_byte(base + i, d);
        endtask

        /// One DMCPY under the latched DMOPC
        task automatic run_copy(input addr_t src, input addr_t dst, input int unsigned len);
            tf_id_t tid;
            harness.drv_if.dma_set_source(src);
            harness.drv_if.dma_set_dest(dst);
            harness.drv_if.dma_start_copy(addr_t'(len), 2'b00, 3'd0, tid);
            harness.drv_if.dma_wait(tid, 3'd0);
        endtask

        /// Compare [base, base+n) to the DPI golden and a guard band either side to the sentinel
        task automatic check_golden(input string what, input addr_t base, input int unsigned n);
            logic [7:0] actual;
            for (int unsigned i = 0; i < n; i++) begin
                actual = rd_byte(base + i);
                if (actual !== 8'(gm_get(int'(i)))) begin
                    if (errors < 20) $error("%s mismatch at %0d: expected 0x%02x, got 0x%02x",
                                            what, i, 8'(gm_get(int'(i))), actual);
                    errors++;
                end
            end
            for (int unsigned i = 1; i <= GuardBytes; i++) begin
                if (rd_byte(base - i) !== Sentinel || rd_byte(base + n + i - 1) !== Sentinel) begin
                    if (errors < 20) $error("%s guard band clobbered at +/-%0d", what, i);
                    errors++;
                end
            end
        endtask

        /// AXI FP32 -> TCDM MXFP8, TCDM -> TCDM FP32, TCDM -> AXI FP32
        task automatic check_mx_tcdm();
            logic [31:0] w;
            for (int unsigned el = 0; el < RtBlocks * 32; el++) begin
                w = 32'(gm_stim_fp32(int'(el), int'(RtBlocks * 32), 1));
                for (int unsigned b = 0; b < 4; b++) begin
                    wr_byte(RtSrcAddr + el*4 + b, w[b*8 +: 8]);
                    gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
                end
            end
            gm_mxquant_fp32(int'(RtBlocks));
            fill(TcdmQuant - GuardBytes, RtQuantBytes + 2*GuardBytes, Sentinel);
            fill(TcdmDequant - GuardBytes, RtSrcBytes + 2*GuardBytes, Sentinel);
            fill(AxiDequant - GuardBytes, RtSrcBytes + 2*GuardBytes, Sentinel);

            harness.drv_if.dma_set_compute(32'(idma_inst64_compute_pkg::OpcMxQuant));
            run_copy(RtSrcAddr, TcdmQuant, RtSrcBytes);
            check_golden("mxquant AXI->TCDM", TcdmQuant, RtQuantBytes);

            for (int unsigned i = 0; i < RtQuantBytes; i++) begin
                gm_load(int'(i), int'(rd_byte(TcdmQuant + i)));
            end
            gm_mxdequant(int'(RtBlocks));
            harness.drv_if.dma_set_compute(32'(idma_inst64_compute_pkg::OpcMxDequant));
            run_copy(TcdmQuant, TcdmDequant, RtQuantBytes);
            check_golden("mxdequant TCDM->TCDM", TcdmDequant, RtSrcBytes);
            run_copy(TcdmQuant, AxiDequant, RtQuantBytes);
            check_golden("mxdequant TCDM->AXI", AxiDequant, RtSrcBytes);
            $display("[TB] MX over the TCDM: %0d blocks quantized into and dequantized out of OBI",
                     RtBlocks);
        endtask

        /// A padded tile transposed with M and N short of NE: rows past N are all-zero strobes
        task automatic check_transpose(input string what, input addr_t src, input addr_t dst);
            logic [7:0] actual, expected;
            bit         live;
            for (int unsigned i = 0; i < TpTileBytes; i++) wr_byte(src + i, 8'(i * 7 + 3));
            fill(dst - GuardBytes, TpTileBytes + 2*GuardBytes, Sentinel);
            harness.drv_if.dma_set_compute(
                32'(idma_inst64_compute_pkg::OpcTranspose) |
                    (32'(TpMode) << idma_inst64_compute_pkg::Rs1TpModeLsb),
                (32'(TpM) << idma_inst64_compute_pkg::Rs2TpTensorMLsb) |
                    (32'(TpN) << idma_inst64_compute_pkg::Rs2TpTensorNLsb));
            run_copy(src, dst, TpTileBytes);
            // out[n][m] = in[m][n]; masked lanes and rows keep the sentinel
            for (int unsigned n = 0; n < TpNe; n++) begin
                for (int unsigned m = 0; m < TpNe; m++) begin
                    for (int unsigned b = 0; b < TpElemBytes; b++) begin
                        live     = (m < TpM) && (n < TpN);
                        actual   = rd_byte(dst + n*StrbBytes + m*TpElemBytes + b);
                        expected = live ? rd_byte(src + m*StrbBytes + n*TpElemBytes + b)
                                        : Sentinel;
                        if (actual !== expected) begin
                            if (errors < 20) begin
                                $error("%s out[%0d][%0d].%0d: expected 0x%02x, got 0x%02x",
                                       what, n, m, b, expected, actual);
                            end
                            errors++;
                        end
                    end
                end
            end
            for (int unsigned i = 1; i <= GuardBytes; i++) begin
                if (rd_byte(dst - i) !== Sentinel ||
                    rd_byte(dst + TpTileBytes + i - 1) !== Sentinel) begin
                    if (errors < 20) $error("%s guard band clobbered at +/-%0d", what, i);
                    errors++;
                end
            end
            $display("[TB] transpose %s: %0dx%0d of a %0dx%0d tile, %0d all-zero-strobe rows",
                     what, TpM, TpN, TpNe, TpNe, TpNe - TpN);
        endtask

        initial begin : tcdm_sequence
            wait (axi_done);
            check_mx_tcdm();
            check_transpose("AXI->TCDM", TpAxiSrc, TpTcdmDst);
            check_transpose("TCDM->AXI", TpTcdmSrc, TpAxiDst);
            harness.drv_if.dma_set_compute(32'(idma_inst64_compute_pkg::OpcPassthrough));
            tcdm_done = 1'b1;
        end
    end else begin : gen_no_tcdm_legs
        initial tcdm_done = 1'b1;
    end

    initial begin : watchdog
        repeat (TimeoutCycles) @(posedge harness.clk);
        $fatal(1, "simulation timeout after %0d cycles", TimeoutCycles);
    end

endmodule

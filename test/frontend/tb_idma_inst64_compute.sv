// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// inst64 DMOPC: MX quant to both planes byte-exact per group size, then a copy; NegCase 1 guard.
/// With EnableTcdmObi, MX planes and a padded transpose tile also go into and out of the TCDM.
module tb_idma_inst64_compute #(
    /// Elaborate the backend compute datapath; 0 must fail the golden compare
    parameter bit          EnableCompute = 1'b1,
    /// Topology under test (1: TCDM over OBI); run with the matching monitor bind top
    parameter bit          EnableTcdmObi = 1'b0,
    /// 0 runs the compute test; 1 latches an undecodable DMOPC byte
    parameter int unsigned NegCase       = 32'd0,
    /// Compute ops of the DUT (idma_pkg::compute_enable_t bits)
    parameter logic [3:0]  ComputeOpsMask = 4'hF,
    parameter int unsigned DMATracing    = idma_inst64_tb_pkg::DMATracing
);
    import idma_inst64_tb_pkg::*;

    import "DPI-C" function void gm_load(input int idx, input int val);
    import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
    import "DPI-C" function void gm_mxdequant(input int num_blocks);
    import "DPI-C" function int  gm_get(input int idx);
    import "DPI-C" function int  gm_get_scale(input int idx);
    import "DPI-C" function void gm_load_scale(input int idx, input int val);
    import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

    idma_inst64_base #(
        .EnableCompute ( EnableCompute ),
        .EnableTcdmObi ( EnableTcdmObi ),
        .ComputeOps    ( idma_pkg::compute_enable_t'(ComputeOpsMask) ),
        .DMATracing    ( DMATracing    )
    ) harness ();

    localparam int unsigned TimeoutCycles = 32'd200000;

    // OCP MX geometry; the FP32 source granule is 128 B, a block 32 B of data and 1 B of scale
    localparam int unsigned NumBlocks   = 32'd8;
    localparam int unsigned BlkInBytes  = 32'd128;
    localparam int unsigned SrcBytes    = NumBlocks * BlkInBytes;
    localparam int unsigned QuantBytes  = NumBlocks * 33;

    localparam int unsigned GuardBytes = 32'd64;
    // scale planes 6 and 10 x 64 B above the data plane, inside the sentinel window
    localparam int unsigned PlScaleOff [2] = '{32'd6, 32'd10};
    localparam logic [7:0]  Sentinel   = 8'h5A;
    localparam int unsigned HalfBeat   = AxiDataWidth / 16;
    // highest scale address bit + 1 the DMOPC setter reaches
    localparam int unsigned ScaleTop   = (AxiAddrWidth < 62) ? AxiAddrWidth : 62;

    // Outside the TCDM window in both topologies, so every endpoint decodes to AXI
    localparam addr_t SrcAddr   = 64'h8000_0000;
    localparam addr_t QuantAddr = 64'h9000_0000;
    localparam addr_t CopyAddr  = 64'hA000_0000;

    // TCDM legs: two scale groups, the second partial, each plane in the TCDM and over AXI
    localparam int unsigned StrbBytes    = AxiDataWidth / 32'd8;
    localparam int unsigned RtBlocks     = 32'd67;
    localparam int unsigned RtSrcBytes   = RtBlocks * BlkInBytes;
    localparam int unsigned RtQuantBytes = RtBlocks * 32;
    localparam addr_t RtSrcAddr   = 64'hB000_0000;
    localparam addr_t TcdmQuant   = addr_t'(TcdmStart + 64'h0100);
    localparam addr_t TcdmScale   = addr_t'(TcdmStart + 64'h1000);
    localparam addr_t TcdmDequant = addr_t'(TcdmStart + 64'h2000);
    localparam addr_t TcdmFp32    = addr_t'(TcdmStart + 64'h8000);
    localparam addr_t AxiDequant  = 64'hC000_0000;
    localparam addr_t AxiQuant    = 64'hC100_0000;
    localparam addr_t AxiScale    = 64'hC200_0000;

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

    /// Latch an MX DMOPC and read back the decoded MX options.
    task automatic check_mx_cfg(input logic [7:0] opc, input idma_pkg::mx_options_t exp);
        idma_pkg::compute_options_t got;
        harness.drv_if.dma_set_compute(
            32'(opc) |
                (32'(exp.poison_dis) << idma_inst64_compute_pkg::Rs1MxPoisonDisLsb) |
                (32'(exp.rceil)      << idma_inst64_compute_pkg::Rs1MxRceilLsb) |
                (32'(exp.elem_fmt)   << idma_inst64_compute_pkg::Rs1MxElemFmtLsb) |
                (32'(exp.group)      << idma_inst64_compute_pkg::Rs1MxGroupLsb));
        repeat (4) @(posedge harness.clk);
        got = harness.i_dut.idma_fe_compute_q;
        if (!got.enable || got.params.mx !== exp) begin
            $error("DMOPC 0x%02x MX options: expected %h, got %h (enable=%0b)", opc, exp,
                   got.params.mx, got.enable);
            errors++;
        end
    endtask

    /// Latch a scale address and stride with the DMOPC setters and read back the frontend state.
    task automatic check_scale_cfg(input addr_t saddr, input logic [31:0] stride_lines);
        addr_t got_a;
        addr_t got_s;
        harness.drv_if.dma_set_scale(saddr);
        harness.drv_if.dma_set_scale_stride(stride_lines);
        repeat (4) @(posedge harness.clk);
        got_a = harness.i_dut.idma_fe_req_q.burst_req.scale_addr;
        got_s = harness.i_dut.idma_fe_req_q.d_req[0].scale_strides;
        if (got_a !== saddr) begin
            $error("DMOPC scale address: expected %h, got %h", saddr, got_a);
            errors++;
        end
        if (got_s !== addr_t'($signed(stride_lines)) << 6) begin
            $error("DMOPC scale stride: expected %h lines, got %h B", stride_lines, got_s);
            errors++;
        end
    endtask

    /// Data plane at `QuantAddr`, scale plane `soff` x 64 B above, the rest still sentinel.
    task automatic check_planar_payload(input int unsigned soff);
        bytes_checked = 0;
        bytes_differ  = 0;
        for (int unsigned k = 0; k < NumBlocks; k++) begin
            for (int unsigned i = 0; i < 33; i++) begin
                automatic addr_t a = (i == 0) ? QuantAddr + soff * 64 + k
                                              : QuantAddr + k * 32 + i - 1;
                automatic logic [7:0] e = (i == 0) ? 8'(gm_get_scale(int'(k)))
                                                   : 8'(gm_get(int'(k * 32 + i - 1)));
                bytes_checked++;
                if (harness.mem_read_byte(a) !== e) begin
                    if (errors < 10) $error("planar mismatch blk%0d.%0d at %0h: 0x%02x exp 0x%02x",
                                            k, i, a, harness.mem_read_byte(a), e);
                    errors++;
                end
                // a plain copy would land the source byte here instead
                if (harness.mem_read_byte(a) !== harness.mem_read_byte(SrcAddr + a - QuantAddr))
                    bytes_differ++;
            end
        end
        for (int unsigned i = NumBlocks * 32; i < soff * 64; i++)
            if (harness.mem_read_byte(QuantAddr + i) !== Sentinel) begin
                if (errors < 20) $error("planar data plane overrun at +%0d", i);
                errors++;
            end
        for (int unsigned i = soff * 64 + NumBlocks; i < SrcBytes + GuardBytes; i++)
            if (harness.mem_read_byte(QuantAddr + i) !== Sentinel) begin
                if (errors < 20) $error("planar scale plane overrun at +%0d", i);
                errors++;
            end
        for (int unsigned i = 1; i <= GuardBytes; i++)
            if (harness.mem_read_byte(QuantAddr - i) !== Sentinel) begin
                if (errors < 20) $error("mxquant underrun at -%0d", i);
                errors++;
            end
        // A bypassed compute path leaves the source bytes; name that instead of a diff dump.
        if (bytes_differ == 0)
            $fatal(1, "quantized planes are byte-identical to the source: compute did not run");
        if (bytes_checked != QuantBytes)
            $fatal(1, "compare loop ran %0d times, expected %0d", bytes_checked, QuantBytes);
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
        acc_rsp_item_t refused;

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

        // Walking ones over every MX option bit above the reserved ones, both quant opcodes
        for (int unsigned i = idma_pkg::MxOptResvWidth; i < $bits(idma_pkg::mx_options_t); i++)
        begin
            check_mx_cfg(8'(idma_inst64_compute_pkg::OpcMxQuant),
                         idma_pkg::mx_options_t'(1 << i));
            check_mx_cfg(8'(idma_inst64_compute_pkg::OpcMxQuantFp16),
                         idma_pkg::mx_options_t'(~(1 << i) &
                                                 ~((1 << idma_pkg::MxOptResvWidth) - 1)));
        end
        if (errors != 0) $fatal(1, "TEST FAILED: %0d DMOPC MX option decode errors", errors);
        $display("[TB] DMOPC MX options round-trip over all %0d option bits",
                 $bits(idma_pkg::mx_options_t) - idma_pkg::MxOptResvWidth);

        // Walking ones over every scale address bit DMOPC carries (64 B lines, 62-bit space)
        for (int unsigned i = 6; i < ScaleTop; i++)
            check_scale_cfg(addr_t'(1) << i, 32'(1) << (i % 32));
        check_scale_cfg(addr_t'({(ScaleTop-6){1'b1}}) << 6, 32'hFFFF_FFFF);
        if (errors != 0) $fatal(1, "TEST FAILED: %0d DMOPC scale setter errors", errors);
        $display("[TB] DMOPC scale address and stride round-trip over %0d address bits",
                 ScaleTop - 6);

        $display("[TB] inst64 DMOPC mxquant (EnableCompute=%0d, EnableTcdmObi=%0d): %0d B -> %0d B",
                 EnableCompute, EnableTcdmObi, SrcBytes, QuantBytes);
        seed_source();
        poison_destination(QuantAddr);
        poison_destination(CopyAddr);

        harness.drv_if.dma_poll_status(2'b01, 3'd0, next_id_before);

        harness.drv_if.dma_set_scale(QuantAddr + PlScaleOff[0] * 64);
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
        check_planar_payload(PlScaleOff[0]);

        // The same blocks in scale groups of 32, scale plane further up
        poison_destination(QuantAddr);
        harness.drv_if.dma_set_scale(QuantAddr + PlScaleOff[1] * 64);
        harness.drv_if.dma_set_compute(32'(idma_inst64_compute_pkg::OpcMxQuant) |
            (32'(idma_pkg::MX_GROUP_G32) << idma_inst64_compute_pkg::Rs1MxGroupLsb));
        harness.drv_if.dma_set_dest(QuantAddr);
        harness.drv_if.dma_start_copy(addr_t'(SrcBytes), 2'b00, 3'd0, quant_id);
        harness.drv_if.dma_wait(quant_id, 3'd0);
        check_planar_payload(PlScaleOff[1]);

        // A reserved element format is refused at DMCPY: id 0, error set, nothing written
        poison_destination(QuantAddr);
        for (int unsigned f = 2; f < 4; f++) begin
            harness.drv_if.dma_set_compute(32'(idma_inst64_compute_pkg::OpcMxQuant) |
                (32'(f) << idma_inst64_compute_pkg::Rs1MxElemFmtLsb));
            harness.drv_if.dma_try_copy(addr_t'(SrcBytes), 2'b00, 3'd0, refused);
            if (!refused.error || refused.data !== '0) begin
                $error("elem_fmt %0d: DMCPY not refused (error=%0b id=%0d)", f, refused.error,
                       refused.data);
                errors++;
            end
        end
        // every other MX launch refusal of the frontend
        for (int unsigned c = 0; c < 11; c++) begin
            automatic addr_t       src = SrcAddr, dst = QuantAddr, len = addr_t'(SrcBytes);
            automatic logic [31:0] sst = 'h1000, dst_st = 'h1000;
            automatic logic [1:0]  cfg = 2'b00;
            automatic logic [7:0]  opc = 8'(idma_inst64_compute_pkg::OpcMxQuant);
            if (c inside {[6:8]} && !EnableTcdmObi) continue;
            if (c == 9 && ComputeOpsMask[0]) continue;
            unique case (c)
                0: src = SrcAddr + HalfBeat;
                1: dst = QuantAddr + HalfBeat;
                2: len = addr_t'(SrcBytes - BlkInBytes / 2);
                3: begin cfg = 2'b10; sst = 'h1000 + HalfBeat; end
                4: begin cfg = 2'b10; dst_st = 'h1000 + HalfBeat; end
                5: begin cfg = 2'b10; sst = 'h1000 + HalfBeat; end
                6: begin
                    opc = 8'(idma_inst64_compute_pkg::OpcMxDequant);
                    src = addr_t'(idma_inst64_tb_pkg::TcdmStart);
                end
                7: dst = addr_t'(idma_inst64_tb_pkg::TcdmStart);
                8: harness.drv_if.dma_set_scale(addr_t'(idma_inst64_tb_pkg::TcdmStart));
                9: opc = 8'(idma_inst64_compute_pkg::OpcMxQuantFp16);
                10: begin
                    opc = 8'(idma_inst64_compute_pkg::OpcMxDequant);
                    len = addr_t'(1) << 62;
                end
                default: ;
            endcase
            harness.drv_if.dma_set_compute(32'(opc));
            harness.drv_if.dma_set_source(src);
            harness.drv_if.dma_set_dest(dst);
            harness.drv_if.dma_set_strides(sst, dst_st);
            harness.drv_if.dma_set_reps(32'd2);
            if (c == 5) harness.drv_if.dma_try_copy_imm(len, cfg, 3'd0, refused);
            else        harness.drv_if.dma_try_copy(len, cfg, 3'd0, refused);
            if (!refused.error || refused.data !== '0) begin
                $error("MX launch check %0d: DMCPY not refused (error=%0b id=%0d)", c,
                       refused.error, refused.data);
                errors++;
            end
            harness.drv_if.dma_set_scale(QuantAddr + PlScaleOff[1] * 64);
        end
        harness.drv_if.dma_set_source(SrcAddr);
        harness.drv_if.dma_set_strides('0, '0);
        harness.drv_if.dma_set_reps(32'd1);
        repeat (200) @(posedge harness.clk);
        for (int unsigned i = 0; i < SrcBytes + GuardBytes; i++)
            if (harness.mem_read_byte(QuantAddr - GuardBytes + i) !== Sentinel) begin
                if (errors < 20) $error("refused DMCPY wrote at %0d", i);
                errors++;
            end
        $display("[TB] DMCPY refused: reserved MX format, plane off a beat%s, partial block%s",
                 EnableTcdmObi ? " or a scale plane off its data plane's port" : "",
                 ComputeOpsMask[0] ? "" : ", FP16 quant not elaborated");

        // Back to a plain copy: the latched op must not leak into the next transfer
        harness.drv_if.dma_set_compute(32'(idma_inst64_compute_pkg::OpcPassthrough));
        harness.drv_if.dma_set_dest(CopyAddr);
        harness.drv_if.dma_start_copy(addr_t'(SrcBytes), 2'b00, 3'd0, copy_id);
        harness.drv_if.dma_wait(copy_id, 3'd0);

        check_copy_payload();

        harness.drv_if.dma_poll_status(2'b01, 3'd0, next_id_after);
        if (next_id_after !== next_id_before + 3) begin
            $fatal(1, "next_id moved %0d -> %0d, expected exactly three transfers",
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

        /// Compare [base, base+n) to the golden scale plane and a guard band either side
        task automatic check_scale(input string what, input addr_t base, input int unsigned n);
            for (int unsigned k = 0; k < n; k++) begin
                if (rd_byte(base + k) !== 8'(gm_get_scale(int'(k)))) begin
                    if (errors < 20) $error("%s scale %0d: expected 0x%02x, got 0x%02x", what, k,
                                            8'(gm_get_scale(int'(k))), rd_byte(base + k));
                    errors++;
                end
            end
            for (int unsigned i = 1; i <= GuardBytes; i++) begin
                if (rd_byte(base - i) !== Sentinel || rd_byte(base + n + i - 1) !== Sentinel) begin
                    if (errors < 20) $error("%s scale guard band clobbered at +/-%0d", what, i);
                    errors++;
                end
            end
        endtask

        /// One MX DMCPY with its scale plane
        task automatic run_mx(input logic [7:0] opc, input addr_t src, input addr_t dst,
                              input addr_t scl, input int unsigned len);
            harness.drv_if.dma_set_scale(scl);
            harness.drv_if.dma_set_compute(32'(opc));
            run_copy(src, dst, len);
        endtask

        /// Quant both ways across the TCDM, then dequant out of and into it
        task automatic check_mx_tcdm();
            logic [31:0] w;
            for (int unsigned el = 0; el < RtBlocks * 32; el++) begin
                w = 32'(gm_stim_fp32(int'(el), int'(RtBlocks * 32), 1));
                for (int unsigned b = 0; b < 4; b++) begin
                    wr_byte(RtSrcAddr + el*4 + b, w[b*8 +: 8]);
                    wr_byte(TcdmFp32 + el*4 + b, w[b*8 +: 8]);
                    gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
                end
            end
            gm_mxquant_fp32(int'(RtBlocks));
            fill(TcdmQuant - GuardBytes, RtQuantBytes + 2*GuardBytes, Sentinel);
            fill(TcdmScale - GuardBytes, RtBlocks + 2*GuardBytes, Sentinel);
            fill(AxiQuant - GuardBytes, RtQuantBytes + 2*GuardBytes, Sentinel);
            fill(AxiScale - GuardBytes, RtBlocks + 2*GuardBytes, Sentinel);

            run_mx(idma_inst64_compute_pkg::OpcMxQuant, RtSrcAddr, TcdmQuant, TcdmScale,
                   RtSrcBytes);
            check_golden("mxquant AXI->TCDM", TcdmQuant, RtQuantBytes);
            check_scale("mxquant AXI->TCDM", TcdmScale, RtBlocks);
            run_mx(idma_inst64_compute_pkg::OpcMxQuant, TcdmFp32, AxiQuant, AxiScale, RtSrcBytes);
            check_golden("mxquant TCDM->AXI", AxiQuant, RtQuantBytes);
            check_scale("mxquant TCDM->AXI", AxiScale, RtBlocks);

            for (int unsigned i = 0; i < RtQuantBytes; i++) begin
                gm_load(int'(i), int'(rd_byte(TcdmQuant + i)));
            end
            for (int unsigned k = 0; k < RtBlocks; k++) begin
                gm_load_scale(int'(k), int'(rd_byte(TcdmScale + k)));
            end
            gm_mxdequant(int'(RtBlocks));
            fill(TcdmDequant - GuardBytes, RtSrcBytes + 2*GuardBytes, Sentinel);
            fill(AxiDequant - GuardBytes, RtSrcBytes + 2*GuardBytes, Sentinel);
            run_mx(idma_inst64_compute_pkg::OpcMxDequant, TcdmQuant, TcdmDequant, TcdmScale,
                   RtQuantBytes);
            check_golden("mxdequant TCDM->TCDM", TcdmDequant, RtSrcBytes);
            run_mx(idma_inst64_compute_pkg::OpcMxDequant, TcdmQuant, AxiDequant, TcdmScale,
                   RtQuantBytes);
            check_golden("mxdequant TCDM->AXI", AxiDequant, RtSrcBytes);
            fill(TcdmDequant - GuardBytes, RtSrcBytes + 2*GuardBytes, Sentinel);
            run_mx(idma_inst64_compute_pkg::OpcMxDequant, AxiQuant, TcdmDequant, AxiScale,
                   RtQuantBytes);
            check_golden("mxdequant AXI->TCDM", TcdmDequant, RtSrcBytes);
            $display("[TB] MX over the TCDM: %0d blocks quantized and dequantized on both ports",
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

/// Monitor bind tops: `tb_idma_inst64_mon_axi` for the AXI topology, `_obi` for EnableTcdmObi
module tb_idma_inst64_mon_axi;
`include "include/tb_idma_mx_axi_mon_bind.svh"
endmodule

module tb_idma_inst64_mon_obi;
`IDMA_MX_AXI_MON_BIND(idma_backend_r_init_rw_axi_rw_obi)
endmodule

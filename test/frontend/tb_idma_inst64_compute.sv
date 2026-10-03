// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// inst64 DMOPC: MX quant to both planes byte-exact per group size, then a copy; NegCase 1 guard.
module tb_idma_inst64_compute #(
    /// Elaborate the backend compute datapath; 0 must fail the golden compare
    parameter bit          EnableCompute = 1'b1,
    /// Topology under test; MX needs AXI on both ends, so the AXI-only one is the default
    parameter bit          EnableTcdmObi = 1'b0,
    /// 0 runs the compute test; 1 latches an undecodable DMOPC byte
    parameter int unsigned NegCase       = 32'd0,
    parameter int unsigned DMATracing    = idma_inst64_tb_pkg::DMATracing
);
    import idma_inst64_tb_pkg::*;

    import "DPI-C" function void gm_load(input int idx, input int val);
    import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
    import "DPI-C" function int  gm_get(input int idx);
    import "DPI-C" function int  gm_get_scale(input int idx);
    import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

    bind idma_backend_rw_axi idma_mx_axi_mon #(
      .StrbWidth(StrbWidth), .AddrWidth(AddrWidth), .LenWidth(TFLenWidth)
    ) i_mx_axi_mon (
      .clk_i, .rst_ni, .req_valid_i, .req_ready_i(req_ready_o), .req_len_i(idma_req_i.length),
      .req_src_i(idma_req_i.src_addr), .req_dst_i(idma_req_i.dst_addr),
      .req_scale_i(idma_req_i.scale_addr),
      .req_src_burst_i(idma_req_i.opt.src.burst), .req_dst_burst_i(idma_req_i.opt.dst.burst),
      .req_decouple_rw_i(idma_req_i.opt.beo.decouple_rw), .req_cmp_i(idma_req_i.opt.compute),
      .ar_valid_i(axi_read_req_o.ar_valid), .ar_ready_i(axi_read_rsp_i.ar_ready),
      .ar_addr_i(axi_read_req_o.ar.addr), .ar_len_i(axi_read_req_o.ar.len),
      .ar_size_i(axi_read_req_o.ar.size), .ar_burst_i(axi_read_req_o.ar.burst),
      .r_valid_i(axi_read_rsp_i.r_valid), .r_ready_i(axi_read_req_o.r_ready),
      .r_last_i(axi_read_rsp_i.r.last), .aw_valid_i(axi_write_req_o.aw_valid),
      .aw_ready_i(axi_write_rsp_i.aw_ready), .aw_addr_i(axi_write_req_o.aw.addr),
      .aw_len_i(axi_write_req_o.aw.len), .aw_size_i(axi_write_req_o.aw.size),
      .aw_burst_i(axi_write_req_o.aw.burst), .w_valid_i(axi_write_req_o.w_valid),
      .w_ready_i(axi_write_rsp_i.w_ready), .w_data_i(axi_write_req_o.w.data),
      .w_strb_i(axi_write_req_o.w.strb), .w_last_i(axi_write_req_o.w.last),
      .b_valid_i(axi_write_rsp_i.b_valid), .b_ready_i(axi_write_req_o.b_ready)
    );

    idma_inst64_base #(
        .EnableCompute ( EnableCompute ),
        .EnableTcdmObi ( EnableTcdmObi ),
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
    // highest scale address bit + 1 the DMOPC setter reaches
    localparam int unsigned ScaleTop   = (AxiAddrWidth < 62) ? AxiAddrWidth : 62;

    // Outside the TCDM window in both topologies, so every endpoint decodes to AXI
    localparam addr_t SrcAddr   = 64'h8000_0000;
    localparam addr_t QuantAddr = 64'h9000_0000;
    localparam addr_t CopyAddr  = 64'hA000_0000;

    int unsigned errors        = 0;
    int unsigned bytes_checked = 0;
    int unsigned bytes_differ  = 0;

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
        repeat (200) @(posedge harness.clk);
        for (int unsigned i = 0; i < SrcBytes + GuardBytes; i++)
            if (harness.mem_read_byte(QuantAddr - GuardBytes + i) !== Sentinel) begin
                if (errors < 20) $error("refused DMCPY wrote at %0d", i);
                errors++;
            end
        $display("[TB] DMCPY with a reserved MX element format refused");

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
        $display({"[TB] TEST PASSED: %0d B quantized byte-exact (%0d of them differ from the ",
                  "source), %0d B copied back through a passthrough DMOPC"},
                 bytes_checked, bytes_differ, SrcBytes);
        $finish;
    end

    initial begin : watchdog
        repeat (TimeoutCycles) @(posedge harness.clk);
        $fatal(1, "simulation timeout after %0d cycles", TimeoutCycles);
    end

endmodule

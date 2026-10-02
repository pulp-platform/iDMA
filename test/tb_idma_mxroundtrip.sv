// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// MX roundtrip through one rw_axi backend, quant then dequant, checked
// byte-exact against the DPI-C golden (idma_mxquant_dpi.c); the roundtrip is
// the exact E5M2/E4M3 identity. QuantFp16 picks the source/destination format of
// both legs, ElemFmt the MX element format (0 E5M2, 1 E4M3).

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_mxroundtrip
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter bit          QuantFp16  = 1'b1,
  parameter int unsigned ElemFmt    = 0
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_mxquant(input int num_blocks);
  import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
  import "DPI-C" function void gm_mxdequant(input int num_blocks);
  import "DPI-C" function void gm_mxdequant_fp16(input int num_blocks);
  import "DPI-C" function void gm_mxquant_cfg(input int num_blocks, input int fp16, input int elem,
                                              input int rceil, input int poison_dis);
  import "DPI-C" function void gm_mxdequant_cfg(input int num_blocks, input int fp16,
                                                input int elem);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_stim_fp16(input int e, input int total, input int salt);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

  `include "include/tb_idma_mx_common.svh"

  localparam int unsigned NumBlocks = 2 * StrbWidth;  // k % StrbWidth == 0 for dequant

  assign axi_req_mem = axi_req;
  assign axi_rsp     = axi_rsp_mem;

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{mxquant: 1'b1, mxdequant: 1'b1,
                                            mxfp16: QuantFp16, default: '0}),
    .ComputeTuning('1),
    .RAWCouplingAvail(1'b1), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(StrbWidth),
    .MemSysDepth(0),
    .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t), .idma_eh_req_t(idma_eh_req_t),
    .idma_busy_t(idma_busy_t), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .write_meta_channel_t(write_meta_channel_t), .read_meta_channel_t(read_meta_channel_t)
  ) i_idma_backend (
    .clk_i(clk), .rst_ni(rst_n),
    .idma_req_i(idma_req), .req_valid_i(req_valid), .req_ready_o(req_ready),
    .idma_rsp_o(idma_rsp), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
    .idma_eh_req_i(idma_eh_req), .eh_req_valid_i(eh_req_valid), .eh_req_ready_o(eh_req_ready),
    .axi_read_req_o(axi_read_req), .axi_read_rsp_i(axi_read_rsp),
    .axi_write_req_o(axi_write_req), .axi_write_rsp_i(axi_write_rsp), .busy_o(busy)
  );

  stream_watchdog #(.NumCycles(8000)) i_r_wd (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));
  stream_watchdog #(.NumCycles(8000)) i_w_wd (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));


  task automatic do_xfer(input addr_t src, input addr_t dst, input int unsigned L,
                         input idma_pkg::compute_op_e op);
    idma_req = '0;
    idma_req.length   = tf_len_t'(L);
    idma_req.src_addr = src;
    idma_req.dst_addr = dst;
    idma_req.opt.src_protocol = idma_pkg::AXI;
    idma_req.opt.dst_protocol = idma_pkg::AXI;
    idma_req.opt.src.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.beo.decouple_rw = 1'b1;
    idma_req.opt.beo.decouple_aw = 1'b1;
    idma_req.opt.compute.enable  = 1'b1;
    idma_req.opt.compute.op      = op;
    idma_req.opt.compute.params.mx.elem_fmt = idma_pkg::mx_elem_e'(ElemFmt);
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
  endtask

  localparam int unsigned QuantInBytes = QuantFp16 ? 64 : 128;

  // directed E8M0 decode: X = 1, 2^-127, 2^127 and the NaN scale, against literal values
  localparam logic [7:0]  DqScale [4] = '{8'h7F, 8'h00, 8'hFE, 8'hFF};
  localparam logic [7:0]  DqE5m2  [8] = '{8'h40, 8'hC0, 8'h7B, 8'h01, 8'h7C, 8'hFD, 8'h00, 8'h80};
  // E4M3: 2.0, -2.0, max normal 448, min subnormal 2^-9, NaN, -NaN, +-0
  localparam logic [7:0]  DqE4m3  [8] = '{8'h40, 8'hC0, 8'h7E, 8'h01, 8'h7F, 8'hFF, 8'h00, 8'h80};
  // exact: below FP32 min normal gives FP32 subnormals, above FP32 max gives Inf
  localparam logic [31:0] DqE4m3Fp32 [4][8] = '{
    '{32'h4000_0000, 32'hC000_0000, 32'h43E0_0000, 32'h3B00_0000,
      32'h7FC0_0000, 32'h7FC0_0000, 32'h0000_0000, 32'h8000_0000},
    '{32'h0080_0000, 32'h8080_0000, 32'h0460_0000, 32'h0000_2000,
      32'h7FC0_0000, 32'h7FC0_0000, 32'h0000_0000, 32'h8000_0000},
    '{32'h7F80_0000, 32'hFF80_0000, 32'h7F80_0000, 32'h7A80_0000,
      32'h7FC0_0000, 32'h7FC0_0000, 32'h0000_0000, 32'h8000_0000},
    '{default: 32'h7FC0_0000}};
  localparam logic [15:0] DqE4m3Fp16 [4][8] = '{
    '{16'h4000, 16'hC000, 16'h5F00, 16'h1800, 16'h7E00, 16'h7E00, 16'h0000, 16'h8000},
    '{16'h0000, 16'h8000, 16'h0000, 16'h0000, 16'h7E00, 16'h7E00, 16'h0000, 16'h8000},
    '{16'h7C00, 16'hFC00, 16'h7C00, 16'h7C00, 16'h7E00, 16'h7E00, 16'h0000, 16'h8000},
    '{default: 16'h7E00}};
  localparam logic [31:0] DqE5m2Fp32 [4][8] = '{
    '{32'h4000_0000, 32'hC000_0000, 32'h4760_0000, 32'h3780_0000,
      32'h7F80_0000, 32'h7FC0_0000, 32'h0000_0000, 32'h8000_0000},
    '{32'h0080_0000, 32'h8080_0000, 32'h07E0_0000, 32'h0000_0040,
      32'h7F80_0000, 32'h7FC0_0000, 32'h0000_0000, 32'h8000_0000},
    '{32'h7F80_0000, 32'hFF80_0000, 32'h7F80_0000, 32'h7700_0000,
      32'h7F80_0000, 32'h7FC0_0000, 32'h0000_0000, 32'h8000_0000},
    '{default: 32'h7FC0_0000}};
  localparam logic [15:0] DqE5m2Fp16 [4][8] = '{
    '{16'h4000, 16'hC000, 16'h7B00, 16'h0100, 16'h7C00, 16'h7E00, 16'h0000, 16'h8000},
    '{16'h0000, 16'h8000, 16'h0000, 16'h0000, 16'h7C00, 16'h7E00, 16'h0000, 16'h8000},
    '{16'h7C00, 16'hFC00, 16'h7C00, 16'h7C00, 16'h7C00, 16'h7E00, 16'h0000, 16'h8000},
    '{default: 16'h7E00}};
  localparam bit E4m3 = (ElemFmt == 1);

  task automatic do_dequant_directed(output int unsigned errs_lit, output int unsigned errs_gm);
    automatic addr_t src = 'h0007_0000, dst = 'h0009_0000;
    automatic int unsigned nb = StrbWidth, ob = QuantFp16 ? 2 : 4;
    automatic logic [31:0] exp_w, got_w;
    automatic logic [7:0]  el;
    errs_lit = 0; errs_gm = 0;
    for (int unsigned b = 0; b < nb; b++) begin
      wr_mem(src + b*33, DqScale[b % 4]);
      gm_load(int'(b*33), int'(DqScale[b % 4]));
      for (int unsigned e = 0; e < 32; e++) begin
        el = E4m3 ? DqE4m3[(e + b) % 8] : DqE5m2[(e + b) % 8];
        wr_mem(src + b*33 + 1 + e, el);
        gm_load(int'(b*33 + 1 + e), int'(el));
      end
    end
    for (int unsigned i = 0; i < nb*32*ob; i++) wr_mem(dst + i, 8'h5A);
    gm_mxdequant_cfg(int'(nb), int'(QuantFp16), int'(ElemFmt));
    do_xfer(src, dst, nb*33,
            QuantFp16 ? idma_pkg::COMPUTE_MXDEQUANT_FP16 : idma_pkg::COMPUTE_MXDEQUANT);
    for (int unsigned b = 0; b < nb; b++)
      for (int unsigned e = 0; e < 32; e++) begin
        if (E4m3) exp_w = QuantFp16 ? 32'(DqE4m3Fp16[b % 4][(e + b) % 8])
                                    : DqE4m3Fp32[b % 4][(e + b) % 8];
        else      exp_w = QuantFp16 ? 32'(DqE5m2Fp16[b % 4][(e + b) % 8])
                                    : DqE5m2Fp32[b % 4][(e + b) % 8];
        got_w = '0;
        for (int unsigned k = 0; k < ob; k++)
          got_w[k*8 +: 8] = rd_mem(dst + (b*32 + e)*ob + k);
        if (got_w !== exp_w) begin
          errs_lit++;
          if (errs_lit <= 8) $display("[MXRT] E8M0 blk%0d.%0d scale %02h elem %02h = %08h exp %08h",
            b, e, DqScale[b % 4], E4m3 ? DqE4m3[(e + b) % 8] : DqE5m2[(e + b) % 8], got_w, exp_w);
        end
        for (int unsigned k = 0; k < ob; k++)
          if (rd_mem(dst + (b*32 + e)*ob + k) !== 8'(gm_get(int'((b*32 + e)*ob + k)))) errs_gm++;
      end
    $display("[MXRT] E8M0 directed dequant: %0d literal, %0d golden mismatches",
             errs_lit, errs_gm);
  endtask

  initial begin
    automatic addr_t src = 'h0001_0000, mid = 'h0003_0000, dst = 'h0005_0000;
    automatic int unsigned qL  = NumBlocks * QuantInBytes;
    automatic int unsigned mL  = NumBlocks * 33;
    automatic int unsigned dL  = NumBlocks * (QuantFp16 ? 64 : 128);
    automatic int unsigned e1 = 0, e2 = 0, e3 = 0, e4 = 0;
    automatic logic [15:0] h;
    automatic logic [31:0] w;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    if (QuantFp16) begin
      for (int unsigned el = 0; el < NumBlocks*32; el++) begin
        h = 16'(gm_stim_fp16(int'(el), int'(NumBlocks*32), 0));
        wr_mem(src + el*2,     h[7:0]);
        wr_mem(src + el*2 + 1, h[15:8]);
        gm_load(int'(el*2),     int'(h[7:0]));
        gm_load(int'(el*2 + 1), int'(h[15:8]));
      end
      gm_mxquant_cfg(int'(NumBlocks), 1, int'(ElemFmt), 0, 0);
    end else begin
      for (int unsigned el = 0; el < NumBlocks*32; el++) begin
        w = 32'(gm_stim_fp32(int'(el), int'(NumBlocks*32), 0));
        for (int unsigned b = 0; b < 4; b++) begin
          wr_mem(src + el*4 + b, w[b*8 +: 8]);
          gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
        end
      end
      gm_mxquant_cfg(int'(NumBlocks), 0, int'(ElemFmt), 0, 0);
    end
    for (int unsigned i = 0; i < mL; i++) wr_mem(mid + i, 8'hA5);
    for (int unsigned i = 0; i < dL; i++) wr_mem(dst + i, 8'h5A);

    do_xfer(src, mid, qL,
            QuantFp16 ? idma_pkg::COMPUTE_MXQUANT_FP16 : idma_pkg::COMPUTE_MXQUANT);
    for (int unsigned i = 0; i < mL; i++)
      if (rd_mem(mid + i) !== 8'(gm_get(int'(i)))) begin
        e1++;
        if (e1 <= 8)
          $display("[MXRT] quant mid[%0d]=%02h exp %02h", i, rd_mem(mid+i), 8'(gm_get(int'(i))));
      end

    for (int unsigned i = 0; i < mL; i++) gm_load(int'(i), int'(rd_mem(mid + i)));
    gm_mxdequant_cfg(int'(NumBlocks), int'(QuantFp16), int'(ElemFmt));

    do_xfer(mid, dst, mL,
            QuantFp16 ? idma_pkg::COMPUTE_MXDEQUANT_FP16 : idma_pkg::COMPUTE_MXDEQUANT);
    for (int unsigned i = 0; i < dL; i++)
      if (rd_mem(dst + i) !== 8'(gm_get(int'(i)))) begin
        e2++;
        if (e2 <= 8)
          $display("[MXRT] dequant dst[%0d]=%02h exp %02h", i, rd_mem(dst+i), 8'(gm_get(int'(i))));
      end

    do_dequant_directed(e3, e4);

    if (e1 + e2 + e3 + e4 == 0)
      $display("[MXRT] ALL PASS (%0d blocks, StrbWidth=%0d, %s)", NumBlocks, StrbWidth,
               E4m3 ? "E4M3" : "E5M2");
    else
      $fatal(1, "[MXRT] FAIL: quant=%0d dequant=%0d e8m0=%0d/%0d mismatches", e1, e2, e3, e4);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #80_000_000; $fatal(1, "[MXRT] timeout"); end

endmodule

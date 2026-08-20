// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Constrained-random MX compute campaign: back-to-back transfers with a random
// op per iteration (FP16/FP32 quant, dequant, plain copy), random block counts
// and beat-aligned addresses biased toward 4K-crossing writes, all through an
// AXI shim that injects random per-channel stalls. Byte-exact against the DPI-C
// golden; canary bytes around each destination catch out-of-bounds writes.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_mxrand
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter int unsigned NumXfers   = 40,
  parameter int unsigned StallPct   = 40
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_mxquant(input int num_blocks);
  import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
  import "DPI-C" function void gm_mxdequant(input int num_blocks);
  import "DPI-C" function void gm_mxdequant_fp16(input int num_blocks);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_stim_fp16(input int e, input int total, input int salt);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

  `include "include/tb_idma_mx_common.svh"

  // random-stall shim: a channel's go bit may rise any cycle but only falls after its handshake
  logic aw_go, w_go, ar_go, b_go, r_go;
  function automatic logic go_next(input logic go, input logic vld, input logic rdy);
    if (go && vld && !rdy) return 1'b1;
    return ($urandom_range(99) >= StallPct);
  endfunction
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) {aw_go, w_go, ar_go, b_go, r_go} <= '0;
    else begin
      aw_go <= go_next(aw_go, axi_req.aw_valid,    axi_rsp_mem.aw_ready);
      w_go  <= go_next(w_go,  axi_req.w_valid,     axi_rsp_mem.w_ready);
      ar_go <= go_next(ar_go, axi_req.ar_valid,    axi_rsp_mem.ar_ready);
      b_go  <= go_next(b_go,  axi_rsp_mem.b_valid, axi_req.b_ready);
      r_go  <= go_next(r_go,  axi_rsp_mem.r_valid, axi_req.r_ready);
    end
  end
  always_comb begin
    axi_req_mem = axi_req;
    axi_rsp     = axi_rsp_mem;
    axi_req_mem.aw_valid = axi_req.aw_valid & aw_go;
    axi_req_mem.w_valid  = axi_req.w_valid  & w_go;
    axi_req_mem.ar_valid = axi_req.ar_valid & ar_go;
    axi_req_mem.b_ready  = axi_req.b_ready  & b_go;
    axi_req_mem.r_ready  = axi_req.r_ready  & r_go;
    axi_rsp.aw_ready     = axi_rsp_mem.aw_ready & aw_go;
    axi_rsp.w_ready      = axi_rsp_mem.w_ready  & w_go;
    axi_rsp.ar_ready     = axi_rsp_mem.ar_ready & ar_go;
    axi_rsp.b_valid      = axi_rsp_mem.b_valid  & b_go;
    axi_rsp.r_valid      = axi_rsp_mem.r_valid  & r_go;
  end


  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{mxquant: 1'b1, mxdequant: 1'b1,
                                            mxfp16: (StrbWidth <= 64), default: '0}),
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

  int unsigned rsp_cnt;
  always @(posedge clk) if (rsp_valid && rsp_ready) rsp_cnt <= rsp_cnt + 1;

  task automatic do_xfer(input addr_t src, input addr_t dst, input int unsigned L,
                         input logic en, input idma_pkg::compute_op_e op);
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
    idma_req.opt.compute.enable  = en;
    idma_req.opt.compute.op      = op;
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (10) @(posedge clk);
  endtask

  localparam addr_t SrcBase = 'h0001_0000, DstBase = 'h0009_0000;
  localparam int unsigned Margin = 64;

  initial begin
    automatic int unsigned errs = 0;
    automatic logic [7:0]  golden [1024];
    automatic logic [15:0] h;
    automatic logic [31:0] w;
    automatic addr_t src, dst;
    automatic int unsigned op, nb, L, WL, salt;
    automatic bit fp16;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    for (int unsigned x = 0; x < NumXfers; x++) begin
      salt = x * 4099;
      op = $urandom_range(2);
      case (op)
        0: begin  // plain copy, arbitrary alignment, compute idle
          L  = $urandom_range(1, 1000); WL = L;
          src = SrcBase + $urandom_range(4095);
          dst = DstBase + $urandom_range(4095);
          for (int unsigned i = 0; i < L; i++) begin
            golden[i] = 8'((salt + i * 131) ^ (i >> 3));
            wr_mem(src + i, golden[i]);
          end
        end
        1: begin  // MX quant, FP16 below 1024b else FP32, dst biased toward 4K crossings
          fp16 = (StrbWidth <= 64) && $urandom_range(1);
          nb   = $urandom_range(1, 24);
          L    = nb * (fp16 ? 64 : 128); WL = nb * 33;
          src  = SrcBase + StrbWidth * $urandom_range(4096 / StrbWidth - 1);
          dst  = $urandom_range(1) ? DstBase + 'h1000 - StrbWidth * $urandom_range(1, 4)
                                   : DstBase + StrbWidth * $urandom_range(4096 / StrbWidth - 1);
          for (int unsigned el = 0; el < nb * 32; el++) begin
            if (fp16) begin
              h = 16'(gm_stim_fp16(int'(el), int'(nb*32), int'(salt)));
              for (int unsigned b = 0; b < 2; b++) begin
                wr_mem(src + el*2 + b, h[b*8 +: 8]); gm_load(int'(el*2 + b), int'(h[b*8 +: 8]));
              end
            end else begin
              w = 32'(gm_stim_fp32(int'(el), int'(nb*32), int'(salt)));
              for (int unsigned b = 0; b < 4; b++) begin
                wr_mem(src + el*4 + b, w[b*8 +: 8]); gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
              end
            end
          end
          if (fp16) gm_mxquant(int'(nb)); else gm_mxquant_fp32(int'(nb));
        end
        default: begin  // MX dequant, k blocks with k % StrbWidth == 0; FP16 out at <=512b
          fp16 = (StrbWidth <= 64) && $urandom_range(1);
          nb = StrbWidth * ((StrbWidth >= 64) ? 1 : $urandom_range(1, 2));
          L  = nb * 33; WL = nb * (fp16 ? 64 : 128);
          src = SrcBase + StrbWidth * $urandom_range(4096 / StrbWidth - 1);
          dst = DstBase + StrbWidth * $urandom_range(4096 / StrbWidth - 1);
          for (int unsigned i = 0; i < L; i++) begin
            wr_mem(src + i, 8'((salt + i * 197) ^ (i >> 2)));
            gm_load(int'(i), int'(8'((salt + i * 197) ^ (i >> 2))));
          end
          if (fp16) gm_mxdequant_fp16(int'(nb)); else gm_mxdequant(int'(nb));
        end
      endcase

      for (int unsigned i = 0; i < WL + 2 * Margin; i++) wr_mem(dst - Margin + i, 8'hC5);

      case (op)
        0:       do_xfer(src, dst, L, 1'b0, idma_pkg::COMPUTE_NONE);
        1:       do_xfer(src, dst, L, 1'b1,
                         fp16 ? idma_pkg::COMPUTE_MXQUANT_FP16 : idma_pkg::COMPUTE_MXQUANT);
        default: do_xfer(src, dst, L, 1'b1,
                         fp16 ? idma_pkg::COMPUTE_MXDEQUANT_FP16 : idma_pkg::COMPUTE_MXDEQUANT);
      endcase

      for (int unsigned i = 0; i < WL; i++) begin
        automatic logic [7:0] exp_b = (op == 0) ? golden[i] : 8'(gm_get(int'(i)));
        if (rd_mem(dst + i) !== exp_b) begin
          errs++;
          if (errs <= 8) $display("[MXRD] x%0d op%0d dst[%0d]=%02h exp %02h",
                                  x, op, i, rd_mem(dst + i), exp_b);
        end
      end
      for (int unsigned i = 0; i < Margin; i++) begin
        if (rd_mem(dst - Margin + i) !== 8'hC5 || rd_mem(dst + WL + i) !== 8'hC5) begin
          errs++;
          if (errs <= 8)
            $display("[MXRD] x%0d op%0d canary hit near dst=%08h WL=%0d", x, op, dst, WL);
        end
      end
    end

    // pipelined same-config quant stream: lane-exact tail retire across transfer boundaries
    begin
      localparam int unsigned BK = 6, BNb = 24;
      automatic logic [7:0] bgold [BK][BNb*33];
      for (int unsigned k = 0; k < BK; k++) begin
        for (int unsigned el = 0; el < BNb * 32; el++) begin
          w = 32'(gm_stim_fp32(int'(el), int'(BNb*32), int'(k * 7919)));
          for (int unsigned b = 0; b < 4; b++) begin
            wr_mem(SrcBase + k * 'h2000 + el*4 + b, w[b*8 +: 8]);
            gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
          end
        end
        gm_mxquant_fp32(int'(BNb));
        for (int unsigned i = 0; i < BNb * 33; i++) bgold[k][i] = 8'(gm_get(int'(i)));
        for (int unsigned i = 0; i < BNb * 33 + 2 * Margin; i++)
          wr_mem(DstBase + k * 'h2000 - Margin + i, 8'hC5);
      end
      for (int unsigned i = 0; i < 512; i++) begin
        wr_mem(SrcBase + 'hC000 + i, 8'((i * 89 + 5) ^ (i >> 3)));
        wr_mem(DstBase + 'hC000 + i, 8'hC5);
      end
      rsp_cnt = 0;
      for (int unsigned k = 0; k <= BK; k++) begin
        idma_req = '0;
        if (k < BK) begin
          idma_req.length   = tf_len_t'(BNb * 128);
          idma_req.src_addr = SrcBase + k * 'h2000;
          idma_req.dst_addr = DstBase + k * 'h2000;
          idma_req.opt.compute.enable = 1'b1;
          idma_req.opt.compute.op     = idma_pkg::COMPUTE_MXQUANT;
        end else begin
          // different config issued pipelined: the hardware interlock must drain first
          idma_req.length   = tf_len_t'(512);
          idma_req.src_addr = SrcBase + 'hC000;
          idma_req.dst_addr = DstBase + 'hC000;
        end
        idma_req.opt.src_protocol = idma_pkg::AXI;
        idma_req.opt.dst_protocol = idma_pkg::AXI;
        idma_req.opt.src.burst    = axi_pkg::BURST_INCR;
        idma_req.opt.dst.burst    = axi_pkg::BURST_INCR;
        idma_req.opt.beo.decouple_rw = 1'b1;
        idma_req.opt.beo.decouple_aw = 1'b1;
        idma_req.opt.last            = 1'b1;
        req_valid = 1'b1;
        do @(posedge clk); while (!req_ready);
      end
      req_valid = 1'b0;
      idma_req = '0;
      while (rsp_cnt < BK + 1) @(posedge clk);
      repeat (20) @(posedge clk);
      for (int unsigned k = 0; k < BK; k++) begin
        for (int unsigned i = 0; i < BNb * 33; i++)
          if (rd_mem(DstBase + k * 'h2000 + i) !== bgold[k][i]) begin
            errs++;
            if (errs <= 8) $display("[MXRD] b2b k%0d dst[%0d]=%02h exp %02h",
                                    k, i, rd_mem(DstBase + k * 'h2000 + i), bgold[k][i]);
          end
        for (int unsigned i = 0; i < Margin; i++)
          if (rd_mem(DstBase + k * 'h2000 - Margin + i) !== 8'hC5 ||
              rd_mem(DstBase + k * 'h2000 + BNb * 33 + i) !== 8'hC5) begin
            errs++;
            if (errs <= 8) $display("[MXRD] b2b k%0d canary hit", k);
          end
      end
      for (int unsigned i = 0; i < 512; i++)
        if (rd_mem(DstBase + 'hC000 + i) !== 8'((i * 89 + 5) ^ (i >> 3))) begin
          errs++;
          if (errs <= 8) $display("[MXRD] interlock copy dst[%0d] wrong", i);
        end
    end

    if (errs == 0) $display("[MXRD] ALL PASS (%0d transfers, StrbWidth=%0d, StallPct=%0d)",
                            NumXfers, StrbWidth, StallPct);
    else           $fatal(1, "[MXRD] FAIL: %0d mismatches", errs);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #400_000_000; $fatal(1, "[MXRD] timeout"); end

endmodule

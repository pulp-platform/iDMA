// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// End-to-end FP16 -> MXFP8 quantization test: COMPUTE_MXQUANT_FP16 drives
// 64B (32 FP16 elems) -> 33B (E8M0 scale + 32 E5M2) blocks through the rw_axi
// backend. Checked byte-exact against the DPI-C golden (idma_mxquant_dpi.c).
// Watchdogs surface a hang; one run crosses a 4K page boundary.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_mxquant
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_mxquant(input int num_blocks);
  import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_stim_fp16(input int e, input int total);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total);

  `include "include/tb_idma_mx_common.svh"

  localparam int unsigned BlkInBytes  = 64; // 32 FP16 elems
  localparam int unsigned BlkOutBytes = 33;

  assign axi_req_mem = axi_req;
  assign axi_rsp     = axi_rsp_mem;

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{mxquant: 1'b1, mxfp16: (StrbWidth <= 64), default: '0}),
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


  // one num_blocks FP16->MXFP8 transfer; returns error count
  task automatic do_mxquant(input addr_t src, input addr_t dst, input int unsigned num_blocks,
                            output int unsigned errs);
    automatic int unsigned L  = num_blocks * BlkInBytes;
    automatic int unsigned WL = num_blocks * BlkOutBytes;
    automatic logic [15:0] h;
    errs = 0;
    for (int unsigned el = 0; el < num_blocks*32; el++) begin
      h = 16'(gm_stim_fp16(int'(el), int'(num_blocks*32)));
      wr_mem(src + el*2,     h[7:0]);
      wr_mem(src + el*2 + 1, h[15:8]);
      gm_load(int'(el*2),     int'(h[7:0]));
      gm_load(int'(el*2 + 1), int'(h[15:8]));
    end
    gm_mxquant(int'(num_blocks));
    for (int unsigned i = 0; i < WL; i++) wr_mem(dst + i, 8'hA5);
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
    idma_req.opt.compute.op      = idma_pkg::COMPUTE_MXQUANT_FP16;
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    for (int unsigned i = 0; i < WL; i++)
      if (rd_mem(dst + i) !== 8'(gm_get(int'(i)))) begin
        errs++; if (errs <= 8) $display("[MXQ] dst[%0d] blk%0d.%0d = %02h exp %02h",
          i, i/BlkOutBytes, i%BlkOutBytes, rd_mem(dst+i), 8'(gm_get(int'(i))));
      end
  endtask

  // one num_blocks FP32->MXFP8 transfer; returns error count
  task automatic do_mxquant_fp32(input addr_t src, input addr_t dst, input int unsigned num_blocks,
                                 output int unsigned errs);
    automatic int unsigned L  = num_blocks * 128;
    automatic int unsigned WL = num_blocks * BlkOutBytes;
    automatic logic [31:0] w;
    errs = 0;
    for (int unsigned el = 0; el < num_blocks*32; el++) begin
      w = 32'(gm_stim_fp32(int'(el), int'(num_blocks*32)));
      for (int unsigned b = 0; b < 4; b++) begin
        wr_mem(src + el*4 + b, w[b*8 +: 8]);
        gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
      end
    end
    gm_mxquant_fp32(int'(num_blocks));
    for (int unsigned i = 0; i < WL; i++) wr_mem(dst + i, 8'hA5);
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
    idma_req.opt.compute.op      = idma_pkg::COMPUTE_MXQUANT;
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    for (int unsigned i = 0; i < WL; i++)
      if (rd_mem(dst + i) !== 8'(gm_get(int'(i)))) begin
        errs++; if (errs <= 8) $display("[MXQ] fp32 dst[%0d] blk%0d.%0d = %02h exp %02h",
          i, i/BlkOutBytes, i%BlkOutBytes, rd_mem(dst+i), 8'(gm_get(int'(i))));
      end
  endtask

  initial begin
    automatic int unsigned total = 0, e1, e2, e3;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    if (StrbWidth <= 64) begin
      do_mxquant('h0000_2000, 'h0000_4000, 8, e1);   // 8 blocks, aligned
      do_mxquant('h0000_6000, 'h0000_0F80, 6, e2);   // write (198B) crosses 4K boundary
    end else begin
      e1 = 0; e2 = 0;                                // FP16 quant capped at StrbWidth 64
    end
    do_mxquant_fp32('h0000_A000, 'h0000_D000, 8, e3);
    total = e1 + e2 + e3;

    if (total == 0) $display("[MXQ] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else            $fatal(1, "[MXQ] FAIL: %0d mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #80_000_000; $fatal(1, "[MXQ] timeout"); end

endmodule

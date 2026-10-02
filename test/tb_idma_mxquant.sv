// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// End-to-end FP16/FP32 -> MXFP8 quantization test: 64B (32 FP16 elems) or 128B
// (32 FP32 elems) -> 33B (E8M0 scale + 32 E5M2 or E4M3) blocks through the rw_axi
// backend, FLOOR and RCEIL scale rounding. Checked byte-exact against the DPI-C golden
// (idma_mxquant_dpi.c) and against hand-computed blocks.
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
  import "DPI-C" function void gm_mxquant_cfg(input int num_blocks, input int fp16, input int elem,
                                              input int rceil, input int poison_dis);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_stim_fp16(input int e, input int total, input int salt);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

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
                            output int unsigned errs, input mx_elem_e elem = MX_E5M2,
                            input logic rceil = 1'b0);
    automatic int unsigned L  = num_blocks * BlkInBytes;
    automatic int unsigned WL = num_blocks * BlkOutBytes;
    automatic logic [15:0] h;
    errs = 0;
    for (int unsigned el = 0; el < num_blocks*32; el++) begin
      h = 16'(gm_stim_fp16(int'(el), int'(num_blocks*32), 0));
      wr_mem(src + el*2,     h[7:0]);
      wr_mem(src + el*2 + 1, h[15:8]);
      gm_load(int'(el*2),     int'(h[7:0]));
      gm_load(int'(el*2 + 1), int'(h[15:8]));
    end
    gm_mxquant_cfg(int'(num_blocks), 1, int'(elem), int'(rceil), 0);
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
    idma_req.opt.compute.params.mx.elem_fmt = elem;
    idma_req.opt.compute.params.mx.rceil    = rceil;
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    for (int unsigned i = 0; i < WL; i++)
      if (rd_mem(dst + i) !== 8'(gm_get(int'(i)))) begin
        errs++; if (errs <= 8) $display("[MXQ] %s%s dst[%0d] blk%0d.%0d = %02h exp %02h",
          elem.name(), rceil ? " rceil" : "", i, i/BlkOutBytes, i%BlkOutBytes, rd_mem(dst+i),
          8'(gm_get(int'(i))));
      end
  endtask

  // one num_blocks FP32->MXFP8 transfer; returns error count
  task automatic do_mxquant_fp32(input addr_t src, input addr_t dst, input int unsigned num_blocks,
                                 output int unsigned errs, input mx_elem_e elem = MX_E5M2,
                                 input logic rceil = 1'b0);
    automatic int unsigned L  = num_blocks * 128;
    automatic int unsigned WL = num_blocks * BlkOutBytes;
    automatic logic [31:0] w;
    errs = 0;
    for (int unsigned el = 0; el < num_blocks*32; el++) begin
      w = 32'(gm_stim_fp32(int'(el), int'(num_blocks*32), 0));
      for (int unsigned b = 0; b < 4; b++) begin
        wr_mem(src + el*4 + b, w[b*8 +: 8]);
        gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
      end
    end
    gm_mxquant_cfg(int'(num_blocks), 0, int'(elem), int'(rceil), 0);
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
    idma_req.opt.compute.params.mx.elem_fmt = elem;
    idma_req.opt.compute.params.mx.rceil    = rceil;
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    for (int unsigned i = 0; i < WL; i++)
      if (rd_mem(dst + i) !== 8'(gm_get(int'(i)))) begin
        errs++; if (errs <= 8) $display("[MXQ] fp32 %s%s dst[%0d] blk%0d.%0d = %02h exp %02h",
          elem.name(), rceil ? " rceil" : "", i, i/BlkOutBytes, i%BlkOutBytes, rd_mem(dst+i),
          8'(gm_get(int'(i))));
      end
  endtask

  // OCP MX E8M0 conformance: directed FP32 blocks against hand-computed bytes (no DPI)
  localparam int unsigned ConfBlocks = 10;
  task automatic do_conform(input addr_t src, input addr_t dst, input logic pdis,
                            output int unsigned errs);
    automatic logic [31:0] cv [ConfBlocks*32];
    automatic logic [7:0]  cx [ConfBlocks*33];
    errs = 0;
    for (int unsigned e = 0; e < 32; e++) begin
      cv[e]       = 32'h3F80_0000;                               // 1.0: X = 2^-15
      cv[32 + e]  = (e == 1) ? 32'h8000_0000 : 32'h0000_0000;    // zeros: clamps to 2^-127
      cv[64 + e]  = 32'h0080_0000;                               // 2^-126: clamps to 2^-127
      cv[96 + e]  = 32'h0780_0000;                               // 2^-112: exactly 2^-127
      cv[128 + e] = (e == 0) ? 32'h0800_0000 : 32'h0780_0000;    // 2^-111: X = 2^-126
      cv[160 + e] = (e == 0) ? 32'h7F7F_FFFF :                   // FP32 max: X = 2^112
                    (e == 1) ? 32'hFF7F_FFFF : 32'h7F00_0000;
      cv[192 + e] = (e == 0) ? 32'h7F80_0000 : (e == 1) ? 32'hFF80_0000 :
                    (e == 2) ? 32'h7FC0_0000 : (e == 3) ? 32'hFFC0_0001 :
                    32'h3FC0_0000;                               // Inf/NaN: poisoned
      cv[224 + e] = (e == 0) ? 32'h7F80_0000 : 32'h0000_0000;    // Inf over zeros: poisoned
      cv[256 + e] = 32'h0040_0000;                               // 2^-127 subnormals: 1.0
      cv[288 + e] = (e == 0) ? 32'h0000_2000 :                   // 2^-136 -> 2^-9
                    (e == 1) ? 32'h007F_FFFF : 32'h0000_0001;    // max subnormal -> 2.0
    end
    for (int unsigned e = 0; e < 32; e++) begin
      cx[1 + e]   = 8'h78;
      cx[34 + e]  = (e == 1) ? 8'h80 : 8'h00;
      cx[67 + e]  = 8'h40;
      cx[100 + e] = 8'h78;
      cx[133 + e] = (e == 0) ? 8'h78 : 8'h74;
      cx[166 + e] = (e == 0) ? 8'h7B : (e == 1) ? 8'hFB : 8'h78;
      cx[199 + e] = !pdis ? 8'h7D : (e == 0) ? 8'h7B : (e == 1) ? 8'hFB : (e == 2) ? 8'h7D :
                    (e == 3) ? 8'hFD : 8'h7A;
      cx[232 + e] = !pdis ? 8'h7D : (e == 0) ? 8'h7B : 8'h00;
      cx[265 + e] = 8'h3C;
      cx[298 + e] = (e == 0) ? 8'h18 : (e == 1) ? 8'h40 : 8'h00;
    end
    cx[0] = 8'h70; cx[33] = 8'h00; cx[66] = 8'h00; cx[99] = 8'h00;
    cx[132] = 8'h01; cx[165] = 8'hEF;
    cx[198] = pdis ? 8'h70 : 8'hFF; cx[231] = pdis ? 8'h00 : 8'hFF;
    cx[264] = 8'h00; cx[297] = 8'h00;
    for (int unsigned el = 0; el < ConfBlocks*32; el++)
      for (int unsigned b = 0; b < 4; b++) wr_mem(src + el*4 + b, cv[el][b*8 +: 8]);
    for (int unsigned i = 0; i < ConfBlocks*33; i++) wr_mem(dst + i, 8'hA5);
    idma_req = '0;
    idma_req.length   = tf_len_t'(ConfBlocks*128);
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
    idma_req.opt.compute.params.mx.poison_dis = pdis;
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    for (int unsigned i = 0; i < ConfBlocks*33; i++)
      if (rd_mem(dst + i) !== cx[i]) begin
        errs++; if (errs <= 8) $display("[MXQ] conform dst[%0d] blk%0d.%0d = %02h exp %02h",
          i, i/33, i%33, rd_mem(dst+i), cx[i]);
      end
    $display("[MXQ] E8M0 conformance (poison %s): %0d mismatches", pdis ? "off" : "on", errs);
  endtask

  // OCP MX E4M3 and RCEIL conformance: directed FP32 blocks against hand-computed bytes (no DPI).
  // E4M3: max normal 448 = 0x7E, min subnormal 2^-9 = 0x01, NaN S.1111.111; RCEIL raises the scale
  // of a block whose max significand exceeds 1.75. Blocks 6, 7 are quantized to E5M2.
  localparam int unsigned CfBlocks = 8;
  task automatic do_conform_cfg(input addr_t src, input addr_t dst, input logic rceil,
                                input logic pdis, output int unsigned errs);
    automatic logic [31:0] cv [CfBlocks*32];
    automatic logic [7:0]  cx [CfBlocks*33];
    automatic logic [7:0]  c2 [8];
    errs = 0;
    for (int unsigned e = 0; e < CfBlocks*32; e++) cv[e] = 32'h0;
    for (int unsigned e = 0; e < CfBlocks*33; e++) cx[e] = 8'h00;
    for (int unsigned e = 0; e < 32; e++) begin
      cv[e]      = 32'h3F80_0000;                                  // 1.0: X = 2^-8
      cx[1 + e]  = 8'h78;
      cv[160 + e] = 32'h0040_0000;                                 // 2^-127: clamps to 2^-127
      cx[166 + e] = 8'h38;
    end
    cx[0] = 8'h77; cx[165] = 8'h00;
    cv[32] = 32'h43E0_0000; cv[33] = 32'hC3E0_0000; cv[34] = 32'h3F80_0000;  // +-448, 1.0
    cx[33] = 8'h7F; cx[34] = 8'h7E; cx[35] = 8'hFE; cx[36] = 8'h38;
    // 480 (1.875 * 2^8), 2^-9, 2^-10, 1.5 * 2^-10, 7 * 2^-9, 2^-6, 7.5 * 2^-9
    cv[64] = 32'h43F0_0000; cv[65] = 32'h3B00_0000; cv[66] = 32'h3A80_0000; cv[67] = 32'h3AC0_0000;
    cv[68] = 32'h3C60_0000; cv[69] = 32'h3C80_0000; cv[70] = 32'h3C70_0000;
    c2 = rceil ? '{8'h80, 8'h77, 8'h00, 8'h00, 8'h00, 8'h04, 8'h04, 8'h04}
               : '{8'h7F, 8'h7E, 8'h01, 8'h00, 8'h01, 8'h07, 8'h08, 8'h08};
    for (int unsigned e = 0; e < 8; e++) cx[66 + e] = c2[e];
    cv[96] = 32'h7F80_0000; cv[97] = 32'h3F80_0000;               // [+Inf, 1.0, 0 x30]
    cv[128] = 32'hFFC0_0000; cv[129] = 32'h4000_0000;              // [-NaN, 2.0, 0 x30]
    for (int unsigned e = 0; e < 33; e++) begin
      cx[99 + e]  = (e == 0) ? 8'hFF : 8'h7F;
      cx[132 + e] = (e == 0) ? 8'hFF : 8'h7F;
    end
    if (pdis) begin
      cx[99] = 8'h77;  cx[100] = 8'h7E; cx[101] = 8'h78;
      cx[132] = 8'h78; cx[133] = 8'hFF; cx[134] = 8'h78;
      for (int unsigned e = 2; e < 32; e++) begin cx[100 + e] = 8'h00; cx[133 + e] = 8'h00; end
    end
    // E5M2: [1.875, 0 x31] saturates under FLOOR, not under RCEIL; [1.75, 1.0, 0 x30] stays
    cv[192] = 32'h3FF0_0000;
    cx[198] = rceil ? 8'h71 : 8'h70; cx[199] = rceil ? 8'h78 : 8'h7B;
    cv[224] = 32'h3FE0_0000; cv[225] = 32'h3F80_0000;
    cx[231] = 8'h70; cx[232] = 8'h7B; cx[233] = 8'h78;
    for (int unsigned el = 0; el < CfBlocks*32; el++)
      for (int unsigned b = 0; b < 4; b++) wr_mem(src + el*4 + b, cv[el][b*8 +: 8]);
    for (int unsigned i = 0; i < 6*33; i++) wr_mem(dst + i, 8'hA5);
    for (int unsigned i = 0; i < 2*33; i++) wr_mem(dst + 'h400 + i, 8'hA5);
    for (int unsigned k = 0; k < 2; k++) begin
      idma_req = '0;
      idma_req.length   = tf_len_t'((k == 0) ? 6*128 : 2*128);
      idma_req.src_addr = src + ((k == 0) ? 0 : 6*128);
      idma_req.dst_addr = dst + ((k == 0) ? 0 : 'h400);
      idma_req.opt.src_protocol = idma_pkg::AXI;
      idma_req.opt.dst_protocol = idma_pkg::AXI;
      idma_req.opt.src.burst    = axi_pkg::BURST_INCR;
      idma_req.opt.dst.burst    = axi_pkg::BURST_INCR;
      idma_req.opt.beo.decouple_rw = 1'b1;
      idma_req.opt.beo.decouple_aw = 1'b1;
      idma_req.opt.compute.enable  = 1'b1;
      idma_req.opt.compute.op      = idma_pkg::COMPUTE_MXQUANT;
      idma_req.opt.compute.params.mx.poison_dis = pdis;
      idma_req.opt.compute.params.mx.rceil      = rceil;
      idma_req.opt.compute.params.mx.elem_fmt   = (k == 0) ? MX_E4M3 : MX_E5M2;
      idma_req.opt.last            = 1'b1;
      req_valid = 1'b1;
      do @(posedge clk); while (!req_ready);
      req_valid = 1'b0;
      idma_req = '0;
      while (!(rsp_valid && rsp_ready)) @(posedge clk);
      repeat (20) @(posedge clk);
    end
    for (int unsigned i = 0; i < CfBlocks*33; i++) begin
      automatic addr_t a = (i < 6*33) ? dst + i : dst + 'h400 + (i - 6*33);
      if (rd_mem(a) !== cx[i]) begin
        errs++; if (errs <= 8) $display("[MXQ] conform cfg blk%0d.%0d = %02h exp %02h",
          i/33, i%33, rd_mem(a), cx[i]);
      end
    end
    $display("[MXQ] E4M3/RCEIL conformance (%s, poison %s): %0d mismatches",
             rceil ? "RCEIL" : "FLOOR", pdis ? "off" : "on", errs);
  endtask

  initial begin
    automatic int unsigned total = 0, e1, e2, e3, e4, e5;
    automatic int unsigned c [8];
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
    do_conform('h0001_2000, 'h0001_4000, 1'b0, e4);
    do_conform('h0001_6000, 'h0001_8000, 1'b1, e5);
    total = e1 + e2 + e3 + e4 + e5;
    for (int unsigned k = 0; k < 4; k++)
      do_conform_cfg('h0002_0000 + k * 'h2000, 'h0003_0000 + k * 'h2000, k[0], k[1], c[k]);
    if (StrbWidth <= 64) begin
      do_mxquant('h0004_0000, 'h0004_8000, 8, c[4], MX_E4M3, 1'b0);
      do_mxquant('h0005_0000, 'h0005_8000, 6, c[5], MX_E5M2, 1'b1);
    end else begin
      c[4] = 0; c[5] = 0;
    end
    do_mxquant_fp32('h0006_0000, 'h0006_8000, 8, c[6], MX_E4M3, 1'b1);
    do_mxquant_fp32('h0007_0000, 'h0007_8000, 8, c[7], MX_E4M3, 1'b0);
    for (int unsigned k = 0; k < 8; k++) total += c[k];

    if (total == 0) $display("[MXQ] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else            $fatal(1, "[MXQ] FAIL: %0d mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #80_000_000; $fatal(1, "[MXQ] timeout"); end

endmodule

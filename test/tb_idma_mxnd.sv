// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// MX through the ND midend: the scale plane address steps per row with its own strides.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_mxnd
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 512,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_mxquant_cfg(input int num_blocks, input int fp16,
                                               input int e4m3, input int rceil, input int pdis);
  import "DPI-C" function void gm_mxdequant_cfg(input int num_blocks, input int fp16,
                                                 input int e4m3);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_get_scale(input int idx);
  import "DPI-C" function void gm_load_scale(input int idx, input int val);
  import "DPI-C" function int  gm_stim_fp16(input int e, input int total, input int salt);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

  `include "include/tb_idma_mx_common.svh"

  localparam int unsigned NumDim = 3;
  localparam bit          Fp16   = StrbWidth <= 64;

  typedef logic [AddrWidth-1:0] strides_t;
  typedef logic [31:0]          reps_t;
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)

  idma_nd_req_t nd_req;
  logic         nd_req_valid, nd_req_ready, nd_rsp_valid;

  assign axi_req_mem = axi_req;
  assign axi_rsp     = axi_rsp_mem;

  idma_nd_midend #(
    .NumDim(NumDim), .addr_t(addr_t), .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t),
    .idma_nd_req_t(idma_nd_req_t), .RepWidths('{default: 32'd32})
  ) i_idma_nd_midend (
    .clk_i(clk), .rst_ni(rst_n),
    .nd_req_i(nd_req), .nd_req_valid_i(nd_req_valid), .nd_req_ready_o(nd_req_ready),
    .nd_rsp_o(), .nd_rsp_valid_o(nd_rsp_valid), .nd_rsp_ready_i(1'b1),
    .burst_req_o(idma_req), .burst_req_valid_o(req_valid), .burst_req_ready_i(req_ready),
    .burst_rsp_i(idma_rsp), .burst_rsp_valid_i(rsp_valid), .burst_rsp_ready_o(rsp_ready),
    .busy_o()
  );

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{mxquant: 1'b1, mxdequant: 1'b1, mxfp16: Fp16,
                                            default: '0}),
    .ComputeTuning('1),
    .RAWCouplingAvail(1'b1), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(16),
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

  stream_watchdog #(.NumCycles(20000)) i_r_wd (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));
  stream_watchdog #(.NumCycles(20000)) i_w_wd (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));

  // one ND job: rows of `nblk` blocks, `reps[0]` rows per tile, `reps[1]` tiles
  typedef struct {
    string       tag;
    bit          dq, fp16, g32, e4m3, rceil;
    int unsigned nblk;
    int unsigned reps [2];
    addr_t       src, dst, scl;
    int          src_st [2];
    int          dst_st [2];
    int          scl_st [2];
  } job_t;

  logic [7:0] exp_mem [addr_t];
  addr_t      win_lo [$];
  addr_t      win_hi [$];
  int unsigned salt;

  task automatic window(input addr_t lo, input addr_t hi);
    for (addr_t a = lo; a < hi; a++) if (!exp_mem.exists(a)) wr_mem(a, 8'hA5);
    win_lo.push_back(lo);
    win_hi.push_back(hi);
  endtask

  // the row addresses the ND midend walks: dimension d's stride is added after its inner rows
  task automatic rows_of(input job_t j, output addr_t s [$], output addr_t d [$],
                         output addr_t c [$]);
    automatic addr_t sa = j.src, da = j.dst, ca = j.scl;
    for (int unsigned t = 0; t < j.reps[1]; t++)
      for (int unsigned r = 0; r < j.reps[0]; r++) begin
        s.push_back(sa); d.push_back(da); c.push_back(ca);
        if (r + 1 < j.reps[0]) begin
          sa += addr_t'(j.src_st[0]); da += addr_t'(j.dst_st[0]); ca += addr_t'(j.scl_st[0]);
        end else begin
          sa += addr_t'(j.src_st[1]); da += addr_t'(j.dst_st[1]); ca += addr_t'(j.scl_st[1]);
        end
      end
  endtask

  // writes every row's source and records the bytes the job must produce
  task automatic prepare(input job_t j);
    automatic addr_t s [$], d [$], c [$];
    automatic int unsigned ne = j.nblk * 32;
    automatic int unsigned eb = j.fp16 ? 2 : 4;
    rows_of(j, s, d, c);
    foreach (s[r]) begin
      automatic logic [7:0] dat [] = new[ne];
      automatic logic [7:0] scl [] = new[j.nblk];
      salt++;
      for (int unsigned e = 0; e < ne; e++) begin
        automatic logic [31:0] v = j.fp16 ? 32'(gm_stim_fp16(int'(e), int'(ne), int'(salt)))
                                          : 32'(gm_stim_fp32(int'(e), int'(ne), int'(salt)));
        for (int unsigned b = 0; b < eb; b++) begin
          gm_load(int'(e * eb + b), int'(v[8*b +: 8]));
          if (!j.dq) wr_mem(s[r] + addr_t'(e * eb + b), v[8*b +: 8]);
        end
      end
      gm_mxquant_cfg(int'(j.nblk), int'(j.fp16), int'(j.e4m3), int'(j.rceil), 0);
      for (int unsigned i = 0; i < ne; i++) dat[i] = 8'(gm_get(int'(i)));
      for (int unsigned k = 0; k < j.nblk; k++) scl[k] = 8'(gm_get_scale(int'(k)));
      if (!j.dq) begin
        for (int unsigned k = 0; k < j.nblk; k++) exp_mem[c[r] + addr_t'(k)] = scl[k];
        for (int unsigned i = 0; i < ne; i++) exp_mem[d[r] + addr_t'(i)] = dat[i];
      end else begin
        for (int unsigned k = 0; k < j.nblk; k++) begin
          wr_mem(c[r] + addr_t'(k), scl[k]);
          gm_load_scale(int'(k), int'(scl[k]));
        end
        for (int unsigned i = 0; i < ne; i++) begin
          wr_mem(s[r] + addr_t'(i), dat[i]);
          gm_load(int'(i), int'(dat[i]));
        end
        gm_mxdequant_cfg(int'(j.nblk), int'(j.fp16), int'(j.e4m3));
        for (int unsigned i = 0; i < ne * eb; i++)
          exp_mem[d[r] + addr_t'(i)] = 8'(gm_get(int'(i)));
      end
    end
    // canaries around every written row, data and scale
    foreach (d[r]) begin
      window(d[r] - 64, d[r] + addr_t'(j.dq ? ne * eb : ne) + 64);
      if (!j.dq) window(c[r] - 64, c[r] + addr_t'(j.nblk) + 64);
    end
  endtask

  function automatic idma_nd_req_t req_of(input job_t j);
    automatic idma_nd_req_t r = '0;
    r.burst_req.length     = tf_len_t'(j.dq ? j.nblk * 32 : j.nblk * (j.fp16 ? 64 : 128));
    r.burst_req.src_addr   = j.src;
    r.burst_req.dst_addr   = j.dst;
    r.burst_req.scale_addr = j.scl;
    r.burst_req.opt.src_protocol = idma_pkg::AXI;
    r.burst_req.opt.dst_protocol = idma_pkg::AXI;
    r.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    r.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    r.burst_req.opt.compute.enable = 1'b1;
    r.burst_req.opt.compute.op     = j.dq ? (j.fp16 ? COMPUTE_MXDEQUANT_FP16 : COMPUTE_MXDEQUANT)
                                          : (j.fp16 ? COMPUTE_MXQUANT_FP16 : COMPUTE_MXQUANT);
    r.burst_req.opt.compute.params.mx.group    = j.g32 ? MX_GROUP_G32 : MX_GROUP_G64;
    r.burst_req.opt.compute.params.mx.elem_fmt = j.e4m3 ? MX_E4M3 : MX_E5M2;
    r.burst_req.opt.compute.params.mx.rceil    = j.rceil;
    for (int unsigned k = 0; k < 2; k++) begin
      r.d_req[k].reps          = reps_t'(j.reps[k]);
      r.d_req[k].src_strides   = strides_t'(j.src_st[k]);
      r.d_req[k].dst_strides   = strides_t'(j.dst_st[k]);
      r.d_req[k].scale_strides = strides_t'(j.scl_st[k]);
    end
    return r;
  endfunction

  task automatic run(input job_t j, output int unsigned errs);
    prepare(j);
    nd_req       = req_of(j);
    nd_req_valid = 1'b1;
    do @(posedge clk); while (!nd_req_ready);
    nd_req_valid = 1'b0;
    nd_req       = '0;
    while (!nd_rsp_valid) @(posedge clk);
    repeat (20) @(posedge clk);
    errs = 0;
    foreach (win_lo[w])
      for (addr_t a = win_lo[w]; a < win_hi[w]; a++) begin
        automatic logic [7:0] e = exp_mem.exists(a) ? exp_mem[a] : 8'hA5;
        if (rd_mem(a) !== e) begin
          errs++;
          if (errs <= 8) $display("[MXND] %s mem[%0h] = %02h exp %02h%s", j.tag, a, rd_mem(a), e,
                                  exp_mem.exists(a) ? "" : " (canary)");
        end
      end
    exp_mem.delete();
    win_lo.delete();
    win_hi.delete();
    $display("[MXND] %s: %0d rows, %0d mismatches", j.tag, j.reps[0] * j.reps[1], errs);
  endtask

  initial begin
    automatic int unsigned total = 0, e;
    automatic job_t js [$];
    automatic int unsigned bw = (StrbWidth > 32) ? StrbWidth : 32;
    nd_req_valid = 1'b0; nd_req = '0; salt = 0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    // MXCore-like A tile on padded rows: 1 block per row, 16 rows x 2 k-tiles, a scale line per row
    js.push_back('{"q16 1-block rows", 0, 1, 0, 0, 0, 1, '{16, 2},
                   'h0001_0000, 'h0010_0000, 'h0018_0000,
                   '{2048, 64 - 15 * 2048}, '{bw, 1024 - 15 * bw}, '{64, 1024 - 15 * 64}});
    // full G64 rows: a contiguous [rows][64] scale plane
    js.push_back('{"q32 64-block rows", 0, 0, 0, 0, 0, 64, '{4, 1},
                   'h0002_0000, 'h0020_0000, 'h0028_0000,
                   '{8192, 0}, '{2048, 0}, '{64, 0}});
    // odd-sized G32 E4M3 RCEIL rows, scale lines walking down
    js.push_back('{"q16 33-block G32 rows", 0, 1, 1, 1, 1, 33, '{3, 2},
                   'h0004_0000, 'h0030_0000, 'h0038_0000,
                   '{4096, 4096}, '{1088, 1088}, '{-128, -256}});
    // dequant, one block per row
    js.push_back('{"dq32 1-block rows", 1, 0, 0, 0, 0, 1, '{16, 1},
                   'h0040_0000, 'h0048_0000, 'h0044_0000,
                   '{bw, 0}, '{256, 0}, '{64, 0}});
    // dequant, odd G32 rows (half beat at 512 bit)
    js.push_back('{"dq16 3-block G32 E4M3 rows", 1, 1, 1, 1, 0, 3, '{5, 2},
                   'h0050_0000, 'h0058_0000, 'h0054_0000,
                   '{256, 4096}, '{512, 4096}, '{192, -64}});
    foreach (js[k]) begin
      if (js[k].fp16 && !Fp16) continue;
      run(js[k], e);
      total += e;
    end

    if (total == 0) $display("[MXND] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else            $fatal(1, "[MXND] FAIL: %0d mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #200_000_000; $fatal(1, "[MXND] timeout"); end

endmodule

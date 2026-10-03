// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// MX data and scale planes end to end, every byte and the canaries around both planes.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_mxplanar
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 512,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_mxquant(input int num_blocks);
  import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
  import "DPI-C" function void gm_mxdequant(input int num_blocks);
  import "DPI-C" function void gm_mxdequant_fp16(input int num_blocks);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_get_scale(input int idx);
  import "DPI-C" function void gm_load_scale(input int idx, input int val);
  import "DPI-C" function int  gm_stim_fp16(input int e, input int total, input int salt);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

  `include "include/tb_idma_mx_common.svh"

  localparam bit Fp16 = StrbWidth <= 64;

  assign axi_req_mem = axi_req;
  assign axi_rsp     = axi_rsp_mem;

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

  typedef struct {
    bit          dq;
    bit          fp16;
    bit          g32;
    int unsigned nblk;
    addr_t       src;
    addr_t       dst;
    int          soff;
  } xfer_t;

  // expected bytes of the transfers in flight; any other byte in a checked window is a canary
  logic [7:0] exp_mem [addr_t];
  addr_t      win_lo [$];
  addr_t      win_hi [$];
  int unsigned salt;

  // compressed side address of block k's data and scale byte
  function automatic addr_t blk_data(input xfer_t x, input int unsigned k);
    return (x.dq ? x.src : x.dst) + addr_t'(k * 32);
  endfunction

  function automatic addr_t blk_scale(input xfer_t x, input int unsigned k);
    return (x.dq ? x.src : x.dst) + addr_t'(x.soff * 64) + addr_t'(k);
  endfunction

  function automatic idma_req_t req_of(input xfer_t x);
    automatic idma_req_t r = '0;
    r.length   = tf_len_t'(x.dq ? x.nblk * 32 : x.nblk * (x.fp16 ? 64 : 128));
    r.src_addr = x.src;
    r.dst_addr = x.dst;
    r.opt.src_protocol = idma_pkg::AXI;
    r.opt.dst_protocol = idma_pkg::AXI;
    r.opt.src.burst    = axi_pkg::BURST_INCR;
    r.opt.dst.burst    = axi_pkg::BURST_INCR;
    r.opt.beo.decouple_rw = 1'b1;
    r.opt.beo.decouple_aw = 1'b1;
    r.opt.compute.enable  = 1'b1;
    r.opt.compute.op      = x.dq ? (x.fp16 ? COMPUTE_MXDEQUANT_FP16 : COMPUTE_MXDEQUANT)
                                 : (x.fp16 ? COMPUTE_MXQUANT_FP16 : COMPUTE_MXQUANT);
    r.opt.compute.params.mx.group     = x.g32 ? MX_GROUP_G32 : MX_GROUP_G64;
    r.opt.compute.params.mx.scale_off = MxScaleOffWidth'(x.soff);
    r.opt.last = 1'b1;
    return r;
  endfunction

  task automatic window(input addr_t lo, input addr_t hi);
    for (addr_t a = lo; a < hi; a++) if (!exp_mem.exists(a)) wr_mem(a, 8'hA5);
    win_lo.push_back(lo);
    win_hi.push_back(hi);
  endtask

  // writes the source of x and records the bytes x must produce
  task automatic prepare(input xfer_t x);
    automatic int unsigned ne = x.nblk * 32;
    automatic int unsigned eb = x.fp16 ? 2 : 4;
    automatic logic [7:0] dat [];
    automatic logic [7:0] scl [];
    salt++;
    // golden planes of fresh FP stimulus
    for (int unsigned e = 0; e < ne; e++) begin
      automatic logic [31:0] v = x.fp16 ? 32'(gm_stim_fp16(int'(e), int'(ne), int'(salt)))
                                        : 32'(gm_stim_fp32(int'(e), int'(ne), int'(salt)));
      for (int unsigned b = 0; b < eb; b++) begin
        gm_load(int'(e * eb + b), int'(v[8*b +: 8]));
        if (!x.dq) wr_mem(x.src + addr_t'(e * eb + b), v[8*b +: 8]);
      end
    end
    if (x.fp16) gm_mxquant(int'(x.nblk)); else gm_mxquant_fp32(int'(x.nblk));
    dat = new[x.nblk * 32];
    scl = new[x.nblk];
    for (int unsigned i = 0; i < x.nblk * 32; i++) dat[i] = 8'(gm_get(int'(i)));
    for (int unsigned k = 0; k < x.nblk; k++) scl[k] = 8'(gm_get_scale(int'(k)));
    if (!x.dq) begin
      for (int unsigned k = 0; k < x.nblk; k++) begin
        exp_mem[blk_scale(x, k)] = scl[k];
        for (int unsigned i = 0; i < 32; i++)
          exp_mem[blk_data(x, k) + addr_t'(i)] = dat[k*32 + i];
      end
      window(x.dst - 128, blk_data(x, x.nblk - 1) + 32 + 128);
      window(blk_scale(x, 0) - 128, blk_scale(x, x.nblk - 1) + 128);
    end else begin
      for (int unsigned k = 0; k < x.nblk; k++) begin
        wr_mem(blk_scale(x, k), scl[k]);
        gm_load_scale(int'(k), int'(scl[k]));
        for (int unsigned i = 0; i < 32; i++)
          wr_mem(blk_data(x, k) + addr_t'(i), dat[k*32 + i]);
      end
      for (int unsigned i = 0; i < x.nblk * 32; i++) gm_load(int'(i), int'(dat[i]));
      if (x.fp16) gm_mxdequant_fp16(int'(x.nblk)); else gm_mxdequant(int'(x.nblk));
      for (int unsigned i = 0; i < x.nblk * 32 * eb; i++)
        exp_mem[x.dst + addr_t'(i)] = 8'(gm_get(int'(i)));
      window(x.dst - 128, x.dst + addr_t'(x.nblk * 32 * eb) + 128);
    end
  endtask

  task automatic issue(input xfer_t x);
    idma_req  = req_of(x);
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req  = '0;
  endtask

  task automatic check(input string tag, output int unsigned errs);
    errs = 0;
    foreach (win_lo[w])
      for (addr_t a = win_lo[w]; a < win_hi[w]; a++) begin
        automatic logic [7:0] e = exp_mem.exists(a) ? exp_mem[a] : 8'hA5;
        if (rd_mem(a) !== e) begin
          errs++;
          if (errs <= 8) $display("[MXPL] %s mem[%0h] = %02h exp %02h%s", tag, a, rd_mem(a), e,
                                  exp_mem.exists(a) ? "" : " (canary)");
        end
      end
    exp_mem.delete();
    win_lo.delete();
    win_hi.delete();
  endtask

  // one transfer at a time, or a batch issued back to back
  task automatic run(input string tag, input xfer_t xs [$], output int unsigned errs);
    automatic int unsigned nrsp = 0;
    foreach (xs[i]) prepare(xs[i]);
    fork
      foreach (xs[i]) issue(xs[i]);
      while (nrsp < xs.size()) begin @(posedge clk); if (rsp_valid && rsp_ready) nrsp++; end
    join
    repeat (20) @(posedge clk);
    check(tag, errs);
    $display("[MXPL] %s: %0d transfers, %0d mismatches", tag, xs.size(), errs);
  endtask

  localparam int unsigned NumN = 10;
  localparam int unsigned Ns [NumN] = '{1, 2, 3, 31, 32, 33, 64, 65, 97, 130};

  initial begin
    automatic int unsigned total = 0, e;
    automatic xfer_t b2b [$];
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0; salt = 0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    for (int dq = 0; dq < 2; dq++)
      for (int f16 = 0; f16 < 2; f16++)
        for (int g32 = 0; g32 < 2; g32++)
          for (int n = 0; n < NumN; n++) begin
            automatic xfer_t x;
            if (f16 && !Fp16) continue;
            x.dq = dq; x.fp16 = f16; x.g32 = g32; x.nblk = Ns[n];
            x.src = 32'h0001_0000;
            x.dst = 32'h0010_0000;
            x.soff = (n % 2) ? -32'sd64 : 32'sd256;
            // a quant data plane or a dequant destination crossing a 4 KiB page
            if (n == NumN - 1) x.dst = 32'h0010_0FC0 & ~32'(StrbWidth - 1);
            if (dq) begin x.src = 32'h0010_0000; x.dst = 32'h0020_0000; end
            run($sformatf("%s%0d G%0d n=%0d", dq ? "dq" : "q", f16 ? 16 : 32,
                          x.g32 ? 32 : 64, x.nblk), '{x}, e);
            total += e;
          end

    // back to back: quant and dequant, both group sizes, interleaved
    for (int i = 0; i < 12; i++) begin
      automatic xfer_t x;
      x.dq = i % 3 == 2; x.fp16 = Fp16 && (i % 2 == 0);
      x.g32 = (i % 5) < 2; x.nblk = Ns[(i * 7) % NumN];
      x.src = 32'h0001_0000 + i * 32'h0001_0000;
      x.dst = 32'h0100_0000 + i * 32'h0002_0000;
      x.soff = (i % 2) ? -32'sd96 : 32'sd512;
      b2b.push_back(x);
    end
    run("b2b mix", b2b, e);
    total += e;

    if (total == 0) $display("[MXPL] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else            $fatal(1, "[MXPL] FAIL: %0d mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #200_000_000; $fatal(1, "[MXPL] timeout"); end

endmodule

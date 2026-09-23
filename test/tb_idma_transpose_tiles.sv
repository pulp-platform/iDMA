// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Back-to-back single-tile transposes through the rw_axi backend, the shape inst64
// issues (one NE x NE padded tile per request). Runs the same request streams on a
// FullDuplex=0 and a FullDuplex=1 backend, checks every destination byte, reports the
// write-channel rate and fails unless full duplex overlaps consecutive tiles. A mixed
// stream interleaves transposes of changing geometry with a plain copy and an MX quant
// (checked against the DPI-C golden, idma_mxquant_dpi.c).

`include "axi/typedef.svh"
`include "idma/typedef.svh"

// One backend plus memory; the top calls its tasks hierarchically
module idma_transpose_tiles_bench
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter bit          FullDuplex = 1'b1
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

  `include "include/tb_idma_mx_common.svh"

  localparam logic [7:0] Guard = 8'hC5;

  assign axi_req_mem = axi_req;
  assign axi_rsp     = axi_rsp_mem;

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{transpose: 1'b1, mxquant: 1'b1, default: '0}),
    .ComputeTuning(idma_pkg::compute_tuning_t'{transpose_full_duplex: FullDuplex}),
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

  // W-channel handshake window and response count
  longint unsigned cyc = 0, w_beats = 0, w_first = 0, w_last = 0, rsp_cnt = 0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (rst_n && axi_req.w_valid && axi_rsp.w_ready) begin
      if (w_beats == 0) w_first <= cyc;
      w_last  <= cyc;
      w_beats <= w_beats + 1;
    end
    if (rst_n && rsp_valid && rsp_ready) rsp_cnt <= rsp_cnt + 1;
  end

  // One request of a stream and the destination bytes it must leave behind
  typedef struct {
    idma_req_t   req;
    addr_t       dst;
    int unsigned dst_len;
  } job_t;

  job_t        jobs [$];
  logic [7:0]  exp_mem [addr_t];

  function automatic int unsigned mode_of(input int unsigned eb);
    return (eb == 8) ? 3 : (eb == 4) ? 2 : (eb == 2) ? 1 : 0;
  endfunction

  function automatic idma_req_t base_req(input addr_t src, input addr_t dst,
                                         input int unsigned len);
    idma_req_t r = '0;
    r.length               = tf_len_t'(len);
    r.src_addr             = src;
    r.dst_addr             = dst;
    r.opt.src_protocol     = idma_pkg::AXI;
    r.opt.dst_protocol     = idma_pkg::AXI;
    r.opt.src.burst        = axi_pkg::BURST_INCR;
    r.opt.dst.burst        = axi_pkg::BURST_INCR;
    r.opt.beo.decouple_rw  = 1'b1;
    r.opt.beo.decouple_aw  = 1'b1;
    r.opt.last             = 1'b1;
    return r;
  endfunction

  // One padded NE x NE tile holding an m x n matrix of eb-byte elements (m, n <= NE)
  task automatic add_tile(input int unsigned m, input int unsigned n, input int unsigned eb,
                          input addr_t src, input addr_t dst, input int unsigned salt);
    automatic int unsigned ne = StrbWidth / eb;
    automatic job_t j;
    for (int unsigned i = 0; i < ne * StrbWidth; i++) begin
      wr_mem(src + i, 8'(((i + salt) * 29 + 7) & 8'hFF));
      wr_mem(dst + i, Guard);
      exp_mem[dst + i] = Guard;
    end
    // out[k][e] = in[e][k]; bytes outside the m x n matrix stay strobed off
    for (int unsigned k = 0; k < n; k++)
      for (int unsigned e = 0; e < m; e++)
        for (int unsigned b = 0; b < eb; b++)
          exp_mem[dst + k * StrbWidth + e * eb + b] = rd_mem(src + e * StrbWidth + k * eb + b);
    j.req                                          = base_req(src, dst, ne * StrbWidth);
    j.req.opt.compute.enable                       = 1'b1;
    j.req.opt.compute.op                           = idma_pkg::COMPUTE_TRANSPOSE;
    j.req.opt.compute.params.transpose.mode        = 2'(mode_of(eb));
    j.req.opt.compute.params.transpose.tensor_m    = 12'(m);
    j.req.opt.compute.params.transpose.tensor_n    = 12'(n);
    j.dst     = dst;
    j.dst_len = ne * StrbWidth;
    jobs.push_back(j);
  endtask

  // Plain copy, deliberately misaligned on both sides
  task automatic add_copy(input addr_t src, input addr_t dst, input int unsigned len);
    automatic job_t j;
    for (int unsigned i = 0; i < len; i++) begin
      wr_mem(src + i, 8'((i * 11 + 1) & 8'hFF));
      exp_mem[dst + i] = 8'((i * 11 + 1) & 8'hFF);
    end
    wr_mem(dst - 1, Guard);   exp_mem[dst - 1]   = Guard;
    wr_mem(dst + len, Guard); exp_mem[dst + len] = Guard;
    j.req     = base_req(src, dst, len);
    j.dst     = dst - 1;
    j.dst_len = len + 2;
    jobs.push_back(j);
  endtask

  // FP32 -> MXFP8 quant of num_blocks blocks, golden from the DPI-C model
  task automatic add_mxquant(input addr_t src, input addr_t dst, input int unsigned num_blocks);
    automatic int unsigned out_len = num_blocks * MxBlockBytes;
    automatic logic [31:0] w;
    automatic job_t j;
    for (int unsigned el = 0; el < num_blocks * 32; el++) begin
      w = 32'(gm_stim_fp32(int'(el), int'(num_blocks * 32), 3));
      for (int unsigned b = 0; b < 4; b++) begin
        wr_mem(src + el * 4 + b, w[b*8 +: 8]);
        gm_load(int'(el * 4 + b), int'(w[b*8 +: 8]));
      end
    end
    gm_mxquant_fp32(int'(num_blocks));
    for (int unsigned i = 0; i < out_len; i++) begin
      wr_mem(dst + i, Guard);
      exp_mem[dst + i] = 8'(gm_get(int'(i)));
    end
    wr_mem(dst + out_len, Guard); exp_mem[dst + out_len] = Guard;
    j.req                    = base_req(src, dst, num_blocks * MxFp32BlockBytes);
    j.req.opt.compute.enable = 1'b1;
    j.req.opt.compute.op     = idma_pkg::COMPUTE_MXQUANT;
    j.dst     = dst;
    j.dst_len = out_len + 1;
    jobs.push_back(j);
  endtask

  // Issue queued jobs back-to-back and check every byte; rate is W beats per 1000 cycles
  task automatic run_jobs(input string name, output int unsigned errs, output int unsigned rate);
    automatic longint unsigned rsp_target;
    automatic int unsigned n = jobs.size();
    errs = 0;
    @(posedge clk);
    #(TA);
    w_beats    = 0;
    rsp_target = rsp_cnt + n;
    foreach (jobs[i]) begin
      idma_req  = jobs[i].req;
      req_valid = 1'b1;
      @(posedge clk);
      while (!req_ready) @(posedge clk);
      #(TA);
    end
    req_valid = 1'b0;
    idma_req  = '0;
    while (rsp_cnt < rsp_target) @(posedge clk);
    repeat (20) @(posedge clk);
    foreach (jobs[i])
      for (int unsigned a = 0; a < jobs[i].dst_len; a++)
        if (rd_mem(jobs[i].dst + a) !== exp_mem[jobs[i].dst + a]) begin
          errs++;
          if (errs <= 8)
            $display("[TILES] FD=%0d %s job %0d dst+0x%0h = %h exp %h", FullDuplex, name, i, a,
                     rd_mem(jobs[i].dst + a), exp_mem[jobs[i].dst + a]);
        end
    rate = int'((1000 * w_beats) / (w_last - w_first + 1));
    $display("[TILES] FD=%0d %-34s %2d jobs %5d W beats in %5d cycles = %.3f beat/cycle %s",
             FullDuplex, name, n, w_beats, w_last - w_first + 1, real'(rate) / 1000.0,
             (errs == 0) ? "PASS" : "FAIL");
    jobs.delete();
    exp_mem.delete();
  endtask

  // Streams shared by both benches; returns the self-checked single-tile rates
  task automatic run_all(output int unsigned errs, output int unsigned rate_same,
                         output int unsigned rate_runs);
    automatic int unsigned e, rate;
    automatic int unsigned ne;
    automatic int unsigned max_eb = (StrbWidth < 8) ? StrbWidth : 8;
    automatic addr_t src = 'h0010_0000;
    automatic addr_t dst = 'h0040_0000;
    // one 4 KiB-aligned slot per job, large enough for a tile, the copy and the MX source
    automatic int unsigned tile = (StrbWidth * StrbWidth > 4096) ? StrbWidth * StrbWidth : 4096;
    errs = 0;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    wait (rst_n === 1'b1);
    repeat (5) @(posedge clk);

    // identical full tiles: the inst64 steady state
    for (int unsigned t = 0; t < 12; t++)
      add_tile(StrbWidth, StrbWidth, 1, src + t * tile, dst + t * tile, t);
    run_jobs("single-tile same geometry", e, rate_same); errs += e;

    // same geometry per run of four, runs change mode and edge shape
    for (int unsigned t = 0; t < 16; t++) begin
      automatic int unsigned eb = 1 << ((t / 4) % ($clog2(max_eb) + 1));
      ne = StrbWidth / eb;
      add_tile((t / 4 == 1) ? ne - 1 : ne, (t / 4 == 2) ? (ne + 1) / 2 : ne, eb,
               src + t * tile, dst + t * tile, 40 + t);
    end
    run_jobs("single-tile runs of four", e, rate_runs); errs += e;

    // geometry changes on every tile
    for (int unsigned t = 0; t < 12; t++) begin
      automatic int unsigned eb = 1 << (t % ($clog2(max_eb) + 1));
      ne = StrbWidth / eb;
      add_tile(1 + (t * 5) % ne, 1 + (t * 3) % ne, eb, src + t * tile, dst + t * tile, 80 + t);
    end
    run_jobs("single-tile changing geometry", e, rate); errs += e;

    // transpose, copy, transpose (other mode), MX quant, transpose, all queued back-to-back
    add_tile(StrbWidth, StrbWidth - 1, 1, src, dst, 120);
    add_tile(StrbWidth, StrbWidth - 1, 1, src + tile, dst + tile, 121);
    add_copy(src + 2 * tile + 3, dst + 2 * tile + 5, 3 * StrbWidth + 7);
    add_tile(StrbWidth / 2, StrbWidth / 2 - 1, 2, src + 3 * tile, dst + 3 * tile, 122);
    add_mxquant(src + 4 * tile, dst + 4 * tile, 4);
    add_tile(StrbWidth / max_eb, 1, max_eb, src + 8 * tile, dst + 8 * tile, 123);
    add_tile(StrbWidth, StrbWidth, 1, src + 9 * tile, dst + 9 * tile, 124);
    run_jobs("mixed transpose / copy / mxquant", e, rate); errs += e;
  endtask

endmodule

module tb_idma_transpose_tiles #(
  parameter int unsigned DataWidth      = 64,
  /// FD=1 must beat FD=0 on identical single tiles by at least this factor (in percent)
  parameter int unsigned MinGainPct     = 150,
  /// Same for runs of four equal tiles; a config change drains the backend between runs
  parameter int unsigned MinRunsGainPct = 120
);

  idma_transpose_tiles_bench #(.DataWidth(DataWidth), .FullDuplex(1'b0)) i_fd0 ();
  idma_transpose_tiles_bench #(.DataWidth(DataWidth), .FullDuplex(1'b1)) i_fd1 ();

  initial begin
    automatic int unsigned e0, e1, r0, r1, q0, q1;
    // benches run one after the other: the DPI-C golden keeps global state
    i_fd0.run_all(e0, r0, q0);
    i_fd1.run_all(e1, r1, q1);
    $display("[TILES] same geometry: FD=0 %.3f, FD=1 %.3f beat/cycle (min gain %0d%%)",
             real'(r0) / 1000.0, real'(r1) / 1000.0, MinGainPct);
    $display("[TILES] runs of four:  FD=0 %.3f, FD=1 %.3f beat/cycle (min gain %0d%%)",
             real'(q0) / 1000.0, real'(q1) / 1000.0, MinRunsGainPct);
    if (e0 + e1 != 0)
      $fatal(1, "[TILES] FAIL: %0d mismatches (FD=0 %0d, FD=1 %0d)", e0 + e1, e0, e1);
    if (r1 * 100 < r0 * MinGainPct || q1 * 100 < q0 * MinRunsGainPct)
      $fatal(1, "[TILES] FAIL: full duplex does not overlap back-to-back tiles");
    $display("[TILES] ALL PASS (DataWidth=%0d)", DataWidth);
    $finish();
  end

  initial begin #200_000_000; $fatal(1, "[TILES] timeout"); end

endmodule

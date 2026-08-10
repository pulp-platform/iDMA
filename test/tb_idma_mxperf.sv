// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Steady-state throughput: measures bottleneck-channel utilization (beats per
// cycle between first and last handshake) for large MX transfers against an
// ideal memory. Quant is read-bound, dequant write-bound; each must stay within
// UtilSlackPct of the plain-copy baseline on the same channel.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_mxperf
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth    = 64,
  parameter int unsigned AddrWidth    = 32,
  parameter int unsigned UserWidth    = 1,
  parameter int unsigned AxiIdWidth   = 12,
  parameter int unsigned TFLenWidth   = 32,
  parameter int unsigned UtilSlackPct = 5
);

  localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
  localparam int unsigned StrbWidth = DataWidth / 8;

  typedef logic [AddrWidth-1:0]  addr_t;
  typedef logic [DataWidth-1:0]  data_t;
  typedef logic [StrbWidth-1:0]  strb_t;
  typedef logic [AxiIdWidth-1:0] id_t;
  typedef logic [UserWidth-1:0]  user_t;
  typedef logic [TFLenWidth-1:0] tf_len_t;

  `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)
  `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
  `AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

  typedef struct packed { axi_ar_chan_t ar_chan; } axi_read_meta_channel_t;
  typedef struct packed { axi_read_meta_channel_t axi; } read_meta_channel_t;
  typedef struct packed { axi_aw_chan_t aw_chan; } axi_write_meta_channel_t;
  typedef struct packed { axi_write_meta_channel_t axi; } write_meta_channel_t;

  logic clk, rst_n;
  idma_req_t    idma_req;    logic req_valid, req_ready;
  idma_rsp_t    idma_rsp;    logic rsp_valid, rsp_ready;
  idma_eh_req_t idma_eh_req; logic eh_req_valid, eh_req_ready;
  axi_req_t axi_read_req, axi_write_req, axi_req;
  axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp;
  idma_busy_t busy;

  assign idma_eh_req = '0;
  assign eh_req_valid = 1'b0;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  axi_rw_join #(.axi_req_t(axi_req_t), .axi_resp_t(axi_rsp_t)) i_axi_rw_join (
    .clk_i(clk), .rst_ni(rst_n),
    .slv_read_req_i(axi_read_req),  .slv_read_resp_o(axi_read_rsp),
    .slv_write_req_i(axi_write_req), .slv_write_resp_o(axi_write_rsp),
    .mst_req_o(axi_req), .mst_resp_i(axi_rsp)
  );

  axi_sim_mem #(
    .AddrWidth(AddrWidth), .DataWidth(DataWidth), .IdWidth(AxiIdWidth), .UserWidth(UserWidth),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
  ) i_axi_sim_mem (
    .clk_i(clk), .rst_ni(rst_n), .axi_req_i(axi_req), .axi_rsp_o(axi_rsp),
    .mon_r_last_o(), .mon_r_beat_count_o(), .mon_r_user_o(), .mon_r_id_o(),
    .mon_r_data_o(), .mon_r_addr_o(), .mon_r_valid_o(),
    .mon_w_last_o(), .mon_w_beat_count_o(), .mon_w_user_o(), .mon_w_id_o(),
    .mon_w_data_o(), .mon_w_addr_o(), .mon_w_valid_o()
  );

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{mxquant: 1'b1, mxdequant: 1'b1, default: '0}),
    .ComputeFullDuplex(1'b1),
    .RAWCouplingAvail(1'b1), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(StrbWidth), .MemSysDepth(0),
    .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t), .idma_eh_req_t(idma_eh_req_t),
    .idma_busy_t(idma_busy_t), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .write_meta_channel_t(write_meta_channel_t), .read_meta_channel_t(read_meta_channel_t)
  ) i_idma_backend (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .idma_req_i(idma_req), .req_valid_i(req_valid), .req_ready_o(req_ready),
    .idma_rsp_o(idma_rsp), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
    .idma_eh_req_i(idma_eh_req), .eh_req_valid_i(eh_req_valid), .eh_req_ready_o(eh_req_ready),
    .axi_read_req_o(axi_read_req), .axi_read_rsp_i(axi_read_rsp),
    .axi_write_req_o(axi_write_req), .axi_write_rsp_i(axi_write_rsp), .busy_o(busy)
  );

  // per-channel handshake windows
  longint cyc, r_beats, w_beats, r_first, r_last, w_first, w_last, rsp_cnt;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (axi_rsp.r_valid && axi_req.r_ready) begin
      if (r_beats == 0) r_first <= cyc;
      r_last  <= cyc;
      r_beats <= r_beats + 1;
    end
    if (axi_req.w_valid && axi_rsp.w_ready) begin
      if (w_beats == 0) w_first <= cyc;
      w_last  <= cyc;
      w_beats <= w_beats + 1;
    end
    if (rsp_valid && rsp_ready) rsp_cnt <= rsp_cnt + 1;
  end

  function automatic int unsigned util_pct(input longint beats, input longint first,
                                           input longint last);
    return (last > first) ? int'(100 * beats / (last - first + 1)) : 100;
  endfunction

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
    repeat (20) @(posedge clk);
  endtask

  task automatic measure(input string name, input addr_t src, input addr_t dst,
                         input int unsigned L, input logic en, input idma_pkg::compute_op_e op,
                         output int unsigned r_util, output int unsigned w_util);
    r_beats = 0; w_beats = 0; r_first = 0; r_last = 0; w_first = 0; w_last = 0;
    do_xfer(src, dst, L, en, op);
    r_util = util_pct(r_beats, r_first, r_last);
    w_util = util_pct(w_beats, w_first, w_last);
    $display("[MXPF] %-12s R %3d%% (%0d beats)  W %3d%% (%0d beats)  StrbWidth=%0d",
             name, r_util, r_beats, w_util, w_beats, StrbWidth);
  endtask

  // pipelined issue: req_valid stays high across the K transfers, one rsp per transfer
  task automatic measure_b2b(input string name, input addr_t src, input addr_t dst,
                             input int unsigned L, input int unsigned K,
                             input logic en, input idma_pkg::compute_op_e op,
                             output int unsigned r_util, output int unsigned w_util);
    r_beats = 0; w_beats = 0; r_first = 0; r_last = 0; w_first = 0; w_last = 0; rsp_cnt = 0;
    for (int unsigned k = 0; k < K; k++) begin
      idma_req = '0;
      idma_req.length   = tf_len_t'(L);
      idma_req.src_addr = src;
      idma_req.dst_addr = dst + k * 'h0001_0000;
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
    end
    req_valid = 1'b0;
    idma_req = '0;
    while (rsp_cnt < K) @(posedge clk);
    repeat (20) @(posedge clk);
    r_util = util_pct(r_beats, r_first, r_last);
    w_util = util_pct(w_beats, w_first, w_last);
    $display("[MXPF] %-12s R %3d%% (%0d beats)  W %3d%% (%0d beats)  StrbWidth=%0d",
             name, r_util, r_beats, w_util, w_beats, StrbWidth);
  endtask

  localparam addr_t Src = 'h0010_0000, Dst = 'h0090_0000;
  localparam int unsigned NbQ  = 512;
  localparam int unsigned NbDq = 8 * StrbWidth;
  localparam int unsigned NbB2b  = 128;
  localparam int unsigned NbDqB2b = 2 * StrbWidth;
  localparam int unsigned KB2b = 8;

  initial begin
    automatic int unsigned cp_r, cp_w, q32_r, q32_w, q16_r, q16_w, dq_r, dq_w;
    automatic int unsigned bcp_r, bcp_w, bq_r, bq_w, bdq_r, bdq_w;
    automatic int unsigned errs = 0;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    for (int unsigned i = 0; i < NbQ * 128; i++) i_axi_sim_mem.mem[Src + i] = 8'(i * 61 + 7);
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    measure("copy",        Src, Dst, NbQ * 128, 1'b0, idma_pkg::COMPUTE_NONE,      cp_r,  cp_w);
    measure("mxquant32",   Src, Dst, NbQ * 128, 1'b1, idma_pkg::COMPUTE_MXQUANT,   q32_r, q32_w);
    if (StrbWidth <= 64)
      measure("mxquant16", Src, Dst, NbQ * 64,  1'b1, idma_pkg::COMPUTE_MXQUANT_FP16, q16_r, q16_w);
    else begin q16_r = cp_r; q16_w = 100; end
    measure("mxdequant",   Src, Dst, NbDq * 33, 1'b1, idma_pkg::COMPUTE_MXDEQUANT, dq_r,  dq_w);

    // pipelined back-to-back streams: aggregate window includes inter-transfer boundaries
    measure_b2b("b2b-copy",    Src, Dst, NbB2b * 128,  KB2b, 1'b0,
                idma_pkg::COMPUTE_NONE,      bcp_r, bcp_w);
    measure_b2b("b2b-quant32", Src, Dst, NbB2b * 128,  KB2b, 1'b1,
                idma_pkg::COMPUTE_MXQUANT,   bq_r,  bq_w);
    measure_b2b("b2b-dequant", Src, Dst, NbDqB2b * 33, KB2b, 1'b1,
                idma_pkg::COMPUTE_MXDEQUANT, bdq_r, bdq_w);

    // quant is read-bound, dequant write-bound; compare against the copy baseline
    if (q32_r + UtilSlackPct < cp_r) begin
      errs++; $display("[MXPF] FAIL mxquant32 R %0d%% vs copy %0d%%", q32_r, cp_r);
    end
    if (q16_r + UtilSlackPct < cp_r) begin
      errs++; $display("[MXPF] FAIL mxquant16 R %0d%% vs copy %0d%%", q16_r, cp_r);
    end
    if (dq_w + UtilSlackPct < cp_w) begin
      errs++; $display("[MXPF] FAIL mxdequant W %0d%% vs copy %0d%%", dq_w, cp_w);
    end
    // no bubbles between transfers on the wide configs (512b/1024b targets)
    if (StrbWidth >= 64) begin
      if (bq_r + UtilSlackPct < bcp_r) begin
        errs++; $display("[MXPF] FAIL b2b-quant32 R %0d%% vs b2b-copy %0d%%", bq_r, bcp_r);
      end
      if (bdq_w + UtilSlackPct < bcp_w) begin
        errs++; $display("[MXPF] FAIL b2b-dequant W %0d%% vs b2b-copy %0d%%", bdq_w, bcp_w);
      end
    end

    if (errs == 0) $display("[MXPF] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else           $fatal(1, "[MXPF] FAIL: %0d utilization regressions", errs);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #400_000_000; $fatal(1, "[MXPF] timeout"); end

endmodule

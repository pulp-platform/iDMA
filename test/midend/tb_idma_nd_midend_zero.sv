// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Zero-repetition ND regression: the rejection survives backpressure and keeps the next base

`include "idma/typedef.svh"

module tb_idma_nd_midend_zero;

  localparam time TCK = 10ns;
  localparam int unsigned AddrWidth = 32;
  localparam int unsigned NumDim    = 2;
  localparam logic [NumDim-1:0][31:0] RepWidths = '{default: 32'd16};
  localparam int unsigned Reps = 3;
  localparam int unsigned Timeout = 50;

  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [31:0]          tf_len_t;
  typedef logic [11:0]          id_t;
  typedef logic [31:0]          reps_t;

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, addr_t)

  localparam addr_t Src = 'h0000_1000, Dst = 'h0002_0000;
  localparam addr_t ZSrc = 'h00ab_0000, ZDst = 'h00cd_0000;
  localparam addr_t SrcStride = 'h40, DstStride = 'h400;

  logic clk, rst_n;
  idma_nd_req_t nd_req;    logic nd_req_valid, nd_req_ready;
  idma_rsp_t    nd_rsp;    logic nd_rsp_valid, nd_rsp_ready;
  idma_req_t    burst_req; logic burst_req_valid, burst_req_ready;
  logic busy;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  clocking cb @(posedge clk);
    default input #1step output #0;
    input  nd_req_ready;
    output nd_req, nd_req_valid;
  endclocking

  idma_nd_midend #(
    .NumDim(NumDim), .addr_t(addr_t), .idma_req_t(idma_req_t),
    .idma_rsp_t(idma_rsp_t), .idma_nd_req_t(idma_nd_req_t), .RepWidths(RepWidths)
  ) i_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .nd_req_i(nd_req), .nd_req_valid_i(nd_req_valid), .nd_req_ready_o(nd_req_ready),
    .nd_rsp_o(nd_rsp), .nd_rsp_valid_o(nd_rsp_valid), .nd_rsp_ready_i(nd_rsp_ready),
    .burst_req_o(burst_req), .burst_req_valid_o(burst_req_valid),
    .burst_req_ready_i(burst_req_ready),
    .burst_rsp_i('0), .burst_rsp_valid_i(1'b0), .burst_rsp_ready_o(),
    .busy_o(busy)
  );

  int unsigned errs, n_rsp, n_offer;
  addr_t cap_src [$];
  addr_t cap_dst [$];
  logic rsp_owed_q;

  // a response offered while not ready must stay until it is taken
  always @(posedge clk) if (rst_n) begin
    if (rsp_owed_q && !nd_rsp_valid) begin
      errs++;
      $display("[NDZ] %0t: response withdrawn before its handshake", $time);
    end
    rsp_owed_q <= nd_rsp_valid && !nd_rsp_ready;
    if (nd_rsp_valid && !nd_rsp_ready) n_offer++;
    if (nd_rsp_valid && nd_rsp_ready) begin
      n_rsp++;
      if (!nd_rsp.error || nd_rsp.pld.err_type != idma_pkg::ND_MIDEND) begin
        errs++;
        $display("[NDZ] %0t: response error %0b type %0d, expected the ND rejection",
                 $time, nd_rsp.error, nd_rsp.pld.err_type);
      end
    end
    if (burst_req_valid && burst_req_ready) begin
      cap_src.push_back(burst_req.src_addr);
      cap_dst.push_back(burst_req.dst_addr);
    end
  end else rsp_owed_q <= 1'b0;

  function automatic idma_nd_req_t mk_req(input reps_t reps, input addr_t s, input addr_t d);
    idma_nd_req_t r = '0;
    r.burst_req.length           = tf_len_t'('h8);
    r.burst_req.src_addr         = s;
    r.burst_req.dst_addr         = d;
    r.burst_req.opt.src_protocol = idma_pkg::AXI;
    r.burst_req.opt.dst_protocol = idma_pkg::AXI;
    r.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    r.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    r.d_req[0].reps              = reps;
    r.d_req[0].src_strides       = SrcStride;
    r.d_req[0].dst_strides       = DstStride;
    return r;
  endfunction

  task automatic send(input idma_nd_req_t r);
    cb.nd_req       <= r;
    cb.nd_req_valid <= 1'b1;
    do @(cb); while (!cb.nd_req_ready);
    cb.nd_req_valid <= 1'b0;
    cb.nd_req       <= '0;
  endtask

  task automatic expect_rsp(input int unsigned n, input string what);
    int unsigned t = 0;
    while (n_rsp < n && t < Timeout) begin @(cb); t++; end
    if (n_rsp != n) begin
      errs++;
      $display("[NDZ] %s: %0d responses, expected %0d", what, n_rsp, n);
    end
  endtask

  initial begin
    errs = 0; n_rsp = 0; n_offer = 0;
    nd_req = '0; nd_req_valid = 1'b0; nd_rsp_ready = 1'b1; burst_req_ready = 1'b1;
    @(posedge rst_n);
    repeat (3) @(cb);

    // case 1: the rejection meets response backpressure
    nd_rsp_ready <= 1'b0;
    fork
      send(mk_req('0, ZSrc, ZDst));
      begin repeat (6) @(cb); nd_rsp_ready <= 1'b1; end
    join
    expect_rsp(1, "backpressured rejection");
    // valid must not wait for ready
    if (n_offer == 0) begin errs++; $display("[NDZ] rejection not offered before ready"); end
    repeat (3) @(cb);

    // case 2: the rejection arrives while the backend stalls, a strided transfer follows
    burst_req_ready <= 1'b0;
    fork
      begin send(mk_req('0, ZSrc, ZDst)); send(mk_req(Reps, Src, Dst)); end
      begin repeat (6) @(cb); burst_req_ready <= 1'b1; end
    join
    expect_rsp(2, "stalled rejection");
    repeat (Reps + 3) @(cb);

    if (cap_src.size() != Reps) begin
      errs++;
      $display("[NDZ] %0d bursts, expected %0d", cap_src.size(), Reps);
    end else for (int unsigned i = 0; i < Reps; i++) begin
      if (cap_src[i] !== Src + i * SrcStride || cap_dst[i] !== Dst + i * DstStride) begin
        errs++;
        $display("[NDZ] burst %0d at (%0h,%0h), expected (%0h,%0h)", i, cap_src[i], cap_dst[i],
                 Src + i * SrcStride, Dst + i * DstStride);
      end
    end

    if (errs == 0) $display("[NDZ] ALL PASS");
    else           $fatal(1, "[NDZ] FAIL: %0d errors", errs);
    $finish();
  end

  initial begin #100_000; $fatal(1, "[NDZ] timeout"); end

endmodule

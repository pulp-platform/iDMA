// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Back-to-back ND regression for idma_nd_midend. Drives the midend directly and
// golden-checks the burst_req address sequence: two back-to-back transfers (no
// gap) plus one after an idle gap must each walk from their own base. Catches a
// stale base-address reuse across transfers.

`include "idma/typedef.svh"

module tb_idma_nd_midend_b2b;

  localparam time TCK = 10ns;
  localparam int unsigned AddrWidth = 32;
  localparam int unsigned NumDim    = 4;     // 1D burst + 3 strided dims
  localparam logic [NumDim-1:0][31:0] RepWidths = '{default: 32'd16};

  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [31:0]          tf_len_t;
  typedef logic [11:0]          id_t;
  typedef logic [31:0]          reps_t;

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, addr_t)

  // ── Program (shared by all three transfers; only the base addresses differ) ──
  localparam int unsigned R0 = 3, R1 = 2, R2 = 2;
  localparam int unsigned NB = R0 * R1 * R2;           // bursts per transfer
  localparam addr_t SS0 = 'h10,   DS0 = 'h100;
  localparam addr_t SS1 = 'h40,   DS1 = 'h400;
  localparam addr_t SS2 = 'h1000, DS2 = 'h4000;
  localparam addr_t S1 = 'h0000_1000, D1 = 'h0001_0000;  // transfer 1 base
  localparam addr_t S2 = 'h0000_2000, D2 = 'h0002_0000;  // transfer 2 base (back-to-back)
  localparam addr_t S3 = 'h0000_3000, D3 = 'h0003_0000;  // transfer 3 base (after idle gap)

  logic clk, rst_n;
  idma_nd_req_t nd_req;  logic nd_req_valid, nd_req_ready;
  idma_rsp_t    nd_rsp;  logic nd_rsp_valid, nd_rsp_ready;
  idma_req_t    burst_req; logic burst_req_valid, burst_req_ready;
  idma_rsp_t    burst_rsp; logic burst_rsp_valid, burst_rsp_ready;
  logic busy;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  idma_nd_midend #(
    .NumDim(NumDim), .addr_t(addr_t), .idma_req_t(idma_req_t),
    .idma_rsp_t(idma_rsp_t), .idma_nd_req_t(idma_nd_req_t), .RepWidths(RepWidths)
  ) i_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .nd_req_i(nd_req), .nd_req_valid_i(nd_req_valid), .nd_req_ready_o(nd_req_ready),
    .nd_rsp_o(nd_rsp), .nd_rsp_valid_o(nd_rsp_valid), .nd_rsp_ready_i(nd_rsp_ready),
    .burst_req_o(burst_req), .burst_req_valid_o(burst_req_valid), .burst_req_ready_i(burst_req_ready),
    .burst_rsp_i(burst_rsp), .burst_rsp_valid_i(burst_rsp_valid), .burst_rsp_ready_o(burst_rsp_ready),
    .busy_o(busy)
  );

  // Backpressure on burst_req_ready is essential: during a stall stride_sel_q
  // collapses toward 0, which is what can defeat the base reload. ready always-1 hides it.
  logic [2:0] bp_lfsr;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) bp_lfsr <= 3'b101;
    else        bp_lfsr <= {bp_lfsr[1:0], bp_lfsr[2] ^ bp_lfsr[1]};
  assign burst_req_ready = bp_lfsr[0];   // stalls ~half the cycles, incl. boundaries
  assign burst_rsp       = '0;
  assign burst_rsp_valid = 1'b0;
  assign nd_rsp_ready    = 1'b1;

  // ── Capture every issued burst's src/dst address in order ──
  addr_t cap_src [$];
  addr_t cap_dst [$];
  always @(posedge clk) if (rst_n && burst_req_valid && burst_req_ready) begin
    cap_src.push_back(burst_req.src_addr);
    cap_dst.push_back(burst_req.dst_addr);
  end

  // build a NumDim=4 ND program with a given base
  function automatic idma_nd_req_t mk_req(input addr_t s, input addr_t d);
    idma_nd_req_t r = '0;
    r.burst_req.length   = tf_len_t'('h8);
    r.burst_req.src_addr = s;
    r.burst_req.dst_addr = d;
    r.burst_req.opt.src_protocol = idma_pkg::AXI;
    r.burst_req.opt.dst_protocol = idma_pkg::AXI;
    r.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    r.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    r.d_req[0].reps = reps_t'(R0); r.d_req[0].src_strides = SS0; r.d_req[0].dst_strides = DS0;
    r.d_req[1].reps = reps_t'(R1); r.d_req[1].src_strides = SS1; r.d_req[1].dst_strides = DS1;
    r.d_req[2].reps = reps_t'(R2); r.d_req[2].src_strides = SS2; r.d_req[2].dst_strides = DS2;
    return r;
  endfunction

  initial begin
    automatic int unsigned errs = 0;
    nd_req = '0; nd_req_valid = 1'b0;
    @(posedge rst_n);
    repeat (3) @(posedge clk);

    // ── transfer 1 ──
    nd_req = mk_req(S1, D1); nd_req_valid = 1'b1;
    @(posedge clk);
    while (!nd_req_ready) @(posedge clk);
    // ── transfer 2 : BACK-TO-BACK (keep valid high, swap payload the cycle after accept) ──
    nd_req = mk_req(S2, D2);
    @(posedge clk);
    while (!nd_req_ready) @(posedge clk);
    nd_req_valid = 1'b0;
    nd_req = '0;
    // ── idle gap ──
    repeat (5) @(posedge clk);
    // ── transfer 3 : after the gap ──
    nd_req = mk_req(S3, D3); nd_req_valid = 1'b1;
    @(posedge clk);
    while (!nd_req_ready) @(posedge clk);
    nd_req_valid = 1'b0;
    repeat (3) @(posedge clk);

    // ── checks ──
    if (cap_src.size() != 3*NB)
      begin errs++; $display("[B2B] burst count %0d != %0d", cap_src.size(), 3*NB); end
    else begin
      // first burst of each transfer must equal its OWN base (reload happened)
      if (cap_src[0]     !== S1 || cap_dst[0]     !== D1) begin errs++; $display("[B2B] T1[0]=(%0h,%0h) exp (%0h,%0h)", cap_src[0], cap_dst[0], S1, D1); end
      if (cap_src[NB]    !== S2 || cap_dst[NB]    !== D2) begin errs++; $display("[B2B] T2[0]=(%0h,%0h) exp (%0h,%0h) -- back-to-back base NOT reloaded", cap_src[NB], cap_dst[NB], S2, D2); end
      if (cap_src[2*NB]  !== S3 || cap_dst[2*NB]  !== D3) begin errs++; $display("[B2B] T3[0]=(%0h,%0h) exp (%0h,%0h)", cap_src[2*NB], cap_dst[2*NB], S3, D3); end
      // full-sequence independence: T2 and T3 must be T1 shifted by their base delta
      for (int unsigned i = 0; i < NB; i++) begin
        if ((cap_src[NB+i]   - cap_src[i]) !== (S2 - S1) || (cap_dst[NB+i]   - cap_dst[i]) !== (D2 - D1)) begin
          errs++; if (errs <= 8) $display("[B2B] T2[%0d] not T1+delta: src %0h vs %0h (Δexp %0h)", i, cap_src[NB+i], cap_src[i], S2-S1); end
        if ((cap_src[2*NB+i] - cap_src[i]) !== (S3 - S1) || (cap_dst[2*NB+i] - cap_dst[i]) !== (D3 - D1)) begin
          errs++; if (errs <= 8) $display("[B2B] T3[%0d] not T1+delta: src %0h vs %0h (Δexp %0h)", i, cap_src[2*NB+i], cap_src[i], S3-S1); end
      end
    end

    if (errs == 0) $display("[B2B] PASS: %0d back-to-back + gapped ND transfers each walked from their own base", 3*NB);
    else           $fatal(1, "[B2B] FAIL: %0d errors (back-to-back ND base-address reuse)", errs);
    $finish();
  end

  initial begin #500_000; $fatal(1, "[B2B] timeout"); end

endmodule

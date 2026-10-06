// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Zero-repetition regression for idma_nd_midend. A zero transfer must hold its request until
// its error response is taken, and must leave the next transfer starting from its own base.

`include "idma/typedef.svh"

module tb_idma_nd_midend_zero;

  localparam time TCK = 10ns;
  localparam int unsigned AddrWidth = 32;
  localparam int unsigned NumDim    = 3;
  localparam int unsigned Stall     = 5;
  localparam logic [NumDim-1:0][31:0] RepWidths = '{default: 32'd16};

  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [31:0]          tf_len_t;
  typedef logic [11:0]          id_t;
  typedef logic [31:0]          reps_t;

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, addr_t)

  localparam int unsigned R0 = 3, R1 = 2;
  localparam int unsigned NB = R0 * R1;
  localparam addr_t SS0 = 'h10, DS0 = 'h100;
  localparam addr_t SS1 = 'h40, DS1 = 'h400;
  localparam addr_t S = 'h0000_1000, D = 'h0001_0000;
  localparam addr_t ZS = 'h0000_7000, ZD = 'h0007_0000;

  logic clk, rst_n;
  idma_nd_req_t nd_req;  logic nd_req_valid, nd_req_ready;
  idma_rsp_t    nd_rsp;  logic nd_rsp_valid, nd_rsp_ready;
  idma_req_t    burst_req; logic burst_req_valid, burst_req_ready;
  logic busy;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

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

  int unsigned n_acc, n_err_rsp, n_bad_rsp;
  addr_t cap_src [$];
  addr_t cap_dst [$];
  always @(posedge clk) if (rst_n) begin
    if (nd_req_valid && nd_req_ready) n_acc++;
    if (nd_rsp_valid && nd_rsp_ready) begin
      if (nd_rsp.error && nd_rsp.pld.err_type == idma_pkg::ND_MIDEND) n_err_rsp++;
      else                                                            n_bad_rsp++;
    end
    if (burst_req_valid && burst_req_ready) begin
      cap_src.push_back(burst_req.src_addr);
      cap_dst.push_back(burst_req.dst_addr);
    end
  end

  function automatic idma_nd_req_t mk_req(input addr_t s, input addr_t d,
                                          input int unsigned r0, input int unsigned r1);
    idma_nd_req_t r = '0;
    r.burst_req.length   = tf_len_t'('h8);
    r.burst_req.src_addr = s;
    r.burst_req.dst_addr = d;
    r.burst_req.opt.src_protocol = idma_pkg::AXI;
    r.burst_req.opt.dst_protocol = idma_pkg::AXI;
    r.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    r.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    r.d_req[0].reps = reps_t'(r0); r.d_req[0].src_strides = SS0; r.d_req[0].dst_strides = DS0;
    r.d_req[1].reps = reps_t'(r1); r.d_req[1].src_strides = SS1; r.d_req[1].dst_strides = DS1;
    return r;
  endfunction

  int unsigned errs = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin errs++; $display("[ZERO] %s", msg); end
  endtask

  // drive at the falling edge; returns whether the next rising edge accepts the request
  task automatic cycle(output bit acc);
    #(TCK / 4);
    acc = nd_req_valid & nd_req_ready;
    @(negedge clk);
  endtask

  task automatic wait_accept();
    automatic bit acc;
    do cycle(acc); while (!acc);
  endtask

  // issue a zero transfer with one ready held low for up to Stall cycles
  task automatic zero_stalled(input bit stall_rsp);
    automatic bit acc = 1'b0;
    nd_req          = mk_req(ZS, ZD, 0, 0);
    nd_req_valid    = 1'b1;
    nd_rsp_ready    = !stall_rsp;
    burst_req_ready = stall_rsp;
    for (int unsigned i = 0; i < Stall && !acc; i++) begin
      cycle(acc);
      if (stall_rsp) check(!acc, "zero transfer accepted before its response");
    end
    nd_rsp_ready    = 1'b1;
    burst_req_ready = 1'b1;
    if (!acc) wait_accept();
    nd_req_valid    = 1'b0;
    nd_req          = '0;
    @(negedge clk);
  endtask

  initial begin
    automatic addr_t es, ed;
    nd_req = '0; nd_req_valid = 1'b0; nd_rsp_ready = 1'b1; burst_req_ready = 1'b1;
    @(posedge rst_n);
    repeat (3) @(negedge clk);

    // response backpressure: the error response must not be dropped
    zero_stalled(1'b1);
    check(n_err_rsp == 1, $sformatf("%0d error responses after a stalled zero transfer, exp 1",
                                    n_err_rsp));

    // burst backpressure, then a real transfer that must start from its base
    zero_stalled(1'b0);
    check(n_err_rsp == 2, $sformatf("%0d error responses after two zero transfers, exp 2",
                                    n_err_rsp));
    nd_req       = mk_req(S, D, R0, R1);
    nd_req_valid = 1'b1;
    wait_accept();
    nd_req_valid = 1'b0;
    nd_req       = '0;
    repeat (3) @(negedge clk);

    check(n_acc == 3, $sformatf("%0d requests accepted, exp 3", n_acc));
    check(n_err_rsp == 2 && n_bad_rsp == 0,
          $sformatf("responses: %0d error, %0d other, exp 2/0", n_err_rsp, n_bad_rsp));
    check(cap_src.size() == NB, $sformatf("%0d bursts, exp %0d", cap_src.size(), NB));
    // strides accumulate: the outer stride is applied on top of the last inner address
    es = S;
    ed = D;
    for (int unsigned i = 0; i < cap_src.size() && i < NB; i++) begin
      if (i != 0) begin
        es += (i % R0 == 0) ? SS1 : SS0;
        ed += (i % R0 == 0) ? DS1 : DS0;
      end
      check(cap_src[i] === es && cap_dst[i] === ed,
            $sformatf("burst %0d at (%0h,%0h), exp (%0h,%0h)", i, cap_src[i], cap_dst[i], es, ed));
    end

    if (errs == 0) $display("[ZERO] PASS");
    else           $fatal(1, "[ZERO] FAIL: %0d errors", errs);
    $finish();
  end

  initial begin #100_000; $fatal(1, "[ZERO] timeout"); end

endmodule

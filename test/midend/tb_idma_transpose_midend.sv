// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "idma/typedef.svh"

/// Unit check for idma_transpose_midend: the expanded NumDim=4 ND request must
/// match the golden compact and tile-padded geometries, and a non-transpose
/// request must pass through unchanged. Sweeps a geometry list internally
/// (one elaboration per bus width).
module tb_idma_transpose_midend #(
  parameter int unsigned DataWidth = 512,
  parameter int unsigned AddrWidth = 64
);
  import idma_pkg::*;

  localparam int unsigned StrbWidth = DataWidth/8;
  localparam int unsigned NumDim = 4;

  // Geometry cases (M, N, EB); EB>StrbWidth cases skip.
  localparam int unsigned NCases = 7;
  localparam int unsigned Cases [NCases][3] = '{
    '{8, 8, 1}, '{16, 16, 1}, '{40, 24, 1}, '{13, 19, 2}, '{5, 7, 1}, '{9, 5, 4}, '{6, 10, 1}
  };

  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [31:0]          tf_len_t;
  typedef logic [2:0]           id_t;
  typedef logic [31:0]          reps_t;

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, addr_t)

  idma_nd_req_t nd_in, nd_out;
  logic vi, ro, vo, ri;
  assign vi = 1'b1;
  assign ri = 1'b1;

  idma_transpose_midend #(
    .NumDim(NumDim), .StrbWidth(StrbWidth), .addr_t(addr_t), .idma_nd_req_t(idma_nd_req_t)
  ) i_dut (
    .nd_req_i(nd_in), .valid_i(vi), .ready_o(ro),
    .nd_req_o(nd_out), .valid_o(vo), .ready_i(ri)
  );

  int errs = 0;
  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      errs++;
      $display("[MID] %s: got %0d exp %0d", name, $signed(got), $signed(exp));
    end
  endtask

  // Check both compact and tile-padded expansion for one transpose geometry.
  task automatic chk_geom(input int unsigned m, input int unsigned n, input int unsigned eb,
                          input bit compact);
    automatic int unsigned ne   = StrbWidth/eb;
    automatic int unsigned mode = (eb==4) ? 2 : (eb==2) ? 1 : 0;
    automatic int unsigned yt   = (m + ne - 1)/ne;
    automatic int unsigned nt   = (n + ne - 1)/ne;
    automatic int unsigned mp   = yt*ne;
    automatic int unsigned dp   = compact ? m : mp;
    nd_in = '0;
    nd_in.burst_req.src_addr = 64'h1000;
    nd_in.burst_req.dst_addr = 64'h2000;
    nd_in.burst_req.opt.compute.enable                    = 1'b1;
    nd_in.burst_req.opt.compute.op                        = COMPUTE_TRANSPOSE;
    nd_in.burst_req.opt.compute.params.transpose.compact  = compact;
    nd_in.burst_req.opt.compute.params.transpose.mode     = 2'(mode);
    nd_in.burst_req.opt.compute.params.transpose.tensor_m = 12'(m);
    nd_in.burst_req.opt.compute.params.transpose.tensor_n = 12'(n);
    #1;
    // golden geometry (same formulas as tb_idma_transpose_nd)
    chk("length",  nd_out.burst_req.length,     ne*eb);
    chk("d0.reps", nd_out.d_req[0].reps,        ne);
    chk("d0.src",  nd_out.d_req[0].src_strides, addr_t'(n*eb));
    chk("d0.dst",  nd_out.d_req[0].dst_strides, addr_t'(dp*eb));
    chk("d1.reps", nd_out.d_req[1].reps,        yt);
    chk("d1.src",  nd_out.d_req[1].src_strides, addr_t'(n*eb));
    chk("d1.dst",  nd_out.d_req[1].dst_strides, addr_t'(int'(ne*eb) - int'((ne-1)*dp*eb)));
    chk("d2.reps", nd_out.d_req[2].reps,        nt);
    chk("d2.src",  nd_out.d_req[2].src_strides, addr_t'(int'(ne*eb) - int'((yt*ne-1)*n*eb)));
    chk("d2.dst",  nd_out.d_req[2].dst_strides, addr_t'(int'(dp*eb) - int'((yt-1)*ne*eb)));
    // addresses + compute must survive untouched
    chk("src_addr", nd_out.burst_req.src_addr, 64'h1000);
    chk("dst_addr", nd_out.burst_req.dst_addr, 64'h2000);
    chk("cmp_en",   nd_out.burst_req.opt.compute.enable, 1);
    if (errs == 0)
      $display("[MID] PASS: %0dx%0d EB=%0d compact=%0d (NE=%0d YT=%0d NT=%0d DP=%0d)",
               m, n, eb, compact, ne, yt, nt, dp);
  endtask

  initial begin
    // --- passthrough case: a non-transpose request must be untouched ---
    nd_in = '0;
    nd_in.burst_req.src_addr = 64'hDEAD;
    nd_in.burst_req.dst_addr = 64'hBEEF;
    nd_in.d_req[0].reps = 7;
    #1;
    if (nd_out !== nd_in) begin
      errs++;
      $display("[MID] passthrough altered a non-transpose request");
    end

    // --- transpose cases ---
    for (int unsigned k = 0; k < NCases; k++) begin
      if (Cases[k][2] > StrbWidth) continue;   // element must fit the bus
      chk_geom(Cases[k][0], Cases[k][1], Cases[k][2], 1'b0);
      chk_geom(Cases[k][0], Cases[k][1], Cases[k][2], 1'b1);
    end

    if (errs == 0) $display("[MID] ALL PASS (%0d geometries x 2 layouts, StrbWidth=%0d)",
                            NCases, StrbWidth);
    else           $fatal(1, "[MID] FAIL: %0d mismatches", errs);
    $finish;
  end
endmodule

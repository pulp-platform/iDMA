// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "idma/typedef.svh"

/// Unit check for idma_transpose_midend: the expanded NumDim=4 ND request must
/// match the golden geometry that tb_idma_transpose_nd hand-builds, and a
/// non-transpose request must pass through unchanged.
module tb_idma_transpose_midend #(
  parameter int unsigned DataWidth = 512,
  parameter int unsigned AddrWidth = 64,
  parameter int unsigned M  = 40,
  parameter int unsigned N  = 24,
  parameter int unsigned EB = 1
);
  import idma_pkg::*;

  localparam int unsigned StrbWidth = DataWidth/8;
  localparam int unsigned NE   = StrbWidth/EB;
  localparam int unsigned MODE = (EB==4) ? 2 : (EB==2) ? 1 : 0;
  localparam int unsigned YT   = (M + NE - 1)/NE;
  localparam int unsigned NT   = (N + NE - 1)/NE;
  localparam int unsigned MP   = YT*NE;
  localparam int unsigned NumDim = 4;

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

  initial begin
    // --- passthrough case ---
    nd_in = '0;
    nd_in.burst_req.src_addr = 64'hDEAD;
    nd_in.burst_req.dst_addr = 64'hBEEF;
    nd_in.d_req[0].reps = 7;
    #1;
    if (nd_out !== nd_in) begin
      errs++;
      $display("[MID] passthrough altered a non-transpose request");
    end

    // --- transpose case ---
    nd_in = '0;
    nd_in.burst_req.src_addr = 64'h1000;
    nd_in.burst_req.dst_addr = 64'h2000;
    nd_in.burst_req.opt.compute.enable                  = 1'b1;
    nd_in.burst_req.opt.compute.op                      = COMPUTE_TRANSPOSE;
    nd_in.burst_req.opt.compute.params.transpose.mode     = 2'(MODE);
    nd_in.burst_req.opt.compute.params.transpose.tensor_m = 12'(M);
    nd_in.burst_req.opt.compute.params.transpose.tensor_n = 12'(N);
    #1;

    // golden geometry (same formulas as tb_idma_transpose_nd)
    chk("length",  nd_out.burst_req.length,     NE*EB);
    chk("d0.reps", nd_out.d_req[0].reps,        NE);
    chk("d0.src",  nd_out.d_req[0].src_strides, addr_t'(N*EB));
    chk("d0.dst",  nd_out.d_req[0].dst_strides, addr_t'(MP*EB));
    chk("d1.reps", nd_out.d_req[1].reps,        YT);
    chk("d1.src",  nd_out.d_req[1].src_strides, addr_t'(N*EB));
    chk("d1.dst",  nd_out.d_req[1].dst_strides, addr_t'(int'(NE*EB) - int'((NE-1)*MP*EB)));
    chk("d2.reps", nd_out.d_req[2].reps,        NT);
    chk("d2.src",  nd_out.d_req[2].src_strides, addr_t'(int'(NE*EB) - int'((YT*NE-1)*N*EB)));
    chk("d2.dst",  nd_out.d_req[2].dst_strides, addr_t'(int'(MP*EB) - int'((YT-1)*NE*EB)));
    // addresses + compute must survive untouched
    chk("src_addr", nd_out.burst_req.src_addr, 64'h1000);
    chk("dst_addr", nd_out.burst_req.dst_addr, 64'h2000);
    chk("cmp_en",   nd_out.burst_req.opt.compute.enable, 1);

    if (errs == 0)
      $display("[MID] PASS: %0dx%0d EB=%0d golden (NE=%0d YT=%0d NT=%0d MP=%0d)",
               M, N, EB, NE, YT, NT, MP);
    else           $fatal(1, "[MID] FAIL: %0d mismatches", errs);
    $finish;
  end
endmodule

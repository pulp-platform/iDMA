// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "idma/typedef.svh"

/// Unit check for idma_mp_dist_midend: every slice must carry the region-local
/// address on the distributed side and the correctly rebased address on the
/// counterpart side. Covers transfers starting in a non-zero region, which is
/// where truncating the start address silently mis-rebases every slice after
/// the first.
module tb_idma_mp_midend #(
  parameter int unsigned NumBEs      = 32'd4,
  parameter int unsigned RegionWidth = 32'h1000,
  parameter int unsigned AddrWidth   = 32'd32
);

  localparam int unsigned RegionStart = 32'h0000_0000;
  localparam int unsigned RegionEnd   = RegionStart + NumBEs * RegionWidth;
  localparam int unsigned NotInvolvedLen = 32'd1;

  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [        31:0] tf_len_t;
  typedef logic [         2:0] id_t;

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

  logic clk, rst_n;

  idma_req_t              req_in;
  idma_req_t [NumBEs-1:0] req_out;
  logic      [NumBEs-1:0] req_valid_out, req_ready_in, rsp_valid_in, rsp_ready_out;
  idma_rsp_t [NumBEs-1:0] rsp_in;
  idma_pkg::idma_busy_t [NumBEs-1:0] busy_in;

  assign req_ready_in = '1;
  assign rsp_valid_in = '0;
  assign rsp_in       = '0;
  assign busy_in      = '0;

  idma_mp_dist_midend #(
    .NumBEs      ( NumBEs      ),
    .RegionWidth ( RegionWidth ),
    .RegionStart ( RegionStart ),
    .RegionEnd   ( RegionEnd   ),
    .AddrWidth   ( AddrWidth   ),
    .idma_req_t  ( idma_req_t  ),
    .idma_rsp_t  ( idma_rsp_t  )
  ) i_dut (
    .clk_i            ( clk           ),
    .rst_ni           ( rst_n         ),
    .idma_req_i       ( req_in        ),
    .idma_req_valid_i ( 1'b0          ),
    .idma_req_ready_o (               ),
    .idma_rsp_o       (               ),
    .idma_rsp_valid_o (               ),
    .idma_rsp_ready_i ( 1'b1          ),
    .idma_busy_o      (               ),
    .idma_req_o       ( req_out       ),
    .idma_req_valid_o ( req_valid_out ),
    .idma_req_ready_i ( req_ready_in  ),
    .idma_rsp_i       ( rsp_in        ),
    .idma_rsp_valid_i ( rsp_valid_in  ),
    .idma_rsp_ready_o ( rsp_ready_out ),
    .idma_busy_i      ( busy_in       )
  );

  initial begin
    clk = 1'b0;
    forever #0.5ns clk = ~clk;
  end

  int errs = 0;

  task automatic chk(input string name, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      errs++;
      $display("[MID] %s: got 0x%0h exp 0x%0h", name, got, exp);
    end
  endtask

  /// Check one slice of a transfer whose distributed side is `src`.
  task automatic chk_slice(input string  name,
                           input int unsigned i,
                           input logic [63:0] exp_src,
                           input logic [63:0] exp_dst,
                           input logic [63:0] exp_len);
    chk($sformatf("%s be%0d src", name, i), req_out[i].src_addr, exp_src);
    chk($sformatf("%s be%0d dst", name, i), req_out[i].dst_addr, exp_dst);
    chk($sformatf("%s be%0d len", name, i), req_out[i].length,   exp_len);
  endtask

  /// A back-end outside the transfer emits the tie-off request, not a slice.
  task automatic chk_idle(input string name, input int unsigned i);
    chk($sformatf("%s be%0d len", name, i), req_out[i].length,   NotInvolvedLen);
    chk($sformatf("%s be%0d src", name, i), req_out[i].src_addr, '0);
    chk($sformatf("%s be%0d dst", name, i), req_out[i].dst_addr, '0);
  endtask

  task automatic drive(input logic [63:0] src, input logic [63:0] dst, input logic [63:0] len);
    req_in          = '0;
    req_in.src_addr = addr_t'(src);
    req_in.dst_addr = addr_t'(dst);
    req_in.length   = tf_len_t'(len);
    #1ns;
  endtask

  // Counterpart base, well clear of the distributed region.
  localparam longint unsigned CpBase = 64'h0010_0000;
  localparam longint unsigned RW     = 64'(RegionWidth);
  localparam longint unsigned Half   = RW / 2;

  /// Every back-end outside [lo, hi] must carry the tie-off request.
  task automatic chk_idle_outside(input string name, input int unsigned lo, input int unsigned hi);
    for (int unsigned i = 0; i < NumBEs; i++) begin
      if (i < lo || i > hi) chk_idle(name, i);
    end
  endtask

  initial begin
    req_in = '0;
    rst_n  = 1'b0;
    #5ns;
    rst_n = 1'b1;
    #5ns;

    // --- Start half way into region 1 and run one region long, so the transfer
    // --- ends half way into region 2. Slice 2 is rebased, and its counterpart
    // --- address is only right if the whole start address is subtracted.
    drive(RW + Half, CpBase, RW);
    chk_slice("r1span", 1, RW + Half,   CpBase,        RW - Half);
    chk_slice("r1span", 2, 2*RW,        CpBase + Half, Half);
    chk_idle_outside("r1span", 1, 2);

    // --- The same shape starting in region 0, where truncating the start
    // --- address is a no-op. Guards the fix against over-correcting.
    drive(Half, CpBase, RW);
    chk_slice("r0span", 0, Half, CpBase,             RW - Half);
    chk_slice("r0span", 1, RW,   CpBase + RW - Half, Half);
    chk_idle_outside("r0span", 0, 1);

    // --- Distributed side on the destination; the source is the counterpart.
    drive(CpBase, RW + Half, RW);
    chk_slice("dstdist", 1, CpBase,        RW + Half, RW - Half);
    chk_slice("dstdist", 2, CpBase + Half, 2*RW,      Half);
    chk_idle_outside("dstdist", 1, 2);

    // --- Wholly inside one region: a single slice carries the full length.
    drive(RW + Half, CpBase, Half / 2);
    chk_slice("single", 1, RW + Half, CpBase, Half / 2);
    chk_idle_outside("single", 1, 1);

    // --- Full span: every back-end takes exactly one region.
    drive(64'd0, CpBase, 64'(NumBEs) * RW);
    for (int unsigned i = 0; i < NumBEs; i++) begin
      chk_slice("fullspan", i, 64'(i) * RW, CpBase + 64'(i) * RW, RW);
    end

    if (errs == 0) $display("[MID] ALL PASS (NumBEs=%0d RegionWidth=0x%0h)", NumBEs, RegionWidth);
    else           $fatal(1, "[MID] FAIL: %0d mismatches", errs);
    $finish;
  end

endmodule

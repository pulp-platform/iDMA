// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// On-the-fly MX dequantizer, beat-granular and never stalling: inline 33B blocks
// ([1B E8M0 scale][32B E5M2]) are accepted whole beats into the input buffer (IB),
// extracted one output beat at a time (D0) and expanded to FP16 or FP32 (D1) into the
// output queue (OQd). Input pops and output pushes are credit-checked from flops.
module idma_otf_mxdequant
  import idma_float_pkg::*;
#(
  parameter int unsigned StrbWidth = 32'd8,
  parameter bit          Fp16En    = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,

  /// Dataflow-element head beat tagged as dequant; `fp16_i` selects the destination format
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  input  logic                      fp16_i,
  output logic                      pop_o,

  /// Output queue head, popped on the W beat handshake
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic                      beat_valid_o,
  input  logic                      beat_pop_i,
  output logic                      busy_o
);

  // pragma translate_off
  initial assert (StrbWidth >= 4 && StrbWidth <= 128 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_mxdequant: StrbWidth (%0d) must be a power of two in [4,128]", StrbWidth);
  // pragma translate_on

  // FP16 is illegal above StrbWidth 64 (legalizer ComputeMxFp16Width), so gate it off
  localparam bit          Fp16Dn = Fp16En && (StrbWidth <= 64);
  localparam int unsigned NL16   = StrbWidth / 2;
  localparam int unsigned NL32   = StrbWidth / 4;
  localparam int unsigned NL     = Fp16Dn ? NL16 : NL32;
  localparam int unsigned NIB    = 3;
  localparam int unsigned NOQ    = 3;
  localparam int unsigned OW     = $clog2(StrbWidth);
  localparam int unsigned SubW   = (StrbWidth < 128) ? $clog2(128 / StrbWidth) : 1;

  // IB: whole input beats, each with its destination format
  logic [NIB-1:0][StrbWidth-1:0][7:0] ib_q;
  logic [NIB-1:0]                     ib_fp16_q;
  logic [1:0]                         ib_wr_q, ib_hd_q, ib_hd1;
  logic [1:0]                         ib_cnt_q, ib_cnt_d;
  logic                               in_ok_q;
  logic [OW-1:0]                      off_q;
  logic [SubW-1:0]                    sub_q;

  // D0 stage register
  logic                               d0_v_q, d0_fp16_q;
  logic [7:0]                         d0_sc_q;
  logic [NL-1:0][7:0]                 d0_el_q;

  // OQd with its free-slot credit counter
  logic [NOQ-1:0][StrbWidth-1:0][7:0] oq_q;
  logic [1:0]                         oq_wr_q, oq_rd_q, oq_cnt_q, oq_free_q;

  function automatic logic [1:0] inc3(input logic [1:0] p);
    return (p == 2'd2) ? 2'd0 : p + 2'd1;
  endfunction

  assign pop_o = in_ok_q & valid_i;

  // D0 issue: the window holds the next output beat's bytes and an OQd slot is free
  logic          fmt16, first, avail, issue, adv;
  logic [OW+1:0] need, nxt;
  logic [SubW-1:0] sub_last;
  assign ib_hd1   = inc3(ib_hd_q);
  assign fmt16    = Fp16Dn & ib_fp16_q[ib_hd_q];
  assign first    = (sub_q == '0);
  assign need     = (fmt16 ? (OW+2)'(NL16) : (OW+2)'(NL32)) + (OW+2)'(first);
  assign nxt      = (OW+2)'(off_q) + need;
  assign avail    = (ib_cnt_q >= 2'd2) | ((ib_cnt_q == 2'd1) & (nxt <= (OW+2)'(StrbWidth)));
  assign issue    = avail & (oq_free_q != 2'd0);
  assign adv      = issue & (nxt >= (OW+2)'(StrbWidth));
  assign sub_last = fmt16 ? SubW'((64 / StrbWidth) - 1) : SubW'((128 / StrbWidth) - 1);

  logic [2*StrbWidth-1:0][7:0] win;
  logic [NL:0][7:0]            ext;
  assign win = {ib_q[ib_hd1], ib_q[ib_hd_q]};
  assign ext = (8*(NL+1))'(win >> {off_q, 3'b000});

  assign ib_cnt_d = ib_cnt_q + 2'(pop_o) - 2'(adv);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ib_wr_q <= '0; ib_hd_q <= '0; ib_cnt_q <= '0; in_ok_q <= 1'b1;
      off_q   <= '0; sub_q   <= '0; d0_v_q   <= 1'b0;
    end else begin
      ib_cnt_q <= ib_cnt_d;
      in_ok_q  <= ib_cnt_d < 2'(NIB);
      d0_v_q   <= issue;
      if (pop_o) ib_wr_q <= inc3(ib_wr_q);
      if (adv)   ib_hd_q <= ib_hd1;
      if (issue) begin
        off_q <= OW'(nxt);
        sub_q <= (sub_q == sub_last) ? '0 : sub_q + SubW'(1);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (pop_o) begin
      ib_q[ib_wr_q]      <= data_i;
      ib_fp16_q[ib_wr_q] <= fp16_i;
    end
    if (issue) begin
      d0_fp16_q <= fmt16;
      if (first) d0_sc_q <= ext[0];
      for (int i = 0; i < NL; i++) d0_el_q[i] <= first ? ext[i+1] : ext[i];
    end
  end

  // D1: expand lanes straight into the OQd tail entry
  logic [NL-1:0][31:0]       d1_lane;
  logic [StrbWidth-1:0][7:0] d1_beat;
  for (genvar i = 0; i < NL; i++) begin : gen_d1_lane
    assign d1_lane[i] = e5m2_dequant_lane(d0_el_q[i], d0_sc_q, (i >= NL32) | d0_fp16_q);
  end
  always_comb begin
    d1_beat = '0;
    for (int i = 0; i < NL; i++) begin
      if (d0_fp16_q)     d1_beat[2*i +: 2] = d1_lane[i][15:0];
      else if (i < NL32) d1_beat[4*i +: 4] = d1_lane[i];
    end
  end

  always_ff @(posedge clk_i) if (d0_v_q) oq_q[oq_wr_q] <= d1_beat;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      oq_wr_q <= '0; oq_rd_q <= '0; oq_cnt_q <= '0; oq_free_q <= 2'(NOQ);
    end else begin
      if (d0_v_q)     oq_wr_q <= inc3(oq_wr_q);
      if (beat_pop_i) oq_rd_q <= inc3(oq_rd_q);
      oq_cnt_q  <= oq_cnt_q  + 2'(d0_v_q) - 2'(beat_pop_i);
      oq_free_q <= oq_free_q - 2'(issue)  + 2'(beat_pop_i);
    end
  end

  assign beat_valid_o = (oq_cnt_q != 2'd0);
  assign data_o       = oq_q[oq_rd_q];
  assign busy_o       = (ib_cnt_q != 2'd0) | (sub_q != '0) | d0_v_q | beat_valid_o;

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni) begin
    assert (!beat_pop_i || beat_valid_o)
      else $fatal(1, "idma_otf_mxdequant: pop of an empty output queue");
    assert (!d0_v_q || (oq_cnt_q != 2'(NOQ)))
      else $fatal(1, "idma_otf_mxdequant: output queue overflow");
  end
  // pragma translate_on

endmodule : idma_otf_mxdequant

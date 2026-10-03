// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// On-the-fly MX dequantizer: data beats (IB) with scales from SR, D0 select, D1 expand, OQd.
module idma_otf_mxdequant
  import idma_float_pkg::*;
#(
  parameter int unsigned StrbWidth = 32'd8,
  parameter bit          Fp16En    = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,

  /// Dataflow-element head beat tagged as dequant, with its tag
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  input  idma_pkg::mx_tag_t         tag_i,
  output logic                      pop_o,

  /// Output queue head, popped on the W beat handshake
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic                      beat_valid_o,
  input  logic                      beat_pop_i,
  output logic                      busy_o
);

  // pragma translate_off
  initial assert (StrbWidth >= 4 && StrbWidth <= 64 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_mxdequant: StrbWidth (%0d) must be a power of two in [4, 64]", StrbWidth);
  // pragma translate_on

  localparam bit          Fp16Dn = Fp16En;
  localparam int unsigned NL16   = StrbWidth / 2;
  localparam int unsigned NL32   = StrbWidth / 4;
  localparam int unsigned NL     = Fp16Dn ? NL16 : NL32;
  localparam int unsigned NIB    = 3;
  localparam int unsigned NOQ    = 3;
  localparam int unsigned IbPW   = $clog2(NIB);
  localparam int unsigned IbCW   = $clog2(NIB + 1);
  localparam int unsigned OqPW   = $clog2(NOQ);
  localparam int unsigned OqCW   = $clog2(NOQ + 1);
  // scale bytes per IB entry, the 64 B scale line
  localparam int unsigned DatB   = idma_pkg::MxDataBlockBytes;
  localparam int unsigned NSc    = (StrbWidth > DatB) ? StrbWidth / DatB : 1;
  localparam int unsigned SlB    = idma_pkg::MxScaleSlotBytes;

  // IB: whole data beats, each with its destination and element format and its scale bytes
  logic [NIB-1:0][StrbWidth-1:0][7:0] ib_q;
  logic [NIB-1:0]                     ib_fp16_q, ib_e4m3_q, ib_half_q;
  logic [NIB-1:0][NSc-1:0][7:0]       ib_sc_q;
  // scale register, data byte counter within the scale line, scale sub-beat pointer
  logic [SlB-1:0][7:0]                sr_q;
  logic [10:0]                        dk_q;
  logic [5:0]                         sw_q;
  logic                               in_s_q;
  logic                               is_sc, dpop, spop;
  logic [IbPW-1:0]                    ib_wr_q, ib_hd_q;
  logic [IbCW-1:0]                    ib_cnt_q, ib_cnt_d;
  logic                               in_ok_q;
  // output beat within the head entry: 2 (FP16) or 4 (FP32) per data beat
  logic [1:0]                         os_q;

  // D0 stage register
  logic                               d0_v_q, d0_fp16_q, d0_e4m3_q;
  logic [7:0]                         d0_sc_q;
  logic [NL-1:0][7:0]                 d0_el_q;

  // OQd with its free-slot credit counter
  logic [NOQ-1:0][StrbWidth-1:0][7:0] oq_q;
  logic [OqPW-1:0]                    oq_wr_q, oq_rd_q;
  logic [OqCW-1:0]                    oq_cnt_q, oq_free_q;

  function automatic logic [OqPW-1:0] inc_oq(input logic [OqPW-1:0] p);
    return (32'(p) == NOQ - 1) ? '0 : p + OqPW'(1);
  endfunction

  function automatic logic [IbPW-1:0] inc_ib(input logic [IbPW-1:0] p);
    return (32'(p) == NIB - 1) ? '0 : p + IbPW'(1);
  endfunction

  assign is_sc = tag_i.is_scale;
  // a scale beat never waits: the previous group's data beats copied their scale bytes already
  assign pop_o = valid_i & (in_ok_q | is_sc);
  assign dpop  = pop_o & ~is_sc;
  assign spop  = pop_o & is_sc;

  // D0 issue: the head entry's next output beat; a half entry ends after its first 32 B
  logic                fmt16, half_hd, issue, adv;
  logic [1:0]          os_last;
  logic [NL-1:0][7:0]  ext;
  logic [7:0]          sc;
  assign fmt16   = Fp16Dn & ib_fp16_q[ib_hd_q];
  assign half_hd = ib_half_q[ib_hd_q];
  assign os_last = (fmt16 ? 2'd1 : 2'd3) >> half_hd;
  assign issue   = (ib_cnt_q != '0) & (oq_free_q != '0);
  assign adv     = issue & (os_q == os_last);

  always_comb begin
    for (int i = 0; i < NL; i++) begin
      if (fmt16)       ext[i] = ib_q[ib_hd_q][32'(os_q[0])*NL16 + i];
      else if (i < NL32) ext[i] = ib_q[ib_hd_q][32'(os_q)*NL32 + i];
      else             ext[i] = '0;
    end
    if (NSc > 1) sc = ib_sc_q[ib_hd_q][fmt16 ? 32'(os_q[0]) : 32'(os_q[1])];
    else         sc = ib_sc_q[ib_hd_q][0];
  end

  assign ib_cnt_d = ib_cnt_q + IbCW'(dpop) - IbCW'(adv);

  // a group's scale beats fill the scale line from the sub-beat of its first block on
  logic [5:0] sw_d;
  assign sw_d = in_s_q ? sw_q + 6'(StrbWidth) : (dk_q[10:5] & ~6'(StrbWidth - 1));
  if (StrbWidth >= SlB) begin : gen_sr_line
    always_ff @(posedge clk_i) if (spop) sr_q <= (8*SlB)'(data_i);
  end else begin : gen_sr_sub
    always_ff @(posedge clk_i) if (spop) sr_q[sw_d +: StrbWidth] <= data_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ib_wr_q <= '0; ib_hd_q <= '0; ib_cnt_q <= '0; in_ok_q <= 1'b1;
      os_q    <= '0; d0_v_q  <= 1'b0;
      dk_q    <= '0; sw_q    <= '0; in_s_q   <= 1'b0;
    end else begin
      ib_cnt_q <= ib_cnt_d;
      in_ok_q  <= ib_cnt_d < IbCW'(NIB);
      d0_v_q   <= issue;
      if (dpop)  ib_wr_q <= inc_ib(ib_wr_q);
      if (adv)   ib_hd_q <= inc_ib(ib_hd_q);
      if (issue) os_q    <= adv ? 2'd0 : os_q + 2'd1;
      // data bytes within the scale line
      if (dpop)  dk_q    <= tag_i.last ? '0 : dk_q + 11'(StrbWidth);
      if (pop_o) in_s_q  <= is_sc;
      if (spop)  sw_q    <= sw_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (dpop) begin
      ib_q[ib_wr_q]      <= data_i;
      ib_fp16_q[ib_wr_q] <= Fp16Dn & (tag_i.fmt == idma_pkg::MX_FMT_FP16);
      ib_e4m3_q[ib_wr_q] <= tag_i.elem_fmt == idma_pkg::MX_E4M3;
      ib_half_q[ib_wr_q] <= tag_i.half;
      for (int k = 0; k < NSc; k++) ib_sc_q[ib_wr_q][k] <= sr_q[dk_q[10:5] + 6'(k)];
    end
    if (issue) begin
      d0_fp16_q <= fmt16;
      d0_e4m3_q <= ib_e4m3_q[ib_hd_q];
      d0_sc_q   <= sc;
      d0_el_q   <= ext;
    end
  end

  // D1: expand lanes straight into the OQd tail entry
  logic [NL-1:0][31:0]       d1_lane;
  logic [StrbWidth-1:0][7:0] d1_beat;
  for (genvar i = 0; i < NL; i++) begin : gen_d1_lane
    assign d1_lane[i] = mx_dequant_lane(d0_el_q[i], d0_sc_q, (i >= NL32) | d0_fp16_q, d0_e4m3_q);
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
      oq_wr_q <= '0; oq_rd_q <= '0; oq_cnt_q <= '0; oq_free_q <= OqCW'(NOQ);
    end else begin
      if (d0_v_q)     oq_wr_q <= inc_oq(oq_wr_q);
      if (beat_pop_i) oq_rd_q <= inc_oq(oq_rd_q);
      oq_cnt_q  <= oq_cnt_q  + OqCW'(d0_v_q) - OqCW'(beat_pop_i);
      oq_free_q <= oq_free_q - OqCW'(issue)  + OqCW'(beat_pop_i);
    end
  end

  assign beat_valid_o = (oq_cnt_q != '0);
  assign data_o       = oq_q[oq_rd_q];
  assign busy_o       = (ib_cnt_q != '0) | d0_v_q | beat_valid_o;

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni) begin
    assert (!beat_pop_i || beat_valid_o)
      else $fatal(1, "idma_otf_mxdequant: pop of an empty output queue");
    assert (!d0_v_q || (oq_cnt_q != OqCW'(NOQ)))
      else $fatal(1, "idma_otf_mxdequant: output queue overflow");
  end
  // pragma translate_on

endmodule : idma_otf_mxdequant

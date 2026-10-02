// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// On-the-fly MX quantizer: FP32 or FP16 input beats to inline [1 B E8M0 scale][32 B E5M2 or
/// E4M3] blocks or, planar and grouped, to 32 B data blocks followed per scale group by one scale
/// chunk, emitted as whole output beats. Four never-stalling stages: Q0 unpack and partial max, Q1
/// block scale and exponent distances, Q2 element lanes, Q3 insert into the data queue (OQ) and the
/// scale queue (SQ). A beat is accepted only while the queues hold credit for what its block opens.
/// A block holding an Inf or NaN is poisoned (0xFF scale, canonical NaN elements) unless its tag
/// disables it; the tag also selects the element format and FLOOR or RCEIL scale rounding.
module idma_otf_mxquant
  import idma_float_pkg::*;
#(
  parameter int unsigned StrbWidth = 32'd8,
  parameter bit          Fp16En    = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,

  /// Input beat and its tag; `ready_o` is a registered credit check
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  idma_pkg::mx_tag_t         tag_i,
  input  logic                      valid_i,
  output logic                      ready_o,

  /// Output queue head (one destination beat), popped by the write beat handshake
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic                      valid_o,
  input  logic                      ready_i,

  output logic                      busy_o
);

  localparam bit          Fp16Up = Fp16En && (StrbWidth <= 64);
  localparam bit          PlEn   = StrbWidth <= 64;
  localparam int unsigned E16    = Fp16Up ? StrbWidth / 2 : 1;
  localparam int unsigned E32    = StrbWidth / 4;
  localparam int unsigned Nb16   = MxBlockSize / E16;
  localparam int unsigned Nb32   = MxBlockSize / E32;
  localparam int unsigned PhW    = (Nb32 > 1) ? $clog2(Nb32) : 1;
  localparam int unsigned OffW   = $clog2(StrbWidth);
  localparam int unsigned BlkB   = MxCompressedBlockBytes;
  localparam int unsigned DatB   = idma_pkg::MxDataBlockBytes;
  localparam int unsigned NumGrp = MxBlockSize / 4;
  // output entries one block can touch, and the queue depth covering the credit loop
  localparam int unsigned Win    = (StrbWidth + BlkB + StrbWidth - 2) / StrbWidth;
  localparam int unsigned Depth  = Win + 4;
  localparam int unsigned PtrW   = $clog2(Depth);
  localparam int unsigned CntW   = $clog2(Depth + 1);
  localparam int unsigned WinB   = Win * StrbWidth;
  // scale queue: 64 B lines, one per group, read in sub-beats; the tail line fills in place
  localparam int unsigned SlB    = idma_pkg::MxScaleSlotBytes;
  localparam int unsigned NSq    = 4;
  localparam int unsigned SqCW   = $clog2(NSq + 1);
  localparam int unsigned SqPW   = $clog2(NSq);
  localparam int unsigned NSub   = PlEn ? SlB / StrbWidth : 1;
  localparam int unsigned SubW   = (NSub > 1) ? $clog2(NSub) : 1;

  typedef logic [StrbWidth-1:0][7:0] beat_t;
  typedef logic [SlB-1:0][7:0]       line_t;

  // pragma translate_off
  initial assert (StrbWidth >= 4 && StrbWidth <= 128 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_mxquant: StrbWidth (%0d) must be a power of two in [4, 128]", StrbWidth);
  // pragma translate_on

  // output entries a block opens when it starts at byte `off` of the open entry
  function automatic logic [CntW-1:0] need(input logic [OffW-1:0] off, input logic pl);
    return CntW'(((32'(off) + (pl ? DatB : BlkB) + StrbWidth - 1) >> OffW) - 32'(off != '0));
  endfunction

  //--------------------------------------
  // Issue: credit check and Q0
  //--------------------------------------
  logic            pop, fp16, blk_done, oq_pop, sq_pop;
  logic [PhW-1:0]  phase_q, phase_d;
  logic [OffW-1:0] ioff_q, ioff_d;
  logic [CntW-1:0] free_q, free_d;
  logic [SqCW-1:0] sfree_q, sfree_d;
  logic            in_ok_q, in_ok_d;
  // planar: block index `a` in the 64 B scale line, group end, next block opens a group
  logic            pl, grp, gend, pl_q, pl_d, xb_q, xb_d, gfst_q, gfst_d;
  logic [5:0]      a_q, a_d;

  assign fp16     = Fp16Up && (tag_i.fmt == idma_pkg::MX_FMT_FP16);
  assign pl       = PlEn && (tag_i.layout != idma_pkg::MX_LAYOUT_INLINE);
  assign grp      = PlEn && (tag_i.layout == idma_pkg::MX_LAYOUT_GROUPED);
  assign gend     = pl & (tag_i.last | ((a_q[4:0] == 5'd31) &
                                        ((tag_i.group == idma_pkg::MX_GROUP_G32) | a_q[5])));
  assign blk_done = phase_q == (fp16 ? PhW'(Nb16 - 1) : PhW'(Nb32 - 1));
  assign ready_o  = in_ok_q;
  assign pop      = valid_i & in_ok_q;

  always_comb begin
    phase_d = phase_q;
    ioff_d  = ioff_q;
    a_d     = a_q;
    gfst_d  = gfst_q;
    free_d  = free_q + CntW'(oq_pop);
    sfree_d = sfree_q + SqCW'(sq_pop);
    pl_d    = pop ? pl : pl_q;
    xb_d    = xb_q;
    if (pop) begin
      phase_d = blk_done ? '0 : phase_q + PhW'(1);
      xb_d    = blk_done & tag_i.last;
      if (blk_done) begin
        ioff_d  = tag_i.last ? '0 : OffW'(32'(ioff_q) + (pl ? DatB : BlkB));
        free_d  = free_d - need(ioff_q, pl);
        a_d     = (tag_i.last | (grp & gend)) ? '0 : a_q + 6'd1;
        gfst_d  = gend | tag_i.last;
        sfree_d = sfree_d - SqCW'(pl & gfst_q);
      end
    end
    // only a beat that completes a block needs credit (either source format may follow); the
    // layout of a transfer's first block is unknown until it arrives
    in_ok_d = !((Fp16Up && phase_d == PhW'(Nb16 - 1)) || phase_d == PhW'(Nb32 - 1)) ||
              ((free_d >= (xb_d ? need('0, 1'b0) : need(ioff_d, pl_d))) &&
               (!(gfst_d & (pl_d | xb_d)) || (sfree_d != '0)));
  end

  // block max operand: {floor(log2|v|), significand above max normal}
  typedef logic signed [9:0] mkey_t;

  mx_lane_t          un16 [E16];
  mx_lane_t          un32 [E32];
  mx_lane_t          ln   [MxBlockSize];
  mx_lane_t          lane_q [MxBlockSize];
  mkey_t             pmax_d [NumGrp];
  mkey_t             pmax_q [NumGrp];
  logic [NumGrp-1:0] pspec_d, pspec_q;
  logic              v0_q, pdis0_q, last0_q, pl0_q, g320_q, gend0_q, e4m3_0q, rceil0_q;
  logic [5:0]        a0_q;

  always_comb begin
    for (int e = 0; e < E32; e++)
      un32[e] = mx_unpack_fp32({data_i[4*e+3], data_i[4*e+2], data_i[4*e+1], data_i[4*e]});
    for (int e = 0; e < E16; e++)
      un16[e] = mx_unpack_fp16({data_i[2*e+1], data_i[2*e]});
    // a beat fills lane slot `phase` of the block; the lane register is the block buffer
    for (int i = 0; i < MxBlockSize; i++) begin
      if (fp16) ln[i] = (PhW'(i / E16) == phase_q) ? un16[i % E16] : lane_q[i];
      else      ln[i] = (PhW'(i / E32) == phase_q) ? un32[i % E32] : lane_q[i];
    end
    for (int g = 0; g < NumGrp; g++) begin
      mkey_t k [4];
      mkey_t a, b;
      for (int j = 0; j < 4; j++)
        k[j] = {ln[4*g+j].key, mx_sig_big(ln[4*g+j].sig, ln[4*g+j].sticky)};
      a = (k[0] > k[1]) ? k[0] : k[1];
      b = (k[2] > k[3]) ? k[2] : k[3];
      pmax_d[g]  = (a > b) ? a : b;
      pspec_d[g] = 1'b0;
      for (int j = 0; j < 4; j++) pspec_d[g] |= ln[4*g+j].cls inside {MX_INF, MX_NAN};
    end
  end

  always_ff @(posedge clk_i) begin
    if (pop) lane_q <= ln;
    if (pop && blk_done) begin
      pmax_q   <= pmax_d;
      pspec_q  <= pspec_d;
      pdis0_q  <= tag_i.poison_dis;
      last0_q  <= tag_i.last;
      pl0_q    <= pl;
      g320_q   <= tag_i.group == idma_pkg::MX_GROUP_G32;
      gend0_q  <= gend;
      a0_q     <= a_q;
      e4m3_0q  <= tag_i.elem_fmt == idma_pkg::MX_E4M3;
      rceil0_q <= tag_i.rceil;
    end
  end

  //--------------------------------------
  // Q1: block scale, exponent distances
  //--------------------------------------
  logic signed [8:0] bmax, sem, emin;
  logic              poison1_d, bump1_d;
  logic [7:0]        scale1_d;
  mx_qlane_t         ql1_d [MxBlockSize];
  mx_qlane_t         ql1_q [MxBlockSize];
  logic [7:0]        scale1_q;
  logic              v1_q, poison1_q, last1_q, pl1_q, g321_q, gend1_q, e4m3_1q, bump1_q;
  logic [5:0]        a1_q;

  always_comb begin
    mkey_t m [NumGrp];
    for (int g = 0; g < NumGrp; g++) m[g] = pmax_q[g];
    for (int s = NumGrp / 2; s > 0; s = s / 2)
      for (int g = 0; g < s; g++) m[g] = (m[g] > m[g+s]) ? m[g] : m[g+s];
    bmax = m[0][9:1];
    // E8M0 shared exponent bmax - emax clamped below at -127, plus the RCEIL bump; sem = shared
    // exponent + emax, so the lane gaps are format independent
    emin      = e4m3_0q ? -9'sd119 : -9'sd112;
    sem       = (bmax < emin) ? emin : bmax;
    bump1_d   = rceil0_q & m[0][0] & (bmax >= emin);
    poison1_d = (|pspec_q) & ~pdis0_q;
    scale1_d  = poison1_d ? E8m0Nan : 8'(sem - emin) + 8'(bump1_d);
    for (int i = 0; i < MxBlockSize; i++) begin
      logic signed [9:0] d;
      d = 10'(sem) - 10'(lane_q[i].key);
      ql1_d[i].sign   = lane_q[i].sign;
      ql1_d[i].cls    = lane_q[i].cls;
      ql1_d[i].gap    = (d > 10'sd63) ? 6'd63 : d[5:0];
      ql1_d[i].sig    = lane_q[i].sig;
      ql1_d[i].sticky = lane_q[i].sticky;
    end
  end

  always_ff @(posedge clk_i) begin
    ql1_q     <= ql1_d;
    scale1_q  <= scale1_d;
    poison1_q <= poison1_d;
    last1_q   <= last0_q;
    pl1_q     <= pl0_q;
    g321_q    <= g320_q;
    gend1_q   <= gend0_q;
    a1_q      <= a0_q;
    e4m3_1q   <= e4m3_0q;
    bump1_q   <= bump1_d;
  end

  //--------------------------------------
  // Q2: element lanes
  //--------------------------------------
  logic [BlkB-1:0][7:0] blk_d, blk_q;
  logic                 v2_q, last2_q, pl2_q, g322_q, gend2_q;
  logic [5:0]           a2_q;

  always_comb begin
    blk_d[0] = scale1_q;
    for (int i = 0; i < MxBlockSize; i++) begin
      mx_qlane_t l;
      l     = ql1_q[i];
      l.gap = l.gap + 6'(bump1_q & (l.gap != 6'd63));
      if (poison1_q)    blk_d[i+1] = e4m3_1q ? E4m3Nan : E5m2Nan;
      else if (e4m3_1q) blk_d[i+1] = mx_e4m3_quant(l);
      else              blk_d[i+1] = mx_e5m2_quant(l);
    end
  end

  always_ff @(posedge clk_i) begin
    blk_q   <= blk_d;
    last2_q <= last1_q;
    pl2_q   <= pl1_q;
    g322_q  <= g321_q;
    gend2_q <= gend1_q;
    a2_q    <= a1_q;
  end

  //--------------------------------------
  // Q3: insert into the output queues
  //--------------------------------------
  beat_t             oq_q [Depth];
  logic [Depth-1:0]  oq_gend_q;
  logic [PtrW-1:0]   wp_q, wp_d, rp_q, rp_d;
  logic [OffW-1:0]   woff_q, woff_d;
  logic [CntW-1:0]   cnt_q, cnt_d;
  logic [BlkB*8-1:0] ins;
  logic [WinB*8-1:0] win;
  logic [WinB-1:0]   wen;
  logic [OffW+6:0]   wend;
  logic [CntW-1:0]   npush;

  // planar blocks insert their 32 B of elements; the scale byte goes to the scale line
  always_comb begin
    ins    = pl2_q ? (BlkB*8)'(blk_q[BlkB-1:1]) : blk_q;
    win    = (WinB*8)'(ins) << {woff_q, 3'b000};
    wen    = (pl2_q ? WinB'({DatB{1'b1}}) : WinB'({BlkB{1'b1}})) << woff_q;
    wend   = (OffW+7)'(woff_q) + (pl2_q ? (OffW+7)'(DatB) : (OffW+7)'(BlkB));
    npush  = v2_q ? CntW'(wend >> OffW) + CntW'(last2_q && (wend[OffW-1:0] != '0)) : '0;
    wp_d   = PtrW'((32'(wp_q) + 32'(npush)) % Depth);
    rp_d   = oq_pop ? PtrW'((32'(rp_q) + 1) % Depth) : rp_q;
    woff_d = woff_q;
    if (v2_q) woff_d = last2_q ? '0 : wend[OffW-1:0];
    cnt_d  = cnt_q + npush - CntW'(oq_pop);
  end

  for (genvar e = 0; e < Depth; e++) begin : gen_oq
    logic [PtrW-1:0] j;
    assign j = PtrW'((32'(e) + Depth - 32'(wp_q)) % Depth);
    always_ff @(posedge clk_i) begin
      for (int b = 0; b < StrbWidth; b++)
        if (v2_q && (32'(j) < Win) && wen[32'(j)*StrbWidth + b])
          oq_q[e][b] <= win[(32'(j)*StrbWidth + b)*8 +: 8];
      // a group's last data entry is followed by the group's scale chunk
      if (v2_q && (32'(j) < 32'(npush)))
        oq_gend_q[e] <= pl2_q & gend2_q & (32'(j) == 32'(npush) - 1);
    end
  end

  // scale queue: the tail line collects its group's scale bytes and is pushed at the group end;
  // the chunk covers sub-beats s0..s1 of the line
  line_t           sq_q    [NSq];
  logic [SubW-1:0] sq_s0_q [NSq];
  logic [SubW-1:0] sq_s1_q [NSq];
  logic [SqPW-1:0] swp_q, srp_q;
  logic [SqCW-1:0] scnt_q;
  logic            so_q, sq_push;
  logic [SubW-1:0] ssub_q;
  beat_t           sq_beat;

  assign sq_push = v2_q & pl2_q & gend2_q;

  always_ff @(posedge clk_i) begin
    if (v2_q && pl2_q) begin
      sq_q[swp_q][a2_q] <= blk_q[0];
      if (gend2_q) begin
        sq_s0_q[swp_q] <= SubW'(32'({a2_q[5] & g322_q, 5'd0}) / StrbWidth);
        sq_s1_q[swp_q] <= SubW'(32'(a2_q) / StrbWidth);
      end
    end
  end

  if (NSub > 1) begin : gen_sq_sub
    assign sq_beat = sq_q[srp_q][32'(ssub_q)*StrbWidth +: StrbWidth];
  end else begin : gen_sq_line
    assign sq_beat = beat_t'(sq_q[srp_q]);
  end

  // output: the data entries in order, each group's scale chunk after its last data entry
  assign data_o  = so_q ? sq_beat : oq_q[rp_q];
  assign valid_o = so_q ? (scnt_q != '0) : (cnt_q != '0);
  assign oq_pop  = valid_o & ready_i & ~so_q;
  assign sq_pop  = valid_o & ready_i & so_q & (ssub_q == sq_s1_q[srp_q]);
  assign busy_o  = v0_q | v1_q | v2_q | (free_q != CntW'(Depth)) | (phase_q != '0) |
                   (sfree_q != SqCW'(NSq));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase_q <= '0;
      ioff_q  <= '0;
      free_q  <= CntW'(Depth);
      sfree_q <= SqCW'(NSq);
      in_ok_q <= 1'b1;
      pl_q    <= 1'b0;
      xb_q    <= 1'b1;
      gfst_q  <= 1'b1;
      a_q     <= '0;
      v0_q    <= 1'b0;
      v1_q    <= 1'b0;
      v2_q    <= 1'b0;
      wp_q    <= '0;
      rp_q    <= '0;
      woff_q  <= '0;
      cnt_q   <= '0;
      swp_q   <= '0;
      srp_q   <= '0;
      scnt_q  <= '0;
      so_q    <= 1'b0;
      ssub_q  <= '0;
    end else begin
      phase_q <= phase_d;
      ioff_q  <= ioff_d;
      free_q  <= free_d;
      sfree_q <= sfree_d;
      in_ok_q <= in_ok_d;
      pl_q    <= pl_d;
      xb_q    <= xb_d;
      gfst_q  <= gfst_d;
      a_q     <= a_d;
      v0_q    <= pop & blk_done;
      v1_q    <= v0_q;
      v2_q    <= v1_q;
      wp_q    <= wp_d;
      rp_q    <= rp_d;
      woff_q  <= woff_d;
      cnt_q   <= cnt_d;
      scnt_q  <= scnt_q + SqCW'(sq_push) - SqCW'(sq_pop);
      if (sq_push) swp_q <= (32'(swp_q) == NSq - 1) ? '0 : swp_q + SqPW'(1);
      if (sq_pop)  srp_q <= (32'(srp_q) == NSq - 1) ? '0 : srp_q + SqPW'(1);
      if (oq_pop && oq_gend_q[rp_q]) begin
        so_q   <= 1'b1;
        ssub_q <= sq_s0_q[srp_q];
      end else if (ready_i && so_q) begin
        so_q   <= ~sq_pop;
        ssub_q <= ssub_q + SubW'(1);
      end
    end
  end

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni) begin
    assert (32'(free_d) <= Depth)
      else $fatal(1, "idma_otf_mxquant: output credit overflow");
    assert (!pop || !blk_done || (free_q >= need(ioff_q, pl)))
      else $fatal(1, "idma_otf_mxquant: block issued without output credit");
    assert (!ready_i || valid_o)
      else $fatal(1, "idma_otf_mxquant: pop of an empty output queue");
    assert (32'(cnt_d) <= Depth)
      else $fatal(1, "idma_otf_mxquant: output queue overflow");
    assert (!(pop && blk_done && pl && gfst_q) || (sfree_q != '0))
      else $fatal(1, "idma_otf_mxquant: scale group opened without a scale line");
    assert (!(so_q && ready_i) || (scnt_q != '0))
      else $fatal(1, "idma_otf_mxquant: scale chunk read before its line was pushed");
  end
  // pragma translate_on

endmodule : idma_otf_mxquant

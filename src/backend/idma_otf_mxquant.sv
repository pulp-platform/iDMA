// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// On-the-fly MX quantizer: FP32 or FP16 input beats to inline [1 B E8M0 scale][32 B E5M2] blocks,
/// emitted as whole output beats. Four never-stalling stages: Q0 unpack and partial max, Q1 block
/// scale and exponent distances, Q2 element lanes, Q3 insert into the output queue. A beat is
/// accepted only while the queue holds credit for the entries its block opens. A block holding an
/// Inf or NaN is poisoned (0xFF scale, canonical NaN elements) unless its tag disables it.
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
  localparam int unsigned E16    = Fp16Up ? StrbWidth / 2 : 1;
  localparam int unsigned E32    = StrbWidth / 4;
  localparam int unsigned Nb16   = MxBlockSize / E16;
  localparam int unsigned Nb32   = MxBlockSize / E32;
  localparam int unsigned PhW    = (Nb32 > 1) ? $clog2(Nb32) : 1;
  localparam int unsigned OffW   = $clog2(StrbWidth);
  localparam int unsigned BlkB   = MxCompressedBlockBytes;
  localparam int unsigned NumGrp = MxBlockSize / 4;
  // output entries one block can touch, and the queue depth covering the credit loop
  localparam int unsigned Win    = (StrbWidth + BlkB + StrbWidth - 2) / StrbWidth;
  localparam int unsigned Depth  = Win + 4;
  localparam int unsigned PtrW   = $clog2(Depth);
  localparam int unsigned CntW   = $clog2(Depth + 1);
  localparam int unsigned WinB   = Win * StrbWidth;

  typedef logic [StrbWidth-1:0][7:0] beat_t;

  // pragma translate_off
  initial assert (StrbWidth >= 4 && StrbWidth <= 128 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_mxquant: StrbWidth (%0d) must be a power of two in [4, 128]", StrbWidth);
  // pragma translate_on

  // output entries a block opens when it starts at byte `off` of the open entry
  function automatic logic [CntW-1:0] need(input logic [OffW-1:0] off);
    return CntW'(((32'(off) + BlkB + StrbWidth - 1) >> OffW) - 32'(off != '0));
  endfunction

  //--------------------------------------
  // Issue: credit check and Q0
  //--------------------------------------
  logic            pop, fp16, blk_done, oq_pop;
  logic [PhW-1:0]  phase_q, phase_d;
  logic [OffW-1:0] ioff_q, ioff_d;
  logic [CntW-1:0] free_q, free_d;
  logic            in_ok_q, in_ok_d;

  assign fp16     = Fp16Up && (tag_i.fmt == idma_pkg::MX_FMT_FP16);
  assign blk_done = phase_q == (fp16 ? PhW'(Nb16 - 1) : PhW'(Nb32 - 1));
  assign ready_o  = in_ok_q;
  assign pop      = valid_i & in_ok_q;
  assign oq_pop   = valid_o & ready_i;

  always_comb begin
    phase_d = phase_q;
    ioff_d  = ioff_q;
    free_d  = free_q + CntW'(oq_pop);
    if (pop) begin
      phase_d = blk_done ? '0 : phase_q + PhW'(1);
      if (blk_done) begin
        ioff_d = tag_i.last ? '0 : OffW'(32'(ioff_q) + BlkB);
        free_d = free_d - need(ioff_q);
      end
    end
    // only a beat that completes a block needs credit (either source format may follow)
    in_ok_d = !((Fp16Up && phase_d == PhW'(Nb16 - 1)) || phase_d == PhW'(Nb32 - 1)) ||
              (free_d >= need(ioff_d));
  end

  mx_lane_t          un16 [E16];
  mx_lane_t          un32 [E32];
  mx_lane_t          ln   [MxBlockSize];
  mx_lane_t          lane_q [MxBlockSize];
  logic signed [8:0] pmax_d [NumGrp];
  logic signed [8:0] pmax_q [NumGrp];
  logic [NumGrp-1:0] pspec_d, pspec_q;
  logic              v0_q, pdis0_q, last0_q;

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
      logic signed [8:0] a, b;
      a = (ln[4*g].key   > ln[4*g+1].key) ? ln[4*g].key   : ln[4*g+1].key;
      b = (ln[4*g+2].key > ln[4*g+3].key) ? ln[4*g+2].key : ln[4*g+3].key;
      pmax_d[g]  = (a > b) ? a : b;
      pspec_d[g] = 1'b0;
      for (int j = 0; j < 4; j++) pspec_d[g] |= ln[4*g+j].cls inside {MX_INF, MX_NAN};
    end
  end

  always_ff @(posedge clk_i) begin
    if (pop) lane_q <= ln;
    if (pop && blk_done) begin
      pmax_q  <= pmax_d;
      pspec_q <= pspec_d;
      pdis0_q <= tag_i.poison_dis;
      last0_q <= tag_i.last;
    end
  end

  //--------------------------------------
  // Q1: block scale, exponent distances
  //--------------------------------------
  logic signed [8:0] bmax, se15;
  logic              poison1_d;
  logic [7:0]        scale1_d;
  mx_qlane_t         ql1_d [MxBlockSize];
  mx_qlane_t         ql1_q [MxBlockSize];
  logic [7:0]        scale1_q;
  logic              v1_q, poison1_q, last1_q;

  always_comb begin
    logic signed [8:0] m [NumGrp];
    for (int g = 0; g < NumGrp; g++) m[g] = pmax_q[g];
    for (int s = NumGrp / 2; s > 0; s = s / 2)
      for (int g = 0; g < s; g++) m[g] = (m[g] > m[g+s]) ? m[g] : m[g+s];
    bmax = m[0];
    // E8M0 shared exponent bmax - emax, clamped below at -127; se15 = shared exponent + emax
    se15      = (bmax < -9'sd112) ? -9'sd112 : bmax;
    poison1_d = (|pspec_q) & ~pdis0_q;
    scale1_d  = poison1_d ? E8m0Nan : 8'(se15 + 9'sd112);
    for (int i = 0; i < MxBlockSize; i++) begin
      logic signed [9:0] d;
      d = 10'(se15) - 10'(lane_q[i].key);
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
  end

  //--------------------------------------
  // Q2: element lanes
  //--------------------------------------
  logic [BlkB-1:0][7:0] blk_d, blk_q;
  logic                 v2_q, last2_q;

  always_comb begin
    blk_d[0] = scale1_q;
    for (int i = 0; i < MxBlockSize; i++)
      blk_d[i+1] = poison1_q ? E5m2Nan : mx_e5m2_quant(ql1_q[i]);
  end

  always_ff @(posedge clk_i) begin
    blk_q   <= blk_d;
    last2_q <= last1_q;
  end

  //--------------------------------------
  // Q3: insert into the output queue
  //--------------------------------------
  beat_t             oq_q [Depth];
  logic [PtrW-1:0]   wp_q, wp_d, rp_q, rp_d;
  logic [OffW-1:0]   woff_q, woff_d;
  logic [CntW-1:0]   cnt_q, cnt_d;
  logic [WinB*8-1:0] win;
  logic [WinB-1:0]   wen;
  logic [OffW+6:0]   wend;
  logic [CntW-1:0]   npush;

  always_comb begin
    win   = (WinB*8)'(blk_q) << {woff_q, 3'b000};
    wen   = WinB'({BlkB{1'b1}}) << woff_q;
    wend  = (OffW+7)'(woff_q) + (OffW+7)'(BlkB);
    npush = v2_q ? CntW'(wend >> OffW) + CntW'(last2_q && (wend[OffW-1:0] != '0)) : '0;
    wp_d  = PtrW'((32'(wp_q) + 32'(npush)) % Depth);
    rp_d  = oq_pop ? PtrW'((32'(rp_q) + 1) % Depth) : rp_q;
    woff_d = woff_q;
    if (v2_q) woff_d = last2_q ? '0 : wend[OffW-1:0];
    cnt_d = cnt_q + npush - CntW'(oq_pop);
  end

  for (genvar e = 0; e < Depth; e++) begin : gen_oq
    logic [PtrW-1:0] j;
    assign j = PtrW'((32'(e) + Depth - 32'(wp_q)) % Depth);
    always_ff @(posedge clk_i) begin
      for (int b = 0; b < StrbWidth; b++)
        if (v2_q && (32'(j) < Win) && wen[32'(j)*StrbWidth + b])
          oq_q[e][b] <= win[(32'(j)*StrbWidth + b)*8 +: 8];
    end
  end

  assign data_o  = oq_q[rp_q];
  assign valid_o = cnt_q != '0;
  assign busy_o  = v0_q | v1_q | v2_q | (free_q != CntW'(Depth)) | (phase_q != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase_q <= '0;
      ioff_q  <= '0;
      free_q  <= CntW'(Depth);
      in_ok_q <= 1'b1;
      v0_q    <= 1'b0;
      v1_q    <= 1'b0;
      v2_q    <= 1'b0;
      wp_q    <= '0;
      rp_q    <= '0;
      woff_q  <= '0;
      cnt_q   <= '0;
    end else begin
      phase_q <= phase_d;
      ioff_q  <= ioff_d;
      free_q  <= free_d;
      in_ok_q <= in_ok_d;
      v0_q    <= pop & blk_done;
      v1_q    <= v0_q;
      v2_q    <= v1_q;
      wp_q    <= wp_d;
      rp_q    <= rp_d;
      woff_q  <= woff_d;
      cnt_q   <= cnt_d;
    end
  end

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni) begin
    assert (32'(free_d) <= Depth)
      else $fatal(1, "idma_otf_mxquant: output credit overflow");
    assert (!pop || !blk_done || (free_q >= need(ioff_q)))
      else $fatal(1, "idma_otf_mxquant: block issued without output credit");
    assert (!ready_i || valid_o)
      else $fatal(1, "idma_otf_mxquant: pop of an empty output queue");
    assert (32'(cnt_d) <= Depth)
      else $fatal(1, "idma_otf_mxquant: output queue overflow");
  end
  // pragma translate_on

endmodule : idma_otf_mxquant

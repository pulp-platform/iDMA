// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// On-the-fly MX quantization sub-unit for the iDMA compute seam. Collects a
// 32-element block over the input beats (FP32 4B/elem, FP16 2B/elem widened to
// FP32), quantizes to one 33B MX block ([1B E8M0 scale][32B E5M2]) and packs it
// into StrbWidth-wide output beats. lane_valid_o reports pack occupancy per
// lane; the write manager's own beat mask decides acceptance, so a partial
// presentation can only ever complete the transfer's genuine tail beat.
// FP16 requires StrbWidth <= 64 (<=1 block completes per beat).
module idma_otf_mxquant
  import idma_mxquant_pkg::*;
#(
  parameter int unsigned StrbWidth = 32'd8,
  parameter bit          Fp16En    = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  /// Source element format: FP16 collects 64B/block, FP32 128B/block
  input  idma_pkg::mx_fmt_e src_fmt_i,

  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  output logic                      ready_o,

  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      lane_valid_o,
  /// Byte lanes the write accepted this cycle; the pack pops exactly these
  input  logic [StrbWidth-1:0]      lane_ready_i,
  output logic                      busy_o
);

  // FP32 packs one block per beat up to StrbWidth 128; FP16 above 64 is rejected by the legalizer
  initial assert (StrbWidth >= 4 && StrbWidth <= 128 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_mxquant: StrbWidth (%0d) must be a power of two in [4, 128]", StrbWidth);

  localparam int unsigned BufSize     = MxCompressedBlockBytes + StrbWidth;
  localparam int unsigned OffsetWidth = $clog2(BufSize) + 1;
  localparam int unsigned ElemsFP32   = StrbWidth / 4;
  localparam int unsigned ElemsFP16   = StrbWidth / 2;
  localparam int unsigned FillW       = $clog2(MxBlockSize) + 1;
  // FP16 is illegal above StrbWidth 64 (legalizer ComputeMxFp16Width), so gate it off
  localparam bit          Fp16Up      = Fp16En && (StrbWidth <= 64);
  localparam int unsigned ElemsMax    = Fp16Up ? ElemsFP16 : ElemsFP32;
  localparam bit          FullBeat    = (!Fp16Up) && (ElemsFP32 == MxBlockSize);
  localparam int unsigned PopW        = $clog2(StrbWidth + 1);
  localparam int unsigned IdxW        = (ElemsMax > 1) ? $clog2(ElemsMax) : 1;

  logic [31:0]      elem_q [MxBlockSize];
  logic [FillW-1:0] fill_q;
  logic [31:0]      elem_d [MxBlockSize];
  logic [FillW-1:0] fill_d;

  logic [            7:0] pack_q [BufSize];
  logic [OffsetWidth-1:0] pack_off_q;
  logic [            7:0] pack_d [BufSize];
  logic [OffsetWidth-1:0] pack_off_d;

  logic fp16_act;
  assign fp16_act = (Fp16Up != 1'b0) && (src_fmt_i == idma_pkg::MX_FMT_FP16);

  // lane-exact pop: a tail beat pops only its own bytes
  logic [PopW-1:0] pop_cnt;
  always_comb begin
    pop_cnt = '0;
    for (int i = 0; i < StrbWidth; i++)
      if (lane_ready_i[i] && lane_valid_o[i]) pop_cnt += PopW'(1);
  end

  assign busy_o = (fill_q != '0) || (pack_off_q != '0);

  // widen this beat's elements to FP32
  logic [31:0] in_elem [ElemsMax];
  always_comb begin
    for (int e = 0; e < ElemsMax; e++) begin
      if (fp16_act)
        in_elem[e] = fp16_bits_to_fp32({data_i[e*2+1], data_i[e*2]});
      else if (e < ElemsFP32)
        in_elem[e] = {data_i[e*4+3], data_i[e*4+2], data_i[e*4+1], data_i[e*4]};
      else
        in_elem[e] = 32'd0;
    end
  end

  logic             blk_completing;
  logic [FillW-1:0] nelems, fill_next;
  assign nelems         = fp16_act ? FillW'(ElemsFP16) : FillW'(ElemsFP32);
  assign fill_next      = fill_q + nelems;
  assign blk_completing = fill_next[FillW-1];

  // single rotate crossbar: lane i sees incoming element (i - fill_q) mod 32
  logic [31:0] rot_elem [MxBlockSize];
  logic [31:0] blk_elem [MxBlockSize];
  always_comb begin
    for (int i = 0; i < MxBlockSize; i++) begin : lane
      logic [4:0] rot;
      rot = 5'(i) - fill_q[4:0];
      rot_elem[i] = in_elem[rot[IdxW-1:0]];
      blk_elem[i] = (i < 32'(fill_q)) ? elem_q[i] : rot_elem[i];
    end
  end

  // in-module reimplementation of fp32_to_mxfp8_byte_prescaled: bit-exact, with
  // proven-bound narrowing (scaled_exp in [-255,256] -> 10b signed) and the
  // subnormal shifter reduced to its 3 reachable amounts (sh in {22,23,24})
  function automatic logic [7:0] q_e5m2(input logic [31:0] f, input logic signed [7:0] dec_scale);
    logic               sign;
    logic [7:0]         expf;
    logic [22:0]        manf;
    logic signed [9:0]  exp_s, sc_s, scaled_exp;
    logic [23:0]        full_mant;
    logic [3:0]         rounded;
    logic               guard, sticky, roundup, carry;
    logic [5:0]         oexp;
    logic [4:0]         mexp;
    logic [1:0]         mmant;
    logic [3:0]         sub_kept;
    logic               sub_guard, sub_stky;

    sign = f[31]; expf = f[30:23]; manf = f[22:0];
    if (expf == 8'd0 && manf == 23'd0) return {sign, 5'd0, 2'd0};
    if (expf == 8'hFF && manf != 23'd0) return {sign, 5'h1F, 2'd1};
    if (expf == 8'hFF)                  return {sign, 5'h1E, 2'd3};

    exp_s      = signed'({2'b00, expf});
    sc_s       = signed'({{2{dec_scale[7]}}, dec_scale});
    scaled_exp = exp_s - 10'sd127 - sc_s;
    full_mant  = {1'b1, manf};

    if (scaled_exp > 10'sd15) return {sign, 5'h1E, 2'd3};

    if (scaled_exp >= -10'sd14) begin
      rounded = {1'b0, full_mant[23:21]};
      guard   = full_mant[20];
      sticky  = (full_mant[19:0] != 20'd0);
      roundup = guard && (rounded[0] || sticky);
      if (roundup) rounded = rounded + 4'd1;
      carry = rounded[3];
      oexp  = 6'(scaled_exp + 10'sd15) + 6'(carry);
      mmant = rounded[1:0];
      if (oexp > 6'd30) begin
        mexp  = 5'd30;
        mmant = 2'd3;
      end else begin
        mexp = oexp[4:0];
      end
      return {sign, mexp, mmant};
    end

    if (scaled_exp < -10'sd17) return {sign, 5'd0, 2'd0};
    // scaled_exp in {-15,-16,-17} <=> low bits {01,00,11}; sh_amt {22,23,24}
    case (scaled_exp[1:0])
      2'b01:   begin sub_kept = {2'b00, full_mant[23:22]}; sub_guard = full_mant[21]; sub_stky = (full_mant[20:0] != 21'd0); end
      2'b00:   begin sub_kept = {3'b000, full_mant[23]};   sub_guard = full_mant[22]; sub_stky = (full_mant[21:0] != 22'd0); end
      default: begin sub_kept = 4'd0;                      sub_guard = full_mant[23]; sub_stky = (full_mant[22:0] != 23'd0); end
    endcase
    if (sub_guard && (sub_kept[0] || sub_stky)) sub_kept = sub_kept + 4'd1;
    if (sub_kept == 4'd0)     return {sign, 5'd0, 2'd0};
    else if (sub_kept < 4'd4) return {sign, 5'd0, sub_kept[1:0]};
    else                      return {sign, 5'd1, 2'd0};
  endfunction

  // one shared scale tree + one bank of 32 quantizers (<=1 block completes per beat)
  logic [7:0]        blk_scale;
  logic signed [7:0] dec_scale;
  logic [7:0]        qbyte [MxBlockSize];
  always_comb begin
    blk_scale = compute_block_scale_with_bias(blk_elem, E5m2Bias);
    dec_scale = signed'(blk_scale);
    for (int i = 0; i < MxBlockSize; i++)
      qbyte[i] = q_e5m2(blk_elem[i], dec_scale);
  end

  logic                              can_accept, accept;
  logic [OffsetWidth-1:0]            ins_base;
  logic [MxCompressedBlockBytes-1:0][7:0] blk33;
  logic [BufSize*8-1:0]              blk_vec;
  logic [BufSize-1:0]                ins_mask;

  always_comb begin
    for (int i = 0; i < BufSize; i++) pack_d[i] = pack_q[i];
    pack_off_d = pack_off_q;

    if (pop_cnt != '0) begin
      for (int i = 0; i < BufSize; i++)
        pack_d[i] = ((i + 32'(pop_cnt)) < BufSize) ? pack_q[i + 32'(pop_cnt)] : 8'd0;
      pack_off_d = (pack_off_d > OffsetWidth'(pop_cnt)) ? OffsetWidth'(pack_off_d - pop_cnt) : '0;
    end

    // pack space (one 33B block; <=1 completes per beat) is only needed on a completing beat
    can_accept = (pack_off_d + OffsetWidth'(MxCompressedBlockBytes)) <= OffsetWidth'(BufSize)
                 || !blk_completing;
    accept = valid_i && can_accept;

    fill_d = fill_q;
    for (int i = 0; i < MxBlockSize; i++) elem_d[i] = elem_q[i];
    if (accept) begin
      if (blk_completing) begin
        // spill = fill_next - 32 elements start the next block at index 0
        for (int i = 0; i < MxBlockSize; i++)
          elem_d[i] = (i < 32'(fill_next[FillW-2:0])) ? rot_elem[i] : blk_elem[i];
        fill_d = {1'b0, fill_next[FillW-2:0]};
      end else begin
        for (int i = 0; i < MxBlockSize; i++)
          elem_d[i] = (i < 32'(fill_next)) ? blk_elem[i] : elem_q[i];
        fill_d = fill_next;
      end
    end

    // hoisted single 33B block insert at the post-pop write offset
    ins_base = pack_off_d;
    blk33[0] = blk_scale;
    for (int i = 0; i < MxBlockSize; i++) blk33[i+1] = qbyte[i];
    blk_vec  = (BufSize*8)'(blk33) << {ins_base, 3'b000};
    ins_mask = BufSize'({MxCompressedBlockBytes{1'b1}}) << ins_base;
    if (accept && blk_completing) begin
      for (int i = 0; i < BufSize; i++)
        if (ins_mask[i]) pack_d[i] = blk_vec[i*8 +: 8];
      pack_off_d = pack_off_d + OffsetWidth'(MxCompressedBlockBytes);
    end

    ready_o = can_accept;
  end

  // outputs are pure functions of pack state (identical to the former output regs)
  for (genvar i = 0; i < StrbWidth; i++) begin : gen_out
    assign lane_valid_o[i] = (OffsetWidth'(i) < pack_off_q);
    assign data_o[i]       = lane_valid_o[i] ? pack_q[i] : 8'd0;
  end

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni)
    assert (pack_off_d <= OffsetWidth'(BufSize))
      else $fatal(1, "idma_otf_mxquant: pack-buffer overflow (StrbWidth=%0d)", StrbWidth);
  always @(posedge clk_i) if (rst_ni)
    assert (32'(pop_cnt) <= 32'(pack_off_q))
      else $fatal(1, "idma_otf_mxquant: pop exceeds pack occupancy");
  // NOT IMPLEMENTED: overlapping compute transfers (a clear must never drop in-flight state)
  always @(posedge clk_i) if (rst_ni && clear_i)
    assert ((fill_q == '0) && (pack_off_q == '0))
      else $fatal(1, "idma_otf_mxquant: clear with in-flight state (overlapping transfers)");
  // pragma translate_on

  if (FullBeat) begin : gen_fill_const
    // every accepted beat is a whole block, so the fill counter is a constant 0
    assign fill_q = '0;
  end else begin : gen_fill_ff
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni)      fill_q <= '0;
      else if (clear_i) fill_q <= '0;
      else              fill_q <= fill_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pack_off_q <= '0;
      for (int i = 0; i < MxBlockSize; i++) elem_q[i] <= 32'd0;
      for (int i = 0; i < BufSize; i++)     pack_q[i] <= 8'd0;
    end else if (clear_i) begin
      pack_off_q <= '0;
    end else begin
      for (int i = 0; i < MxBlockSize; i++) elem_q[i] <= elem_d[i];
      pack_off_q <= pack_off_d;
      for (int i = 0; i < BufSize; i++)     pack_q[i] <= pack_d[i];
    end
  end

endmodule : idma_otf_mxquant

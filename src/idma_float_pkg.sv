// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// FP-cast core for MX compute: FP16/FP32 <-> MXFP8 (E5M2) with E8M0 block scale.
package idma_float_pkg;

  // block geometry is single-homed in idma_pkg
  localparam int unsigned MxBlockSize            = idma_pkg::MxBlockElems;
  localparam int unsigned MxFp32BlockBytes       = idma_pkg::MxFp32BlockBytes;
  localparam int unsigned MxFp16BlockBytes       = idma_pkg::MxFp16BlockBytes;
  localparam int unsigned MxCompressedBlockBytes = idma_pkg::MxBlockBytes;

  localparam int unsigned E5m2ExpBits = 5;
  localparam int unsigned Fp32ExpBits = 8;
  localparam int unsigned Fp16ExpBits = 5;

  // IEEE-754 symmetric bias: 2**(exp_bits-1) - 1
  function automatic int fp_bias(input int unsigned exp_bits);
    return (1 << (exp_bits - 1)) - 1;
  endfunction

  localparam int E5m2Bias   = fp_bias(E5m2ExpBits);
  localparam int E5m2ExpMax = E5m2Bias;
  localparam int E5m2ExpMin = 1 - E5m2Bias;
  localparam int Fp32Bias   = fp_bias(Fp32ExpBits);
  localparam int Fp16Bias   = fp_bias(Fp16ExpBits);

  // OCP MX v1.0 E8M0 block scale: X = 2^(E - 127), E in [0, 254], 0xFF = NaN
  localparam int         E8m0Bias   = 127;
  localparam int         E8m0ExpMax = 127;
  localparam int         E8m0ExpMin = -127;
  localparam logic [7:0] E8m0Nan    = 8'hFF;
  // canonical E5M2 NaN of a poisoned block (OCP MX v1.0 6.3)
  localparam logic [7:0] E5m2Nan    = 8'h7D;

  function automatic int decode_e8m0_scale(input logic [7:0] scale);
    return int'(scale) - E8m0Bias;
  endfunction

  // Inf/NaN lanes are excluded from the scan; the shared exponent clamps to the E8M0 range
  function automatic logic [7:0] compute_block_scale_with_bias(
      input logic [31:0] fp32_bits[MxBlockSize], input int bias);
    logic [7:0] max_exp;
    logic [7:0] exp_tree [MxBlockSize];
    int         scale;
    for (int i = 0; i < MxBlockSize; i++)
      exp_tree[i] = (fp32_bits[i][30:23] == 8'hFF) ? 8'd0 : fp32_bits[i][30:23];
    for (int s = MxBlockSize/2; s > 0; s = s/2)
      for (int i = 0; i < s; i++)
        exp_tree[i] = (exp_tree[i] > exp_tree[i+s]) ? exp_tree[i] : exp_tree[i+s];
    max_exp = exp_tree[0];
    scale = int'(max_exp) - Fp32Bias - bias;
    if (scale < E8m0ExpMin) scale = E8m0ExpMin;
    else if (scale > E8m0ExpMax) scale = E8m0ExpMax;
    return 8'(scale + E8m0Bias);
  endfunction

  // any Inf/NaN lane poisons the block
  function automatic logic block_has_special(input logic [31:0] fp32_bits[MxBlockSize]);
    logic special;
    special = 1'b0;
    for (int i = 0; i < MxBlockSize; i++) special |= (fp32_bits[i][30:23] == 8'hFF);
    return special;
  endfunction

  // RNE FP32 -> E5M2 with exact subnormal inputs and outputs. The split normal/subnormal
  // bands are load-bearing: merging them halves the smallest-normal band and
  // flushes all subnormals to zero. Do not merge.
  function automatic logic [7:0] fp32_to_mxfp8_byte_prescaled(input logic [31:0] fp32_bits,
                                                              input int decoded_scale);
    logic        sign;
    logic [ 7:0] expf;
    logic [22:0] manf;
    int unbiased, scaled_exp;
    logic [23:0] full_mant;
    logic [ 4:0] mexp;
    logic [ 1:0] mmant;
    logic exp_is_zero, exp_is_max, mant_is_zero;
    logic [ 3:0] rounded;
    logic guard, sticky, roundup;
    logic signed [31:0] out_exp;
    logic carry;
    logic [ 5:0] sh_amt;
    logic [ 3:0] sub_kept;
    logic        sub_guard, sub_stky;

    sign         = fp32_bits[31];
    expf         = fp32_bits[30:23];
    manf         = fp32_bits[22:0];

    exp_is_zero  = (expf == 8'd0);
    exp_is_max   = (expf == 8'hFF);
    mant_is_zero = (manf == 23'd0);

    if (exp_is_zero && mant_is_zero) begin
      return {sign, 5'd0, 2'd0};   // zero
    end else if (exp_is_max && !mant_is_zero) begin
      return {sign, 5'h1F, 2'd1};  // NaN
    end else if (exp_is_max) begin
      return {sign, 5'h1E, 2'd3};  // Inf saturates (OCP FP8 SAT)
    end

    if (exp_is_zero) begin
      unbiased  = 1 - Fp32Bias;
      full_mant = {1'b0, manf};
      for (int i = 0; i < 23; i++) begin
        if (!full_mant[23]) begin
          full_mant = full_mant << 1;
          unbiased--;
        end
      end
    end else begin
      unbiased  = int'(expf) - Fp32Bias;
      full_mant = {1'b1, manf};
    end
    scaled_exp = unbiased - decoded_scale;

    if (scaled_exp > E5m2ExpMax) return {sign, 5'h1E, 2'd3}; // saturate

    if (scaled_exp >= E5m2ExpMin) begin
      rounded = {1'b0, full_mant[23:21]};
      guard   = full_mant[20];
      sticky  = (full_mant[19:0] != 20'd0);
      roundup = guard && (rounded[0] || sticky);
      if (roundup) rounded = rounded + 4'd1;
      carry   = rounded[3];
      out_exp = scaled_exp + E5m2Bias + int'(carry);
      mmant   = rounded[1:0];
      if (out_exp > 30) begin
        mexp  = 5'd30;
        mmant = 2'd3;
      end else begin
        mexp = out_exp[4:0];
      end
      return {sign, mexp, mmant};
    end else begin
      if (scaled_exp < (E5m2ExpMin - 3)) return {sign, 5'd0, 2'd0};
      sh_amt    = 6'(21 + (E5m2ExpMin - scaled_exp));
      sub_kept  = 4'(full_mant >> sh_amt);
      sub_guard = full_mant[sh_amt - 1];
      sub_stky  = |(full_mant & ((24'd1 << (sh_amt - 1)) - 24'd1));
      if (sub_guard && (sub_kept[0] || sub_stky)) sub_kept = sub_kept + 4'd1;
      if (sub_kept == 4'd0)      return {sign, 5'd0, 2'd0};
      else if (sub_kept < 4'd4)  return {sign, 5'd0, sub_kept[1:0]};
      else                       return {sign, 5'd1, 2'd0};
    end
  endfunction

  // Exact FP16 (E5M10) -> FP32 widen (lossless).
  function automatic logic [31:0] fp16_bits_to_fp32(input logic [15:0] fp16_bits);
    logic       sign;
    logic [4:0] exp16;
    logic [9:0] man16;
    logic [7:0] exp32;
    logic [22:0] man32;
    logic [3:0] lz;
    logic [9:0] man_norm;

    sign  = fp16_bits[15];
    exp16 = fp16_bits[14:10];
    man16 = fp16_bits[9:0];

    if (exp16 == 5'h1F) begin
      if (man16 == 10'd0) return {sign, 8'hFF, 23'd0};
      else                return {sign, 8'hFF, 1'b1, man16, 12'd0};
    end
    if (exp16 == 5'd0 && man16 == 10'd0) return {sign, 31'd0};
    if (exp16 == 5'd0) begin
      casez (man16)
        10'b1?????????: lz = 4'd0;
        10'b01????????: lz = 4'd1;
        10'b001???????: lz = 4'd2;
        10'b0001??????: lz = 4'd3;
        10'b00001?????: lz = 4'd4;
        10'b000001????: lz = 4'd5;
        10'b0000001???: lz = 4'd6;
        10'b00000001??: lz = 4'd7;
        10'b000000001?: lz = 4'd8;
        default:        lz = 4'd9;
      endcase
      exp32    = 8'((Fp32Bias - Fp16Bias) - int'(lz));
      man_norm = man16 << (lz + 4'd1);
      man32    = {man_norm, 13'd0};
      return {sign, exp32, man32};
    end
    exp32 = 8'(int'(exp16) + (Fp32Bias - Fp16Bias));
    man32 = {man16, 13'd0};
    return {sign, exp32, man32};
  endfunction

  // IEEE FP32 -> FP16 narrowing: RNE, overflow saturates to +-Inf, NaN keeps a payload bit
  function automatic logic [15:0] fp32_bits_to_fp16(input logic [31:0] fp32_bits);
    logic        sign;
    logic [ 7:0] exp32;
    logic [22:0] man32;
    int          unb;
    logic [12:0] rest;
    logic [ 9:0] man16;
    logic [10:0] rounded;
    logic [24:0] full;
    int          sh;
    logic        guard, sticky;
    sign  = fp32_bits[31];
    exp32 = fp32_bits[30:23];
    man32 = fp32_bits[22:0];
    if (exp32 == 8'hFF) return (man32 != '0) ? {sign, 5'h1F, 10'h200} : {sign, 5'h1F, 10'd0};
    if (exp32 == 8'd0) return {sign, 15'd0};
    unb = int'(exp32) - Fp32Bias;
    if (unb > 15) return {sign, 5'h1F, 10'd0};
    if (unb >= -14) begin
      man16 = man32[22:13];
      rest  = man32[12:0];
      rounded = {1'b0, man16} + 11'((rest > 13'h1000) || (rest == 13'h1000 && man16[0]));
      if (rounded[10]) begin
        if (unb == 15) return {sign, 5'h1F, 10'd0};
        return {sign, 5'(unb + Fp16Bias + 1), 10'd0};
      end
      return {sign, 5'(unb + Fp16Bias), rounded[9:0]};
    end
    if (unb < -25) return {sign, 15'd0};
    full   = {1'b1, man32, 1'b0};
    sh     = -14 - unb;
    man16  = 10'(full >> (sh + 14));
    guard  = full[sh+13];
    sticky = ((full << (12 - sh)) != '0);
    rounded = {1'b0, man16} + 11'(guard && (man16[0] || sticky));
    return {sign, rounded[10] ? {5'd1, 10'd0} : {5'd0, rounded[9:0]}};
  endfunction

  // MXFP8 (E5M2) -> FP32 with the decoded block scale applied, exact (IEEE subnormals, overflow to
  // Inf); the caller handles the NaN scale
  function automatic logic [31:0] mxfp8_byte_to_fp32_prescaled(input logic [7:0] byte_val,
                                                               input int scaled);
    logic        sign;
    logic [ 4:0] exp_e5;
    logic [ 1:0] mant;
    logic [31:0] sign_bit;
    logic signed [31:0] fp32_exp;
    logic [22:0] out_mant;
    logic exp_is_zero, exp_is_max;

    sign        = byte_val[7];
    exp_e5      = byte_val[6:2];
    mant        = byte_val[1:0];
    sign_bit    = {sign, 31'd0};

    exp_is_zero = (exp_e5 == 5'd0);
    exp_is_max  = (exp_e5 == 5'h1F);

    if (exp_is_zero && mant == 2'd0) return sign_bit;
    if (exp_is_max && mant == 2'd0) return sign_bit | 32'h7F800000;
    if (exp_is_max) return 32'h7FC00000;

    if (exp_is_zero) begin
      fp32_exp = (-16 + int'(mant > 2'd1) + scaled) + Fp32Bias;
      out_mant = {mant[1] & mant[0], 22'd0};
    end else begin
      fp32_exp = int'(exp_e5) - E5m2Bias + scaled + Fp32Bias;
      out_mant = {mant, 21'd0};
    end

    if (fp32_exp >= 255) return sign_bit | 32'h7F800000;
    if (fp32_exp <= 0) return sign_bit | 32'(({1'b1, out_mant}) >> (1 - fp32_exp));
    return sign_bit | (32'(fp32_exp[7:0]) << 23) | 32'(out_mant);
  endfunction

  // FP32 subnormal -> exponent 0, mantissa [22:18] {3 bits after the leading one, sticky, 1},
  // [5:0] -lz; lossless for E5M2 rounding, the other bits are don't care. The leading one is
  // found per nibble, then inside the 8-bit window at the leading nibble
  function automatic logic [31:0] fp32_sub_norm(input logic [31:0] f);
    logic [23:0] mp;
    logic [5:0]  nz, ohk, below;
    logic [7:0]  w;
    logic [1:0]  lz4;
    logic [4:0]  lz;
    logic        m1, m0, g, st, rem;
    if (f[30:23] != 8'd0 || f[22:0] == 23'd0) return f;
    mp = {1'b0, f[22:0]};
    for (int k = 0; k < 6; k++) nz[k] = |mp[4*k +: 4];
    for (int k = 0; k < 6; k++) begin
      ohk[k] = nz[k];
      for (int j = k + 1; j < 6; j++) ohk[k] &= ~nz[j];
      below[k] = 1'b0;
      for (int j = 0; j < k - 1; j++) below[k] |= nz[j];
    end
    w = '0; lz = '0; st = 1'b0;
    for (int k = 0; k < 6; k++) begin
      w  |= {8{ohk[k]}} & ((k > 0) ? mp[4*k-4 +: 8] : {mp[3:0], 4'd0});
      lz |= {5{ohk[k]}} & 5'(4 * (5 - k));
      st |= ohk[k] & below[k];
    end
    lz4 = w[7] ? 2'd0 : w[6] ? 2'd1 : w[5] ? 2'd2 : 2'd3;
    unique case (lz4)
      2'd0:    begin m1 = w[6]; m0 = w[5]; g = w[4]; rem = |w[3:0]; end
      2'd1:    begin m1 = w[5]; m0 = w[4]; g = w[3]; rem = |w[2:0]; end
      2'd2:    begin m1 = w[4]; m0 = w[3]; g = w[2]; rem = |w[1:0]; end
      default: begin m1 = w[3]; m0 = w[2]; g = w[1]; rem = w[0];    end
    endcase
    lz = lz + 5'(lz4) - 5'd1;
    return {f[31], 8'd0, m1, m0, g, st | rem, 1'b1, f[17:6], 6'(-lz)};
  endfunction

  // fp32_to_mxfp8_byte_prescaled on fp32_sub_norm words: scaled_exp in [-276, 254] fits 10 b,
  // the subnormal shifter keeps its 3 reachable amounts (sh in {22,23,24})
  function automatic logic [7:0] e5m2_lane(input logic [31:0] f,
                                           input logic signed [7:0] dec_scale);
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

    if (expf == 8'd0) begin
      exp_s     = 10'(signed'(manf[5:0]));
      full_mant = {1'b1, manf[22:19], 19'd0};
    end else begin
      exp_s     = signed'({2'b00, expf});
      full_mant = {1'b1, manf};
    end
    sc_s       = signed'({{2{dec_scale[7]}}, dec_scale});
    scaled_exp = exp_s - 10'sd127 - sc_s;

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
      2'b01: begin
        sub_kept  = {2'b00, full_mant[23:22]};
        sub_guard = full_mant[21];
        sub_stky  = (full_mant[20:0] != 21'd0);
      end
      2'b00: begin
        sub_kept  = {3'b000, full_mant[23]};
        sub_guard = full_mant[22];
        sub_stky  = (full_mant[21:0] != 22'd0);
      end
      default: begin
        sub_kept  = 4'd0;
        sub_guard = full_mant[23];
        sub_stky  = (full_mant[22:0] != 23'd0);
      end
    endcase
    if (sub_guard && (sub_kept[0] || sub_stky)) sub_kept = sub_kept + 4'd1;
    if (sub_kept == 4'd0)     return {sign, 5'd0, 2'd0};
    else if (sub_kept < 4'd4) return {sign, 5'd0, sub_kept[1:0]};
    else                      return {sign, 5'd1, 2'd0};
  endfunction

  // E5M2 x E8M0 -> FP32 (exact: IEEE subnormals, overflow to Inf) or FP16 ([15:0], RNE) from one
  // denormalizing shifter; same results as mxfp8_byte_to_fp32_prescaled and fp32_bits_to_fp16
  function automatic logic [31:0] e5m2_dequant_lane(input logic [7:0] b, input logic [7:0] sc,
                                                    input logic fp16);
    logic              sign;
    logic [4:0]        e5, amt;
    logic [1:0]        m, sig2;
    logic [7:0]        base;
    logic signed [9:0] es, eb;
    logic [22:0]       sh;
    logic [10:0]       r;
    sign = b[7]; e5 = b[6:2]; m = b[1:0];
    base = (e5 == 5'd0) ? (8'd111 + 8'(m[1])) : (8'd112 + 8'(e5));
    sig2 = (e5 == 5'd0) ? {m[1] & m[0], 1'b0} : m;
    es   = signed'({2'b00, base}) + signed'({2'b00, sc}) - 10'(E8m0Bias);
    eb   = fp16 ? es - 10'sd112 : es;
    if (sc == E8m0Nan || (e5 == 5'h1F && m != 2'd0)) return fp16 ? 32'h7E00 : 32'h7FC00000;
    if (e5 == 5'd0 && m == 2'd0) return fp16 ? {16'd0, sign, 15'd0} : {sign, 31'd0};
    if (e5 == 5'h1F || eb >= (fp16 ? 10'sd31 : 10'sd255))
      return fp16 ? {16'd0, sign, 5'h1F, 10'd0} : {sign, 8'hFF, 23'd0};
    if (eb >= 10'sd1)
      return fp16 ? {16'd0, sign, eb[4:0], sig2, 8'd0} : {sign, eb[7:0], sig2, 21'd0};
    amt = (eb < -10'sd23) ? 5'd23 : 5'(-eb);
    sh  = {1'b1, sig2, 20'd0} >> amt;
    if (!fp16) return {sign, 8'd0, sh};
    r = {1'b0, sh[22:13]} + 11'(sh[12] & (sh[13] | (|sh[11:0])));
    return {16'd0, sign, r[10] ? 5'd1 : 5'd0, r[9:0]};
  endfunction

endpackage

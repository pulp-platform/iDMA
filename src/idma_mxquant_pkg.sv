// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// MX quantization numeric core: FP16/FP32 -> MXFP8 (E5M2) with E8M0 block
/// scale. Bit-exact with the viDMA ALCU / Rust golden. Ported from
/// pulp-platform/vidma hw/vidma/vidma_alcu_pkg.sv.
package idma_mxquant_pkg;

  localparam int unsigned MxBlockSize          = 32;
  localparam int unsigned MxFp32BlockBytes     = MxBlockSize * 4; // 128
  localparam int unsigned MxFp16BlockBytes     = MxBlockSize * 2; // 64
  localparam int unsigned MxCompressedBlockBytes = MxBlockSize + 1; // 33

  localparam int E5m2Bias   = 15;
  localparam int E5m2ExpMax = 15;
  localparam int E5m2ExpMin = -14;
  localparam int Fp32Bias   = 127;
  localparam int Fp16Bias   = 15;

  function automatic int decode_signed_scale(input logic [7:0] scale);
    if (scale < 128) return int'(scale);
    else return int'(scale) - 256;
  endfunction

  // Inf/NaN lanes are excluded from the scan and the scale saturates instead of
  // wrapping (two deliberate corrections vs the viDMA ALCU)
  function automatic logic [7:0] compute_block_scale_with_bias(
      input logic [31:0] fp32_bits[MxBlockSize], input int bias);
    logic [7:0] max_exp;
    logic [7:0] elem_exp;
    int         scale;
    max_exp = 8'd0;
    for (int i = 0; i < MxBlockSize; i++) begin
      elem_exp = fp32_bits[i][30:23];
      if (elem_exp != 8'hFF && elem_exp > max_exp) max_exp = elem_exp;
    end
    scale = int'(max_exp) - Fp32Bias - bias;
    if (scale < -128) scale = -128;
    else if (scale > 127) scale = 127;
    return 8'(scale);
  endfunction

  // RNE FP32 -> E5M2 with full subnormal support. The split normal/subnormal
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
    int   out_exp;
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
      return {sign, 5'h1E, 2'd3};  // Inf
    end

    unbiased   = int'(expf) - Fp32Bias;
    scaled_exp = unbiased - decoded_scale;
    full_mant  = {1'b1, manf};

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

  // MXFP8 (E5M2) -> FP32 dequantization with the decoded block scale applied.
  function automatic logic [31:0] mxfp8_byte_to_fp32_prescaled(input logic [7:0] byte_val,
                                                               input int scaled);
    logic        sign;
    logic [ 4:0] exp_e5;
    logic [ 1:0] mant;
    logic [31:0] sign_bit;
    int          fp32_exp;
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

    if (fp32_exp <= 0) return sign_bit;
    else if (fp32_exp >= 255) return sign_bit | {1'b0, 8'hFE, 23'h7FFFFF};
    else return sign_bit | (32'(fp32_exp[7:0]) << 23) | 32'(out_mant);
  endfunction

endpackage

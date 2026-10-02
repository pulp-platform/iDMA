// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// FP-cast core for MX compute: FP16/FP32 <-> MXFP8 (E5M2, E4M3) with E8M0 block scale.
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
  // canonical E5M2 / E4M3 NaN of a poisoned block (OCP MX v1.0 6.3)
  localparam logic [7:0] E5m2Nan    = 8'h7D;
  localparam logic [7:0] E4m3Nan    = 8'h7F;

  function automatic int decode_e8m0_scale(input logic [7:0] scale);
    return int'(scale) - E8m0Bias;
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

  // FP32 subnormal -> exponent 0, mantissa [22:18] {4 bits after the leading one, sticky},
  // [5:0] -lz; lossless for E5M2/E4M3 rounding, the other bits are don't care. The leading one
  // is found per nibble, then inside the 8-bit window at the leading nibble
  function automatic logic [31:0] fp32_sub_norm(input logic [31:0] f);
    logic [23:0] mp;
    logic [5:0]  nz, ohk, below;
    logic [7:0]  w;
    logic [1:0]  lz4;
    logic [4:0]  lz;
    logic [3:0]  m4;
    logic        st, rem;
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
      2'd0:    begin m4 = w[6:3]; rem = |w[2:0]; end
      2'd1:    begin m4 = w[5:2]; rem = |w[1:0]; end
      2'd2:    begin m4 = w[4:1]; rem = w[0];    end
      default: begin m4 = w[3:0]; rem = 1'b0;    end
    endcase
    lz = lz + 5'(lz4) - 5'd1;
    return {f[31], 8'd0, m4, st | rem, f[17:6], 6'(-lz)};
  endfunction

  // quantizer input lane: floor(log2|v|) (MxKeyNone unless finite non-zero), the 4 bits after
  // the leading one and a sticky over the rest
  typedef enum logic [1:0] { MX_ZERO, MX_FIN, MX_INF, MX_NAN } mx_cls_e;
  typedef struct packed {
    logic              sign;
    mx_cls_e           cls;
    logic signed [8:0] key;
    logic [3:0]        sig;
    logic              sticky;
  } mx_lane_t;

  // quantizer element lane: `gap` = binades below the block's element emax, saturated
  typedef struct packed {
    logic       sign;
    mx_cls_e    cls;
    logic [5:0] gap;
    logic [3:0] sig;
    logic       sticky;
  } mx_qlane_t;

  localparam logic signed [8:0] MxKeyNone = -9'sd256;

  function automatic mx_lane_t mx_unpack_fp16(input logic [15:0] h);
    mx_lane_t   l;
    logic [3:0] lz;
    logic [9:0] mm;
    l.sign = h[15]; l.cls = MX_FIN; l.key = MxKeyNone; l.sig = '0; l.sticky = 1'b0;
    lz = 4'd9;
    for (int i = 0; i < 10; i++) if (h[i]) lz = 4'(9 - i);
    mm = h[9:0] << (lz + 4'd1);
    if (h[14:10] == 5'h1F) begin
      l.cls = (h[9:0] != '0) ? MX_NAN : MX_INF;
    end else if (h[14:0] == '0) begin
      l.cls = MX_ZERO;
    end else if (h[14:10] != '0) begin
      l.key = signed'({4'd0, h[14:10]}) - 9'sd15; l.sig = h[9:6]; l.sticky = |h[5:0];
    end else begin
      l.key = -9'sd15 - signed'({5'd0, lz}); l.sig = mm[9:6]; l.sticky = |mm[5:0];
    end
    return l;
  endfunction

  function automatic mx_lane_t mx_unpack_fp32(input logic [31:0] f);
    mx_lane_t    l;
    logic [31:0] n;
    l.sign = f[31]; l.cls = MX_FIN; l.key = MxKeyNone; l.sig = '0; l.sticky = 1'b0;
    n = fp32_sub_norm(f);
    if (f[30:23] == 8'hFF) begin
      l.cls = (f[22:0] != '0) ? MX_NAN : MX_INF;
    end else if (f[30:0] == '0) begin
      l.cls = MX_ZERO;
    end else if (f[30:23] != '0) begin
      l.key = signed'({1'b0, f[30:23]}) - 9'sd127; l.sig = f[22:19]; l.sticky = |f[18:0];
    end else begin
      l.key = 9'(signed'(n[5:0])) - 9'sd127; l.sig = n[22:19]; l.sticky = n[18];
    end
    return l;
  endfunction

  // significand above the max-normal 1.75 of E5M2/E4M3: RCEIL raises the scale of a block whose
  // max lane has it
  function automatic logic mx_sig_big(input logic [3:0] sig, input logic sticky);
    return sig[3] & sig[2] & (|{sig[1:0], sticky});
  endfunction

  // E5M2 element: RNE, element subnormals, saturation to max normal; Inf/NaN lanes only reach
  // here with poisoning disabled
  function automatic logic [7:0] mx_e5m2_quant(input mx_qlane_t l);
    logic [3:0] r;
    logic [4:0] e;
    logic [2:0] k;
    logic       st, up, up_sub;
    st     = l.sig[0] | l.sticky;
    up     = l.sig[1] & (l.sig[2] | st);
    up_sub = l.sig[2] & (l.sig[3] | l.sig[1] | st);
    unique case (l.cls)
      MX_ZERO: return {l.sign, 7'h00};
      MX_INF:  return {l.sign, 7'h7B};
      MX_NAN:  return {l.sign, E5m2Nan[6:0]};
      default: ;
    endcase
    if (l.gap <= 6'd29) begin
      r = {2'b01, l.sig[3:2]} + {3'd0, up};
      e = 5'(6'd30 - l.gap) + {4'd0, r[3]};
      return (e == 5'd31) ? {l.sign, 7'h7B} : {l.sign, e, r[1:0]};
    end
    unique case (l.gap)
      6'd30:   k = {2'b01, l.sig[3]} + {2'd0, up_sub};
      6'd31:   k = {1'b0, l.sig[3], ~l.sig[3]};
      6'd32:   k = {2'd0, |{l.sig, l.sticky}};
      default: k = 3'd0;
    endcase
    return {l.sign, 4'd0, k};
  endfunction

  // E4M3 element: RNE, element subnormals, saturation to max normal 0x7E (no Inf code)
  function automatic logic [7:0] mx_e4m3_quant(input mx_qlane_t l);
    logic [4:0] r, e;
    logic [3:0] k;
    logic       up, up15, up16;
    up   = l.sig[0] & (l.sig[1] | l.sticky);
    up15 = l.sig[1] & (l.sig[2] | l.sig[0] | l.sticky);
    up16 = l.sig[2] & (l.sig[3] | l.sig[1] | l.sig[0] | l.sticky);
    unique case (l.cls)
      MX_ZERO: return {l.sign, 7'h00};
      MX_INF:  return {l.sign, 7'h7E};
      MX_NAN:  return {l.sign, E4m3Nan[6:0]};
      default: ;
    endcase
    if (l.gap <= 6'd14) begin
      r = {2'b01, l.sig[3:1]} + {4'd0, up};
      e = 5'(6'd15 - l.gap) + {4'd0, r[4]};
      return (e[4] || (e[3:0] == 4'hF && r[2:0] == 3'b111)) ? {l.sign, 7'h7E}
                                                             : {l.sign, e[3:0], r[2:0]};
    end
    unique case (l.gap)
      6'd15:   k = {2'b01, l.sig[3:2]} + {3'd0, up15};
      6'd16:   k = {2'b01, l.sig[3]} + {3'd0, up16};
      6'd17:   k = {2'd0, l.sig[3], ~l.sig[3]};
      6'd18:   k = {3'd0, |{l.sig, l.sticky}};
      default: k = 4'd0;
    endcase
    return {l.sign, 3'd0, k};
  endfunction

  // E5M2/E4M3 x E8M0 -> FP32 (exact: IEEE subnormals, overflow to Inf) or FP16 ([15:0], RNE)
  // from one denormalizing shifter; same results as mxfp8_byte_to_fp32_prescaled and
  // fp32_bits_to_fp16 for E5M2
  function automatic logic [31:0] mx_dequant_lane(input logic [7:0] b, input logic [7:0] sc,
                                                  input logic fp16, input logic e4m3);
    logic              sign, is_nan, is_inf, is_zero;
    logic [4:0]        e5, amt;
    logic [3:0]        e4;
    logic [2:0]        m3, sig3;
    logic [7:0]        base;
    logic signed [9:0] es, eb;
    logic [22:0]       sh;
    logic [10:0]       r;
    sign = b[7]; e5 = b[6:2]; e4 = b[6:3]; m3 = b[2:0];
    is_zero = (b[6:0] == 7'd0);
    if (e4m3) begin
      is_nan = (b[6:0] == 7'h7F);
      is_inf = 1'b0;
      if (e4 != 4'd0)  begin base = 8'd120 + 8'(e4); sig3 = m3;              end
      else if (m3[2])  begin base = 8'd120;          sig3 = {m3[1:0], 1'b0}; end
      else if (m3[1])  begin base = 8'd119;          sig3 = {m3[0], 2'b00};  end
      else             begin base = 8'd118;          sig3 = 3'd0;            end
    end else begin
      is_nan = (e5 == 5'h1F) && (b[1:0] != 2'd0);
      is_inf = (e5 == 5'h1F) && (b[1:0] == 2'd0);
      base = (e5 == 5'd0) ? (8'd111 + 8'(b[1])) : (8'd112 + 8'(e5));
      sig3 = (e5 == 5'd0) ? {b[1] & b[0], 2'b00} : {b[1:0], 1'b0};
    end
    es = signed'({2'b00, base}) + signed'({2'b00, sc}) - 10'(E8m0Bias);
    eb = fp16 ? es - 10'sd112 : es;
    if (sc == E8m0Nan || is_nan) return fp16 ? 32'h7E00 : 32'h7FC00000;
    if (is_zero) return fp16 ? {16'd0, sign, 15'd0} : {sign, 31'd0};
    if (is_inf || eb >= (fp16 ? 10'sd31 : 10'sd255))
      return fp16 ? {16'd0, sign, 5'h1F, 10'd0} : {sign, 8'hFF, 23'd0};
    if (eb >= 10'sd1)
      return fp16 ? {16'd0, sign, eb[4:0], sig3, 7'd0} : {sign, eb[7:0], sig3, 20'd0};
    amt = (eb < -10'sd23) ? 5'd23 : 5'(-eb);
    sh  = {1'b1, sig3, 19'd0} >> amt;
    if (!fp16) return {sign, 8'd0, sh};
    r = {1'b0, sh[22:13]} + 11'(sh[12] & (sh[13] | (|sh[11:0])));
    return {16'd0, sign, r[10] ? 5'd1 : 5'd0, r[9:0]};
  endfunction

endpackage

// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Bit-exact OCP MX goldens (E8M0 scale plane + E5M2/E4M3 data plane) and test stimulus.

#pragma once

#include <stdint.h>
#include <stddef.h>

static inline uint32_t fp16_to_fp32_bits(uint16_t h) {
  uint32_t sign = (uint32_t)(h >> 15) & 0x1u;
  uint32_t exp  = (uint32_t)(h >> 10) & 0x1Fu;
  uint32_t mant = (uint32_t)h & 0x3FFu;
  if (exp == 0) {
    if (mant == 0) return sign << 31;
    int e = -1;
    uint32_t m = mant;
    do { m <<= 1; e++; } while ((m & 0x400u) == 0);
    m &= 0x3FFu;
    uint32_t fexp = (uint32_t)(127 - 15 - e);
    return (sign << 31) | (fexp << 23) | (m << 13);
  }
  if (exp == 0x1Fu) {
    if (mant == 0) return (sign << 31) | (0xFFu << 23);
    return (sign << 31) | (0xFFu << 23) | (1u << 22) | (mant << 12);  // qNaN, payload kept
  }
  return (sign << 31) | ((exp + (127 - 15)) << 23) | (mant << 13);
}

#define MX_E8M0_BIAS 127
#define MX_E8M0_NAN  0xFFu
#define MX_E5M2_NAN  0x7Du
#define MX_E4M3_NAN  0x7Fu

// element formats, as idma_pkg::mx_elem_e
#define MX_ELEM_E5M2 0
#define MX_ELEM_E4M3 1

static inline int block_has_special(const uint32_t *block, size_t len) {
  for (size_t i = 0; i < len; ++i)
    if (((block[i] >> 23) & 0xFFu) == 0xFFu) return 1;
  return 0;
}

// Shared exponent over the finite lanes, clamped to [-127, 127], E8M0-encoded; rceil adds one
// when the max magnitude's significand exceeds the element max normal's 1.75
static inline uint8_t block_scale_mx(const uint32_t *block, size_t len, int elem, int rceil) {
  uint32_t max_mag = 0;
  for (size_t i = 0; i < len; ++i) {
    uint32_t mag = block[i] & 0x7FFFFFFFu;
    if ((mag >> 23) != 0xFFu && mag > max_mag) max_mag = mag;
  }
  uint32_t max_exp = max_mag >> 23;
  int32_t scaled = (int32_t)max_exp - 127 - (elem == MX_ELEM_E4M3 ? 8 : 15);
  if (rceil && max_exp != 0u && (max_mag & 0x7FFFFFu) > 0x600000u) scaled++;
  if (scaled < -127) scaled = -127;
  else if (scaled > 127) scaled = 127;
  return (uint8_t)(scaled + MX_E8M0_BIAS);
}

static inline uint8_t block_scale_e5m2(const uint32_t *block, size_t len) {
  return block_scale_mx(block, len, MX_ELEM_E5M2, 0);
}

// RNE with element subnormals; saturates to max normal (0x7B E5M2, 0x7E E4M3), NaN keeps its sign
static inline uint8_t quantize_fp32_mx(uint32_t bits, int8_t scale, int elem) {
  const int e4m3 = elem == MX_ELEM_E4M3;
  const int MB = e4m3 ? 3 : 2, EBIAS = e4m3 ? 7 : 15, EMAX = e4m3 ? 8 : 15, EMIN = 1 - EBIAS;
  const uint32_t SAT = e4m3 ? 0x7Eu : 0x7Bu, NAN_CODE = e4m3 ? MX_E4M3_NAN : MX_E5M2_NAN;
  uint32_t sign = bits >> 31, expf = (bits >> 23) & 0xFFu, manf = bits & 0x7FFFFFu;
  if (expf == 0u && manf == 0u) return (uint8_t)(sign << 7);
  if (expf == 0xFFu && manf != 0u) return (uint8_t)((sign << 7) | NAN_CODE);
  if (expf == 0xFFu) return (uint8_t)((sign << 7) | SAT);
  int unbiased = (int)expf - 127;
  uint32_t full_mant = (1u << 23) | manf;
  if (expf == 0u) {  // subnormal: normalize, no implicit 1
    unbiased  = -126;
    full_mant = manf;
    while (!(full_mant & (1u << 23))) { full_mant <<= 1; unbiased--; }
  }
  int scaled_exp = unbiased - (int)scale;
  if (scaled_exp > EMAX) return (uint8_t)((sign << 7) | SAT);
  if (scaled_exp >= EMIN) {
    uint32_t rounded = (full_mant >> (23 - MB)) & ((1u << (MB + 1)) - 1u);
    uint32_t guard   = (full_mant >> (22 - MB)) & 0x1u;
    uint32_t sticky  = (full_mant & ((1u << (22 - MB)) - 1u)) != 0u;
    if (guard && ((rounded & 0x1u) || sticky)) rounded += 1u;
    int out_exp = scaled_exp + EBIAS + (int)(rounded >> (MB + 1));
    uint32_t mmant = rounded & ((1u << MB) - 1u);
    if (out_exp > EMAX + EBIAS || (e4m3 && out_exp == EMAX + EBIAS && mmant == 0x7u))
      return (uint8_t)((sign << 7) | SAT);
    return (uint8_t)((sign << 7) | ((uint32_t)out_exp << MB) | mmant);
  }
  if (scaled_exp < EMIN - MB - 1) return (uint8_t)(sign << 7);
  uint32_t sh   = (uint32_t)(23 - MB + (EMIN - scaled_exp));
  uint32_t kept = full_mant >> sh;
  uint32_t sg   = (full_mant >> (sh - 1u)) & 0x1u;
  uint32_t ss   = (full_mant & ((1u << (sh - 1u)) - 1u)) != 0u;
  if (sg && ((kept & 0x1u) || ss)) kept += 1u;
  return (uint8_t)((sign << 7) | kept);  // kept == 1 << MB is the smallest normal
}

static inline uint8_t quantize_fp32_e5m2(uint32_t bits, int8_t scale) {
  return quantize_fp32_mx(bits, scale, MX_ELEM_E5M2);
}

// Exact (IEEE subnormals, overflow to Inf); same as idma_float_pkg::mxfp8_byte_to_fp32_prescaled.
static inline uint32_t dequant_e5m2_fp32(uint8_t b, int scaled) {
  uint32_t sign = (b >> 7) & 1u, exp5 = (b >> 2) & 0x1Fu, mant = b & 3u;
  uint32_t sign_bit = sign << 31;
  int fp32_exp;
  uint32_t out_mant;
  if (exp5 == 0u && mant == 0u) return sign_bit;
  if (exp5 == 0x1Fu && mant == 0u) return sign_bit | 0x7F800000u;
  if (exp5 == 0x1Fu) return 0x7FC00000u;
  if (exp5 == 0u) {
    fp32_exp = (-16 + (mant > 1u ? 1 : 0) + scaled) + 127;
    out_mant = ((mant == 3u) ? 1u : 0u) << 22;
  } else {
    fp32_exp = (int)exp5 - 15 + scaled + 127;
    out_mant = mant << 21;
  }
  if (fp32_exp >= 255) return sign_bit | 0x7F800000u;
  if (fp32_exp <= 0) return sign_bit | (((1u << 23) | out_mant) >> (1 - fp32_exp));
  return sign_bit | ((uint32_t)fp32_exp << 23) | out_mant;
}

// Exact (IEEE subnormals, overflow to Inf); E4M3 has no Inf, S.1111.111 is NaN
static inline uint32_t dequant_e4m3_fp32(uint8_t b, int scaled) {
  uint32_t sign_bit = (uint32_t)(b >> 7) << 31, e4 = (b >> 3) & 0xFu, n = b & 7u;
  int q = -9, lead = 3;
  if ((b & 0x7Fu) == 0x7Fu) return 0x7FC00000u;
  if ((b & 0x7Fu) == 0u) return sign_bit;
  if (e4 != 0u) { n |= 8u; q = (int)e4 - 10; }
  while (!(n & (1u << lead))) lead--;
  int fp32_exp = q + lead + scaled + 127;
  uint32_t frac = (n << (23 - lead)) & 0x7FFFFFu;
  if (fp32_exp >= 255) return sign_bit | 0x7F800000u;
  if (fp32_exp <= 0) return sign_bit | (((1u << 23) | frac) >> (1 - fp32_exp));
  return sign_bit | ((uint32_t)fp32_exp << 23) | frac;
}

// Dequantize one element under an E8M0 scale; the NaN scale makes every element NaN
static inline uint32_t dequant_mx_fp32(uint8_t b, uint8_t scale, int elem) {
  if (scale == MX_E8M0_NAN) return 0x7FC00000u;
  return elem == MX_ELEM_E4M3 ? dequant_e4m3_fp32(b, (int)scale - MX_E8M0_BIAS)
                              : dequant_e5m2_fp32(b, (int)scale - MX_E8M0_BIAS);
}

static inline uint32_t dequant_e8m0_fp32(uint8_t b, uint8_t scale) {
  return dequant_mx_fp32(b, scale, MX_ELEM_E5M2);
}

// IEEE FP32 -> FP16 narrowing, RNE; same rounding as idma_float_pkg::fp32_bits_to_fp16
static inline uint16_t fp32_to_fp16_bits(uint32_t f) {
  uint32_t sign = (f >> 31) & 1u, exp32 = (f >> 23) & 0xFFu, man32 = f & 0x7FFFFFu;
  if (exp32 == 0xFFu) return (uint16_t)((sign << 15) | (0x1Fu << 10) | (man32 ? 0x200u : 0u));
  if (exp32 == 0u) return (uint16_t)(sign << 15);
  int unb = (int)exp32 - 127;
  if (unb > 15) return (uint16_t)((sign << 15) | (0x1Fu << 10));
  if (unb >= -14) {
    uint32_t man16 = man32 >> 13, rest = man32 & 0x1FFFu;
    uint32_t rounded = man16 + ((rest > 0x1000u) || (rest == 0x1000u && (man16 & 1u)));
    if (rounded >> 10) {
      if (unb == 15) return (uint16_t)((sign << 15) | (0x1Fu << 10));
      return (uint16_t)((sign << 15) | ((uint32_t)(unb + 16) << 10));
    }
    return (uint16_t)((sign << 15) | ((uint32_t)(unb + 15) << 10) | rounded);
  }
  if (unb < -25) return (uint16_t)(sign << 15);
  uint32_t full = (1u << 24) | (man32 << 1);
  int sh = -14 - unb;
  uint32_t man16 = full >> (sh + 14);
  uint32_t guard = (full >> (sh + 13)) & 1u;
  uint32_t sticky = (full & ((1u << (sh + 13)) - 1u)) != 0u;
  uint32_t rounded = man16 + (guard && ((man16 & 1u) || sticky));
  if (rounded >> 10) return (uint16_t)((sign << 15) | (1u << 10));
  return (uint16_t)((sign << 15) | rounded);
}

// One 32-element FP32 block into its 32 elements and its scale byte
static inline void quantize_block_mx(const uint32_t *blk, uint8_t *data, uint8_t *scale_out,
                                     int elem, int rceil, int poison_dis) {
  uint8_t scale = block_scale_mx(blk, 32u, elem, rceil);
  int poison = !poison_dis && block_has_special(blk, 32u);
  *scale_out = poison ? (uint8_t)MX_E8M0_NAN : scale;
  for (uint32_t lane = 0; lane < 32u; ++lane)
    data[lane] = poison ? (uint8_t)(elem == MX_ELEM_E4M3 ? MX_E4M3_NAN : MX_E5M2_NAN)
                        : quantize_fp32_mx(blk[lane], (int8_t)(scale - MX_E8M0_BIAS), elem);
}

static inline void quantize_block_e5m2(const uint32_t *blk, uint8_t *data, uint8_t *scale_out,
                                       int poison_dis) {
  quantize_block_mx(blk, data, scale_out, MX_ELEM_E5M2, 0, poison_dis);
}

// Quantize num_blocks 64B FP16 blocks into a data plane (32B/block) and a scale plane.
static inline void mx_quant_fp16_cfg(const uint8_t *in, uint8_t *data, uint8_t *scale,
                                     uint32_t num_blocks, int elem, int rceil, int poison_dis) {
  for (uint32_t b = 0; b < num_blocks; ++b) {
    uint32_t blk[32];
    for (uint32_t lane = 0; lane < 32u; ++lane) {
      uint16_t h = (uint16_t)((uint32_t)in[b*64u + lane*2u]
                            | ((uint32_t)in[b*64u + lane*2u + 1u] << 8));
      blk[lane] = fp16_to_fp32_bits(h);
    }
    quantize_block_mx(blk, data + b*32u, scale + b, elem, rceil, poison_dis);
  }
}

// Quantize num_blocks 128B FP32 blocks from in into a data plane and a scale plane.
static inline void mx_quant_fp32_cfg(const uint8_t *in, uint8_t *data, uint8_t *scale,
                                     uint32_t num_blocks, int elem, int rceil, int poison_dis) {
  for (uint32_t b = 0; b < num_blocks; ++b) {
    uint32_t blk[32];
    for (uint32_t lane = 0; lane < 32u; ++lane)
      blk[lane] = (uint32_t)in[b*128u + lane*4u]
                | ((uint32_t)in[b*128u + lane*4u + 1u] << 8)
                | ((uint32_t)in[b*128u + lane*4u + 2u] << 16)
                | ((uint32_t)in[b*128u + lane*4u + 3u] << 24);
    quantize_block_mx(blk, data + b*32u, scale + b, elem, rceil, poison_dis);
  }
}

static inline void mx_quant_fp16_opt(const uint8_t *in, uint8_t *data, uint8_t *scale,
                                     uint32_t num_blocks, int poison_dis) {
  mx_quant_fp16_cfg(in, data, scale, num_blocks, MX_ELEM_E5M2, 0, poison_dis);
}

static inline void mx_quant_fp32_opt(const uint8_t *in, uint8_t *data, uint8_t *scale,
                                     uint32_t num_blocks, int poison_dis) {
  mx_quant_fp32_cfg(in, data, scale, num_blocks, MX_ELEM_E5M2, 0, poison_dis);
}

static inline void mx_quant_fp16(const uint8_t *in, uint8_t *data, uint8_t *scale,
                                 uint32_t num_blocks) {
  mx_quant_fp16_opt(in, data, scale, num_blocks, 0);
}

static inline void mx_quant_fp32(const uint8_t *in, uint8_t *data, uint8_t *scale,
                                 uint32_t num_blocks) {
  mx_quant_fp32_opt(in, data, scale, num_blocks, 0);
}

// Dequantize num_blocks blocks (data plane, scale plane) into 64B FP16 blocks in out.
static inline void mx_dequant_fp16_cfg(const uint8_t *data, const uint8_t *scale, uint8_t *out,
                                       uint32_t num_blocks, int elem) {
  for (uint32_t b = 0; b < num_blocks; ++b) {
    for (uint32_t lane = 0; lane < 32u; ++lane) {
      uint16_t h = fp32_to_fp16_bits(dequant_mx_fp32(data[b*32u + lane], scale[b], elem));
      out[b*64u + lane*2u]      = (uint8_t)(h & 0xFFu);
      out[b*64u + lane*2u + 1u] = (uint8_t)((uint32_t)h >> 8);
    }
  }
}

// Dequantize num_blocks blocks (data plane, scale plane) into 128B FP32 blocks in out.
static inline void mx_dequant_fp32_cfg(const uint8_t *data, const uint8_t *scale, uint8_t *out,
                                       uint32_t num_blocks, int elem) {
  for (uint32_t b = 0; b < num_blocks; ++b) {
    for (uint32_t lane = 0; lane < 32u; ++lane) {
      uint32_t f = dequant_mx_fp32(data[b*32u + lane], scale[b], elem);
      out[b*128u + lane*4u + 0u] = (uint8_t)(f & 0xFFu);
      out[b*128u + lane*4u + 1u] = (uint8_t)((f >> 8) & 0xFFu);
      out[b*128u + lane*4u + 2u] = (uint8_t)((f >> 16) & 0xFFu);
      out[b*128u + lane*4u + 3u] = (uint8_t)((f >> 24) & 0xFFu);
    }
  }
}

static inline void mx_dequant_fp16(const uint8_t *data, const uint8_t *scale, uint8_t *out,
                                   uint32_t num_blocks) {
  mx_dequant_fp16_cfg(data, scale, out, num_blocks, MX_ELEM_E5M2);
}

static inline void mx_dequant_fp32(const uint8_t *data, const uint8_t *scale, uint8_t *out,
                                   uint32_t num_blocks) {
  mx_dequant_fp32_cfg(data, scale, out, num_blocks, MX_ELEM_E5M2);
}

// Deterministic FP16 stimulus for element e of a total-element buffer; last blocks hold corners.
static inline uint16_t mx_stim_fp16(uint32_t e, uint32_t total, uint32_t salt) {
  uint32_t blk = e / 32u, lane = e % 32u, nb = total / 32u;
  static const uint16_t sm[8] = {0x0200u, 0x0100u, 0x0080u, 0x0040u,
                                 0x3C00u, 0xBC00u, 0x0001u, 0x0000u};
  if (nb < 6u && blk + 1u == nb) {
    if (lane == 0u) return 0x7BFFu;  // max normal: pins the scale and rounds up to saturation
    if (lane == 1u) return 0x7C00u;
    if (lane == 2u) return 0xFC00u;
    if (lane == 3u) return 0x7E00u;
    return sm[(lane + salt) & 7u];
  }
  if (nb >= 6u && blk + 6u >= nb && blk + 3u < nb) {
    if (lane == 0u) return 0x7800u;
    return sm[(lane + blk + salt) & 7u];
  }
  if (nb >= 6u && (blk + 3u == nb || blk + 2u == nb)) {
    if (lane == 0u) return (blk + 3u == nb) ? 0x7BFFu : 0xFBFFu;
    return (uint16_t)(0x3C00u + (((lane * 7u) + (blk + 2u == nb ? 1u : 0u) + salt) & 0x3FFu));
  }
  if (nb >= 6u && blk + 1u == nb) {
    if (lane == 0u) return 0x7C00u;
    if (lane == 1u) return 0xFC00u;
    if (lane == 2u) return 0x7E00u;
    return (uint16_t)(0x0200u + ((lane + salt) & 0x1Fu));
  }
  {
    uint32_t j   = (lane + blk * 7u + salt) & 0x1Fu;
    uint32_t sgn = (j & 1u) << 15;
    uint32_t man = ((j * 53u) + blk * 11u + salt * 29u) & 0x3FFu;
    int ne = (int)(12u + (j % 8u)) + (int)((blk + salt) % 9u) - 4;
    if (ne < 1) ne = 1;
    if (ne > 30) ne = 30;
    return (uint16_t)(sgn | ((uint32_t)ne << 10) | man);
  }
}

// Deterministic FP32 stimulus for element e of a total-element buffer; fixed blocks hold corners.
static inline uint32_t mx_stim_fp32(uint32_t e, uint32_t total, uint32_t salt) {
  if (e + 8u >= total) {
    switch (e % 8u) {
      case 0: return 0x00000000u;
      case 1: return 0x80000000u;
      case 2: return 0x00000345u;
      case 3: return 0x7F800000u;
      case 4: return 0xFF800000u;
      case 5: return 0x7FC12345u;
      case 6: return 0x7F7FFFFFu;
      default: return 0x00800000u;
    }
  }
  if (e < 32u)
    return ((e & 1u) << 31) | (((1u + ((e + salt) % 13u)) & 0xFFu) << 23)
         | (((e * 977u) + salt) & 0x7FFFFFu);
  if (e < 64u) {
    if (e == 32u) return 0x7F800000u;
    if (e == 33u) return 0xFFC00001u;
    return ((e & 1u) << 31) | (((100u + ((e + salt) % 30u)) & 0xFFu) << 23)
         | (((e * 331u) + salt) & 0x7FFFFFu);
  }
  return ((e & 1u) << 31) | (((64u + ((e + salt) % 128u)) & 0xFFu) << 23)
       | (((e * 2654435761u) + salt) & 0x7FFFFFu);
}

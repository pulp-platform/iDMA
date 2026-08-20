// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Bit-exact C goldens and deterministic stimulus for the MX compute ops, shared
// by the DPI-C testbench glue and by integrators' on-target tests: FP32/FP16 ->
// MXFP8 (E5M2) quantization and MXFP8 -> FP32/FP16 dequantization; blocks are
// [1B E8M0 scale][32B E5M2]. Pure functions over bit patterns and caller-owned buffers.

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

static inline uint8_t block_scale_e5m2(const uint32_t *block, size_t len) {
  uint32_t max_exp = 0;
  for (size_t i = 0; i < len; ++i) {
    uint32_t exp = (block[i] >> 23) & 0xFFu;
    if (exp != 0xFFu && exp > max_exp) max_exp = exp;
  }
  int32_t scaled = (int32_t)max_exp - 127 - 15;
  if (scaled < -128) scaled = -128;
  else if (scaled > 127) scaled = 127;
  return (uint8_t)(scaled & 0xFF);
}

static inline uint8_t quantize_fp32_e5m2(uint32_t bits, int8_t scale) {
  uint32_t sign = bits >> 31, expf = (bits >> 23) & 0xFFu, manf = bits & 0x7FFFFFu;
  if (expf == 0u && manf == 0u) return (uint8_t)(sign << 7);
  if (expf == 0xFFu && manf != 0u) return (uint8_t)((sign << 7) | (0x1Fu << 2) | 0x1u);
  if (expf == 0xFFu) return (uint8_t)((sign << 7) | (0x1Eu << 2) | 0x3u);
  int unbiased   = (int)expf - 127;
  int scaled_exp = unbiased - (int)scale;
  uint32_t full_mant = (1u << 23) | manf;
  const int EMAX = 15, EMIN = -14, EBIAS = 15;
  if (scaled_exp > EMAX) return (uint8_t)((sign << 7) | (0x1Eu << 2) | 0x3u);
  if (scaled_exp >= EMIN) {
    uint32_t rounded = (full_mant >> 21) & 0x7u;
    uint32_t guard   = (full_mant >> 20) & 0x1u;
    uint32_t sticky  = (full_mant & 0xFFFFFu) != 0u;
    if (guard && ((rounded & 0x1u) || sticky)) rounded += 1u;
    uint32_t carry = (rounded >> 3) & 0x1u;
    int out_exp = scaled_exp + EBIAS + (int)carry;
    uint32_t mmant = rounded & 0x3u, mexp;
    if (out_exp > 30) { mexp = 30u; mmant = 0x3u; }
    else mexp = (uint32_t)out_exp & 0x1Fu;
    return (uint8_t)((sign << 7) | ((mexp & 0x1Fu) << 2) | (mmant & 0x3u));
  } else {
    if (scaled_exp < (EMIN - 3)) return (uint8_t)(sign << 7);
    uint32_t sh   = (uint32_t)(21 + (EMIN - scaled_exp));
    uint32_t kept = (full_mant >> sh) & 0xFu;
    uint32_t sg   = (full_mant >> (sh - 1u)) & 0x1u;
    uint32_t ss   = (full_mant & ((1u << (sh - 1u)) - 1u)) != 0u;
    if (sg && ((kept & 0x1u) || ss)) kept += 1u;
    if (kept == 0u)     return (uint8_t)(sign << 7);
    else if (kept < 4u) return (uint8_t)((sign << 7) | (kept & 0x3u));
    else                return (uint8_t)((sign << 7) | (0x1u << 2));
  }
}

// Same rounding as idma_float_pkg::mxfp8_byte_to_fp32_prescaled.
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
  if (fp32_exp <= 0) return sign_bit;
  if (fp32_exp >= 255) return sign_bit | (0xFEu << 23) | 0x7FFFFFu;
  return sign_bit | ((uint32_t)fp32_exp << 23) | out_mant;
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

// Quantize num_blocks 64B FP16 blocks from in into 33B MX blocks in out.
static inline void mx_quant_fp16(const uint8_t *in, uint8_t *out, uint32_t num_blocks) {
  for (uint32_t b = 0; b < num_blocks; ++b) {
    uint32_t blk[32];
    uint8_t scale;
    for (uint32_t lane = 0; lane < 32u; ++lane) {
      uint16_t h = (uint16_t)((uint32_t)in[b*64u + lane*2u]
                            | ((uint32_t)in[b*64u + lane*2u + 1u] << 8));
      blk[lane] = fp16_to_fp32_bits(h);
    }
    scale = block_scale_e5m2(blk, 32u);
    out[b*33u] = scale;
    for (uint32_t lane = 0; lane < 32u; ++lane)
      out[b*33u + 1u + lane] = quantize_fp32_e5m2(blk[lane], (int8_t)scale);
  }
}

// Quantize num_blocks 128B FP32 blocks from in into 33B MX blocks in out.
static inline void mx_quant_fp32(const uint8_t *in, uint8_t *out, uint32_t num_blocks) {
  for (uint32_t b = 0; b < num_blocks; ++b) {
    uint32_t blk[32];
    uint8_t scale;
    for (uint32_t lane = 0; lane < 32u; ++lane)
      blk[lane] = (uint32_t)in[b*128u + lane*4u]
                | ((uint32_t)in[b*128u + lane*4u + 1u] << 8)
                | ((uint32_t)in[b*128u + lane*4u + 2u] << 16)
                | ((uint32_t)in[b*128u + lane*4u + 3u] << 24);
    scale = block_scale_e5m2(blk, 32u);
    out[b*33u] = scale;
    for (uint32_t lane = 0; lane < 32u; ++lane)
      out[b*33u + 1u + lane] = quantize_fp32_e5m2(blk[lane], (int8_t)scale);
  }
}

// Dequantize num_blocks 33B MX blocks from in into 64B FP16 blocks in out.
static inline void mx_dequant_fp16(const uint8_t *in, uint8_t *out, uint32_t num_blocks) {
  for (uint32_t b = 0; b < num_blocks; ++b) {
    int dec = (int)(int8_t)in[b*33u];
    for (uint32_t lane = 0; lane < 32u; ++lane) {
      uint16_t h = fp32_to_fp16_bits(dequant_e5m2_fp32(in[b*33u + 1u + lane], dec));
      out[b*64u + lane*2u]      = (uint8_t)(h & 0xFFu);
      out[b*64u + lane*2u + 1u] = (uint8_t)((uint32_t)h >> 8);
    }
  }
}

// Dequantize num_blocks 33B MX blocks from in into 128B FP32 blocks in out.
static inline void mx_dequant_fp32(const uint8_t *in, uint8_t *out, uint32_t num_blocks) {
  for (uint32_t b = 0; b < num_blocks; ++b) {
    int dec = (int)(int8_t)in[b*33u];
    for (uint32_t lane = 0; lane < 32u; ++lane) {
      uint32_t f = dequant_e5m2_fp32(in[b*33u + 1u + lane], dec);
      out[b*128u + lane*4u + 0u] = (uint8_t)(f & 0xFFu);
      out[b*128u + lane*4u + 1u] = (uint8_t)((f >> 8) & 0xFFu);
      out[b*128u + lane*4u + 2u] = (uint8_t)((f >> 16) & 0xFFu);
      out[b*128u + lane*4u + 3u] = (uint8_t)((f >> 24) & 0xFFu);
    }
  }
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

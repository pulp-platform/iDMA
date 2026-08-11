// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// DPI-C golden for idma_otf_mxquant: FP16 -> MXFP8 (E5M2), 32-element blocks
// packed as [1B E8M0 scale][32B E5M2]. Bit-exact with idma_mxquant_pkg / the
// viDMA ALCU. Ported from sw/cheshire/tests/l2_dma_mxquant.c.

#include <stdint.h>
#include <stddef.h>

#define GM_MAX_BYTES (1 << 24)

static uint8_t gm_in[GM_MAX_BYTES];   // FP16 input bytes (little-endian)
static uint8_t gm_out[GM_MAX_BYTES];  // 33B-block MXFP8 output

void gm_load(int idx, int val) {
  if (idx >= 0 && idx < GM_MAX_BYTES) gm_in[idx] = (uint8_t)val;
}
int gm_get(int idx) {
  if (idx >= 0 && idx < GM_MAX_BYTES) return (int)gm_out[idx];
  return -1;
}

static uint32_t fp16_to_fp32_bits(uint16_t h) {
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

static uint8_t block_scale_e5m2(const uint32_t *block, size_t len) {
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

static uint8_t quantize_fp32_e5m2(uint32_t bits, int8_t scale) {
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

// Bit-exact C port of idma_mxquant_pkg::mxfp8_byte_to_fp32_prescaled.
static uint32_t dequant_e5m2_fp32(uint8_t b, int scaled) {
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

// Dequantize num_blocks 33B MX blocks from gm_in into 128B FP32 blocks in gm_out.
// IEEE FP32 -> FP16 narrowing: RNE, overflow saturates to +-Inf (mirrors the pkg fn)
static uint16_t fp32_to_fp16_bits(uint32_t f) {
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

void gm_mxdequant_fp16(int num_blocks) {
  for (int b = 0; b < num_blocks; ++b) {
    int dec = (int)(int8_t)gm_in[b*33];
    for (int e = 0; e < 32; ++e) {
      uint16_t h = fp32_to_fp16_bits(dequant_e5m2_fp32(gm_in[b*33 + 1 + e], dec));
      gm_out[b*64 + e*2]     = (uint8_t)(h & 0xFFu);
      gm_out[b*64 + e*2 + 1] = (uint8_t)(h >> 8);
    }
  }
}

void gm_mxdequant(int num_blocks) {
  for (int b = 0; b < num_blocks; ++b) {
    int dec = (int)(int8_t)gm_in[b*33];
    for (int e = 0; e < 32; ++e) {
      uint32_t f = dequant_e5m2_fp32(gm_in[b*33 + 1 + e], dec);
      gm_out[b*128 + e*4 + 0] = (uint8_t)(f & 0xFFu);
      gm_out[b*128 + e*4 + 1] = (uint8_t)((f >> 8) & 0xFFu);
      gm_out[b*128 + e*4 + 2] = (uint8_t)((f >> 16) & 0xFFu);
      gm_out[b*128 + e*4 + 3] = (uint8_t)((f >> 24) & 0xFFu);
    }
  }
}

// Quantize num_blocks 32-element FP16 blocks from gm_in into 33B MX blocks in gm_out.
void gm_mxquant(int num_blocks) {
  for (int b = 0; b < num_blocks; ++b) {
    uint32_t blk[32];
    for (int lane = 0; lane < 32; ++lane) {
      uint16_t h = (uint16_t)(gm_in[b*64 + lane*2] | (gm_in[b*64 + lane*2 + 1] << 8));
      blk[lane] = fp16_to_fp32_bits(h);
    }
    uint8_t scale = block_scale_e5m2(blk, 32);
    gm_out[b*33] = scale;
    for (int lane = 0; lane < 32; ++lane)
      gm_out[b*33 + 1 + lane] = quantize_fp32_e5m2(blk[lane], (int8_t)scale);
  }
}

// Quantize num_blocks 32-element FP32 blocks from gm_in into 33B MX blocks in gm_out.
void gm_mxquant_fp32(int num_blocks) {
  for (int b = 0; b < num_blocks; ++b) {
    uint32_t blk[32];
    for (int lane = 0; lane < 32; ++lane)
      blk[lane] = (uint32_t)gm_in[b*128 + lane*4]
                | ((uint32_t)gm_in[b*128 + lane*4 + 1] << 8)
                | ((uint32_t)gm_in[b*128 + lane*4 + 2] << 16)
                | ((uint32_t)gm_in[b*128 + lane*4 + 3] << 24);
    uint8_t scale = block_scale_e5m2(blk, 32);
    gm_out[b*33] = scale;
    for (int lane = 0; lane < 32; ++lane)
      gm_out[b*33 + 1 + lane] = quantize_fp32_e5m2(blk[lane], (int8_t)scale);
  }
}

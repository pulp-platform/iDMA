// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// DPI-C golden for the element casts, from the IEEE definitions on the host FPU: RNE and
// saturation for the integer casts (NaN -> 0), RNE for BF16, exact widening (NaN quieted).

#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#define CAST_GM_MAX_BYTES (1 << 20)

static uint8_t cast_gm_in[CAST_GM_MAX_BYTES];
static uint8_t cast_gm_out[CAST_GM_MAX_BYTES];

void cast_gm_load(int idx, int val) {
  if (idx >= 0 && idx < CAST_GM_MAX_BYTES) cast_gm_in[idx] = (uint8_t)val;
}

int cast_gm_get(int idx) {
  if (idx >= 0 && idx < CAST_GM_MAX_BYTES) return (int)cast_gm_out[idx];
  return -1;
}

static uint32_t rd32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static void wr32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

static int64_t f32_to_int_sat(uint32_t bits, int int_bits) {
  float f;
  double r;
  int64_t lo = -((int64_t)1 << (int_bits - 1)), hi = ((int64_t)1 << (int_bits - 1)) - 1;
  memcpy(&f, &bits, 4);
  if (isnan(f)) return 0;
  if (isinf(f)) return signbit(f) ? lo : hi;
  fesetround(FE_TONEAREST);
  r = nearbyint((double)f);
  if (r < (double)lo) return lo;
  if (r > (double)hi) return hi;
  return (int64_t)r;
}

static uint16_t f32_to_bf16(uint32_t bits) {
  if (((bits >> 23) & 0xFFu) == 0xFFu && (bits & 0x7FFFFFu) != 0)
    return (uint16_t)(((bits >> 16) & 0x8000u) | 0x7FC0u);
  return (uint16_t)((bits + 0x7FFFu + ((bits >> 16) & 1u)) >> 16);
}

static uint32_t bf16_to_f32(uint16_t h) {
  uint32_t bits = (uint32_t)h << 16;
  if (((h >> 7) & 0xFFu) == 0xFFu && (h & 0x7Fu) != 0) bits |= 0x00400000u;
  return bits;
}

static uint32_t fp16_to_f32(uint16_t h) {
  uint32_t sign = (uint32_t)(h >> 15) & 0x1u;
  uint32_t exp  = (uint32_t)(h >> 10) & 0x1Fu;
  uint32_t mant = (uint32_t)h & 0x3FFu;
  if (exp == 0) {
    if (mant == 0) return sign << 31;
    int e = -1;
    uint32_t m = mant;
    do { m <<= 1; e++; } while ((m & 0x400u) == 0);
    m &= 0x3FFu;
    return (sign << 31) | ((uint32_t)(127 - 15 - e) << 23) | (m << 13);
  }
  if (exp == 0x1Fu) {
    if (mant == 0) return (sign << 31) | (0xFFu << 23);
    return (sign << 31) | (0xFFu << 23) | (1u << 22) | (mant << 12);
  }
  return (sign << 31) | ((exp + (127 - 15)) << 23) | (mant << 13);
}

// op follows compute_op (7 fp32->i8 .. 13 fp16->fp32); returns the output byte count
int cast_gm_run(int op, int in_bytes) {
  int in_sz = (op <= 9) ? 4 : 2, out = 0;
  if (in_bytes > CAST_GM_MAX_BYTES) in_bytes = CAST_GM_MAX_BYTES;
  for (int i = 0; i + in_sz <= in_bytes; i += in_sz) {
    uint32_t x = (in_sz == 4) ? rd32(&cast_gm_in[i]) : (uint32_t)rd16(&cast_gm_in[i]);
    switch (op) {
      case 7:  cast_gm_out[out] = (uint8_t)f32_to_int_sat(x, 8); out += 1; break;
      case 8:  wr16(&cast_gm_out[out], (uint16_t)f32_to_int_sat(x, 16)); out += 2; break;
      case 9:  wr16(&cast_gm_out[out], f32_to_bf16(x)); out += 2; break;
      case 10: cast_gm_out[out] = (uint8_t)f32_to_int_sat(bf16_to_f32((uint16_t)x), 8); out += 1;
               break;
      case 11: wr16(&cast_gm_out[out], (uint16_t)f32_to_int_sat(bf16_to_f32((uint16_t)x), 16));
               out += 2; break;
      case 12: wr32(&cast_gm_out[out], bf16_to_f32((uint16_t)x)); out += 4; break;
      case 13: wr32(&cast_gm_out[out], fp16_to_f32((uint16_t)x)); out += 4; break;
      default: break;
    }
  }
  return out;
}

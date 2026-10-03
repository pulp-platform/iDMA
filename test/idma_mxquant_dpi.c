// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// DPI-C shim over idma_mx_golden.h: index-addressable data and scale plane buffers.

#include <stdint.h>
#include <stddef.h>

#include "idma_mx_golden.h"

#define GM_MAX_BYTES (1 << 24)
#define GM_MAX_BLOCKS (GM_MAX_BYTES / 32)

static uint8_t gm_in[GM_MAX_BYTES];    // stimulus bytes or dequant data plane (little-endian)
static uint8_t gm_out[GM_MAX_BYTES];   // golden quant data plane or dequant result bytes
static uint8_t gm_sin[GM_MAX_BLOCKS];  // dequant scale plane
static uint8_t gm_sout[GM_MAX_BLOCKS]; // golden quant scale plane

void gm_load(int idx, int val) {
  if (idx >= 0 && idx < GM_MAX_BYTES) gm_in[idx] = (uint8_t)val;
}
void gm_load_scale(int idx, int val) {
  if (idx >= 0 && idx < GM_MAX_BLOCKS) gm_sin[idx] = (uint8_t)val;
}
int gm_get(int idx) {
  if (idx >= 0 && idx < GM_MAX_BYTES) return (int)gm_out[idx];
  return -1;
}
int gm_get_scale(int idx) {
  if (idx >= 0 && idx < GM_MAX_BLOCKS) return (int)gm_sout[idx];
  return -1;
}

int gm_stim_fp16(int e, int total, int salt) {
  return (int)mx_stim_fp16((uint32_t)e, (uint32_t)total, (uint32_t)salt);
}
int gm_stim_fp32(int e, int total, int salt) {
  return (int)mx_stim_fp32((uint32_t)e, (uint32_t)total, (uint32_t)salt);
}

void gm_mxquant(int n)        { mx_quant_fp16(gm_in, gm_out, gm_sout, (uint32_t)n); }
void gm_mxquant_fp32(int n)   { mx_quant_fp32(gm_in, gm_out, gm_sout, (uint32_t)n); }
void gm_mxdequant_fp16(int n) { mx_dequant_fp16(gm_in, gm_sin, gm_out, (uint32_t)n); }
void gm_mxdequant(int n)      { mx_dequant_fp32(gm_in, gm_sin, gm_out, (uint32_t)n); }
void gm_mxquant_cfg(int n, int fp16, int elem, int rceil, int poison_dis) {
  if (fp16) mx_quant_fp16_cfg(gm_in, gm_out, gm_sout, (uint32_t)n, elem, rceil, poison_dis);
  else      mx_quant_fp32_cfg(gm_in, gm_out, gm_sout, (uint32_t)n, elem, rceil, poison_dis);
}
void gm_mxdequant_cfg(int n, int fp16, int elem) {
  if (fp16) mx_dequant_fp16_cfg(gm_in, gm_sin, gm_out, (uint32_t)n, elem);
  else      mx_dequant_fp32_cfg(gm_in, gm_sin, gm_out, (uint32_t)n, elem);
}

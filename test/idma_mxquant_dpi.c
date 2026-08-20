// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Index-addressable byte buffers and the DPI-C entry points the MX testbenches
// call; all numerics live in the shared golden header idma_mx_golden.h.

#include <stdint.h>
#include <stddef.h>

#include "idma_mx_golden.h"

#define GM_MAX_BYTES (1 << 24)

static uint8_t gm_in[GM_MAX_BYTES];   // stimulus bytes (little-endian)
static uint8_t gm_out[GM_MAX_BYTES];  // golden result bytes

void gm_load(int idx, int val) {
  if (idx >= 0 && idx < GM_MAX_BYTES) gm_in[idx] = (uint8_t)val;
}
int gm_get(int idx) {
  if (idx >= 0 && idx < GM_MAX_BYTES) return (int)gm_out[idx];
  return -1;
}

int gm_stim_fp16(int e, int total, int salt) {
  return (int)mx_stim_fp16((uint32_t)e, (uint32_t)total, (uint32_t)salt);
}
int gm_stim_fp32(int e, int total, int salt) {
  return (int)mx_stim_fp32((uint32_t)e, (uint32_t)total, (uint32_t)salt);
}

void gm_mxquant(int num_blocks)        { mx_quant_fp16(gm_in, gm_out, (uint32_t)num_blocks); }
void gm_mxquant_fp32(int num_blocks)   { mx_quant_fp32(gm_in, gm_out, (uint32_t)num_blocks); }
void gm_mxdequant_fp16(int num_blocks) { mx_dequant_fp16(gm_in, gm_out, (uint32_t)num_blocks); }
void gm_mxdequant(int num_blocks)      { mx_dequant_fp32(gm_in, gm_out, (uint32_t)num_blocks); }

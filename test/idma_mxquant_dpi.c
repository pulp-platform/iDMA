// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// DPI-C goldens for the MX compute ops: FP32/FP16 -> MXFP8 (E5M2) quantization
// and MXFP8 -> FP32/FP16 dequantization; blocks are [1B E8M0 scale][32B E5M2].

#include <stdint.h>
#include <stddef.h>

#include "idma_mx_golden.h"

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

// Dequantize num_blocks 33B MX blocks from gm_in into 128B FP32 blocks in gm_out.
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

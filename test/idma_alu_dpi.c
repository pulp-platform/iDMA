// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// DPI-C golden for the byte-wise SIMD ALU: y[i] = f(a[i], b[i], imm) modulo 256. Written
// from the function definitions in idma_reg.rdl (alu_func), not from the RTL.

#include <stdint.h>

#define ALU_GM_MAX_BYTES (1 << 20)

static uint8_t alu_gm_in[ALU_GM_MAX_BYTES];
static uint8_t alu_gm_in_b[ALU_GM_MAX_BYTES];
static uint8_t alu_gm_out[ALU_GM_MAX_BYTES];

void alu_gm_load(int idx, int val) {
  if (idx >= 0 && idx < ALU_GM_MAX_BYTES) alu_gm_in[idx] = (uint8_t)val;
}

void alu_gm_load_b(int idx, int val) {
  if (idx >= 0 && idx < ALU_GM_MAX_BYTES) alu_gm_in_b[idx] = (uint8_t)val;
}

int alu_gm_get(int idx) {
  if (idx >= 0 && idx < ALU_GM_MAX_BYTES) return (int)alu_gm_out[idx];
  return -1;
}

// func follows alu_func: 0-6 not/addi/subi/muli/andi/ori/xori, 8-14 add/sub/mul/and/or/xor/axpy
void alu_gm_run(int func, int imm, int len) {
  uint8_t k = (uint8_t)imm;
  if (len > ALU_GM_MAX_BYTES) len = ALU_GM_MAX_BYTES;
  for (int i = 0; i < len; ++i) {
    uint8_t x = alu_gm_in[i], b = alu_gm_in_b[i], y;
    switch (func) {
      case 0: y = (uint8_t)~x; break;
      case 1: y = (uint8_t)(x + k); break;
      case 2: y = (uint8_t)(x - k); break;
      case 3: y = (uint8_t)(x * k); break;
      case 4: y = (uint8_t)(x & k); break;
      case 5: y = (uint8_t)(x | k); break;
      case 6: y = (uint8_t)(x ^ k); break;
      case 8: y = (uint8_t)(x + b); break;
      case 9: y = (uint8_t)(x - b); break;
      case 10: y = (uint8_t)(x * b); break;
      case 11: y = (uint8_t)(x & b); break;
      case 12: y = (uint8_t)(x | b); break;
      case 13: y = (uint8_t)(x ^ b); break;
      case 14: y = (uint8_t)(k * x + b); break;
      default: y = x; break;
    }
    alu_gm_out[i] = y;
  }
}

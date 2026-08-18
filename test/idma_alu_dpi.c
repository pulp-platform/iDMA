// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// DPI-C golden for the byte-wise SIMD ALU: y[i] = f(x[i], imm) modulo 256. Written
// from the function definitions in idma_reg.rdl (alu_func), not from the RTL.

#include <stdint.h>

#define ALU_GM_MAX_BYTES (1 << 20)

static uint8_t alu_gm_in[ALU_GM_MAX_BYTES];
static uint8_t alu_gm_out[ALU_GM_MAX_BYTES];

void alu_gm_load(int idx, int val) {
  if (idx >= 0 && idx < ALU_GM_MAX_BYTES) alu_gm_in[idx] = (uint8_t)val;
}

int alu_gm_get(int idx) {
  if (idx >= 0 && idx < ALU_GM_MAX_BYTES) return (int)alu_gm_out[idx];
  return -1;
}

// func encoding follows the alu_func enum: 0 not, 1 addi, 2 subi, 3 muli, 4 andi, 5 ori, 6 xori
void alu_gm_run(int func, int imm, int len) {
  uint8_t k = (uint8_t)imm;
  if (len > ALU_GM_MAX_BYTES) len = ALU_GM_MAX_BYTES;
  for (int i = 0; i < len; ++i) {
    uint8_t x = alu_gm_in[i], y;
    switch (func) {
      case 0: y = (uint8_t)~x; break;
      case 1: y = (uint8_t)(x + k); break;
      case 2: y = (uint8_t)(x - k); break;
      case 3: y = (uint8_t)(x * k); break;
      case 4: y = (uint8_t)(x & k); break;
      case 5: y = (uint8_t)(x | k); break;
      case 6: y = (uint8_t)(x ^ k); break;
      default: y = x; break;
    }
    alu_gm_out[i] = y;
  }
}

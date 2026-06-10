// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// DPI-C golden model for idma_otf_transpose: an element-granular matrix
// transpose. Element size E in {1,2,4} bytes (int8/fp16/fp32); each E-byte
// element is kept intact while the M x N element grid is transposed to N x M.
// Accessor-based (no open-array marshalling): the testbench loads the row-major
// input byte by byte, calls gm_transpose(m,n,e), then reads back the transposed
// output bytes. Reference: out_elem[c][r] = in_elem[r][c].

#include <stdint.h>

#define GM_MAX_BYTES (1 << 24)  // 16 MiB

static uint8_t gm_in[GM_MAX_BYTES];
static uint8_t gm_out[GM_MAX_BYTES];

// Load one input byte at flat byte index.
void gm_load(int idx, int val) {
  if (idx >= 0 && idx < GM_MAX_BYTES) gm_in[idx] = (uint8_t)val;
}

// Transpose an m x n matrix of e-byte elements (row-major) into n x m.
void gm_transpose(int m, int n, int e) {
  for (int r = 0; r < m; r++)
    for (int c = 0; c < n; c++)
      for (int b = 0; b < e; b++)
        gm_out[((long)c * m + r) * e + b] = gm_in[((long)r * n + c) * e + b];
}

// Read one transposed output byte at flat byte index.
int gm_get(int idx) {
  if (idx >= 0 && idx < GM_MAX_BYTES) return (int)gm_out[idx];
  return -1;
}

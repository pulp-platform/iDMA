// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Thomas Benz <tbenz@ethz.ch>

`include "axi/typedef.svh"

// for now this is an extended copy of the axi_pkg
// eventually the DMA specific parts should be moved in axi_pkg aswell
package axi_dma_pkg;

  typedef struct packed {
      logic [63:0] aw_stall_cnt, ar_stall_cnt, r_stall_cnt, w_stall_cnt,
                   buf_w_stall_cnt, buf_r_stall_cnt;
      logic [63:0] aw_valid_cnt, aw_ready_cnt, aw_done_cnt, aw_bw;
      logic [63:0] ar_valid_cnt, ar_ready_cnt, ar_done_cnt, ar_bw;
      logic [63:0]  r_valid_cnt,  r_ready_cnt,  r_done_cnt,  r_bw;
      logic [63:0]  w_valid_cnt,  w_ready_cnt,  w_done_cnt,  w_bw;
      logic [63:0]  b_valid_cnt,  b_ready_cnt,  b_done_cnt;
      logic [63:0] next_id,       completed_id;
      logic [63:0] dma_busy_cnt;
  } dma_perf_t;

endpackage

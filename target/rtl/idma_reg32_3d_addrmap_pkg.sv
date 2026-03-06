
// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

package idma_reg32_3d_addrmap_pkg;

localparam longint unsigned IDMA_REG_BASE_ADDR = 64'h0;
localparam longint unsigned IDMA_REG_SIZE = 64'hF8;

function automatic longint unsigned IDMA_REG_DIM_BASE_ADDR(input int unsigned dim_idx);
    return 64'hE0 + (dim_idx * 64'hC);
endfunction
localparam longint unsigned IDMA_REG_DIM_NUM = 64'h2;
localparam longint unsigned IDMA_REG_DIM_SIZE = 64'hC;
localparam longint unsigned IDMA_REG_DIM_STRIDE = 64'hC;
localparam longint unsigned IDMA_REG_DIM_TOTAL_SIZE = 64'h18;


localparam longint unsigned IDMA_REG_CONF_BASE_ADDR = 64'h0;
function automatic longint unsigned IDMA_REG_STATUS_BASE_ADDR(input int unsigned status_idx);
    return 64'h4 + (status_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_STATUS_NUM = 64'h10;
function automatic longint unsigned IDMA_REG_NEXT_ID_BASE_ADDR(input int unsigned next_id_idx);
    return 64'h44 + (next_id_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_NEXT_ID_NUM = 64'h10;
function automatic longint unsigned IDMA_REG_DONE_ID_BASE_ADDR(input int unsigned done_id_idx);
    return 64'h84 + (done_id_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_DONE_ID_NUM = 64'h10;
function automatic longint unsigned IDMA_REG_DST_ADDR_BASE_ADDR(input int unsigned dst_addr_idx);
    return 64'hD0 + (dst_addr_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_DST_ADDR_NUM = 64'h1;
function automatic longint unsigned IDMA_REG_SRC_ADDR_BASE_ADDR(input int unsigned src_addr_idx);
    return 64'hD4 + (src_addr_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_SRC_ADDR_NUM = 64'h1;
function automatic longint unsigned IDMA_REG_LENGTH_BASE_ADDR(input int unsigned length_idx);
    return 64'hD8 + (length_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_LENGTH_NUM = 64'h1;
function automatic longint unsigned IDMA_REG_DIM_DST_STRIDE_BASE_ADDR(input int unsigned dim_idx, input int unsigned dst_stride_idx);
    return 64'hE0 + (dim_idx * 64'hC) + (dst_stride_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_DIM_DST_STRIDE_NUM = 64'h1;
function automatic longint unsigned IDMA_REG_DIM_SRC_STRIDE_BASE_ADDR(input int unsigned dim_idx, input int unsigned src_stride_idx);
    return 64'hE4 + (dim_idx * 64'hC) + (src_stride_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_DIM_SRC_STRIDE_NUM = 64'h1;
function automatic longint unsigned IDMA_REG_DIM_REPS_BASE_ADDR(input int unsigned dim_idx, input int unsigned reps_idx);
    return 64'hE8 + (dim_idx * 64'hC) + (reps_idx * 64'h4);
endfunction
localparam longint unsigned IDMA_REG_DIM_REPS_NUM = 64'h1;



endpackage;

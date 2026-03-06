// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

package idma_desc64_addrmap_pkg;


localparam longint unsigned IDMA_DESC64_REG_BASE_ADDR = 64'h00000000;
localparam longint unsigned IDMA_DESC64_REG_SIZE      = 64'h00000010;

localparam longint unsigned IDMA_DESC64_REG_DESC_ADDR_REG_ADDR   = 64'h00000000;
localparam longint unsigned IDMA_DESC64_REG_DESC_ADDR_REG_OFFSET = 64'h00000000;

localparam longint unsigned IDMA_DESC64_REG_STATUS_REG_ADDR   = 64'h00000008;
localparam longint unsigned IDMA_DESC64_REG_STATUS_REG_OFFSET = 64'h00000008;


endpackage;

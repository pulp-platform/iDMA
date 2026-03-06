// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

package idma_reg64_1d_addrmap_pkg;


localparam longint unsigned IDMA_REG_BASE_ADDR = 64'h00000000;
localparam longint unsigned IDMA_REG_SIZE      = 64'h00000118;

localparam longint unsigned IDMA_REG_CONF_REG_ADDR   = 64'h00000000;
localparam longint unsigned IDMA_REG_CONF_REG_OFFSET = 64'h00000000;

localparam longint unsigned IDMA_REG_STATUS_0_REG_ADDR   = 64'h00000004;
localparam longint unsigned IDMA_REG_STATUS_0_REG_OFFSET = 64'h00000004;
localparam longint unsigned IDMA_REG_STATUS_1_REG_ADDR   = 64'h00000008;
localparam longint unsigned IDMA_REG_STATUS_1_REG_OFFSET = 64'h00000008;
localparam longint unsigned IDMA_REG_STATUS_2_REG_ADDR   = 64'h0000000C;
localparam longint unsigned IDMA_REG_STATUS_2_REG_OFFSET = 64'h0000000C;
localparam longint unsigned IDMA_REG_STATUS_3_REG_ADDR   = 64'h00000010;
localparam longint unsigned IDMA_REG_STATUS_3_REG_OFFSET = 64'h00000010;
localparam longint unsigned IDMA_REG_STATUS_4_REG_ADDR   = 64'h00000014;
localparam longint unsigned IDMA_REG_STATUS_4_REG_OFFSET = 64'h00000014;
localparam longint unsigned IDMA_REG_STATUS_5_REG_ADDR   = 64'h00000018;
localparam longint unsigned IDMA_REG_STATUS_5_REG_OFFSET = 64'h00000018;
localparam longint unsigned IDMA_REG_STATUS_6_REG_ADDR   = 64'h0000001C;
localparam longint unsigned IDMA_REG_STATUS_6_REG_OFFSET = 64'h0000001C;
localparam longint unsigned IDMA_REG_STATUS_7_REG_ADDR   = 64'h00000020;
localparam longint unsigned IDMA_REG_STATUS_7_REG_OFFSET = 64'h00000020;
localparam longint unsigned IDMA_REG_STATUS_8_REG_ADDR   = 64'h00000024;
localparam longint unsigned IDMA_REG_STATUS_8_REG_OFFSET = 64'h00000024;
localparam longint unsigned IDMA_REG_STATUS_9_REG_ADDR   = 64'h00000028;
localparam longint unsigned IDMA_REG_STATUS_9_REG_OFFSET = 64'h00000028;
localparam longint unsigned IDMA_REG_STATUS_10_REG_ADDR   = 64'h0000002C;
localparam longint unsigned IDMA_REG_STATUS_10_REG_OFFSET = 64'h0000002C;
localparam longint unsigned IDMA_REG_STATUS_11_REG_ADDR   = 64'h00000030;
localparam longint unsigned IDMA_REG_STATUS_11_REG_OFFSET = 64'h00000030;
localparam longint unsigned IDMA_REG_STATUS_12_REG_ADDR   = 64'h00000034;
localparam longint unsigned IDMA_REG_STATUS_12_REG_OFFSET = 64'h00000034;
localparam longint unsigned IDMA_REG_STATUS_13_REG_ADDR   = 64'h00000038;
localparam longint unsigned IDMA_REG_STATUS_13_REG_OFFSET = 64'h00000038;
localparam longint unsigned IDMA_REG_STATUS_14_REG_ADDR   = 64'h0000003C;
localparam longint unsigned IDMA_REG_STATUS_14_REG_OFFSET = 64'h0000003C;
localparam longint unsigned IDMA_REG_STATUS_15_REG_ADDR   = 64'h00000040;
localparam longint unsigned IDMA_REG_STATUS_15_REG_OFFSET = 64'h00000040;

localparam longint unsigned IDMA_REG_NEXT_ID_0_REG_ADDR   = 64'h00000044;
localparam longint unsigned IDMA_REG_NEXT_ID_0_REG_OFFSET = 64'h00000044;
localparam longint unsigned IDMA_REG_NEXT_ID_1_REG_ADDR   = 64'h00000048;
localparam longint unsigned IDMA_REG_NEXT_ID_1_REG_OFFSET = 64'h00000048;
localparam longint unsigned IDMA_REG_NEXT_ID_2_REG_ADDR   = 64'h0000004C;
localparam longint unsigned IDMA_REG_NEXT_ID_2_REG_OFFSET = 64'h0000004C;
localparam longint unsigned IDMA_REG_NEXT_ID_3_REG_ADDR   = 64'h00000050;
localparam longint unsigned IDMA_REG_NEXT_ID_3_REG_OFFSET = 64'h00000050;
localparam longint unsigned IDMA_REG_NEXT_ID_4_REG_ADDR   = 64'h00000054;
localparam longint unsigned IDMA_REG_NEXT_ID_4_REG_OFFSET = 64'h00000054;
localparam longint unsigned IDMA_REG_NEXT_ID_5_REG_ADDR   = 64'h00000058;
localparam longint unsigned IDMA_REG_NEXT_ID_5_REG_OFFSET = 64'h00000058;
localparam longint unsigned IDMA_REG_NEXT_ID_6_REG_ADDR   = 64'h0000005C;
localparam longint unsigned IDMA_REG_NEXT_ID_6_REG_OFFSET = 64'h0000005C;
localparam longint unsigned IDMA_REG_NEXT_ID_7_REG_ADDR   = 64'h00000060;
localparam longint unsigned IDMA_REG_NEXT_ID_7_REG_OFFSET = 64'h00000060;
localparam longint unsigned IDMA_REG_NEXT_ID_8_REG_ADDR   = 64'h00000064;
localparam longint unsigned IDMA_REG_NEXT_ID_8_REG_OFFSET = 64'h00000064;
localparam longint unsigned IDMA_REG_NEXT_ID_9_REG_ADDR   = 64'h00000068;
localparam longint unsigned IDMA_REG_NEXT_ID_9_REG_OFFSET = 64'h00000068;
localparam longint unsigned IDMA_REG_NEXT_ID_10_REG_ADDR   = 64'h0000006C;
localparam longint unsigned IDMA_REG_NEXT_ID_10_REG_OFFSET = 64'h0000006C;
localparam longint unsigned IDMA_REG_NEXT_ID_11_REG_ADDR   = 64'h00000070;
localparam longint unsigned IDMA_REG_NEXT_ID_11_REG_OFFSET = 64'h00000070;
localparam longint unsigned IDMA_REG_NEXT_ID_12_REG_ADDR   = 64'h00000074;
localparam longint unsigned IDMA_REG_NEXT_ID_12_REG_OFFSET = 64'h00000074;
localparam longint unsigned IDMA_REG_NEXT_ID_13_REG_ADDR   = 64'h00000078;
localparam longint unsigned IDMA_REG_NEXT_ID_13_REG_OFFSET = 64'h00000078;
localparam longint unsigned IDMA_REG_NEXT_ID_14_REG_ADDR   = 64'h0000007C;
localparam longint unsigned IDMA_REG_NEXT_ID_14_REG_OFFSET = 64'h0000007C;
localparam longint unsigned IDMA_REG_NEXT_ID_15_REG_ADDR   = 64'h00000080;
localparam longint unsigned IDMA_REG_NEXT_ID_15_REG_OFFSET = 64'h00000080;

localparam longint unsigned IDMA_REG_DONE_ID_0_REG_ADDR   = 64'h00000084;
localparam longint unsigned IDMA_REG_DONE_ID_0_REG_OFFSET = 64'h00000084;
localparam longint unsigned IDMA_REG_DONE_ID_1_REG_ADDR   = 64'h00000088;
localparam longint unsigned IDMA_REG_DONE_ID_1_REG_OFFSET = 64'h00000088;
localparam longint unsigned IDMA_REG_DONE_ID_2_REG_ADDR   = 64'h0000008C;
localparam longint unsigned IDMA_REG_DONE_ID_2_REG_OFFSET = 64'h0000008C;
localparam longint unsigned IDMA_REG_DONE_ID_3_REG_ADDR   = 64'h00000090;
localparam longint unsigned IDMA_REG_DONE_ID_3_REG_OFFSET = 64'h00000090;
localparam longint unsigned IDMA_REG_DONE_ID_4_REG_ADDR   = 64'h00000094;
localparam longint unsigned IDMA_REG_DONE_ID_4_REG_OFFSET = 64'h00000094;
localparam longint unsigned IDMA_REG_DONE_ID_5_REG_ADDR   = 64'h00000098;
localparam longint unsigned IDMA_REG_DONE_ID_5_REG_OFFSET = 64'h00000098;
localparam longint unsigned IDMA_REG_DONE_ID_6_REG_ADDR   = 64'h0000009C;
localparam longint unsigned IDMA_REG_DONE_ID_6_REG_OFFSET = 64'h0000009C;
localparam longint unsigned IDMA_REG_DONE_ID_7_REG_ADDR   = 64'h000000A0;
localparam longint unsigned IDMA_REG_DONE_ID_7_REG_OFFSET = 64'h000000A0;
localparam longint unsigned IDMA_REG_DONE_ID_8_REG_ADDR   = 64'h000000A4;
localparam longint unsigned IDMA_REG_DONE_ID_8_REG_OFFSET = 64'h000000A4;
localparam longint unsigned IDMA_REG_DONE_ID_9_REG_ADDR   = 64'h000000A8;
localparam longint unsigned IDMA_REG_DONE_ID_9_REG_OFFSET = 64'h000000A8;
localparam longint unsigned IDMA_REG_DONE_ID_10_REG_ADDR   = 64'h000000AC;
localparam longint unsigned IDMA_REG_DONE_ID_10_REG_OFFSET = 64'h000000AC;
localparam longint unsigned IDMA_REG_DONE_ID_11_REG_ADDR   = 64'h000000B0;
localparam longint unsigned IDMA_REG_DONE_ID_11_REG_OFFSET = 64'h000000B0;
localparam longint unsigned IDMA_REG_DONE_ID_12_REG_ADDR   = 64'h000000B4;
localparam longint unsigned IDMA_REG_DONE_ID_12_REG_OFFSET = 64'h000000B4;
localparam longint unsigned IDMA_REG_DONE_ID_13_REG_ADDR   = 64'h000000B8;
localparam longint unsigned IDMA_REG_DONE_ID_13_REG_OFFSET = 64'h000000B8;
localparam longint unsigned IDMA_REG_DONE_ID_14_REG_ADDR   = 64'h000000BC;
localparam longint unsigned IDMA_REG_DONE_ID_14_REG_OFFSET = 64'h000000BC;
localparam longint unsigned IDMA_REG_DONE_ID_15_REG_ADDR   = 64'h000000C0;
localparam longint unsigned IDMA_REG_DONE_ID_15_REG_OFFSET = 64'h000000C0;

localparam longint unsigned IDMA_REG_DST_ADDR_0_REG_ADDR   = 64'h000000D0;
localparam longint unsigned IDMA_REG_DST_ADDR_0_REG_OFFSET = 64'h000000D0;
localparam longint unsigned IDMA_REG_DST_ADDR_1_REG_ADDR   = 64'h000000D4;
localparam longint unsigned IDMA_REG_DST_ADDR_1_REG_OFFSET = 64'h000000D4;

localparam longint unsigned IDMA_REG_SRC_ADDR_0_REG_ADDR   = 64'h000000D8;
localparam longint unsigned IDMA_REG_SRC_ADDR_0_REG_OFFSET = 64'h000000D8;
localparam longint unsigned IDMA_REG_SRC_ADDR_1_REG_ADDR   = 64'h000000DC;
localparam longint unsigned IDMA_REG_SRC_ADDR_1_REG_OFFSET = 64'h000000DC;

localparam longint unsigned IDMA_REG_LENGTH_0_REG_ADDR   = 64'h000000E0;
localparam longint unsigned IDMA_REG_LENGTH_0_REG_OFFSET = 64'h000000E0;
localparam longint unsigned IDMA_REG_LENGTH_1_REG_ADDR   = 64'h000000E4;
localparam longint unsigned IDMA_REG_LENGTH_1_REG_OFFSET = 64'h000000E4;


endpackage;

// Generated register defines for idma_reg32_2d_frontend

// Copyright information found in source file:
// Copyright 2022 ETH Zurich and University of Bologna.

// Licensing information found in source file:
// Licensed under Solderpad Hardware License, Version 0.51
// SPDX-License-Identifier: SHL-0.51

#ifndef _IDMA_REG32_2D_FRONTEND_REG_DEFS_
#define _IDMA_REG32_2D_FRONTEND_REG_DEFS_

#ifdef __cplusplus
extern "C" {
#endif
// Register width
#define IDMA_REG32_2D_FRONTEND_PARAM_REG_WIDTH 32

// Source Protocol
#define IDMA_REG32_2D_FRONTEND_SRC_PROTOCOL_REG_OFFSET 0x0
#define IDMA_REG32_2D_FRONTEND_SRC_PROTOCOL_SRC_PROTOCOL_MASK 0x3
#define IDMA_REG32_2D_FRONTEND_SRC_PROTOCOL_SRC_PROTOCOL_OFFSET 0
#define IDMA_REG32_2D_FRONTEND_SRC_PROTOCOL_SRC_PROTOCOL_FIELD \
  ((bitfield_field32_t) { .mask = IDMA_REG32_2D_FRONTEND_SRC_PROTOCOL_SRC_PROTOCOL_MASK, .index = IDMA_REG32_2D_FRONTEND_SRC_PROTOCOL_SRC_PROTOCOL_OFFSET })

// Destination Protocol
#define IDMA_REG32_2D_FRONTEND_DST_PROTOCOL_REG_OFFSET 0x4
#define IDMA_REG32_2D_FRONTEND_DST_PROTOCOL_DST_PROTOCOL_MASK 0x3
#define IDMA_REG32_2D_FRONTEND_DST_PROTOCOL_DST_PROTOCOL_OFFSET 0
#define IDMA_REG32_2D_FRONTEND_DST_PROTOCOL_DST_PROTOCOL_FIELD \
  ((bitfield_field32_t) { .mask = IDMA_REG32_2D_FRONTEND_DST_PROTOCOL_DST_PROTOCOL_MASK, .index = IDMA_REG32_2D_FRONTEND_DST_PROTOCOL_DST_PROTOCOL_OFFSET })

// Source Address
#define IDMA_REG32_2D_FRONTEND_SRC_ADDR_REG_OFFSET 0x8

// Destination Address
#define IDMA_REG32_2D_FRONTEND_DST_ADDR_REG_OFFSET 0xc

// Number of bytes
#define IDMA_REG32_2D_FRONTEND_NUM_BYTES_REG_OFFSET 0x10

// Configuration Register for DMA settings
#define IDMA_REG32_2D_FRONTEND_CONF_REG_OFFSET 0x14
#define IDMA_REG32_2D_FRONTEND_CONF_DECOUPLE_BIT 0
#define IDMA_REG32_2D_FRONTEND_CONF_DEBURST_BIT 1
#define IDMA_REG32_2D_FRONTEND_CONF_SERIALIZE_BIT 2
#define IDMA_REG32_2D_FRONTEND_CONF_TWOD_BIT 3

// Source Stride
#define IDMA_REG32_2D_FRONTEND_STRIDE_SRC_REG_OFFSET 0x18

// Destination Stride
#define IDMA_REG32_2D_FRONTEND_STRIDE_DST_REG_OFFSET 0x1c

// Number of 2D repetitions
#define IDMA_REG32_2D_FRONTEND_NUM_REPETITIONS_REG_OFFSET 0x20

// DMA Status
#define IDMA_REG32_2D_FRONTEND_STATUS_REG_OFFSET 0x24
#define IDMA_REG32_2D_FRONTEND_STATUS_BUSY_MASK 0xffff
#define IDMA_REG32_2D_FRONTEND_STATUS_BUSY_OFFSET 0
#define IDMA_REG32_2D_FRONTEND_STATUS_BUSY_FIELD \
  ((bitfield_field32_t) { .mask = IDMA_REG32_2D_FRONTEND_STATUS_BUSY_MASK, .index = IDMA_REG32_2D_FRONTEND_STATUS_BUSY_OFFSET })

// Next ID, launches transfer, returns 0 if transfer not set up properly.
#define IDMA_REG32_2D_FRONTEND_NEXT_ID_REG_OFFSET 0x28

// Get ID of finished transactions.
#define IDMA_REG32_2D_FRONTEND_DONE_REG_OFFSET 0x2c

#ifdef __cplusplus
}  // extern "C"
#endif
#endif  // _IDMA_REG32_2D_FRONTEND_REG_DEFS_
// End generated register defines for idma_reg32_2d_frontend
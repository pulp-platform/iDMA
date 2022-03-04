/*
 * Copyright (C) 2021 ETH Zurich and University of Bologna
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef __ARCHI_IDMA_V1_H__
#define __ARCHI_IDMA_V1_H__

// Generated register defines for idma_reg32_2d_frontend

#ifndef _IDMA_REG32_2D_FRONTEND_REG_DEFS_
#define _IDMA_REG32_2D_FRONTEND_REG_DEFS_

#ifdef __cplusplus
extern "C" {
#endif
// Register width
#define IDMA_REG32_2D_FRONTEND_PARAM_REG_WIDTH 32

// Source Address
#define IDMA_REG32_2D_FRONTEND_SRC_ADDR_REG_OFFSET 0x0

// Destination Address
#define IDMA_REG32_2D_FRONTEND_DST_ADDR_REG_OFFSET 0x4

// Number of bytes
#define IDMA_REG32_2D_FRONTEND_NUM_BYTES_REG_OFFSET 0x8

// Configuration Register for DMA settings
#define IDMA_REG32_2D_FRONTEND_CONF_REG_OFFSET 0xc
#define IDMA_REG32_2D_FRONTEND_CONF_DECOUPLE_BIT 0
#define IDMA_REG32_2D_FRONTEND_CONF_DEBURST_BIT 1
#define IDMA_REG32_2D_FRONTEND_CONF_SERIALIZE_BIT 2
#define IDMA_REG32_2D_FRONTEND_CONF_TWOD_BIT 3

// Source Stride
#define IDMA_REG32_2D_FRONTEND_STRIDE_SRC_REG_OFFSET 0x10

// Destination Stride
#define IDMA_REG32_2D_FRONTEND_STRIDE_DST_REG_OFFSET 0x14

// Number of 2D repetitions
#define IDMA_REG32_2D_FRONTEND_NUM_REPETITIONS_REG_OFFSET 0x18

// DMA Status
#define IDMA_REG32_2D_FRONTEND_STATUS_REG_OFFSET 0x1c
#define IDMA_REG32_2D_FRONTEND_STATUS_BUSY_MASK 0xffff
#define IDMA_REG32_2D_FRONTEND_STATUS_BUSY_OFFSET 0
#define IDMA_REG32_2D_FRONTEND_STATUS_BUSY_FIELD \
  ((bitfield_field32_t) { .mask = IDMA_REG32_2D_FRONTEND_STATUS_BUSY_MASK, .index = IDMA_REG32_2D_FRONTEND_STATUS_BUSY_OFFSET })

// Next ID, launches transfer, returns 0 if transfer not set up properly.
#define IDMA_REG32_2D_FRONTEND_NEXT_ID_REG_OFFSET 0x20

// Get ID of finished transactions.
#define IDMA_REG32_2D_FRONTEND_DONE_REG_OFFSET 0x24

#ifdef __cplusplus
}  // extern "C"
#endif
#endif  // _IDMA_REG32_2D_FRONTEND_REG_DEFS_
// End generated register defines for idma_reg32_2d_frontend

#endif // __ARCHI_IDMA_V1_H__

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

#ifndef __HAL_IDMA_V1_H__
#define __HAL_IDMA_V1_H__

#include <archi/dma/idma_v1.h>
#include "hal/pulp.h"

#define PLP_DMA_LOC2EXT 0
#define PLP_DMA_EXT2LOC 1

#define PLP_DMA_1D 0
#define PLP_DMA_2D 1

#define IDMA_EVENT 8 // all iDMA tx_cplt events are broadcast
#define IDMA_ID_COUNTER_WIDTH 28
#define IDMA_ID_MASK 0x0fffffff

#define IDMA_DEFAULT_CONFIG 0x0
#define IDMA_DEFAULT_CONFIG_2D 0x8

typedef unsigned int dma_ext_t;
typedef unsigned int dma_loc_t;

/** @name High-level DMA memory copy functions
 * The following functions can be used to trigger DMA transfers to copy data between the cluster memory (L1) and another memory outside the cluster (another cluster L1 or L2).
 * The DMA supports the following features:
 *   - Transfers are event-based. With event-based transfers the core can call a wait function to block execution until the transfer is done.
 *   - The DMA supports 2D transfers which allows transfering a 2D tile in one command. Additional information must then be given to specify the width of the tile and the number of bytes between 2 lines of the tile.
 *   - The event sent at the end of the transfer is broadcasted to all cluster cores.
 *   - To identify specific transfers, the DMA provides a transfer identifier.
 *   - Multiple transfers can be launched simultaneously, with them being executed 2-4 in parallel, with more waiting in a queue.
 */
/**@{*/

/** Memory transfer with event-based completion. 
 * 
  \param   ext     Address in the external memory where to access the data. There is no restriction on memory alignment.
  \param   loc     Address in the cluster memory where to access the data. There is no restriction on memory alignment.
  \param   size    Number of bytes to be transfered. The only restriction is that this size must fit 16 bits, i.e. must be inferior to 65536.
  \param   ext2loc If 1, the transfer is loading data from external memory and storing to cluster memory. If 0, it is the contrary
  \return          The identifier of the transfer. This can be used with plp_dma_wait to wait for the completion of this transfer.
  */
static inline int plp_dma_memcpy(dma_ext_t ext, unsigned int loc, unsigned int size, int ext2loc);

/** Cluster memory to external memory transfer with event-based completion. 
 * 
  \param   ext  Address in the external memory where to store the data. There is no restriction on memory alignment.
  \param   loc  Address in the cluster memory where to load the data. There is no restriction on memory alignment.
  \param   size Number of bytes to be transfered. The only restriction is that this size must fit 16 bits, i.e. must be inferior to 65536.
  \return       The identifier of the transfer. This can be used with plp_dma_wait to wait for the completion of this transfer.
  */
static inline int plp_dma_l1ToExt(dma_ext_t ext, unsigned int loc, unsigned short size);

/** External memory to cluster memory transfer with event-based completion. 
 * 
  \param   loc  Address in the cluster memory where to store the data. There is no restriction on memory alignment.
  \param   ext  Address in the external memory where to load the data. There is no restriction on memory alignment.
  \param   size Number of bytes to be transfered. The only restriction is that this size must fit 16 bits, i.e. must be inferior to 65536.
  \return       The identifier of the transfer. This can be used with plp_dma_wait to wait for the completion of this transfer.
  */
static inline int plp_dma_extToL1(unsigned int loc, dma_ext_t ext, unsigned short size);

/** 2-dimensional memory transfer with event-based completion. 
 * 
  \param   ext    Address in the external memory where to access the data. There is no restriction on memory alignment.
  \param   loc    Address in the cluster memory where to access the data. There is no restriction on memory alignment.
  \param   size   Number of bytes to be transfered. The only restriction is that this size must fit 16 bits, i.e. must be inferior to 65536.
  \param   stride 2D stride, which is the number of bytes which are added to the beginning of the current line to switch to the next one. Must fit 16 bits, i.e. must be inferior to 65536.
  \param   length 2D length, which is the number of transfered bytes after which the DMA will switch to the next line. Must fit 16 bits, i.e. must be inferior to 65536.
  \param   ext2loc If 1, the transfer is loading data from external memory and storing to cluster memory. If 0, it is the contrary
  \return         The identifier of the transfer. This can be used with plp_dma_wait to wait for the completion of this transfer.
  */
static inline int plp_dma_memcpy_2d(dma_ext_t ext, unsigned int loc, unsigned int size, unsigned int stride, unsigned int length, int ext2loc);

/** Cluster memory to external memory 2-dimensional transfer with event-based completion. 
 * 
  \param   ext    Address in the external memory where to store the data. There is no restriction on memory alignment.
  \param   loc    Address in the cluster memory where to load the data. There is no restriction on memory alignment.
  \param   size   Number of bytes to be transfered. The only restriction is that this size must fit 16 bits, i.e. must be inferior to 65536.
  \param   stride 2D stride, which is the number of bytes which are added to the beginning of the current line to switch to the next one. Must fit 16 bits, i.e. must be inferior to 65536. This applies only to the external memory.
  \param   length 2D length, which is the number of transfered bytes after which the DMA will switch to the next line. Must fit 16 bits, i.e. must be inferior to 65536. This applies only to the external memory.
  \return         The identifier of the transfer. This can be used with plp_dma_wait to wait for the completion of this transfer.
  */
static inline int plp_dma_l1ToExt_2d(dma_ext_t ext, unsigned int loc, unsigned short size, unsigned short stride, unsigned short length);

/** External memory to cluster memory 2-dimensional transfer with event-based completion. 
 * 
  \param   loc    Address in the cluster memory where to store the data. There is no restriction on memory alignment.
  \param   ext    Address in the external memory where to load the data. There is no restriction on memory alignment.
  \param   size   Number of bytes to be transfered. The only restriction is that this size must fit 16 bits, i.e. must be inferior to 65536.
  \param   stride 2D stride, which is the number of bytes which are added to the beginning of the current line to switch to the next one. Must fit 16 bits, i.e. must be inferior to 65536. This applies only to the external memory.
  \param   length 2D length, which is the number of transfered bytes after which the DMA will switch to the next line. Must fit 16 bits, i.e. must be inferior to 65536. This applies only to the external memory.
  \return         The identifier of the transfer. This can be used with plp_dma_wait to wait for the completion of this transfer
  */
static inline int plp_dma_extToL1_2d(unsigned int loc, dma_ext_t ext, unsigned short size, unsigned short stride, unsigned short length);

//!@}

/** @name DMA wait functions
 */

/** DMA barrier.
 * This blocks the core until no transfer is on-going in the DMA. 
 */
static inline void plp_dma_barrier();

/** DMA wait.
  * This blocks the core until the specified transfer is finished. 
  *
  \param   counter  The counter ID identifying the transfer. This has been returned from an enqueued transfer (e.g. plp_dma_extToL1_2d)
 */
static inline void plp_dma_wait(unsigned int dma_tx_id);

//!@}


/** @name iDMA low-level functions.
  * This can be used instead of the high-level ones in order to have more control over the DMA features. 
 */

/**
 * iDMA configuration generation
 * A standard memcpy will set all of these values to 0.
 *
  \param  decouple   if set to true, there is no longer exactly one AXI write_request issued for
                     every read request. This mode can improve performance of unaligned transfers when crossing
                     the AXI page boundaries.
  \param  deburst    if set, the DMA will split all bursts in single transfers
  \param  serialize  if set, the DMA will only send AX belonging to a given Arbitrary 1D burst request
                     at a time. This is default behavior to prevent deadlocks. Setting `serialize` to
                     zero violates the AXI4+ATOP specification.
  \param  twod       if set, the DMA will execute a 2D transfer.
  \return            The generated configuration
  */
static inline unsigned int pulp_idma_get_conf(unsigned int decouple, unsigned int deburst, unsigned int serialize, unsigned int twod);

/**
 * iDMA transfer status
 *
  \param  dma_tx_id  The dma transfer identifier
  \return            transfer status. 1 if complete, 0 if still ongoing or waiting.
  */
static inline unsigned int pulp_idma_tx_cplt(unsigned int dma_tx_id);

/**
 * iDMA memory transfer
 * Launches a standard 1D memory transfer
 *
  \param  dst_addr   The destination address
  \param  src_addr   The source address
  \param  num_bytes  The number bytes
  \return            The dma transfer identifier
  */
static inline unsigned int pulp_idma_memcpy(unsigned int const dst_addr, unsigned int const src_addr, unsigned int num_bytes);

/**
 * iDMA 2D memory transfer
 * Launches a standard 2D memory transfer
 *
  \param  dst_addr   The destination address
  \param  src_addr   The source address
  \param  num_bytes  The number bytes (per stride)
  \param  dst_stride The stride at the destination
  \param  src_stride The stride at the source
  \param  num_reps   The number of repetitions
  \return            The dma transfer identifier
  */
static inline unsigned int pulp_idma_memcpy_2d(unsigned int const dst_addr, unsigned int const src_addr, unsigned int num_bytes, unsigned int dst_stride, unsigned int src_stride, unsigned int num_reps);


/**
 * iDMA advanced memory transfer
 * Launches a 1D memory transfer with special configuration options
 *
  \param  dst_addr   The destination address
  \param  src_addr   The source address
  \param  num_bytes  The number bytes
  \param  decouple   if set to true, there is no longer exactly one AXI write_request issued for
                     every read request. This mode can improve performance of unaligned transfers when crossing
                     the AXI page boundaries.
  \param  deburst    if set, the DMA will split all bursts in single transfers
  \param  serialize  if set, the DMA will only send AX belonging to a given Arbitrary 1D burst request
                     at a time. This is default behavior to prevent deadlocks. Setting `serialize` to
                     zero violates the AXI4+ATOP specification.
  \param  twod       if set, the DMA will execute a 2D transfer
  \param  dst_stride if 2D, the stride at the destination
  \param  src_stride if 2D, the stride at the source
  \param  num_reps   if 2D, the number of repetitions
  \return            The dma trasfer identifier
  */
static inline unsigned int pulp_idma_memcpy_advanced(unsigned int const dst_addr, unsigned int const src_addr, unsigned int num_bytes, unsigned int decouple, unsigned int deburst, unsigned int serialize, unsigned int twod, unsigned int dst_stride, unsigned int src_stride, unsigned int num_reps);

/** Return the DMA status.
 * 
  \return             DMA status. 1 means there are still on-going transfers, 0 means nothing is on-going.
  */  
static inline unsigned int plp_dma_status();


//!@}


/// @cond IMPLEM

#if ARCHI_HAS_DMA_DEMUX
#define DMA_ADDR ARCHI_IDMA_DEMUX_ADDR
#else
#define DMA_ADDR ARCHI_IDMA_EXT_ADDR
#endif
#if defined(__riscv__) && !defined(RV_ISA_RV32) && !defined(__LLVM__)
#define DMA_WRITE(value, offset) __builtin_pulp_OffsetedWrite((value), (int *)DMA_ADDR, (offset))
#define DMA_READ(offset) __builtin_pulp_OffsetedRead((int *)DMA_ADDR, (offset))
#else
#define DMA_WRITE(value, offset) pulp_write32(DMA_ADDR + (offset), (value))
#define DMA_READ(offset) pulp_read32(DMA_ADDR + (offset))
#endif

static inline unsigned int pulp_idma_get_conf(unsigned int decouple, unsigned int deburst, unsigned int serialize, unsigned int twod) {
  unsigned int conf;
#if defined(__riscv__)
  conf = __builtin_bitinsert(0,    decouple,  1, IDMA_REG32_2D_FRONTEND_CONF_DECOUPLE_BIT);
  conf = __builtin_bitinsert(conf, deburst,   1, IDMA_REG32_2D_FRONTEND_CONF_DEBURST_BIT);
  conf = __builtin_bitinsert(conf, serialize, 1, IDMA_REG32_2D_FRONTEND_CONF_SERIALIZE_BIT);
  conf = __builtin_bitinsert(conf, twod,      1, IDMA_REG32_2D_FRONTEND_CONF_TWOD_BIT);
#else
  conf = (((decouple & 0x1)<<IDMA_REG32_2D_FRONTEND_CONF_DECOUPLE_BIT) | ((deburst & 0x1)<<IDMA_REG32_2D_FRONTEND_CONF_DEBURST_BIT) | ((serialize & 0x1)<<IDMA_REG32_2D_FRONTEND_CONF_SERIALIZE_BIT) | ((twod & 0x1)<<IDMA_REG32_2D_FRONTEND_CONF_TWOD_BIT));
#endif
  return conf;
}

static inline unsigned int pulp_idma_tx_cplt(unsigned int dma_tx_id) {
  unsigned int done_id = DMA_READ(IDMA_REG32_2D_FRONTEND_DONE_REG_OFFSET);
  unsigned int my_id = dma_tx_id & IDMA_ID_MASK;
  if (done_id >> (IDMA_ID_COUNTER_WIDTH-1) == my_id >> (IDMA_ID_COUNTER_WIDTH-1)) {
    return my_id <= done_id;
  } else {
    return ((done_id & (IDMA_ID_MASK - (1<<(IDMA_ID_COUNTER_WIDTH-1))) < (1<<(IDMA_ID_COUNTER_WIDTH-2))));
  }
}


static inline unsigned int pulp_idma_memcpy(unsigned int const dst_addr, unsigned int const src_addr, unsigned int num_bytes) {
  DMA_WRITE(src_addr, IDMA_REG32_2D_FRONTEND_SRC_ADDR_REG_OFFSET);
  DMA_WRITE(dst_addr, IDMA_REG32_2D_FRONTEND_DST_ADDR_REG_OFFSET);
  DMA_WRITE(num_bytes, IDMA_REG32_2D_FRONTEND_NUM_BYTES_REG_OFFSET);
  DMA_WRITE(IDMA_DEFAULT_CONFIG, IDMA_REG32_2D_FRONTEND_CONF_REG_OFFSET);
  asm volatile("" : : : "memory");

  // Launch TX
  unsigned int dma_tx_id = DMA_READ(IDMA_REG32_2D_FRONTEND_NEXT_ID_REG_OFFSET);

  return dma_tx_id;
}

static inline unsigned int pulp_idma_memcpy_2d(unsigned int const dst_addr, unsigned int const src_addr, unsigned int num_bytes, unsigned int dst_stride, unsigned int src_stride, unsigned int num_reps) {
  DMA_WRITE(src_addr, IDMA_REG32_2D_FRONTEND_SRC_ADDR_REG_OFFSET);
  DMA_WRITE(dst_addr, IDMA_REG32_2D_FRONTEND_DST_ADDR_REG_OFFSET);
  DMA_WRITE(num_bytes, IDMA_REG32_2D_FRONTEND_NUM_BYTES_REG_OFFSET);
  DMA_WRITE(IDMA_DEFAULT_CONFIG_2D, IDMA_REG32_2D_FRONTEND_CONF_REG_OFFSET);
  DMA_WRITE(src_stride, IDMA_REG32_2D_FRONTEND_STRIDE_SRC_REG_OFFSET);
  DMA_WRITE(dst_stride, IDMA_REG32_2D_FRONTEND_STRIDE_DST_REG_OFFSET);
  DMA_WRITE(num_reps,   IDMA_REG32_2D_FRONTEND_NUM_REPETITIONS_REG_OFFSET);
  asm volatile("" : : : "memory");

  // Launch TX
  unsigned int dma_tx_id = DMA_READ(IDMA_REG32_2D_FRONTEND_NEXT_ID_REG_OFFSET);

  return dma_tx_id;
}


static inline unsigned int pulp_idma_memcpy_advanced(unsigned int const dst_addr, unsigned int const src_addr, unsigned int num_bytes, unsigned int decouple, unsigned int deburst, unsigned int serialize, unsigned int twod, unsigned int dst_stride, unsigned int src_stride, unsigned int num_reps) {
  DMA_WRITE(src_addr, IDMA_REG32_2D_FRONTEND_SRC_ADDR_REG_OFFSET);
  DMA_WRITE(dst_addr, IDMA_REG32_2D_FRONTEND_DST_ADDR_REG_OFFSET);
  DMA_WRITE(num_bytes, IDMA_REG32_2D_FRONTEND_NUM_BYTES_REG_OFFSET);
  unsigned int conf = pulp_idma_get_conf(decouple, deburst, serialize, twod);
  DMA_WRITE(conf, IDMA_REG32_2D_FRONTEND_CONF_REG_OFFSET);
  if (twod) {
    DMA_WRITE(src_stride, IDMA_REG32_2D_FRONTEND_STRIDE_SRC_REG_OFFSET);
    DMA_WRITE(dst_stride, IDMA_REG32_2D_FRONTEND_STRIDE_DST_REG_OFFSET);
    DMA_WRITE(num_reps, IDMA_REG32_2D_FRONTEND_NUM_REPETITIONS_REG_OFFSET);
  }
  asm volatile("" : : : "memory");

  // Launch TX
  unsigned int dma_tx_id = DMA_READ(IDMA_REG32_2D_FRONTEND_NEXT_ID_REG_OFFSET);

  return dma_tx_id;
}

static inline unsigned int plp_dma_status() {
  return DMA_READ(IDMA_REG32_2D_FRONTEND_STATUS_REG_OFFSET);
}

static inline void plp_dma_wait(unsigned int dma_tx_id) {
  while(!pulp_idma_tx_cplt(dma_tx_id)) {
    eu_evt_maskWaitAndClr(1 << IDMA_EVENT);
  }
  return;
}

static inline int plp_dma_memcpy(dma_ext_t ext, unsigned int loc, unsigned int size, int ext2loc) {
  if (ext2loc) {
    return pulp_idma_memcpy(loc, ext, size);
  } else {
    return pulp_idma_memcpy(ext, loc, size);
  }
}

static inline int plp_dma_l1ToExt(dma_ext_t ext, unsigned int loc, unsigned short size) {
  return pulp_idma_memcpy(ext, loc, size);
}

static inline int plp_dma_extToL1(unsigned int loc, dma_ext_t ext, unsigned short size) {
  return pulp_idma_memcpy(loc, ext, size);
}

static inline int plp_dma_memcpy_2d(dma_ext_t ext, unsigned int loc, unsigned int size, unsigned int stride, unsigned int length, int ext2loc) {
  if (ext2loc) {
    return pulp_idma_memcpy_2d(loc, ext, length, length, stride, size/length);
  } else {
    return pulp_idma_memcpy_2d(ext, loc, length, stride, length, size/length);
  }
}

static inline int plp_dma_l1ToExt_2d(dma_ext_t ext, unsigned int loc, unsigned short size, unsigned short stride, unsigned short length) {
    return pulp_idma_memcpy_2d(ext, loc, length, stride, length, size/length);
}

static inline int plp_dma_extToL1_2d(unsigned int loc, dma_ext_t ext, unsigned short size, unsigned short stride, unsigned short length) {
    return pulp_idma_memcpy_2d(loc, ext, length, length, stride, size/length);
}

static inline void plp_dma_barrier() {
  while(plp_dma_status()) {
    eu_evt_maskWaitAndClr(1 << IDMA_EVENT);
  }
}

#endif // __HAL_IDMA_V1_H__

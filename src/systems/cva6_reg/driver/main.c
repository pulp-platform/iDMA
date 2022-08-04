// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Andreas Kuster <kustera@ethz.ch>
//
// Description: Minimal iDMA engine testing program for CVA6

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>

#include "uart.h"

#include "cva6_idma.h"

#define DMA_BASE 0x50000000  // dma base address

#define DMA_SRC_ADDR      (DMA_BASE + DMA_FRONTEND_SRC_ADDR_REG_OFFSET)
#define DMA_DST_ADDR      (DMA_BASE + DMA_FRONTEND_DST_ADDR_REG_OFFSET)
#define DMA_NUMBYTES_ADDR (DMA_BASE + DMA_FRONTEND_NUM_BYTES_REG_OFFSET)
#define DMA_CONF_ADDR     (DMA_BASE + DMA_FRONTEND_CONF_REG_OFFSET)
#define DMA_STATUS_ADDR   (DMA_BASE + DMA_FRONTEND_STATUS_REG_OFFSET)
#define DMA_NEXTID_ADDR   (DMA_BASE + DMA_FRONTEND_NEXT_ID_REG_OFFSET)
#define DMA_DONE_ADDR     (DMA_BASE + DMA_FRONTEND_DONE_REG_OFFSET)

#define DMA_TRANSFER_SIZE (2*8) // data transfer size in bytes

#define DMA_CONF_DECOUPLE 0
#define DMA_CONF_DEBURST 0
#define DMA_CONF_SERIALIZE 0

#define TEST_SRC 0
#define VERBOSE 1

#define ASSERT(expr, msg)             \
if (!(expr)) {                        \
    print_uart("assertion failed: "); \
    print_uart(msg);                  \
    print_uart("\n");                 \
    return -1;                        \
}


int main(int argc, char const *argv[]) {

    /*
     * Setup uart
     */
    init_uart(50000000, 115200);
    print_uart("Hello CVA6 from iDMA!\n");

    /*
     * Setup relevant configuration registers
     */
    volatile uint64_t *dma_src = (volatile uint64_t *) DMA_SRC_ADDR;
    volatile uint64_t *dma_dst = (volatile uint64_t *) DMA_DST_ADDR;
    volatile uint64_t *dma_num_bytes = (volatile uint64_t *) DMA_NUMBYTES_ADDR;
    volatile uint64_t *dma_conf = (volatile uint64_t *) DMA_CONF_ADDR;
    // volatile uint64_t* dma_status = (volatile uint64_t*)DMA_STATUS_ADDR; // not used in current implementation
    volatile uint64_t *dma_nextid = (volatile uint64_t *) DMA_NEXTID_ADDR;
    volatile uint64_t *dma_done = (volatile uint64_t *) DMA_DONE_ADDR;

    /*
     * Prepare data
     */
    // allocate source array
    uint64_t src[DMA_TRANSFER_SIZE / sizeof(uint64_t)];
    if (VERBOSE) {
        // print array stack address
        print_uart("Source array @0x");
        print_uart_addr((uint64_t) & src);
        print_uart("\n");
    }

    // allocate destination array
    uint64_t dst[DMA_TRANSFER_SIZE / sizeof(uint64_t)];
    if (VERBOSE) {
        // print array stack address
        print_uart("Destination array @0x");
        print_uart_addr((uint64_t) & dst);
        print_uart("\n");
    }

    // fill src array & clear dst array
    for (size_t i = 0; i < DMA_TRANSFER_SIZE / sizeof(uint64_t); i++) {
        src[i] = 42;
        dst[i] = 0;
    }

    // flush cache?

    /*
     * Test register access
     */
    print_uart("Test register read/write\n");

    // test register read/write
    *dma_src = 42;
    *dma_dst = 42;
    *dma_num_bytes = 0;
    *dma_conf = 7;   // 0b111

    ASSERT(*dma_src == 42, "dma_src");
    ASSERT(*dma_dst == 42, "dma_dst");
    ASSERT(*dma_num_bytes == 0, "dma_num_bytes");
    ASSERT(*dma_conf == 7, "dma_conf");

    /*
     * Test DMA transfer
     */
    print_uart("Initiate dma request\n");

    // setup src to dst memory transfer
    *dma_src = (uint64_t) & src;
    *dma_dst = (uint64_t) & dst;
    *dma_num_bytes = DMA_TRANSFER_SIZE;
    *dma_conf = (DMA_CONF_DECOUPLE << DMA_FRONTEND_CONF_DECOUPLE_BIT) |
                (DMA_CONF_DEBURST << DMA_FRONTEND_CONF_DEBURST_BIT) |
                (DMA_CONF_SERIALIZE << DMA_FRONTEND_CONF_SERIALIZE_BIT);

    print_uart("Start transfer\n");

    // launch transfer: read id
    uint64_t transfer_id = *dma_nextid;

    // CVA6 node interconnect work-around: add delay to free axi bus (axi_node does not allow parallel transactions -> need to upgrade axi xbar)
    for (int i = 0; i < 16 * DMA_TRANSFER_SIZE; i++) {
        asm volatile ("nop" :  : ); // nop operation
    }

    // poll wait for transfer to finish
    do {
        print_uart("Transfer finished: ");
        print_uart("transfer_id: ");
        print_uart_int(transfer_id);
        print_uart(" done_id: ");
        print_uart_int(*dma_done);
        print_uart(" dst[0]: ");
        print_uart_int(dst[0]);
        print_uart("\n");
    } while (*dma_done != transfer_id);

    // invalidate cache?

    // check result
    for (size_t i = 0; i < DMA_TRANSFER_SIZE / sizeof(uint64_t); i++) {

        uintptr_t dst_val = (uintptr_t)dst[i];
        print_uart("Try reading dst: 0x");
        print_uart_int(dst_val);
        print_uart("\n");

        ASSERT(dst_val == 42, "dst");

        if (TEST_SRC) {
            uintptr_t src_val = (uintptr_t)src[i];
            print_uart("Try reading src: 0x");
            print_uart_int(src_val);
            print_uart("\n");
        }

    }
    print_uart("Transfer successfully validated.\n");

    print_uart("All done, spin-loop.\n");
    while (1) {
        // do nothing
    }

    return 0;
}

// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

#define STR(x) #x
#define EXPAND(x) x
#define STRINGIFY_MACRO(x) STR(x)
#define CONCAT(n1, n2) STRINGIFY_MACRO(EXPAND(n1)EXPAND(n2))

#define HDR_NAME_STR CONCAT(VNAME,.h)
#define DPI_HDR_STR CONCAT(VNAME,__Dpi.h)
#define SYMS_HDR_STR CONCAT(VNAME,__Syms.h)

#include <verilated.h>
#include HDR_NAME_STR
#include DPI_HDR_STR
#include SYMS_HDR_STR

#include <stdio.h>
#include <stdlib.h>
#include <deque>
#include <map>
#include <iostream>

std::map<uint32_t, uint32_t> memory_accesses;
uint32_t curr_access_id = 0xA5A50000;
size_t invalid_writes = 0;

uint32_t copy_from = 0x1000;
uint32_t copy_to = 0x5000;
uint32_t copy_size = 256;

std::string vNameStr = STRINGIFY_MACRO(VNAME);

void idma_read(int addr, int *data, int *delay) {
    printf("[DRIVER] Read from %08x: %08x\n", addr, curr_access_id);
    *data = curr_access_id;
    *delay = 5000;
    memory_accesses.insert({addr, curr_access_id});
    curr_access_id++;
}

void idma_write(int w_addr, int w_data) {
    uint32_t orig_addr = w_addr + copy_from - copy_to;
    printf("[DRIVER] Write %08x to %08x (original address: %08x)\n", w_data, w_addr, orig_addr);
    if (memory_accesses.count(orig_addr) == 0) {
        printf("[DRIVER] Write is invalid (never read from there)\n");
        invalid_writes++;
    } else if (memory_accesses.at(orig_addr) != w_data) {
        printf("[DRIVER] Write is invalid (wrong value)\n");
        invalid_writes++;
    }
}

typedef struct {
    unsigned int dst_addr;
    unsigned int src_addr;
    unsigned int length;
} idma_req_t;

int main(int argc, char **argv) {
    // Verilated::debug(1);

    Verilated::commandArgs(argc, argv);
    VNAME *idma = new VNAME();
    Verilated::traceEverOn(true);
    svSetScope(svGetScopeFromName(("TOP." + vNameStr.substr(1)).c_str()));
    int cycs = 0;
    while (!Verilated::gotFinish() && cycs++ < 100000) {
        if (cycs == 100) {
            printf("Pushing request\n");
            idma->add_request(copy_size, copy_from, copy_to);
        }

        idma->eval();
        if (!idma->eventsPending()) break;
        Verilated::time(idma->nextTimeSlot());
    }

    idma->final();
    delete idma;

    printf("Testbench terminated. Invalid writes: %ld\n", invalid_writes);
    
    return 0;
}

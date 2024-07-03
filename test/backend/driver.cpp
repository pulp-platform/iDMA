// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

#include <verilated.h>
#include <verilated_dpi.h>
#include "Vtb_idma_backend.h"
#include "Vtb_idma_backend__Dpi.h"
#include "Vtb_idma_backend__Syms.h"

#define RYML_SINGLE_HDR_DEFINE_NOW
#include "third_party/rapidyaml.hpp"

#include <stdio.h>
#include <stdlib.h>
#include <deque>
#include <map>
#include <iostream>

// #define DEBUG

#ifdef DEBUG
    #define DEBUG_PRINT(fmt, args...) printf("DEBUG: %s:%d: " fmt, \
        __FILE__, __LINE__, ##args)
#else
    #define DEBUG_PRINT(fmt, args...)
#endif

typedef Vtb_idma_backend_idma_req_t__struct__0 idma_req_t;

std::map<uint32_t, uint32_t> memory_accesses;
uint32_t curr_access_id = 0xA5A50000;
uint32_t invalid_writes = 0;

uint32_t copy_from = 0x1000;
uint32_t copy_to = 0x20000;
uint32_t copy_size = 1024 * 16;

std::deque<idma_req_t> pendingIdmaRequests;

const idma_req_t &currentIdmaRequest() {
    return pendingIdmaRequests.front();
}

unsigned int num_reads = 0;
unsigned int num_writes = 0;

void idma_read(int addr, int *data, int *delay) {
    DEBUG_PRINT("[DRIVER] Read from %08x: %08x\n", addr, curr_access_id);
    *data = curr_access_id;
    *delay = 5000;
    memory_accesses.insert({addr, curr_access_id});
    curr_access_id++;
    num_reads++;
}

void idma_write(int w_addr, int w_data) {
    uint32_t orig_addr = w_addr + currentIdmaRequest().src_addr - currentIdmaRequest().dst_addr;
    DEBUG_PRINT("[DRIVER] Write %08x to %08x (original address: %08x)\n", w_data, w_addr, orig_addr);
    if (memory_accesses.count(orig_addr) == 0) {
        DEBUG_PRINT("[DRIVER] Write is invalid (never read from there)\n");
        invalid_writes++;
    } else if (memory_accesses.at(orig_addr) != w_data) {
        DEBUG_PRINT("[DRIVER] Write is invalid (wrong value)\n");
        invalid_writes++;
    } else {
        memory_accesses.erase(orig_addr);
    }
    num_writes++;
}

void idma_request_done() {
    printf("[DRIVER] Request done\n");
    pendingIdmaRequests.pop_front();
}

Vtb_idma_backend_idma_pkg::protocol_e strToProtocol(std::string str) {
    if (str == "OBI") return Vtb_idma_backend_idma_pkg::protocol_e::OBI;
    if (str == "AXI") return Vtb_idma_backend_idma_pkg::protocol_e::AXI;
    return Vtb_idma_backend_idma_pkg::protocol_e::OBI;
}

int main(int argc, char **argv) {
    // Verilated::debug(1);

    Verilated::commandArgs(argc, argv);
    Vtb_idma_backend *idma = new Vtb_idma_backend();
    Verilated::traceEverOn(true);
    svSetScope(svGetScopeFromName("TOP.tb_idma_backend"));

    std::string jobFile = argv[1];

    // printf("Loading job file %s\n", jobFile.c_str());
    FILE *jobFp = fopen(jobFile.c_str(), "r");
    if (jobFp == NULL) {
        printf("Failed to open job file\n");
        return 1;
    }
    std::string jobStr;
    char c;
    while ((c = fgetc(jobFp)) != EOF) {
        jobStr += c;
    }

    ryml::Tree jobYaml = ryml::parse_in_place(ryml::to_substr(jobStr));

    int reqCount = jobYaml["jobs"].num_children();

    Vtb_idma_backend_idma_pkg::protocol_e defaultSrcProtocol = strToProtocol(jobYaml["defaults"]["src"].val().str);
    Vtb_idma_backend_idma_pkg::protocol_e defaultDstProtocol = strToProtocol(jobYaml["defaults"]["dst"].val().str);
    int defaultMaxSrcBurst = std::stoi(jobYaml["defaults"]["max_src_burst"].val().str);
    int defaultMaxDstBurst = std::stoi(jobYaml["defaults"]["max_dst_burst"].val().str);

    for (int i = 0; i < reqCount; i++) {
        idma_req_t idmaRequest;
        idmaRequest.dst_addr = std::stoul(jobYaml["jobs"][i]["dst_addr"].val().str, nullptr, 0);
        idmaRequest.src_addr = std::stoul(jobYaml["jobs"][i]["src_addr"].val().str, nullptr, 0);
        idmaRequest.length   = std::stoul(jobYaml["jobs"][i]["length"  ].val().str, nullptr, 0);

        idmaRequest.opt.src_protocol = defaultSrcProtocol;
        idmaRequest.opt.src.burst    = 0b01; // INCR
        idmaRequest.opt.dst_protocol = defaultDstProtocol;
        idmaRequest.opt.dst.burst    = 0b01; // INCR

        idmaRequest.opt.beo.decouple_aw = 0;
        idmaRequest.opt.beo.decouple_rw = 0;
        idmaRequest.opt.beo.src_max_llen = defaultMaxSrcBurst;
        idmaRequest.opt.beo.dst_max_llen = defaultMaxDstBurst;
        idmaRequest.opt.beo.src_reduce_len = 1;
        idmaRequest.opt.beo.dst_reduce_len = 1;

        idmaRequest.opt.last = (i == reqCount - 1);

        pendingIdmaRequests.push_back(idmaRequest);
        idma->tb_idma_backend->trigger_request(idmaRequest.get());
    }

    int cycs = 0;
    while (!Verilated::gotFinish()) {
        idma->eval();
        if (!idma->eventsPending()) break;
        Verilated::time(idma->nextTimeSlot());

        cycs++;
    }

    idma->final();
    delete idma;

    printf("Testbench terminated. Statistics:\n");
    printf("             Reads: %u\n", num_reads);
    printf("            Writes: %u\n", num_writes);
    printf("    Invalid writes: %u\n", invalid_writes);
    printf("Outstanding writes: %lu\n", memory_accesses.size());
    
    return 0;
}

// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Andreas Kuster <kustera@ethz.ch>
//
// Description: Simple trap handler


#include "trap.h"
#include "uart.h"
#include "encoding.h"

void setup_trap() {

    // set interrupt function (direct mode)
    asm volatile ("csrw mtvec, %[reg]" : : [reg] "r"(trap_entry));

    // enable machine mode interrupts
    asm volatile ("csrs mstatus, 0x8");
    asm volatile ("csrs mie, 0x8");
}

void handle_trap() {

    // read exception cause
    uintptr_t cause = 0;
    asm("csrr %0, %1" : "=r"(cause) : "I"(CSR_MCAUSE));

    // switch between causes
    switch (cause) {
        case CAUSE_MISALIGNED_FETCH:
            print_uart("Trap CAUSE_MISALIGNED_FETCH\n");
            break;
        case CAUSE_FETCH_ACCESS:
            print_uart("Trap CAUSE_FETCH_ACCESS\n");
            break;
        case CAUSE_ILLEGAL_INSTRUCTION:
            print_uart("Trap CAUSE_ILLEGAL_INSTRUCTION\n");
            break;
        case CAUSE_BREAKPOINT:
            print_uart("Trap CAUSE_BREAKPOINT\n");
            break;
        case CAUSE_MISALIGNED_LOAD:
            print_uart("Trap CAUSE_MISALIGNED_LOAD\n");
            break;
        case CAUSE_LOAD_ACCESS:
            print_uart("Trap CAUSE_LOAD_ACCESS\n");
            break;
        case CAUSE_MISALIGNED_STORE:
            print_uart("Trap CAUSE_MISALIGNED_STORE\n");
            break;
        case CAUSE_STORE_ACCESS:
            print_uart("Trap CAUSE_STORE_ACCESS\n");
            break;
        case CAUSE_USER_ECALL:
            print_uart("Trap CAUSE_USER_ECALL\n");
            break;
        case CAUSE_SUPERVISOR_ECALL:
            print_uart("Trap CAUSE_SUPERVISOR_ECALL\n");
            break;
        case CAUSE_HYPERVISOR_ECALL:
            print_uart("Trap CAUSE_HYPERVISOR_ECALL\n");
            break;
        case CAUSE_MACHINE_ECALL:
            print_uart("Trap CAUSE_MACHINE_ECALL\n");
            break;
        case CAUSE_FETCH_PAGE_FAULT:
            print_uart("Trap CAUSE_FETCH_PAGE_FAULT\n");
            break;
        case CAUSE_LOAD_PAGE_FAULT:
            print_uart("Trap CAUSE_LOAD_PAGE_FAULT\n");
            break;
        case CAUSE_STORE_PAGE_FAULT:
            print_uart("Trap CAUSE_STORE_PAGE_FAULT\n");
            break;
        default:
            print_uart("Trap OTHER: ");
            print_uart_addr(cause);
            print_uart("\n");
            break;
    }

    // spin-loop
    while (1) {
        // do nothing
    }
}

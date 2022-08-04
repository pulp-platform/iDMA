// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Andreas Kuster <kustera@ethz.ch>
// Description: Bootloader initialization and trap handler

  .section .text.init
  .option norvc
  .globl _prog_start
_prog_start:
  li sp, 0x81000000
  call main

  .align 8
  .globl trap_entry
  .type trap_entry, @function
trap_entry:
    j handle_trap
    mret

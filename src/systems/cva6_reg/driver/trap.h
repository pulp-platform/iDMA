// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Andreas Kuster <kustera@ethz.ch>
//
// Description: Simple trap handler

// reference to base trap address (assembly code)
extern int trap_entry();

void setup_trap();
void handle_trap();

#!/bin/bash

# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Liam Braun <libraun@student.ethz.ch>

verilator -f idma.f --timing --trace --trace-structs --exe --build --structs-packed -j `nproc` \
    -Wno-REDEFMACRO -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-MODDUP -Wno-PINMISSING \
    -Wno-WIDTH -Wno-TIMESCALEMOD \
    -Wno-SPLITVAR \
    -CFLAGS "-DVNAME=Vtb_idma_backend" \
    --top tb_idma_backend \
    --cc driver.cpp \
    -o tb_idma

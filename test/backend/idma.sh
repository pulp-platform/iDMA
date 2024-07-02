#!/bin/bash

# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Liam Braun <libraun@student.ethz.ch>

verilator -f idma.f --timing --trace --trace-structs --trace-fst --build --exe -j `nproc` \
    -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-WIDTH \
    --top tb_idma_backend \
    --cc driver.cpp \
    -o tb_idma

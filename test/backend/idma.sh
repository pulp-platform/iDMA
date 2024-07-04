#!/bin/bash

# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Liam Braun <libraun@student.ethz.ch>

if [ ! -f third_party/rapidyaml.hpp ]; then
    mkdir -p ./third_party
    wget https://github.com/biojppm/rapidyaml/releases/download/v0.7.0/rapidyaml-0.7.0.hpp -O ./third_party/rapidyaml.hpp
fi

verilator -f idma.f --timing --trace --trace-structs --trace-fst --build --exe -j `nproc` \
    -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-WIDTH \
    --top tb_idma_backend \
    --cc driver.cpp \
    -o tb_idma \
    -DPORT_AXI4 -DPORT_OBI -DPORT_W_OBI -DPORT_R_AXI4 \
    -DBACKEND_NAME=idma_backend_r_axi_w_obi

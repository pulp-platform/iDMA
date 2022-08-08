#!/usr/bin/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Only filters modules required for the DMA to make verilator work properly."""
import sys

WHITE_LIST = ['fifo_v3', 'stream_fifo', 'spill_register', 'popcount', 'stream_fork', 'fifo_v2',
    'axi_pkg', 'cf_math', 'fall_through_register', 'idma_', '+define+', '+incdir+']

_, inp_file = sys.argv

with open(inp_file, 'r', encoding='utf-8') as f:
    for line in f.read().split('\n'):
        if line == '':
            print()
        if any(map(line.__contains__, WHITE_LIST)):
            print(line)

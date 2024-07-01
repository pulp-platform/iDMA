// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

`ifndef DPI_INTERFACE_H
`define DPI_INTERFACE_H

import "DPI-C" function void idma_read(input int addr, output int data, output int delay);
import "DPI-C" function void idma_write(input int addr, input int data);

`endif

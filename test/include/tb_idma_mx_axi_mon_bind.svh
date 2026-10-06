// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Binds the AXI protocol and MX plane monitor into idma_backend_rw_axi; include once per top.

`include "include/tb_idma_mx_axi_mon_macro.svh"

`IDMA_MX_AXI_MON_BIND(idma_backend_rw_axi)

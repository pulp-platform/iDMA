// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

`ifndef OBI_DRIVER_COMMON_SV
`define OBI_DRIVER_COMMON_SV

`include "obi/assign.svh"
`include "../src/obi_intf.sv"

class obi_ar_beat;
    logic [31:0] addr;
    logic [31:0] wdata;
endclass

class obi_r_resp;
    logic [31:0] data;
endclass

`endif

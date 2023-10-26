// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

`include "axi/typedef.svh"

/// Synthesis package for the descriptor-based frontend
package idma_desc64_cva6_synth_pkg;
  `AXI_TYPEDEF_ALL(axi, logic [63:0], logic [2:0], logic [63:0], logic [7:0], logic)
  parameter int  AxiAddrWidth     = 64;
  parameter int  AxiDataWidth     = 64;
  parameter int  AxiUserWidth     = 1;
  parameter int  AxiIdWidth       = 3;
  parameter int  AxiSlvIdWidth    = 3;
  parameter int  NSpeculation     = 4;
  parameter int  PendingFifoDepth = 4;
  parameter int  InputFifoDepth   = 1;
  parameter type mst_aw_chan_t    = axi_aw_chan_t; // AW Channel Type, master port
  parameter type mst_w_chan_t     = axi_w_chan_t; //  W Channel Type, all ports
  parameter type mst_b_chan_t     = axi_b_chan_t; //  B Channel Type, master port
  parameter type mst_ar_chan_t    = axi_ar_chan_t; // AR Channel Type, master port
  parameter type mst_r_chan_t     = axi_r_chan_t; //  R Channel Type, master port
  parameter type axi_mst_req_t    = axi_req_t;
  parameter type axi_mst_rsp_t    = axi_resp_t;
  parameter type axi_slv_req_t    = axi_req_t;
  parameter type axi_slv_rsp_t    = axi_resp_t;
endpackage

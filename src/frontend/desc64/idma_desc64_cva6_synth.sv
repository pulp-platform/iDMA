// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

/// Synthesis wrapper for the descriptor-based frontend
module idma_desc64_cva6_synth #(
  parameter int  AxiAddrWidth     = idma_desc64_cva6_synth_pkg::AxiAddrWidth,
  parameter int  AxiDataWidth     = idma_desc64_cva6_synth_pkg::AxiDataWidth,
  parameter int  AxiUserWidth     = idma_desc64_cva6_synth_pkg::AxiUserWidth,
  parameter int  AxiIdWidth       = idma_desc64_cva6_synth_pkg::AxiIdWidth,
  parameter int  AxiSlvIdWidth    = idma_desc64_cva6_synth_pkg::AxiSlvIdWidth,
  parameter int  NSpeculation     = idma_desc64_cva6_synth_pkg::NSpeculation,
  parameter int  PendingFifoDepth = idma_desc64_cva6_synth_pkg::PendingFifoDepth,
  parameter int  InputFifoDepth   = idma_desc64_cva6_synth_pkg::InputFifoDepth,
  parameter type mst_aw_chan_t    = idma_desc64_cva6_synth_pkg::mst_aw_chan_t,
  parameter type mst_w_chan_t     = idma_desc64_cva6_synth_pkg::mst_w_chan_t,
  parameter type mst_b_chan_t     = idma_desc64_cva6_synth_pkg::mst_b_chan_t,
  parameter type mst_ar_chan_t    = idma_desc64_cva6_synth_pkg::mst_ar_chan_t,
  parameter type mst_r_chan_t     = idma_desc64_cva6_synth_pkg::mst_r_chan_t,
  parameter type axi_mst_req_t    = idma_desc64_cva6_synth_pkg::axi_mst_req_t,
  parameter type axi_mst_rsp_t    = idma_desc64_cva6_synth_pkg::axi_mst_rsp_t,
  parameter type axi_slv_req_t    = idma_desc64_cva6_synth_pkg::axi_slv_req_t,
  parameter type axi_slv_rsp_t    = idma_desc64_cva6_synth_pkg::axi_slv_rsp_t
)(
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  output logic         irq_o,
  output axi_mst_req_t axi_master_req_o,
  input  axi_mst_rsp_t axi_master_rsp_i,
  input  axi_slv_req_t axi_slave_req_i,
  output axi_slv_rsp_t axi_slave_rsp_o
);

idma_desc64_cva6_wrap #(
  .AxiAddrWidth  (AxiAddrWidth ),
  .AxiDataWidth  (AxiDataWidth ),
  .AxiUserWidth  (AxiUserWidth ),
  .AxiIdWidth    (AxiIdWidth   ),
  .AxiSlvIdWidth (AxiSlvIdWidth),
  .NSpeculation  (NSpeculation),
  .PendingFifoDepth(PendingFifoDepth),
  .InputFifoDepth(InputFifoDepth),
  .mst_aw_chan_t (mst_aw_chan_t),
  .mst_w_chan_t  (mst_w_chan_t ),
  .mst_b_chan_t  (mst_b_chan_t ),
  .mst_ar_chan_t (mst_ar_chan_t),
  .mst_r_chan_t  (mst_r_chan_t ),
  .axi_mst_req_t (axi_mst_req_t),
  .axi_mst_rsp_t (axi_mst_rsp_t),
  .axi_slv_req_t (axi_slv_req_t),
  .axi_slv_rsp_t (axi_slv_rsp_t)
) i_idma_desc64_cva6_wrap (
  .clk_i,
  .rst_ni,
  .testmode_i,
  .irq_o,
  .axi_master_req_o,
  .axi_master_rsp_i,
  .axi_slave_req_i,
  .axi_slave_rsp_o
);

endmodule

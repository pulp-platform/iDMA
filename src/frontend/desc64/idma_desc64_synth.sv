// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

/// synth wrapper
module idma_desc64_synth #(
    parameter int unsigned AddrWidth        = idma_desc64_synth_pkg::AddrWidth,
    parameter int unsigned DataWidth        = idma_desc64_synth_pkg::DataWidth,
    parameter int unsigned AxiIdWidth       = idma_desc64_synth_pkg::IdWidth,
    parameter type         idma_req_t       = idma_desc64_synth_pkg::idma_req_t,
    parameter type         idma_rsp_t       = idma_desc64_synth_pkg::idma_rsp_t,
    parameter type         axi_rsp_t        = idma_desc64_synth_pkg::axi_rsp_t,
    parameter type         axi_req_t        = idma_desc64_synth_pkg::axi_req_t,
    parameter type         axi_ar_chan_t    = idma_desc64_synth_pkg::axi_ar_chan_t,
    parameter type         axi_r_chan_t     = idma_desc64_synth_pkg::axi_r_chan_t,
    parameter type         apb_rsp_t        = idma_desc64_synth_pkg::apb_resp_t,
    parameter type         apb_req_t        = idma_desc64_synth_pkg::apb_req_t,
    parameter int unsigned InputFifoDepth   = idma_desc64_synth_pkg::InputFifoDepth,
    parameter int unsigned PendingFifoDepth = idma_desc64_synth_pkg::PendingFifoDepth
)(
    input  logic                  clk_i           ,
    input  logic                  rst_ni          ,
    output axi_req_t              master_req_o    ,
    input  axi_rsp_t              master_rsp_i    ,
    input  logic [AxiIdWidth-1:0] axi_ar_id_i     ,
    input  logic [AxiIdWidth-1:0] axi_aw_id_i     ,
    input  apb_req_t              slave_req_i     ,
    output apb_rsp_t              slave_rsp_o     ,
    output idma_req_t             idma_req_o      ,
    output logic                  idma_req_valid_o,
    input  logic                  idma_req_ready_i,
    input  idma_rsp_t             idma_rsp_i      ,
    input  logic                  idma_rsp_valid_i,
    output logic                  idma_rsp_ready_o,
    input  logic                  idma_busy_i     ,
    output logic                  irq_o
);

  idma_desc64_top #(
    .AddrWidth        ( AddrWidth        ),
    .DataWidth        ( DataWidth        ),
    .AxiIdWidth       ( AxiIdWidth       ),
    .idma_req_t       ( idma_req_t       ),
    .idma_rsp_t       ( idma_rsp_t       ),
    .axi_req_t        ( axi_req_t        ),
    .axi_rsp_t        ( axi_rsp_t        ),
    .axi_ar_chan_t    ( axi_ar_chan_t    ),
    .axi_r_chan_t     ( axi_r_chan_t     ),
    .apb_req_t        ( apb_req_t        ),
    .apb_rsp_t        ( apb_rsp_t        ),
    .InputFifoDepth   ( InputFifoDepth   ),
    .PendingFifoDepth ( PendingFifoDepth )
  ) i_dma_desc64 (
    .clk_i           ,
    .rst_ni          ,
    .master_req_o    ,
    .master_rsp_i    ,
    .axi_ar_id_i     ,
    .axi_aw_id_i     ,
    .slave_req_i     ,
    .slave_rsp_o     ,
    .idma_req_o      ,
    .idma_req_valid_o,
    .idma_req_ready_i,
    .idma_rsp_i      ,
    .idma_rsp_valid_i,
    .idma_rsp_ready_o,
    .idma_busy_i     ,
    .irq_o
  );

endmodule

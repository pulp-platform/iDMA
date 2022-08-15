// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

// synth wrapper
module idma_desc64_synth #(
    parameter int unsigned AddrWidth        = idma_desc64_synth_pkg::AddrWidth,
    parameter int unsigned DataWidth        = idma_desc64_synth_pkg::DataWidth,
    parameter int unsigned AxiIdWidth       = idma_desc64_synth_pkg::IdWidth,
    parameter type         idma_req_t       = idma_desc64_synth_pkg::idma_req_t,
    parameter type         idma_rsp_t       = idma_desc64_synth_pkg::idma_rsp_t,
    parameter type         axi_rsp_t        = idma_desc64_synth_pkg::axi_rsp_t,
    parameter type         axi_req_t        = idma_desc64_synth_pkg::axi_req_t,
    parameter type         reg_rsp_t        = idma_desc64_synth_pkg::reg_rsp_t,
    parameter type         reg_req_t        = idma_desc64_synth_pkg::reg_req_t,
    parameter int unsigned InputFifoDepth   = idma_desc64_synth_pkg::InputFifoDepth,
    parameter int unsigned PendingFifoDepth = idma_desc64_synth_pkg::PendingFifoDepth
)(
    input  logic                  clk_i             ,
    input  logic                  rst_ni            ,
    output axi_req_t              master_req_o      ,
    input  axi_rsp_t              master_rsp_i      ,
    input  logic [AxiIdWidth-1:0] axi_r_id_i        ,
    input  logic [AxiIdWidth-1:0] axi_w_id_i        ,
    input  reg_req_t              slave_req_i       ,
    output reg_rsp_t              slave_rsp_o       ,
    output idma_req_t             dma_be_req_o      ,
    output logic                  dma_be_req_valid_o,
    input  logic                  dma_be_req_ready_i,
    input  idma_rsp_t             dma_be_rsp_i      ,
    input  logic                  dma_be_rsp_valid_i,
    output logic                  dma_be_rsp_ready_o,
    input  logic                  dma_be_idle_i     ,
    output logic                  irq_o
);

  idma_desc64_top #(
    .AddrWidth,
    .DataWidth,
    .AxiIdWidth,
    .idma_req_t,
    .idma_rsp_t,
    .axi_req_t,
    .axi_rsp_t,
    .reg_req_t,
    .reg_rsp_t,
    .InputFifoDepth,
    .PendingFifoDepth
  ) i_dma_desc64 (
    .clk_i             ,
    .rst_ni            ,
    .master_req_o      ,
    .master_rsp_i      ,
    .axi_r_id_i        ,
    .axi_w_id_i        ,
    .slave_req_i       ,
    .slave_rsp_o       ,
    .dma_be_req_o      ,
    .dma_be_req_valid_o,
    .dma_be_req_ready_i,
    .dma_be_rsp_i      ,
    .dma_be_rsp_valid_i,
    .dma_be_rsp_ready_o,
    .dma_be_idle_i     ,
    .irq_o
  );

endmodule : idma_desc64_synth

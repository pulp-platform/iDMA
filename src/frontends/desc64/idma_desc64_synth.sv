// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

// synth wrapper
module idma_desc64_synth #(
    parameter int unsigned AddrWidth   = idma_desc64_synth_pkg::AddrWidth,
    parameter type         burst_req_t = idma_desc64_synth_pkg::burst_req_t,
    parameter type         reg_rsp_t   = idma_desc64_synth_pkg::reg_rsp_t,
    parameter type         reg_req_t   = idma_desc64_synth_pkg::reg_req_t
)(
    input  logic       clk_i,
    input  logic       rst_ni,
    output reg_req_t   master_req_o,
    input  reg_rsp_t   master_rsp_i,
    input  reg_req_t   slave_req_i,
    output reg_rsp_t   slave_rsp_o,
    output burst_req_t dma_be_req_o,
    output logic       dma_be_valid_o,
    input  logic       dma_be_ready_i,
    input  logic       dma_be_tx_complete_i,
    input  logic       dma_be_idle_i,
    output logic       irq_o
);

    idma_desc64_top #(
        .AddrWidth   ( AddrWidth   ),
        .burst_req_t ( burst_req_t ),
        .reg_rsp_t   ( reg_rsp_t   ),
        .reg_req_t   ( reg_req_t   )
    ) i_idma_desc64 (
        .clk_i,
        .rst_ni,
        .master_req_o,
        .master_rsp_i,
        .slave_req_i,
        .slave_rsp_o,
        .dma_be_req_o,
        .dma_be_valid_o,
        .dma_be_ready_i,
        .dma_be_tx_complete_i,
        .dma_be_idle_i,
        .irq_o
    );

endmodule : idma_desc64_synth

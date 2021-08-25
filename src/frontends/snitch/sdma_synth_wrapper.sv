// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Thomas Benz <tbenz@ethz.ch>

// defines a type for the axi bus to allow a ooc synthesis

module sdma_synth_wrapper (

    input  logic                     clk_i,
    input  logic                     rst_ni,
    output axi_dma_pkg::req_t        axi_dma_req_o,
    input  axi_dma_pkg::res_t        axi_dma_res_i,
    output logic                     dma_busy_o,
    input  logic              [31:0] acc_qaddr_i,
    input  logic              [ 4:0] acc_qid_i,
    input  logic              [31:0] acc_qdata_op_i,
    input  logic              [63:0] acc_qdata_arga_i,
    input  logic              [63:0] acc_qdata_argb_i,
    input  logic              [63:0] acc_qdata_argc_i,
    input  logic                     acc_qvalid_i,
    output logic                     acc_qready_o,
    output logic              [63:0] acc_pdata_o,
    output logic              [ 4:0] acc_pid_o,
    output logic                     acc_perror_o,
    output logic                     acc_pvalid_o,
    input  logic                     acc_pready_i
);

  axi_dma_tc_snitch_fe #(
      .axi_req_t(axi_dma_pkg::req_t),
      .axi_res_t(axi_dma_pkg::res_t)
  ) i_axi_dma_tc_snitch_fe (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .axi_dma_req_o   (axi_dma_req_o),
      .axi_dma_res_i   (axi_dma_res_i),
      .dma_busy_o      (dma_busy_o),
      .acc_qaddr_i     (acc_qaddr_i),
      .acc_qid_i       (acc_qid_i),
      .acc_qdata_op_i  (acc_qdata_op_i),
      .acc_qdata_arga_i(acc_qdata_arga_i),
      .acc_qdata_argb_i(acc_qdata_argb_i),
      .acc_qdata_argc_i(acc_qdata_argc_i),
      .acc_qvalid_i    (acc_qvalid_i),
      .acc_qready_o    (acc_qready_o),
      .acc_pdata_o     (acc_pdata_o),
      .acc_pid_o       (acc_pid_o),
      .acc_perror_o    (acc_perror_o),
      .acc_pvalid_o    (acc_pvalid_o),
      .acc_pready_i    (acc_pready_i)
  );

endmodule : sdma_synth_wrapper

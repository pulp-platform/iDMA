// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

/// Synthesis wrapper for the Mempool mid-ends
module idma_mp_midend_synth #(
  /// Number of back-ends
  parameter int unsigned NumBEs         = idma_mp_midend_synth_pkg::NumBEs,
  /// Size of the region that one port covers in bytes
  parameter int unsigned RegionWidth    = idma_mp_midend_synth_pkg::RegionWidth,
  /// Base address of the regions
  parameter int unsigned RegionStart    = idma_mp_midend_synth_pkg::RegionStart,
  /// End address of the regions
  parameter int unsigned RegionEnd      = idma_mp_midend_synth_pkg::RegionEnd,
  /// Address Width
  parameter int unsigned AddrWidth      = 32'd32,
  /// Print information on transfers
  parameter bit          PrintInfo      = 1'b0,
  /// DMA iDMA type
  parameter type         idma_req_t     = idma_mp_midend_synth_pkg::idma_req_t,
  /// DMA iDMA request type
  parameter type         idma_rsp_t     = idma_mp_midend_synth_pkg::idma_rsp_t
) (
  /// Clock
  input  logic                              clk_i,
  /// Reset
  input  logic                              rst_ni,
  /// Burst request manager
  input  idma_req_t                         idma_req_i,
  /// iDMA request valid manager
  input  logic                              idma_req_valid_i,
  /// iDMA request ready manager
  output logic                              idma_req_ready_o,
  /// iDMA response manager
  output idma_rsp_t                         idma_rsp_o,
  /// iDMA response valid manager
  output logic                              idma_rsp_valid_o,
  /// iDMA response ready manager
  input  logic                              idma_rsp_ready_i,
  /// DMA busy manager
  output idma_pkg::idma_busy_t              idma_busy_o,
  // Subordinate Port
  /// iDMA request subordinate
  output idma_req_t            [NumBEs-1:0] idma_req_o,
  /// iDMA request valid subordinate
  output logic                 [NumBEs-1:0] idma_req_valid_o,
  /// iDMA request ready subordinate
  input  logic                 [NumBEs-1:0] idma_req_ready_i,
  /// iDMA response subordinate
  input  idma_rsp_t            [NumBEs-1:0] idma_rsp_i,
  /// iDMA response valid subordinate
  input  logic                 [NumBEs-1:0] idma_rsp_valid_i,
  /// iDMA response ready subordinate
  output logic                 [NumBEs-1:0] idma_rsp_ready_o,
  /// DMA busy subordinate
  input  idma_pkg::idma_busy_t [NumBEs-1:0] idma_busy_i
);


  idma_req_t idma_req;
  logic      idma_req_valid;
  logic      idma_req_ready;
  idma_rsp_t idma_rsp;
  logic      idma_rsp_valid;
  logic      idma_rsp_ready;

  idma_mp_split_midend #(
    .RegionWidth ( RegionWidth ),
    .RegionStart ( RegionStart ),
    .RegionEnd   ( RegionEnd   ),
    .AddrWidth   ( AddrWidth   ),
    .PrintInfo   ( PrintInfo   ),
    .idma_req_t  ( idma_req_t  ),
    .idma_rsp_t  ( idma_rsp_t  )
  ) i_idma_mp_split_midend (
    .clk_i,
    .rst_ni,
    .idma_req_i,
    .idma_req_valid_i,
    .idma_req_ready_o,
    .idma_rsp_o,
    .idma_rsp_valid_o,
    .idma_rsp_ready_i,
    .idma_req_o       ( idma_req       ),
    .idma_req_valid_o ( idma_req_valid ),
    .idma_req_ready_i ( idma_req_ready ),
    .idma_rsp_i       ( idma_rsp       ),
    .idma_rsp_valid_i ( idma_rsp_valid ),
    .idma_rsp_ready_o ( idma_rsp_ready )
  );

  idma_mp_dist_midend #(
    .NumBEs      ( NumBEs      ),
    .RegionWidth ( RegionWidth ),
    .RegionStart ( RegionStart ),
    .RegionEnd   ( RegionEnd   ),
    .AddrWidth   ( AddrWidth   ),
    .PrintInfo   ( PrintInfo   ),
    .idma_req_t  ( idma_req_t  ),
    .idma_rsp_t  ( idma_rsp_t  )
  ) i_idma_mp_dist_midend (
    .clk_i,
    .rst_ni,
    .idma_req_i       ( idma_req       ),
    .idma_req_valid_i ( idma_req_valid ),
    .idma_req_ready_o ( idma_req_ready ),
    .idma_rsp_o       ( idma_rsp       ),
    .idma_rsp_valid_o ( idma_rsp_valid ),
    .idma_rsp_ready_i ( idma_rsp_ready ),
    .idma_busy_o,
    .idma_req_o,
    .idma_req_valid_o,
    .idma_req_ready_i,
    .idma_rsp_i,
    .idma_rsp_valid_i,
    .idma_rsp_ready_o,
    .idma_busy_i
  );

endmodule

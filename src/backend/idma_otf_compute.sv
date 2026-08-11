// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// On-the-fly compute dispatcher: latches the per-transfer compute options
/// and dispatches one op per transfer to its sub-unit. Back-to-back transfers
/// with an identical config may pipeline (lane-exact retire keeps the pack
/// sound across tails); any config change requires the engine to be drained.
module idma_otf_compute #(
  /// Byte lanes per beat (= DataWidth/8)
  parameter int unsigned StrbWidth       = 32'd8,
  /// Compile-time per-op feature enables (value rendered by the generator)
  parameter idma_pkg::compute_enable_t ComputeEnable = '0,
  /// Transpose engine duplex (1: two banks full rate, 0: one bank half area)
  parameter bit                        TransposeFullDuplex = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,

  /// Per-transfer compute config; valid only while `cfg_valid_i`
  input  idma_pkg::compute_options_t compute_i,
  input  logic                       cfg_valid_i,
  /// A supported compute op is armed for this transfer
  output logic                       active_o,

  /// Input beat stream (from the dataflow buffer)
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  output logic                      in_ready_o,

  /// Output beat stream: per-lane valid (occupancy) + per-byte strobe (edge mask)
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      strb_o,
  output logic [StrbWidth-1:0]      lane_valid_o,
  input  logic                      ready_i,
  /// Byte lanes the write accepted this cycle (lane-exact retire for the MX units)
  input  logic [StrbWidth-1:0]      lane_ready_i
);

  // config latch with first-beat bypass
  idma_pkg::compute_options_t latched_q, eff_compute;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          latched_q <= '0;
    else if (cfg_valid_i) latched_q <= compute_i;
  end
  assign eff_compute = cfg_valid_i ? compute_i : latched_q;

  // per-op select
  logic sel_transpose, sel_mxquant, sel_mxdequant, mx_fp16;
  assign sel_transpose = eff_compute.enable &
                         (eff_compute.op == idma_pkg::COMPUTE_TRANSPOSE) & ComputeEnable.transpose;
  assign sel_mxquant   = eff_compute.enable & ComputeEnable.mxquant &
                         ((eff_compute.op == idma_pkg::COMPUTE_MXQUANT) |
                          (eff_compute.op == idma_pkg::COMPUTE_MXQUANT_FP16));
  assign mx_fp16       = (eff_compute.op == idma_pkg::COMPUTE_MXQUANT_FP16);
  assign sel_mxdequant = eff_compute.enable &
                         (eff_compute.op == idma_pkg::COMPUTE_MXDEQUANT) & ComputeEnable.mxdequant;

  assign active_o = sel_transpose | sel_mxquant | sel_mxdequant;

  // transpose sub-unit
  logic [StrbWidth-1:0][7:0] tp_data;
  logic [StrbWidth-1:0]      tp_strb;
  logic                      tp_valid, tp_in_ready;

  if (ComputeEnable.transpose) begin : gen_transpose
    idma_otf_transpose #(
      .StrbWidth  ( StrbWidth                   ),
      .DimWidth   ( idma_pkg::TransposeDimWidth ),
      .FullDuplex ( TransposeFullDuplex         )
    ) i_idma_otf_transpose (
      .clk_i,
      .rst_ni,
      .clear_i         ( ~sel_transpose                          ),
      .transp_mode_i   ( eff_compute.params.transpose.mode       ),
      .tensor_size_m_i ( eff_compute.params.transpose.tensor_m   ),
      .tensor_size_n_i ( eff_compute.params.transpose.tensor_n   ),
      .data_i          ( data_i                                  ),
      .valid_i         ( valid_i & sel_transpose                 ),
      .ready_o         ( tp_in_ready                             ),
      .data_o          ( tp_data                                 ),
      .strb_o          ( tp_strb                                 ),
      .valid_o         ( tp_valid                                ),
      .ready_i         ( ready_i & sel_transpose                 )
    );
  end else begin : gen_no_transpose
    assign tp_data = '0; assign tp_strb = '0; assign tp_valid = 1'b0; assign tp_in_ready = 1'b0;
  end

  // MX-quant sub-unit
  logic [StrbWidth-1:0][7:0] mx_data;
  logic [StrbWidth-1:0]      mx_lane_valid;
  logic                      mx_in_ready, mx_busy;

  if (ComputeEnable.mxquant) begin : gen_mxquant
    idma_otf_mxquant #(
      .StrbWidth ( StrbWidth )
    ) i_idma_otf_mxquant (
      .clk_i,
      .rst_ni,
      .clear_i      ( ~sel_mxquant          ),
      .src_fp16_i   ( mx_fp16               ),
      .data_i       ( data_i                ),
      .valid_i      ( valid_i & sel_mxquant ),
      .ready_o      ( mx_in_ready           ),
      .data_o       ( mx_data               ),
      .lane_valid_o ( mx_lane_valid         ),
      .lane_ready_i ( lane_ready_i & {StrbWidth{sel_mxquant}} ),
      .busy_o       ( mx_busy               )
    );
  end else begin : gen_no_mxquant
    assign mx_data = '0; assign mx_lane_valid = '0; assign mx_in_ready = 1'b0;
    assign mx_busy = 1'b0;
  end

  // MX-dequant sub-unit
  logic [StrbWidth-1:0][7:0] dq_data;
  logic [StrbWidth-1:0]      dq_lane_valid;
  logic                      dq_in_ready, dq_busy;

  if (ComputeEnable.mxdequant) begin : gen_mxdequant
    idma_otf_mxdequant #(
      .StrbWidth ( StrbWidth )
    ) i_idma_otf_mxdequant (
      .clk_i,
      .rst_ni,
      .clear_i      ( ~sel_mxdequant          ),
      .data_i       ( data_i                  ),
      .valid_i      ( valid_i & sel_mxdequant ),
      .ready_o      ( dq_in_ready             ),
      .data_o       ( dq_data                 ),
      .lane_valid_o ( dq_lane_valid           ),
      .lane_ready_i ( lane_ready_i & {StrbWidth{sel_mxdequant}} ),
      .busy_o       ( dq_busy                 )
    );
  end else begin : gen_no_mxdequant
    assign dq_data = '0; assign dq_lane_valid = '0; assign dq_in_ready = 1'b0;
    assign dq_busy = 1'b0;
  end

  // output dispatch
  always_comb begin
    data_o       = '0;
    strb_o       = '0;
    lane_valid_o = '0;
    in_ready_o   = 1'b0;
    unique case (1'b1)
      sel_transpose: begin
        data_o       = tp_data;
        strb_o       = tp_strb;
        lane_valid_o = {StrbWidth{tp_valid}};
        in_ready_o   = tp_in_ready;
      end
      sel_mxquant: begin
        data_o       = mx_data;
        strb_o       = '1;
        lane_valid_o = mx_lane_valid;
        in_ready_o   = mx_in_ready;
      end
      sel_mxdequant: begin
        data_o       = dq_data;
        strb_o       = '1;
        lane_valid_o = dq_lane_valid;
        in_ready_o   = dq_in_ready;
      end
      default: ;
    endcase
  end

  // pragma translate_off
  // backstop: the backend request interlock must never let a differing config in while busy
  always @(posedge clk_i) if (rst_ni && cfg_valid_i && (compute_i != latched_q))
    assert (!(mx_busy || dq_busy))
      else $fatal(1, "idma_otf_compute: compute config changed while an MX unit is busy");
  // pragma translate_on

endmodule : idma_otf_compute

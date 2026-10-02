// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// On-the-fly compute dispatcher. MX beats carry their config in a tag through the dataflow
/// element, are popped on the engine's registered credit and leave through whole-beat queues
/// that the write side selects per burst after the write shifter. Transpose runs on the
/// per-transfer config latch; a transpose config change drains the datapath first.
module idma_otf_compute #(
  /// Byte lanes per beat (= DataWidth/8)
  parameter int unsigned StrbWidth       = 32'd8,
  /// Compile-time per-op feature enables
  parameter idma_pkg::compute_enable_t ComputeEnable = '0,
  /// Implementation tuning knobs
  parameter idma_pkg::compute_tuning_t ComputeTuning = '1,
  /// Depth of the dataflow element (entries of the beat-tag FIFO)
  parameter int unsigned BufferDepth     = 32'd3
) (
  input  logic clk_i,
  input  logic rst_ni,

  /// Per-burst write config; valid only while `cfg_valid_i`
  input  idma_pkg::compute_options_t compute_i,
  input  logic                       cfg_valid_i,
  /// The current write burst is a transpose
  output logic                       active_o,

  /// Input beat stream (from the dataflow buffer)
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  output logic                      in_ready_o,

  /// Transpose output beat: per-lane valid (occupancy) + per-byte strobe (edge mask)
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      strb_o,
  output logic                      beat_valid_o,
  input  logic                      beat_ready_i,
  output logic [StrbWidth-1:0]      lane_valid_o,

  /// Tag of each beat pushed into byte lane 0 of the dataflow element, in lockstep with it
  input  idma_pkg::mx_tag_t         tag_i,
  input  logic                      tag_push_i,
  input  logic                      tag_pop_i,
  /// Every lane of the dataflow head holds an MX beat; it is popped by `mx_pop_o`
  input  logic                      mx_valid_i,
  output logic                      mx_pop_o,
  /// Write-shifter output; the current write burst reads an MX queue when `w_mx_o`
  input  logic [StrbWidth-1:0][7:0] w_data_i,
  input  logic [StrbWidth-1:0]      w_valid_i,
  input  logic [StrbWidth-1:0]      w_mask_i,
  output logic [StrbWidth-1:0][7:0] w_data_o,
  output logic [StrbWidth-1:0]      w_valid_o,
  output logic [StrbWidth-1:0]      w_mask_o,
  output logic                      w_mx_o,
  /// W channel ready while a write burst is open; a whole MX beat retires on it
  input  logic                      w_ready_i,
  output logic                      busy_o
);

  // transpose config latch with first-beat bypass
  idma_pkg::compute_options_t latched_q, eff_compute;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          latched_q <= '0;
    else if (cfg_valid_i) latched_q <= compute_i;
  end
  assign eff_compute = cfg_valid_i ? compute_i : latched_q;

  logic sel_transpose, w_mxq, w_mxdq;
  assign sel_transpose = eff_compute.enable & ComputeEnable.transpose &
                         (eff_compute.op == idma_pkg::COMPUTE_TRANSPOSE);
  assign w_mxq         = cfg_valid_i & compute_i.enable & ComputeEnable.mxquant &
                         (compute_i.op inside {idma_pkg::COMPUTE_MXQUANT,
                                               idma_pkg::COMPUTE_MXQUANT_FP16});
  assign w_mxdq        = cfg_valid_i & compute_i.enable & ComputeEnable.mxdequant &
                         (compute_i.op inside {idma_pkg::COMPUTE_MXDEQUANT,
                                               idma_pkg::COMPUTE_MXDEQUANT_FP16});

  assign active_o = sel_transpose;

  // transpose sub-unit
  logic [StrbWidth-1:0][7:0] tp_data;
  logic [StrbWidth-1:0]      tp_strb;
  logic                      tp_valid, tp_in_ready;

  if (ComputeEnable.transpose) begin : gen_transpose
    idma_otf_transpose #(
      .StrbWidth  ( StrbWidth                   ),
      .DimWidth   ( idma_pkg::TransposeDimWidth ),
      .FullDuplex ( ComputeTuning.transpose_full_duplex )
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
      .ready_i         ( beat_ready_i & sel_transpose            )
    );
  end else begin : gen_no_transpose
    assign tp_data = '0; assign tp_strb = '0; assign tp_valid = 1'b0; assign tp_in_ready = 1'b0;
  end

  assign data_o       = tp_data;
  assign strb_o       = tp_strb;
  assign beat_valid_o = sel_transpose & tp_valid;
  assign lane_valid_o = {StrbWidth{beat_valid_o}};
  assign in_ready_o   = sel_transpose & tp_in_ready;

  // MX beat tags
  idma_pkg::mx_tag_t tag;
  logic              tag_valid, mq_in, dq_in;

  if (ComputeEnable.mxquant || ComputeEnable.mxdequant) begin : gen_mx_tag
    cc_passthrough_stream_fifo #(
      .Depth  ( BufferDepth        ),
      .data_t ( idma_pkg::mx_tag_t )
    ) i_tag_fifo (
      .clk_i,
      .rst_ni,
      .clr_i   ( 1'b0       ),
      .flush_i ( 1'b0       ),
      .data_i  ( tag_i      ),
      .valid_i ( tag_push_i ),
      .ready_o ( /* lockstep with lane 0 */ ),
      .data_o  ( tag        ),
      .valid_o ( tag_valid  ),
      .ready_i ( tag_pop_i  )
    );
  end else begin : gen_no_mx_tag
    assign tag = '0; assign tag_valid = 1'b0;
  end

  assign mq_in = mx_valid_i & ~tag.dequant;
  assign dq_in = mx_valid_i &  tag.dequant;

  // MX quant sub-unit
  logic                      mq_valid, mq_ready, mq_busy;
  logic [StrbWidth-1:0][7:0] mq_data;

  if (ComputeEnable.mxquant) begin : gen_mxquant
    idma_otf_mxquant #(
      .StrbWidth ( StrbWidth            ),
      .Fp16En    ( ComputeEnable.mxfp16 )
    ) i_idma_otf_mxquant (
      .clk_i,
      .rst_ni,
      .data_i  ( data_i                       ),
      .tag_i   ( tag               ),
      .valid_i ( mq_in             ),
      .ready_o ( mq_ready          ),
      .data_o  ( mq_data           ),
      .valid_o ( mq_valid          ),
      .ready_i ( w_mxq & mq_valid & w_ready_i ),
      .busy_o  ( mq_busy           )
    );
  end else begin : gen_no_mxquant
    assign mq_ready = 1'b0; assign mq_data = '0; assign mq_valid = 1'b0; assign mq_busy = 1'b0;
  end

  // MX dequant sub-unit
  logic                      dq_valid, dq_pop, dq_busy;
  logic [StrbWidth-1:0][7:0] dq_data;

  if (ComputeEnable.mxdequant) begin : gen_mxdequant
    idma_otf_mxdequant #(
      .StrbWidth ( StrbWidth            ),
      .Fp16En    ( ComputeEnable.mxfp16 )
    ) i_idma_otf_mxdequant (
      .clk_i,
      .rst_ni,
      .data_i       ( data_i                                ),
      .valid_i      ( dq_in                                 ),
      .tag_i        ( tag                                   ),
      .pop_o        ( dq_pop                                ),
      .data_o       ( dq_data                               ),
      .beat_valid_o ( dq_valid                              ),
      .beat_pop_i   ( w_mxdq & dq_valid & w_ready_i         ),
      .busy_o       ( dq_busy                               )
    );
  end else begin : gen_no_mxdequant
    assign dq_data = '0; assign dq_valid = 1'b0; assign dq_pop = 1'b0; assign dq_busy = 1'b0;
  end

  // the write burst's op selects its queue, after the write shifter (MX writes are unshifted)
  assign mx_pop_o  = (mq_in & mq_ready) | dq_pop;
  assign w_mx_o    = w_mxq | w_mxdq;
  assign w_data_o  = w_mxq ? mq_data : w_mxdq ? dq_data : w_data_i;
  assign w_valid_o = w_mxq ? {StrbWidth{mq_valid}} : w_mxdq ? {StrbWidth{dq_valid}} : w_valid_i;
  assign w_mask_o  = w_mx_o ? '1 : w_mask_i;
  assign busy_o    = mq_busy | dq_busy;

  // pragma translate_off
  // an op that is not elaborated must never be presented (legalizer fence reports first)
  always @(posedge clk_i) if (rst_ni && cfg_valid_i && compute_i.enable)
    assert (idma_pkg::compute_op_supported(ComputeEnable, compute_i.op))
      else $fatal(1, "idma_otf_compute: compute op %0d not elaborated (ComputeEnable)",
                  compute_i.op);
  // E2M1 is not elaborated
  always @(posedge clk_i) if (rst_ni && mx_valid_i)
    assert (tag.elem_fmt inside {idma_pkg::MX_E5M2, idma_pkg::MX_E4M3})
      else $fatal(1, "idma_otf_compute: MX element format %0d not elaborated", tag.elem_fmt);
  // the tag FIFO holds the tag of the lane-0 head whenever an MX beat is at the head
  always @(posedge clk_i) if (rst_ni && mx_valid_i)
    assert (tag_valid && tag.mx)
      else $fatal(1, "idma_otf_compute: MX head beat without an MX tag");
  // pragma translate_on

endmodule : idma_otf_compute

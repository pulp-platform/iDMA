// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// On-the-fly compute dispatcher: tagged MX beats on registered credit, transpose on a config latch
module idma_otf_compute #(
  /// Byte lanes per beat (= DataWidth/8)
  parameter int unsigned StrbWidth       = 32'd8,
  /// Compile-time per-op feature enables
  parameter idma_pkg::compute_enable_t ComputeEnable = '0,
  /// Implementation tuning knobs
  parameter idma_pkg::compute_tuning_t ComputeTuning = '1,
  /// Input beats buffered per MX engine (dequant: three more)
  parameter int unsigned BufferDepth     = 32'd3,
  /// MX beats enter their engine through a register stage, which takes one buffered beat
  parameter bit          InReg           = 1'b0
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

  /// Whole MX beat from the read side with its tag; pushed only while `mx_ready_o`
  input  logic [StrbWidth-1:0][7:0] mx_data_i,
  input  idma_pkg::mx_tag_t         mx_tag_i,
  input  logic                      mx_push_i,
  output logic                      mx_ready_o,
  /// Write-shifter output; the current write burst reads an MX queue when `w_mx_o`
  input  logic [StrbWidth-1:0][7:0] w_data_i,
  input  logic [StrbWidth-1:0]      w_valid_i,
  input  logic [StrbWidth-1:0]      w_mask_i,
  output logic [StrbWidth-1:0][7:0] w_data_o,
  output logic [StrbWidth-1:0]      w_valid_o,
  output logic [StrbWidth-1:0]      w_mask_o,
  output logic                      w_mx_o,
  /// W beat handshake of the write port; a whole MX beat retires on it
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
  assign w_mxq         = cfg_valid_i & compute_i.enable &
                         idma_pkg::compute_op_supported(ComputeEnable, compute_i.op) &
                         (compute_i.op inside {idma_pkg::COMPUTE_MXQUANT,
                                               idma_pkg::COMPUTE_MXQUANT_FP16});
  assign w_mxdq        = cfg_valid_i & compute_i.enable &
                         idma_pkg::compute_op_supported(ComputeEnable, compute_i.op) &
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

  // the MX engines write a 64 B scale line per group; wider buses are not implemented
  if ((ComputeEnable.mxquant || ComputeEnable.mxdequant) && (StrbWidth > 64)) begin : gen_mx_width
    $fatal(1, "idma_otf_compute: MX compute needs StrbWidth <= 64, got %0d", StrbWidth);
  end

  // MX input: straight from the read side, or a register stage loaded whenever it can accept
  logic                      in_v, in_rdy, in_push, dq_ready, qb_rdy;
  logic [StrbWidth-1:0][7:0] in_data;
  idma_pkg::mx_tag_t         in_tag;
  assign in_rdy  = in_tag.dequant ? dq_ready : qb_rdy;
  assign in_push = in_v & in_rdy;

  if (InReg) begin : gen_in_reg
    logic                      v_q;
    logic [StrbWidth-1:0][7:0] data_q;
    idma_pkg::mx_tag_t         tag_q;
    assign mx_ready_o = ~v_q | in_rdy;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        v_q   <= 1'b0;
        tag_q <= '0;
      end else begin
        v_q <= mx_push_i | (v_q & ~in_rdy);
        if (mx_ready_o) tag_q <= mx_tag_i;
      end
    end
    always_ff @(posedge clk_i) if (mx_ready_o) data_q <= mx_data_i;
    assign in_v    = v_q;
    assign in_data = data_q;
    assign in_tag  = tag_q;
  end else begin : gen_in_direct
    assign mx_ready_o = in_rdy;
    assign in_v       = mx_push_i;
    assign in_data    = mx_data_i;
    assign in_tag     = mx_tag_i;
  end

  // MX quant sub-unit behind its input queue, which refills in the cycle the engine takes its head
  logic                      mq_valid, mq_ready, mq_busy, qb_v;
  logic [StrbWidth-1:0][7:0] mq_data;

  typedef struct packed {
    idma_pkg::mx_tag_t         tag;
    logic [StrbWidth-1:0][7:0] data;
  } qb_t;

  if (ComputeEnable.mxquant) begin : gen_mxquant
    qb_t [0:0] qb_in, qb_out;

    assign qb_in[0] = '{tag: in_tag, data: in_data};

    idma_dataflow_element #(
      .BufferDepth ( BufferDepth - 32'(InReg) ),
      .SameCycleRW ( 1'b1        ),
      .RegFlags    ( 1'b1        ),
      .StrbWidth   ( 32'd1       ),
      .strb_t      ( logic [0:0] ),
      .byte_t      ( qb_t        )
    ) i_mxq_in (
      .clk_i,
      .rst_ni,
      .data_i  ( qb_in                          ),
      .valid_i ( in_push & ~in_tag.dequant      ),
      .ready_o ( qb_rdy                         ),
      .ahead_i ( '0                             ),
      .data_o  ( qb_out                         ),
      .valid_o ( qb_v                           ),
      .ready_i ( qb_v & mq_ready                )
    );

    idma_otf_mxquant #(
      .StrbWidth ( StrbWidth            ),
      .Fp16En    ( ComputeEnable.mxfp16 )
    ) i_idma_otf_mxquant (
      .clk_i,
      .rst_ni,
      .data_i  ( qb_out[0].data    ),
      .tag_i   ( qb_out[0].tag     ),
      .valid_i ( qb_v              ),
      .ready_o ( mq_ready          ),
      .data_o  ( mq_data           ),
      .valid_o ( mq_valid          ),
      .ready_i ( w_mxq & mq_valid & w_ready_i ),
      .busy_o  ( mq_busy           )
    );
  end else begin : gen_no_mxquant
    assign mq_ready = 1'b0; assign mq_data = '0; assign mq_valid = 1'b0; assign mq_busy = 1'b0;
    assign qb_v     = 1'b0; assign qb_rdy  = 1'b0;
  end

  // MX dequant sub-unit
  logic                      dq_valid, dq_busy;
  logic [StrbWidth-1:0][7:0] dq_data;

  if (ComputeEnable.mxdequant) begin : gen_mxdequant
    idma_otf_mxdequant #(
      .StrbWidth ( StrbWidth            ),
      .Fp16En    ( ComputeEnable.mxfp16 ),
      .InDepth   ( BufferDepth + 32'd3 - 32'(InReg) )
    ) i_idma_otf_mxdequant (
      .clk_i,
      .rst_ni,
      .data_i       ( in_data                               ),
      .valid_i      ( in_push & in_tag.dequant              ),
      .tag_i        ( in_tag                                ),
      .ready_o      ( dq_ready                              ),
      .data_o       ( dq_data                               ),
      .beat_valid_o ( dq_valid                              ),
      .beat_pop_i   ( w_mxdq & dq_valid & w_ready_i         ),
      .busy_o       ( dq_busy                               )
    );
  end else begin : gen_no_mxdequant
    assign dq_data = '0; assign dq_valid = 1'b0; assign dq_ready = 1'b0; assign dq_busy = 1'b0;
  end

  // the write burst's op selects its queue, after the write shifter (MX writes are unshifted)
  assign w_mx_o    = w_mxq | w_mxdq;
  assign w_data_o  = w_mxq ? mq_data : w_mxdq ? dq_data : w_data_i;
  assign w_valid_o = w_mxq ? {StrbWidth{mq_valid}} : w_mxdq ? {StrbWidth{dq_valid}} : w_valid_i;
  assign w_mask_o  = w_mx_o ? '1 : w_mask_i;
  assign busy_o    = in_v | qb_v | mq_busy | dq_busy;

  // pragma translate_off
  // an op that is not elaborated must never be presented (legalizer fence reports first)
  always @(posedge clk_i) if (rst_ni && cfg_valid_i && compute_i.enable)
    assert (idma_pkg::compute_op_supported(ComputeEnable, compute_i.op))
      else $fatal(1, "idma_otf_compute: compute op %0d not elaborated (ComputeEnable)",
                  compute_i.op);
  // E2M1 is not elaborated
  always @(posedge clk_i) if (rst_ni && mx_push_i)
    assert (mx_tag_i.mx && (mx_tag_i.elem_fmt inside {idma_pkg::MX_E5M2, idma_pkg::MX_E4M3}))
      else $fatal(1, "idma_otf_compute: MX element format %0d not elaborated", mx_tag_i.elem_fmt);
  always @(posedge clk_i) if (rst_ni && mx_push_i)
    assert (mx_ready_o) else $fatal(1, "idma_otf_compute: MX beat pushed while not ready");
  // pragma translate_on

endmodule : idma_otf_compute

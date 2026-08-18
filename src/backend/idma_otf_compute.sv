// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// On-the-fly compute dispatcher: routes one op per transfer to its sub-unit.
/// A config change drains the engine before the next transfer starts. The
/// transpose and MX units consume whole beats; the ALU handshakes per lane.
module idma_otf_compute #(
  /// Byte lanes per beat (= DataWidth/8)
  parameter int unsigned StrbWidth       = 32'd8,
  /// Compile-time per-op feature enables
  parameter idma_pkg::compute_enable_t ComputeEnable = '0,
  /// Implementation tuning knobs
  parameter idma_pkg::compute_tuning_t ComputeTuning = '1,
  /// Operand streams presented on `data_i` (2: a second, lane-aligned stream for dual ops)
  parameter int unsigned NumOperands = 32'd1
) (
  input  logic clk_i,
  input  logic rst_ni,

  /// Per-transfer compute config; valid only while `cfg_valid_i`
  input  idma_pkg::compute_options_t compute_i,
  input  logic                       cfg_valid_i,
  /// A supported compute op is armed for this transfer
  output logic                       active_o,

  /// Input beat stream(s) (from the dataflow buffers): per-lane valid/ready of the joined beat
  input  logic [NumOperands*StrbWidth-1:0][7:0] data_i,
  input  logic [StrbWidth-1:0]                  lane_valid_i,
  output logic [StrbWidth-1:0]                  lane_ready_o,

  /// Output beat stream: per-lane valid (occupancy) + per-byte strobe (edge mask)
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      strb_o,
  output logic [StrbWidth-1:0]      lane_valid_o,
  input  logic                      ready_i,
  input  logic [StrbWidth-1:0]      lane_ready_i
);

  // config latch with first-beat bypass
  idma_pkg::compute_options_t latched_q, eff_compute;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          latched_q <= '0;
    else if (cfg_valid_i) latched_q <= compute_i;
  end
  assign eff_compute = cfg_valid_i ? compute_i : latched_q;

  // per-op select: one legality predicate, then route by op
  logic op_legal, sel_transpose, sel_mxquant, sel_mxdequant, sel_alu, sel_cast;
  idma_pkg::mx_fmt_e mx_fmt;
  assign op_legal      = eff_compute.enable &
                         idma_pkg::compute_op_supported(ComputeEnable, eff_compute);
  assign sel_transpose = op_legal & (eff_compute.op == idma_pkg::COMPUTE_TRANSPOSE);
  assign sel_mxquant   = op_legal & (eff_compute.op inside {idma_pkg::COMPUTE_MXQUANT,
                                                            idma_pkg::COMPUTE_MXQUANT_FP16});
  assign sel_mxdequant = op_legal & (eff_compute.op inside {idma_pkg::COMPUTE_MXDEQUANT,
                                                            idma_pkg::COMPUTE_MXDEQUANT_FP16});
  assign sel_alu       = op_legal & (eff_compute.op == idma_pkg::COMPUTE_ALU);
  assign sel_cast      = op_legal & idma_pkg::compute_op_is_cast(eff_compute.op);
  assign mx_fmt        = idma_pkg::compute_op_fmt(eff_compute.op);

  assign active_o = op_legal;

  // the transpose and MX units consume whole beats
  logic beat_valid;
  assign beat_valid = &lane_valid_i;

  // operand split: a is always present, b only when a second stream is elaborated
  logic [StrbWidth-1:0][7:0] data_a, data_b;
  assign data_a = data_i[StrbWidth-1:0];
  if (NumOperands > 1) begin : gen_operand_b
    assign data_b = data_i[2*StrbWidth-1:StrbWidth];
  end else begin : gen_no_operand_b
    assign data_b = '0;
  end

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
      .data_i          ( data_a                                  ),
      .valid_i         ( beat_valid & sel_transpose              ),
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
      .StrbWidth ( StrbWidth            ),
      .Fp16En    ( ComputeEnable.mxfp16 )
    ) i_idma_otf_mxquant (
      .clk_i,
      .rst_ni,
      .clear_i      ( ~sel_mxquant          ),
      .src_fmt_i    ( mx_fmt                ),
      .data_i       ( data_a                ),
      .valid_i      ( beat_valid & sel_mxquant ),
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
      .StrbWidth ( StrbWidth            ),
      .Fp16En    ( ComputeEnable.mxfp16 )
    ) i_idma_otf_mxdequant (
      .clk_i,
      .rst_ni,
      .clear_i      ( ~sel_mxdequant          ),
      .dst_fmt_i    ( mx_fmt                  ),
      .data_i       ( data_a                  ),
      .valid_i      ( beat_valid & sel_mxdequant ),
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

  // ALU sub-unit
  logic [StrbWidth-1:0][7:0] alu_data;
  logic [StrbWidth-1:0]      alu_lane_valid, alu_lane_ready;

  if (ComputeEnable.alu) begin : gen_alu
    idma_otf_alu #(
      .StrbWidth ( StrbWidth             ),
      .MulEn     ( ComputeEnable.alu_mul )
    ) i_idma_otf_alu (
      .func_i       ( eff_compute.params.alu.func ),
      .imm_i        ( eff_compute.params.alu.imm  ),
      .data_i       ( data_a                      ),
      .lane_valid_i ( lane_valid_i & {StrbWidth{sel_alu}} ),
      .lane_ready_o ( alu_lane_ready              ),
      .data_b_i     ( data_b                      ),
      .data_o       ( alu_data                    ),
      .lane_valid_o ( alu_lane_valid              ),
      .lane_ready_i ( lane_ready_i & {StrbWidth{sel_alu}} )
    );
  end else begin : gen_no_alu
    assign alu_data = '0; assign alu_lane_valid = '0; assign alu_lane_ready = '0;
  end

  // element-cast sub-unit
  logic [StrbWidth-1:0][7:0] fc_data;
  logic [StrbWidth-1:0]      fc_lane_valid;
  logic                      fc_in_ready, fc_busy;

  if (ComputeEnable.fpcast) begin : gen_fpcast
    idma_otf_fpcast #(
      .StrbWidth ( StrbWidth )
    ) i_idma_otf_fpcast (
      .clk_i,
      .rst_ni,
      .clear_i      ( ~sel_cast              ),
      .op_i         ( eff_compute.op         ),
      .data_i       ( data_a                 ),
      .valid_i      ( beat_valid & sel_cast  ),
      .ready_o      ( fc_in_ready            ),
      .data_o       ( fc_data                ),
      .lane_valid_o ( fc_lane_valid          ),
      .lane_ready_i ( lane_ready_i & {StrbWidth{sel_cast}} ),
      .busy_o       ( fc_busy                )
    );
  end else begin : gen_no_fpcast
    assign fc_data = '0; assign fc_lane_valid = '0; assign fc_in_ready = 1'b0;
    assign fc_busy = 1'b0;
  end

  // output dispatch, routed per opcode
  always_comb begin
    data_o       = '0;
    strb_o       = '0;
    lane_valid_o = '0;
    lane_ready_o = '0;
    if (op_legal) begin
      unique case (eff_compute.op)
        idma_pkg::COMPUTE_TRANSPOSE: begin
          data_o       = tp_data;
          strb_o       = tp_strb;
          lane_valid_o = {StrbWidth{tp_valid}};
          lane_ready_o = {StrbWidth{beat_valid & tp_in_ready}};
        end
        idma_pkg::COMPUTE_MXQUANT,
        idma_pkg::COMPUTE_MXQUANT_FP16: begin
          data_o       = mx_data;
          strb_o       = '1;
          lane_valid_o = mx_lane_valid;
          lane_ready_o = {StrbWidth{beat_valid & mx_in_ready}};
        end
        idma_pkg::COMPUTE_MXDEQUANT,
        idma_pkg::COMPUTE_MXDEQUANT_FP16: begin
          data_o       = dq_data;
          strb_o       = '1;
          lane_valid_o = dq_lane_valid;
          lane_ready_o = {StrbWidth{beat_valid & dq_in_ready}};
        end
        idma_pkg::COMPUTE_ALU: begin
          data_o       = alu_data;
          strb_o       = '1;
          lane_valid_o = alu_lane_valid;
          lane_ready_o = alu_lane_ready;
        end
        idma_pkg::COMPUTE_CAST_FP32_I8,
        idma_pkg::COMPUTE_CAST_FP32_I16,
        idma_pkg::COMPUTE_CAST_FP32_BF16,
        idma_pkg::COMPUTE_CAST_BF16_I8,
        idma_pkg::COMPUTE_CAST_BF16_I16,
        idma_pkg::COMPUTE_CAST_BF16_FP32,
        idma_pkg::COMPUTE_CAST_FP16_FP32: begin
          data_o       = fc_data;
          strb_o       = '1;
          lane_valid_o = fc_lane_valid;
          lane_ready_o = {StrbWidth{beat_valid & fc_in_ready}};
        end
        default: ;
      endcase
    end
  end

  // pragma translate_off
  // an op that is not elaborated must never be presented (legalizer fence reports first)
  always @(posedge clk_i) if (rst_ni && cfg_valid_i && compute_i.enable)
    assert (idma_pkg::compute_op_supported(ComputeEnable, compute_i))
      else $fatal(1, "idma_otf_compute: compute op %0d not elaborated (ComputeEnable)",
                  compute_i.op);
  // a two-operand op needs the second stream elaborated (legalizer fence reports first)
  always @(posedge clk_i) if (rst_ni && cfg_valid_i && compute_i.enable)
    assert (idma_pkg::compute_operands(compute_i) <= NumOperands)
      else $fatal(1, "idma_otf_compute: two-operand op without a second operand stream");
  // backstop: the backend request interlock must never let a differing config in while busy
  always @(posedge clk_i) if (rst_ni && cfg_valid_i && (compute_i != latched_q))
    assert (!(mx_busy || dq_busy || fc_busy))
      else $fatal(1, "idma_otf_compute: compute config changed while a unit is busy");
  // pragma translate_on

endmodule : idma_otf_compute

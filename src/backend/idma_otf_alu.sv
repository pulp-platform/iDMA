// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Byte-wise SIMD ALU: every byte lane is an independent 8-bit operand, arithmetic
/// wraps modulo 256. Combinational per lane, so valid/ready pass through lane by lane
/// and any alignment or tail beat is handled by the dataflow buffer as in a plain copy.
module idma_otf_alu #(
  /// Byte lanes per beat (= DataWidth/8)
  parameter int unsigned StrbWidth = 32'd8,
  /// Elaborate the multiplier (ALU_MULI); without it the function is a pass-through
  parameter bit          MulEn     = 1'b0
) (
  /// Function and byte immediate, stable for the transfer
  input  idma_pkg::alu_func_e             func_i,
  input  logic [idma_pkg::AluImmWidth-1:0] imm_i,

  /// Input beat stream, per-lane handshake
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic [StrbWidth-1:0]      lane_valid_i,
  output logic [StrbWidth-1:0]      lane_ready_o,

  /// Output beat stream, per-lane handshake
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      lane_valid_o,
  input  logic [StrbWidth-1:0]      lane_ready_i
);

  always_comb begin
    for (int unsigned j = 0; j < StrbWidth; j++) begin
      unique case (func_i)
        idma_pkg::ALU_NOT:  data_o[j] = ~data_i[j];
        idma_pkg::ALU_ADDI: data_o[j] = data_i[j] + imm_i;
        idma_pkg::ALU_SUBI: data_o[j] = data_i[j] - imm_i;
        idma_pkg::ALU_MULI: data_o[j] = MulEn ? 8'(data_i[j] * imm_i) : data_i[j];
        idma_pkg::ALU_ANDI: data_o[j] = data_i[j] & imm_i;
        idma_pkg::ALU_ORI:  data_o[j] = data_i[j] | imm_i;
        idma_pkg::ALU_XORI: data_o[j] = data_i[j] ^ imm_i;
        default:            data_o[j] = data_i[j];
      endcase
    end
  end

  assign lane_valid_o = lane_valid_i;
  assign lane_ready_o = lane_ready_i;

endmodule : idma_otf_alu

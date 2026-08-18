// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// On-the-fly element cast: every input beat converts its FP32/BF16/FP16 elements to
/// INT8/INT16/BF16/FP32 and the converted bytes are packed contiguously into a
/// two-beat buffer that drains through StrbWidth-wide output beats. Beats are whole
/// (beat-aligned addresses, beat-multiple length), so no element straddles a beat.
module idma_otf_fpcast
  import idma_float_pkg::*;
#(
  parameter int unsigned StrbWidth = 32'd8
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  /// Cast op, stable for the transfer
  input  idma_pkg::compute_op_e op_i,

  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  output logic                      ready_o,

  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      lane_valid_o,
  /// Byte lanes the write accepted this cycle; the pack pops exactly these
  input  logic [StrbWidth-1:0]      lane_ready_i,
  output logic                      busy_o
);

  initial assert (StrbWidth >= 4 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_fpcast: StrbWidth (%0d) must be a power of two >= 4", StrbWidth);

  // an expanding beat yields two beats, so the pack holds two and accepts when it fits
  localparam int unsigned BufSize     = 2 * StrbWidth;
  localparam int unsigned OffsetWidth = $clog2(BufSize) + 1;
  localparam int unsigned PopW        = $clog2(StrbWidth + 1);
  localparam int unsigned Elems32     = StrbWidth / 4;
  localparam int unsigned Elems16     = StrbWidth / 2;

  logic [            7:0] pack_q [BufSize];
  logic [OffsetWidth-1:0] pack_off_q;
  logic [            7:0] pack_d [BufSize];
  logic [OffsetWidth-1:0] pack_off_d;

  // per op: element sizes and the converted bytes of this beat, packed from lane 0
  logic [OffsetWidth-1:0] out_bytes;
  logic [BufSize-1:0][7:0] conv;
  always_comb begin
    conv      = '0;
    out_bytes = '0;
    unique case (op_i)
      idma_pkg::COMPUTE_CAST_FP32_I8: begin
        out_bytes = OffsetWidth'(Elems32);
        for (int e = 0; e < Elems32; e++)
          conv[e] = 8'(fp32_to_int_rne_sat(data_i[e*4 +: 4], 32'd8));
      end
      idma_pkg::COMPUTE_CAST_FP32_I16: begin
        out_bytes = OffsetWidth'(2 * Elems32);
        for (int e = 0; e < Elems32; e++)
          conv[e*2 +: 2] = 16'(fp32_to_int_rne_sat(data_i[e*4 +: 4], 32'd16));
      end
      idma_pkg::COMPUTE_CAST_FP32_BF16: begin
        out_bytes = OffsetWidth'(2 * Elems32);
        for (int e = 0; e < Elems32; e++)
          conv[e*2 +: 2] = fp32_bits_to_bf16(data_i[e*4 +: 4]);
      end
      idma_pkg::COMPUTE_CAST_BF16_I8: begin
        out_bytes = OffsetWidth'(Elems16);
        for (int e = 0; e < Elems16; e++)
          conv[e] = 8'(fp32_to_int_rne_sat(bf16_bits_to_fp32(data_i[e*2 +: 2]), 32'd8));
      end
      idma_pkg::COMPUTE_CAST_BF16_I16: begin
        out_bytes = OffsetWidth'(2 * Elems16);
        for (int e = 0; e < Elems16; e++)
          conv[e*2 +: 2] = 16'(fp32_to_int_rne_sat(bf16_bits_to_fp32(data_i[e*2 +: 2]), 32'd16));
      end
      idma_pkg::COMPUTE_CAST_BF16_FP32: begin
        out_bytes = OffsetWidth'(4 * Elems16);
        for (int e = 0; e < Elems16; e++)
          conv[e*4 +: 4] = bf16_bits_to_fp32(data_i[e*2 +: 2]);
      end
      idma_pkg::COMPUTE_CAST_FP16_FP32: begin
        out_bytes = OffsetWidth'(4 * Elems16);
        for (int e = 0; e < Elems16; e++)
          conv[e*4 +: 4] = fp16_bits_to_fp32(data_i[e*2 +: 2]);
      end
      default: ;
    endcase
  end

  // lane-exact pop: a tail beat pops only its own bytes
  logic [PopW-1:0] pop_cnt;
  always_comb begin
    pop_cnt = '0;
    for (int i = 0; i < StrbWidth; i++)
      if (lane_ready_i[i] && lane_valid_o[i]) pop_cnt += PopW'(1);
  end

  assign busy_o = (pack_off_q != '0);

  logic                 accept;
  logic [BufSize*8-1:0] ins_vec;
  logic [BufSize-1:0]   ins_mask;
  always_comb begin
    for (int i = 0; i < BufSize; i++) pack_d[i] = pack_q[i];
    pack_off_d = pack_off_q;

    if (pop_cnt != '0) begin
      for (int i = 0; i < BufSize; i++)
        pack_d[i] = ((i + 32'(pop_cnt)) < BufSize) ? pack_q[i + 32'(pop_cnt)] : 8'd0;
      pack_off_d = (pack_off_d > OffsetWidth'(pop_cnt)) ? OffsetWidth'(pack_off_d - pop_cnt) : '0;
    end

    ready_o = (32'(pack_off_d) + 32'(out_bytes)) <= BufSize;
    accept  = valid_i && ready_o;

    // insert this beat's converted bytes at the post-pop write offset
    ins_vec  = (BufSize*8)'(conv) << {pack_off_d, 3'b000};
    ins_mask = ~({BufSize{1'b1}} << out_bytes) << pack_off_d;
    if (accept) begin
      for (int i = 0; i < BufSize; i++)
        if (ins_mask[i]) pack_d[i] = ins_vec[i*8 +: 8];
      pack_off_d = pack_off_d + out_bytes;
    end
  end

  for (genvar i = 0; i < StrbWidth; i++) begin : gen_out
    assign lane_valid_o[i] = (OffsetWidth'(i) < pack_off_q);
    assign data_o[i]       = lane_valid_o[i] ? pack_q[i] : 8'd0;
  end

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni)
    assert (32'(pop_cnt) <= 32'(pack_off_q))
      else $fatal(1, "idma_otf_fpcast: pop exceeds pack occupancy");
  // NOT IMPLEMENTED: overlapping compute transfers (a clear must never drop in-flight state)
  always @(posedge clk_i) if (rst_ni && clear_i)
    assert (pack_off_q == '0)
      else $fatal(1, "idma_otf_fpcast: clear with in-flight state (overlapping transfers)");
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pack_off_q <= '0;
      for (int i = 0; i < BufSize; i++) pack_q[i] <= 8'd0;
    end else if (clear_i) begin
      pack_off_q <= '0;
    end else begin
      pack_off_q <= pack_off_d;
      for (int i = 0; i < BufSize; i++) pack_q[i] <= pack_d[i];
    end
  end

endmodule : idma_otf_fpcast

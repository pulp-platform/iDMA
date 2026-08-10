// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// On-the-fly MX quantization sub-unit for the iDMA compute seam. Collects a
// 32-element block over the input beats (FP32 4B/elem, FP16 2B/elem widened to
// FP32), quantizes to one 33B MX block ([1B E8M0 scale][32B E5M2]) and packs it
// into StrbWidth-wide output beats. lane_valid_o reports pack occupancy per
// lane; the write manager's own beat mask decides acceptance, so a partial
// presentation can only ever complete the transfer's genuine tail beat.
// Adapted from pulp-platform/vidma hw/vidma/idma_otf_mxquant.sv. FP16 requires
// StrbWidth <= 64 (<=1 block completes per beat).
module idma_otf_mxquant
  import idma_mxquant_pkg::*;
#(
  parameter int unsigned StrbWidth = 32'd8
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  input  logic src_fp16_i,

  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  output logic                      ready_o,

  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      lane_valid_o,
  /// Byte lanes the write accepted this cycle; the pack pops exactly these
  input  logic [StrbWidth-1:0]      lane_ready_i,
  output logic                      busy_o
);

  // FP32 packs one block per beat up to StrbWidth 128; FP16 above 64 is rejected by the legalizer
  initial assert (StrbWidth >= 4 && StrbWidth <= 128 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_mxquant: StrbWidth (%0d) must be a power of two in [4, 128]", StrbWidth);

  localparam int unsigned BufSize     = MxCompressedBlockBytes + StrbWidth;
  localparam int unsigned OffsetWidth = $clog2(BufSize) + 1;
  localparam int unsigned ElemsFP32   = StrbWidth / 4;
  localparam int unsigned ElemsFP16   = StrbWidth / 2;
  localparam int unsigned FillW       = $clog2(MxBlockSize) + 1;

  logic [31:0]      elem_q [MxBlockSize];
  logic [FillW-1:0] fill_q;
  logic [31:0]      elem_d [MxBlockSize];
  logic [FillW-1:0] fill_d;

  logic [            7:0] pack_q [BufSize];
  logic [OffsetWidth-1:0] pack_off_q;
  logic [            7:0] pack_d [BufSize];
  logic [OffsetWidth-1:0] pack_off_d;
  logic [StrbWidth-1:0][7:0] data_o_d;
  logic [StrbWidth-1:0]      lane_valid_d;

  // lane-exact pop: a tail beat pops only its own bytes, keeping any follow-on
  // transfer's data intact (same-config back-to-back streaming)
  int unsigned pop_cnt;
  always_comb begin
    pop_cnt = 0;
    for (int i = 0; i < StrbWidth; i++)
      if (lane_ready_i[i] && lane_valid_o[i]) pop_cnt++;
  end

  assign busy_o = (fill_q != '0) || (pack_off_q != '0);

  // widen this beat's elements to FP32; mark valid iff all source bytes valid
  logic [31:0]          in_elem [ElemsFP16];
  logic [ElemsFP16-1:0] elem_valid;
  always_comb begin
    for (int e = 0; e < ElemsFP16; e++) begin
      if (src_fp16_i) begin
        in_elem[e]    = fp16_bits_to_fp32({data_i[e*2+1], data_i[e*2]});
        elem_valid[e] = valid_i;
      end else if (e < ElemsFP32) begin
        in_elem[e]    = {data_i[e*4+3], data_i[e*4+2], data_i[e*4+1], data_i[e*4]};
        elem_valid[e] = valid_i;
      end else begin
        in_elem[e]    = 32'd0;
        elem_valid[e] = 1'b0;
      end
    end
  end

  logic       can_accept;
  logic       blk_completing;
  logic [7:0] blk_scale;

  assign blk_completing =
      (32'(fill_q) + (src_fp16_i ? ElemsFP16 : ElemsFP32)) >= MxBlockSize;

  always_comb begin
    for (int i = 0; i < MxBlockSize; i++) elem_d[i] = elem_q[i];
    fill_d = fill_q;
    for (int i = 0; i < BufSize; i++) pack_d[i] = pack_q[i];
    pack_off_d = pack_off_q;
    blk_scale  = '0;

    if (pop_cnt > 0) begin
      for (int i = 0; i < BufSize; i++)
        pack_d[i] = ((i + pop_cnt) < BufSize) ? pack_q[i+pop_cnt] : 8'd0;
      pack_off_d = (pack_off_d > OffsetWidth'(pop_cnt)) ? OffsetWidth'(pack_off_d - pop_cnt) : '0;
    end

    // pack space (one 33B block; <=1 completes per beat) is only needed on a completing beat
    can_accept = (pack_off_d + OffsetWidth'(MxCompressedBlockBytes)) <= OffsetWidth'(BufSize)
                 || !blk_completing;
    if (valid_i && can_accept) begin
      for (int e = 0; e < ElemsFP16; e++) begin
        if (elem_valid[e]) begin
          elem_d[fill_d[$clog2(MxBlockSize)-1:0]] = in_elem[e];
          if (fill_d == FillW'(MxBlockSize-1)) begin
            blk_scale = compute_block_scale_with_bias(elem_d, E5m2Bias);
            pack_d[pack_off_d[OffsetWidth-2:0]] = blk_scale;
            pack_off_d = OffsetWidth'(pack_off_d + 1);
            for (int i = 0; i < MxBlockSize; i++) begin
              pack_d[pack_off_d[OffsetWidth-2:0]] =
                  fp32_to_mxfp8_byte_prescaled(elem_d[i], decode_signed_scale(blk_scale));
              pack_off_d = OffsetWidth'(pack_off_d + 1);
            end
            fill_d = '0;
          end else begin
            fill_d = fill_d + FillW'(1);
          end
        end
      end
    end

    // present pack occupancy per lane; the write mask gates full vs. tail beats
    data_o_d     = '0;
    lane_valid_d = '0;
    for (int i = 0; i < StrbWidth; i++) begin
      if (i < pack_off_d) begin
        data_o_d[i]     = pack_d[i];
        lane_valid_d[i] = 1'b1;
      end
    end

    ready_o = can_accept;
  end

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni)
    assert (pack_off_d <= OffsetWidth'(BufSize))
      else $fatal(1, "idma_otf_mxquant: pack-buffer overflow (StrbWidth=%0d)", StrbWidth);
  always @(posedge clk_i) if (rst_ni)
    assert (32'(pop_cnt) <= 32'(pack_off_q))
      else $fatal(1, "idma_otf_mxquant: pop exceeds pack occupancy");
  // NOT IMPLEMENTED: overlapping compute transfers (a clear must never drop in-flight state)
  always @(posedge clk_i) if (rst_ni && clear_i)
    assert ((fill_q == '0) && (pack_off_q == '0))
      else $fatal(1, "idma_otf_mxquant: clear with in-flight state (overlapping transfers)");
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fill_q <= '0; pack_off_q <= '0;
      for (int i = 0; i < MxBlockSize; i++) elem_q[i] <= 32'd0;
      for (int i = 0; i < BufSize; i++)     pack_q[i] <= 8'd0;
      data_o <= '0; lane_valid_o <= '0;
    end else if (clear_i) begin
      fill_q <= '0; pack_off_q <= '0;
      data_o <= '0; lane_valid_o <= '0;
    end else begin
      for (int i = 0; i < MxBlockSize; i++) elem_q[i] <= elem_d[i];
      fill_q <= fill_d;
      for (int i = 0; i < BufSize; i++)     pack_q[i] <= pack_d[i];
      pack_off_q <= pack_off_d;
      data_o       <= data_o_d;
      lane_valid_o <= lane_valid_d;
    end
  end

endmodule : idma_otf_mxquant

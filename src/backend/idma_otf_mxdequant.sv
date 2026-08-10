// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// On-the-fly MX dequantization sub-unit: collects 33B MX blocks
// ([1B E8M0 scale][32B E5M2]) from the input beats and expands each to 32 FP32
// (128B) in the pack buffer. Input length must be beat-aligned (33k % StrbWidth
// == 0, i.e. k blocks with k % StrbWidth == 0); output (128k) is then always
// whole beats, so only full beats are ever presented.
module idma_otf_mxdequant
  import idma_mxquant_pkg::*;
#(
  parameter int unsigned StrbWidth = 32'd8
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,

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
      $fatal(1, "idma_otf_mxdequant: StrbWidth (%0d) must be a power of two >= 4", StrbWidth);

  // one expanded-block window of headroom lets the collector refill while the pack drains
  localparam int unsigned MaxBlkPerBeat = (StrbWidth + 32) / 33;
  localparam int unsigned BufSize       = 128 * MaxBlkPerBeat + 128;
  localparam int unsigned OffsetWidth   = $clog2(BufSize) + 1;
  localparam int unsigned BlkW          = $clog2(MxCompressedBlockBytes) + 1;

  logic [7:0]      blk_q [MxCompressedBlockBytes];
  logic [BlkW-1:0] blk_fill_q;
  logic [7:0]      blk_d [MxCompressedBlockBytes];
  logic [BlkW-1:0] blk_fill_d;

  logic [            7:0] pack_q [BufSize];
  logic [OffsetWidth-1:0] pack_off_q;
  logic [            7:0] pack_d [BufSize];
  logic [OffsetWidth-1:0] pack_off_d;
  logic [StrbWidth-1:0][7:0] data_o_d;
  logic [StrbWidth-1:0]      lane_valid_d;

  int unsigned pop_cnt;
  always_comb begin
    pop_cnt = 0;
    for (int i = 0; i < StrbWidth; i++)
      if (lane_ready_i[i] && lane_valid_o[i]) pop_cnt++;
  end

  assign busy_o = (blk_fill_q != '0) || (pack_off_q != '0);

  logic        can_accept;
  logic        blk_completing;
  logic [31:0] fp32;
  int          dec_scale;

  assign blk_completing = (32'(blk_fill_q) + StrbWidth) >= MxCompressedBlockBytes;

  always_comb begin
    for (int i = 0; i < MxCompressedBlockBytes; i++) blk_d[i] = blk_q[i];
    blk_fill_d = blk_fill_q;
    for (int i = 0; i < BufSize; i++) pack_d[i] = pack_q[i];
    pack_off_d = pack_off_q;
    fp32       = '0;
    dec_scale  = 0;

    if (pop_cnt > 0) begin
      for (int i = 0; i < BufSize; i++)
        pack_d[i] = ((i + pop_cnt) < BufSize) ? pack_q[i+pop_cnt] : 8'd0;
      pack_off_d = (pack_off_d > OffsetWidth'(pop_cnt)) ? OffsetWidth'(pack_off_d - pop_cnt) : '0;
    end

    // pack space is only needed on a block-completing beat
    can_accept = (pack_off_d + OffsetWidth'(128 * MaxBlkPerBeat)) <= OffsetWidth'(BufSize)
                 || !blk_completing;
    if (valid_i && can_accept) begin
      for (int b = 0; b < StrbWidth; b++) begin
        blk_d[blk_fill_d[BlkW-2:0]] = data_i[b];
        if (blk_fill_d == BlkW'(MxCompressedBlockBytes - 1)) begin
          dec_scale = decode_signed_scale(blk_d[0]);
          for (int e = 0; e < MxBlockSize; e++) begin
            fp32 = mxfp8_byte_to_fp32_prescaled(blk_d[e+1], dec_scale);
            pack_d[pack_off_d[OffsetWidth-2:0]]     = fp32[7:0];
            pack_d[pack_off_d[OffsetWidth-2:0] + 1] = fp32[15:8];
            pack_d[pack_off_d[OffsetWidth-2:0] + 2] = fp32[23:16];
            pack_d[pack_off_d[OffsetWidth-2:0] + 3] = fp32[31:24];
            pack_off_d = OffsetWidth'(pack_off_d + 4);
          end
          blk_fill_d = '0;
        end else begin
          blk_fill_d = blk_fill_d + BlkW'(1);
        end
      end
    end

    data_o_d     = '0;
    lane_valid_d = '0;
    if (pack_off_d >= OffsetWidth'(StrbWidth)) begin
      for (int i = 0; i < StrbWidth; i++) data_o_d[i] = pack_d[i];
      lane_valid_d = '1;
    end

    ready_o = can_accept;
  end

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni)
    assert (pack_off_d <= OffsetWidth'(BufSize))
      else $fatal(1, "idma_otf_mxdequant: pack-buffer overflow (StrbWidth=%0d)", StrbWidth);
  // pragma translate_on

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni)
    assert (32'(pop_cnt) <= 32'(pack_off_q))
      else $fatal(1, "idma_otf_mxdequant: pop exceeds pack occupancy");
  // NOT IMPLEMENTED: overlapping compute transfers (a clear must never drop in-flight state)
  always @(posedge clk_i) if (rst_ni && clear_i)
    assert ((blk_fill_q == '0) && (pack_off_q == '0))
      else $fatal(1, "idma_otf_mxdequant: clear with in-flight state (overlapping transfers)");
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      blk_fill_q <= '0; pack_off_q <= '0;
      for (int i = 0; i < MxCompressedBlockBytes; i++) blk_q[i] <= 8'd0;
      for (int i = 0; i < BufSize; i++)                pack_q[i] <= 8'd0;
      data_o <= '0; lane_valid_o <= '0;
    end else if (clear_i) begin
      blk_fill_q <= '0; pack_off_q <= '0;
      data_o <= '0; lane_valid_o <= '0;
    end else begin
      for (int i = 0; i < MxCompressedBlockBytes; i++) blk_q[i] <= blk_d[i];
      blk_fill_q <= blk_fill_d;
      for (int i = 0; i < BufSize; i++)                pack_q[i] <= pack_d[i];
      pack_off_q <= pack_off_d;
      data_o       <= data_o_d;
      lane_valid_o <= lane_valid_d;
    end
  end

endmodule : idma_otf_mxdequant

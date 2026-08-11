// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// On-the-fly MX dequantization sub-unit: collects 33B MX blocks
// ([1B E8M0 scale][32B E5M2]) from the input beats and expands one block per
// cycle (drain-bound: 33B in -> 128B out, so throughput-neutral) into a 256B
// circular pack buffer. Input length must be beat-aligned (33k % StrbWidth
// == 0); output (128k) is then always whole beats, so only full beats are
// ever presented.
module idma_otf_mxdequant
  import idma_mxquant_pkg::*;
#(
  parameter int unsigned StrbWidth = 32'd8,
  parameter bit          Fp16En    = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,
  /// Expand to FP16 (64B/block) instead of FP32 (128B/block)
  input  logic dst_fp16_i,

  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  output logic                      ready_o,

  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      lane_valid_o,
  /// Byte lanes the write accepted this cycle; the pack pops exactly these
  input  logic [StrbWidth-1:0]      lane_ready_i,
  output logic                      busy_o
);

  initial assert (StrbWidth >= 4 && StrbWidth <= 128 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_mxdequant: StrbWidth (%0d) must be a power of two in [4,128]", StrbWidth);

  localparam int unsigned NB      = MxCompressedBlockBytes;  // 33
  localparam int unsigned XB      = 4 * MxBlockSize;         // 128 expanded bytes per block
  localparam int unsigned XBW     = $clog2(XB);
  localparam int unsigned BufSize = 2 * XB;                  // pow2 -> free circular wrap
  localparam int unsigned PtrW    = $clog2(BufSize);
  localparam int unsigned OccW    = PtrW + 1;
  localparam int unsigned IcW     = $clog2(StrbWidth) + 1;
  localparam int unsigned IW      = StrbWidth * 8;
  localparam int unsigned TFW     = NB * 8;
  localparam int unsigned PW      = (IW > TFW) ? IW : TFW;

  // input staging beat + 33B block collector
  logic [StrbWidth-1:0][7:0] in_q;
  logic [IcW-1:0]            in_cnt_q, in_cnt_d;
  logic [NB-1:0][7:0]        blk_q, blk_d;
  logic [5:0]                fill_q, fill_d;

  // circular pack buffer: rd pointer + occupancy instead of a shift-down array
  logic [BufSize-1:0][7:0] pack_q;
  logic [PtrW-1:0]         rd_q;
  logic [OccW-1:0]         occ_q, occ_d;

  logic [IcW-1:0] pop_cnt;
  always_comb begin
    pop_cnt = '0;
    for (int i = 0; i < StrbWidth; i++)
      if (lane_ready_i[i] && lane_valid_o[i]) pop_cnt += IcW'(1);
  end

  logic [PtrW-1:0] rd_a;
  logic [OccW-1:0] occ_a;
  assign rd_a  = rd_q + PtrW'(pop_cnt);
  assign occ_a = occ_q - OccW'(pop_cnt);

  logic [7:0] total, rem;
  logic [5:0] need;
  logic       can_insert, do_expand, absorb, out_vld;
  assign total      = 8'(fill_q) + 8'(in_cnt_q);
  assign need       = 6'(NB) - fill_q;
  assign rem        = total - 8'(NB);
  assign can_insert = occ_a <= OccW'(XB);
  assign do_expand  = (total >= 8'(NB)) && can_insert;
  assign absorb     = (total < 8'(NB)) && (in_cnt_q != '0);
  assign out_vld    = occ_q >= OccW'(StrbWidth);

  assign ready_o      = (total < 8'(NB)) || (can_insert && (total < 8'(2 * NB)));
  assign lane_valid_o = {StrbWidth{out_vld}};
  assign busy_o       = (fill_q != '0) || (occ_q != '0) || (in_cnt_q != '0);

  // staging tail at the consumed pointer, shifted up behind the collected bytes
  logic [IcW-1:0] cons;
  logic [PW-1:0]  in_pad;
  logic [TFW-1:0] tail_flat, tail_shift, refill_flat;
  assign cons        = IcW'(StrbWidth) - in_cnt_q;
  assign in_pad      = PW'(in_q);
  assign tail_flat   = TFW'(in_pad >> {cons, 3'b000});
  assign tail_shift  = TFW'(tail_flat << {fill_q, 3'b000});
  assign refill_flat = TFW'(in_pad >> {8'(cons) + 8'(need), 3'b000});

  logic [NB-1:0][7:0] merged;
  always_comb
    for (int j = 0; j < NB; j++)
      merged[j] = (j < 32'(fill_q)) ? blk_q[j] : tail_shift[8*j +: 8];

  always_comb begin
    fill_d   = fill_q;
    in_cnt_d = in_cnt_q;
    blk_d    = blk_q;
    if (do_expand) begin
      blk_d = refill_flat;
      if (rem < 8'(NB)) begin
        fill_d   = rem[5:0];
        in_cnt_d = '0;
      end else begin
        fill_d   = '0;
        in_cnt_d = in_cnt_q - IcW'(need);
      end
    end else if (absorb) begin
      blk_d    = merged;
      fill_d   = total[5:0];
      in_cnt_d = '0;
    end
    if (valid_i && ready_o) in_cnt_d = IcW'(StrbWidth);
  end

  // bit-exact local reimplementation of decode_signed_scale +
  // mxfp8_byte_to_fp32_prescaled with proven 10-bit exponent range [-17,269]
  function automatic logic [31:0] mx_dq(input logic [7:0] b, input logic signed [7:0] sc);
    logic              sign;
    logic [4:0]        e5;
    logic [1:0]        m;
    logic [7:0]        base;
    logic signed [9:0] es;
    logic [22:0]       om;
    sign = b[7];
    e5   = b[6:2];
    m    = b[1:0];
    base = (e5 == '0) ? (8'd111 + 8'(m[1])) : (8'd112 + 8'(e5));
    es   = signed'({2'b00, base}) + signed'({{2{sc[7]}}, sc});
    om   = (e5 == '0) ? {m[1] & m[0], 22'd0} : {m, 21'd0};
    if (e5 == '0 && m == '0)  return {sign, 31'd0};
    else if (e5 == 5'h1F)     return (m == '0) ? {sign, 8'hFF, 23'd0} : 32'h7FC00000;
    else if (es <= 10'sd0)    return {sign, 31'd0};
    else if (es >= 10'sd255)  return {sign, 8'hFE, 23'h7FFFFF};
    else                      return {sign, es[7:0], om};
  endfunction

  logic                 fp16_act;
  logic signed [7:0]    dec_sc;
  logic [XB-1:0][7:0]   exp32_bytes, exp_bytes;
  logic [XB/2-1:0][7:0] exp16_bytes;
  assign fp16_act = (Fp16En != 1'b0) && dst_fp16_i;
  assign dec_sc   = signed'(merged[0]);
  for (genvar e = 0; e < MxBlockSize; e++) begin : gen_exp
    logic [31:0] w;
    assign w = mx_dq(merged[e+1], dec_sc);
    assign exp32_bytes[4*e+3 : 4*e] = w;
    if (Fp16En) begin : gen_fp16
      assign exp16_bytes[2*e+1 : 2*e] = fp32_bits_to_fp16(w);
    end else begin : gen_no_fp16
      assign exp16_bytes[2*e+1 : 2*e] = '0;
    end
  end
  assign exp_bytes = fp16_act ? {{(XB/2){8'd0}}, exp16_bytes} : exp32_bytes;

  // per-block insert length: 64B (FP16) or 128B (FP32)
  logic [OccW-1:0] blk_bytes;
  assign blk_bytes = fp16_act ? OccW'(XB/2) : OccW'(XB);

  // write: rotate the block by wr_off; enables select insert-length ring positions
  logic [PtrW-1:0]    wr_ptr;
  logic [XBW-1:0]     wr_off;
  logic [XB-1:0][7:0] wrot [XBW+1];
  logic [BufSize-1:0] wren;
  assign wr_ptr    = rd_q + occ_q[PtrW-1:0];
  assign wr_off    = wr_ptr[XBW-1:0];
  assign wrot[XBW] = exp_bytes;
  for (genvar b = 0; b < XBW; b++) begin : gen_wrot
    for (genvar i = 0; i < XB; i++) begin : gen_wrot_byte
      assign wrot[b][i] = wr_off[b] ? wrot[b+1][(i + XB - (1 << b)) % XB] : wrot[b+1][i];
    end
  end
  for (genvar s = 0; s < BufSize; s++) begin : gen_wren
    assign wren[s] = do_expand & (OccW'(PtrW'(s) - wr_ptr) < blk_bytes);
  end

  // read: log-stage rotator at rd_q; DC prunes it to the StrbWidth funnel
  logic [BufSize-1:0][7:0] rrot [PtrW+1];
  assign rrot[PtrW] = pack_q;
  for (genvar b = 0; b < PtrW; b++) begin : gen_rrot
    for (genvar i = 0; i < BufSize; i++) begin : gen_rrot_byte
      assign rrot[b][i] = rd_q[b] ? rrot[b+1][(i + (1 << b)) % BufSize] : rrot[b+1][i];
    end
  end
  assign data_o = out_vld ? rrot[0][StrbWidth-1:0] : '0;

  assign occ_d = occ_a + (do_expand ? blk_bytes : '0);

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni)
    assert (occ_d <= OccW'(BufSize))
      else $fatal(1, "idma_otf_mxdequant: pack-buffer overflow (StrbWidth=%0d)", StrbWidth);
  // pragma translate_on

  // pragma translate_off
  always @(posedge clk_i) if (rst_ni)
    assert (32'(pop_cnt) <= 32'(occ_q))
      else $fatal(1, "idma_otf_mxdequant: pop exceeds pack occupancy");
  // NOT IMPLEMENTED: overlapping compute transfers (a clear must never drop in-flight state)
  always @(posedge clk_i) if (rst_ni && clear_i)
    assert ((fill_q == '0) && (occ_q == '0) && (in_cnt_q == '0))
      else $fatal(1, "idma_otf_mxdequant: clear with in-flight state (overlapping transfers)");
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_q <= '0; occ_q <= '0; fill_q <= '0; in_cnt_q <= '0;
      blk_q <= '0; in_q <= '0;
    end else if (clear_i) begin
      rd_q <= '0; occ_q <= '0; fill_q <= '0; in_cnt_q <= '0;
    end else begin
      rd_q     <= rd_a;
      occ_q    <= occ_d;
      fill_q   <= fill_d;
      in_cnt_q <= in_cnt_d;
      if (do_expand || absorb) blk_q <= blk_d;
      if (valid_i && ready_o)  in_q  <= data_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pack_q <= '0;
    end else if (!clear_i) begin
      for (int s = 0; s < BufSize; s++)
        if (wren[s]) pack_q[s] <= wrot[0][s & (XB - 1)];
    end
  end

endmodule : idma_otf_mxdequant

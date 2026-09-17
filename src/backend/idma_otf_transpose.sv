// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// On-the-fly matrix transpose engine (ping-pong tile banks) for the iDMA
// transport datapath. Adapted from the datamover (Ratha) HWPE:
// pulp-platform/datamover@d58a985, rtl/datamover_engine.sv.
//
// Contract: input padded to full tiles, fed (col-tile, row-tile, row) order;
// out_T[nt*NE+k][rt*NE+r] = in[rt*NE+r][nt*NE+k]. strb_o masks partial edge tiles.
// Throughput: 1 + 1/NE cycles per NE-beat tile (one handoff bubble per tile).

module idma_otf_transpose #(
  /// Byte lanes per beat (= DataWidth/8)
  parameter  int unsigned StrbWidth  = 32'd8,
  /// Tensor dimension width in elements (matches idma_pkg::TransposeDimWidth)
  parameter  int unsigned DimWidth   = 32'd12,
  /// 1: two tile banks, fill while draining; 0: one bank (half area, half rate)
  parameter  bit          FullDuplex = 1'b1,
  localparam int unsigned NumBanks   = FullDuplex ? 32'd2 : 32'd1,
  localparam int unsigned LaneW      = $clog2(StrbWidth)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_i,

  /// Element size select: 0->1B, 1->2B, 2->4B, 3->8B (E = 1<<transp_mode_i)
  input  logic [1:0]  transp_mode_i,
  /// Matrix dimensions in elements
  input  logic [DimWidth-1:0] tensor_size_m_i,
  input  logic [DimWidth-1:0] tensor_size_n_i,

  /// Input beat stream (row-major), padded to full tiles
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  output logic                      ready_o,

  /// Output beat stream (transposed) with per-byte valid mask for edge tiles
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      strb_o,
  output logic                      valid_o,
  input  logic                      ready_i
);

  // StrbWidth must be a power of two >= 2 so LaneW>=1 and the shift geometry holds
  initial assert (StrbWidth >= 2 && (StrbWidth & (StrbWidth-1)) == 0) else
      $fatal(1, "idma_otf_transpose: StrbWidth (%0d) must be a power of two >= 2", StrbWidth);

  // Latch one transfer's geometry on its first input beat.  Once its final tile has been filled,
  // input is blocked until that tile drains; geometry from a following request can therefore not
  // affect an in-flight transpose.
  logic                geometry_valid_q;
  logic [1:0]          transp_mode_q;
  logic [DimWidth-1:0] tensor_size_m_q, tensor_size_n_q;
  logic [1:0]          active_transp_mode;
  logic [DimWidth-1:0] active_tensor_size_m, active_tensor_size_n;

  assign active_transp_mode   = geometry_valid_q ? transp_mode_q : transp_mode_i;
  assign active_tensor_size_m = geometry_valid_q ? tensor_size_m_q : tensor_size_m_i;
  assign active_tensor_size_n = geometry_valid_q ? tensor_size_n_q : tensor_size_n_i;

  // geometry: NE is a power of two, so only shifts and AND-masks
  logic [1:0]       eff_mode;         // element-size mode, saturated at LaneW
  logic [LaneW:0]   ne_m1;            // NE-1
  logic [3:0]       log2_ne;          // log2(NE) = LaneW - eff_mode
  logic [DimWidth-1:0] y_tiles, n_tiles; // row-tiles, col-tiles
  logic [LaneW:0]   leftover_rows, leftover_cols;  // M%NE, N%NE (run-global)

  // saturate at LaneW: out-of-contract mode (E>StrbWidth) degrades to NE=1
  assign eff_mode      = (active_transp_mode > LaneW) ? LaneW[1:0] : active_transp_mode;
  assign ne_m1         = (1 << (LaneW - eff_mode)) - 1;            // NE-1
  assign log2_ne       = LaneW - eff_mode;
  // Widen the ceil-div add by one bit so it cannot wrap at the dim range.
  assign y_tiles       = DimWidth'(((DimWidth+1)'(active_tensor_size_m) + ne_m1) >> log2_ne);
  assign n_tiles       = DimWidth'(((DimWidth+1)'(active_tensor_size_n) + ne_m1) >> log2_ne);
  assign leftover_rows = active_tensor_size_m & ne_m1;
  assign leftover_cols = active_tensor_size_n & ne_m1;

  // FF tile banks (ping-pong when FullDuplex), E=1 worst case (StrbWidth x StrbWidth B)
  logic [StrbWidth-1:0][7:0] tile_q [NumBanks][StrbWidth];

  // internal output + handshakes
  logic [StrbWidth-1:0][7:0] data_int;
  logic [StrbWidth-1:0]      strb_int;
  logic                      valid_int, ready_int;
  logic in_hs, out_hs;
  assign in_hs  = valid_i   & ready_o;
  assign out_hs = valid_int & ready_int;

  // full_q[b]: bank b holds a complete tile. Producer sets on fill-complete,
  // consumer clears on drain-complete.
  logic [NumBanks-1:0] full_q;
  logic             wr_bank, rd_bank;
  logic [LaneW-1:0] wr_cnt, rd_cnt;   // intra-tile beat index (write / read)
  logic             wr_last, rd_last;

  assign wr_last = (wr_cnt == ne_m1[LaneW-1:0]);
  assign rd_last = (rd_cnt == ne_m1[LaneW-1:0]);

  logic input_blocked_q;
  assign ready_o   = ~full_q[wr_bank] & ~input_blocked_q;
  assign valid_int =  full_q[rd_bank];

  // tile walkers (col-tile outer, row-tile inner); drain trails fill by up to one tile
  logic [DimWidth-1:0] rtw, ntw;   // write walker: row-tile, col-tile
  logic [DimWidth-1:0] rtr, ntr;   // read  walker: row-tile, col-tile

  logic last_y_tile_w, last_n_tile_w;  // edge flags of the tile being filled
  assign last_y_tile_w = (rtw == y_tiles - 1);
  assign last_n_tile_w = (ntw == n_tiles - 1);

  logic last_y_tile_r, last_n_tile_r;  // edge flags of the tile being drained
  assign last_y_tile_r = (rtr == y_tiles - 1);
  assign last_n_tile_r = (ntr == n_tiles - 1);

  // per-bank edge flags, captured at fill-complete, consumed by the drain strobe
  logic shadow_last_y [NumBanks];
  logic shadow_last_n [NumBanks];

  // fill-/drain-complete events
  logic fill_done, fill_exec_done, drain_done, exec_done;
  assign fill_done      = in_hs & wr_last;
  assign fill_exec_done = fill_done & last_y_tile_w & last_n_tile_w;
  assign drain_done     = out_hs & rd_last;
  // transfer done once the final tile drains
  assign exec_done  = drain_done & last_y_tile_r & last_n_tile_r;

  // Serialize complete transfers while retaining tile-level ping-pong operation within a transfer.
  // The geometry input may switch to the next descriptor after the final fill, but ready_o remains
  // low and the latched geometry remains active until the final tile has left the tile banks.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      geometry_valid_q <= 1'b0;
      transp_mode_q    <= '0;
      tensor_size_m_q  <= '0;
      tensor_size_n_q  <= '0;
      input_blocked_q  <= 1'b0;
    end else if (clear_i) begin
      geometry_valid_q <= 1'b0;
      transp_mode_q    <= '0;
      tensor_size_m_q  <= '0;
      tensor_size_n_q  <= '0;
      input_blocked_q  <= 1'b0;
    end else begin
      if (in_hs && !geometry_valid_q) begin
        geometry_valid_q <= 1'b1;
        transp_mode_q    <= transp_mode_i;
        tensor_size_m_q  <= tensor_size_m_i;
        tensor_size_n_q  <= tensor_size_n_i;
      end
      if (fill_exec_done) input_blocked_q <= 1'b1;
      if (exec_done) begin
        geometry_valid_q <= 1'b0;
        input_blocked_q  <= 1'b0;
      end
    end
  end

  // producer (input) side
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int b = 0; b < NumBanks; b++)
        for (int r = 0; r < StrbWidth; r++)
          tile_q[b][r] <= '0;
      wr_cnt           <= '0;
      wr_bank          <= 1'b0;
      rtw              <= '0;
      ntw              <= '0;
      for (int b = 0; b < NumBanks; b++) begin
        shadow_last_y[b] <= 1'b0;
        shadow_last_n[b] <= 1'b0;
      end
    end else if (clear_i || exec_done) begin
      wr_cnt           <= '0;
      wr_bank          <= 1'b0;
      rtw              <= '0;
      ntw              <= '0;
      for (int b = 0; b < NumBanks; b++) begin
        shadow_last_y[b] <= 1'b0;
        shadow_last_n[b] <= 1'b0;
      end
    end else begin
      if (in_hs) begin
        tile_q[wr_bank][wr_cnt] <= data_i;
        wr_cnt <= wr_last ? '0 : (wr_cnt + 1'b1);
      end
      if (fill_done) begin
        shadow_last_y[wr_bank] <= last_y_tile_w;
        shadow_last_n[wr_bank] <= last_n_tile_w;
        wr_bank <= FullDuplex ? ~wr_bank : 1'b0;
        if (rtw == y_tiles - 1) begin
          rtw <= '0;
          ntw <= ntw + 1'b1;
        end else begin
          rtw <= rtw + 1'b1;
        end
      end
    end
  end

  // consumer (output) side
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_cnt  <= '0;
      rd_bank <= 1'b0;
      rtr     <= '0;
      ntr     <= '0;
    end else if (clear_i || exec_done) begin
      rd_cnt  <= '0;
      rd_bank <= 1'b0;
      rtr     <= '0;
      ntr     <= '0;
    end else begin
      if (out_hs) begin
        rd_cnt <= rd_last ? '0 : (rd_cnt + 1'b1);
      end
      if (drain_done) begin
        rd_bank <= FullDuplex ? ~rd_bank : 1'b0;
        if (rtr == y_tiles - 1) begin
          rtr <= '0;
          ntr <= ntr + 1'b1;
        end else begin
          rtr <= rtr + 1'b1;
        end
      end
    end
  end

  // full/empty token
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      full_q <= '0;
    end else if (clear_i) begin
      full_q <= '0;
    end else begin
      if (fill_done)  full_q[wr_bank] <= 1'b1;
      if (drain_done) full_q[rd_bank] <= 1'b0;
    end
  end

  // transposed readout: byte p (element e=p>>logE, byte b=p&(E-1)) reads
  // tile_q[rd_bank][e][rd_cnt*E + b]
  always_comb begin
    for (int p = 0; p < StrbWidth; p++) begin
      automatic int unsigned e   = p >> eff_mode;
      automatic int unsigned b   = p & ((1 << eff_mode) - 1);
      automatic int unsigned col = (rd_cnt << eff_mode) | b;
      data_int[p] = tile_q[rd_bank][e][col];
    end
  end

  // output strobe: element-granular edge masking from the drain-side shadow flags
  always_comb begin
    logic [StrbWidth-1:0] em;  // per-element valid (only low NE bits meaningful)
    logic ly, ln;
    ly = shadow_last_y[rd_bank];
    ln = shadow_last_n[rd_bank];
    for (int e = 0; e < StrbWidth; e++) begin
      logic v;
      if ((ly && leftover_rows != 0) && (ln && leftover_cols != 0))
        v = (rd_cnt < leftover_cols) && (e < leftover_rows);
      else if (ly && leftover_rows != 0)
        v = (e < leftover_rows);
      else if (ln && leftover_cols != 0)
        v = (rd_cnt < leftover_cols);
      else
        v = 1'b1;
      em[e] = v;
    end
    for (int p = 0; p < StrbWidth; p++)
      strb_int[p] = em[p >> eff_mode];
  end

  // output register; not cleared by exec_done so the final beat is held until accepted
  assign ready_int = ~valid_o | ready_i;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o <= 1'b0;
      data_o  <= '0;
      strb_o  <= '0;
    end else if (clear_i) begin
      valid_o <= 1'b0;
      data_o  <= '0;
      strb_o  <= '0;
    end else if (ready_int) begin
      valid_o <= valid_int;
      data_o  <= data_int;
      strb_o  <= strb_int;
    end
  end

`ifndef SYNTHESIS
  // The final drain is only legal after the final fill has closed the input side.
  assert property (@(posedge clk_i) disable iff (!rst_ni || clear_i)
      exec_done |-> input_blocked_q)
  else $error("idma_otf_transpose: final tile drained without an active transfer barrier");

  // Once the final tile is buffered, no beat from the next descriptor may enter this transfer.
  assert property (@(posedge clk_i) disable iff (!rst_ni || clear_i)
      input_blocked_q |-> !in_hs)
  else $error("idma_otf_transpose: accepted input while waiting for the final tile to drain");
`endif

endmodule : idma_otf_transpose

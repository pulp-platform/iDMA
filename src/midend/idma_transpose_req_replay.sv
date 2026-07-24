// Copyright 2026 Mosaic SoC AG
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Georg Rutishauser <georg@mosaic-soc.com>

/// Redirect requests for invalid transpose edge rows to known-mapped addresses.
///
/// The current transport architecture requires one paired read/write descriptor
/// for every row of a complete square tile. Partial bottom and right tiles
/// therefore still issue descriptors for nonexistent source and destination
/// rows. This stage keeps the descriptor count unchanged, but replays the
/// first source/destination address for those requests. The transpose engine's
/// output strobe suppresses all data belonging to replayed requests.
module idma_transpose_req_replay #(
    /// Write datapath width in bytes.
    parameter int unsigned StrbWidth = 32'd64,
    /// 1D iDMA request type.
    parameter type idma_req_t = logic
) (
    input  logic      clk_i,
    input  logic      rst_ni,

    input  idma_req_t req_i,
    input  logic      valid_i,
    output logic      ready_o,

    output idma_req_t req_o,
    output logic      valid_o,
    input  logic      ready_i
);

    localparam int unsigned Log2Strb = $clog2(StrbWidth);
    localparam int unsigned LocalW   = Log2Strb;
    localparam int unsigned ModeW    = $bits(req_i.opt.compute.params.transpose.mode);
    localparam int unsigned TensorW  = $bits(req_i.opt.compute.params.transpose.tensor_m);
    localparam int unsigned AddrW    = $bits(req_i.src_addr);
    localparam int unsigned WorkW    = (TensorW > LocalW) ? TensorW + 1 : LocalW + 1;

    typedef logic [AddrW-1:0] addr_t;

    logic [LocalW-1:0]  local_idx_q;
    logic [TensorW-1:0] row_tile_idx_q, col_tile_idx_q;
    addr_t safe_src_addr_q, safe_dst_addr_q;

    logic is_transpose;
    logic req_handshake;
    logic first_request, last_request;
    logic invalid_read, invalid_write;
    logic [WorkW-1:0] ne, ne_m1, row_tiles, col_tiles;
    logic [WorkW-1:0] remaining_rows, remaining_cols;

    assign is_transpose = req_i.opt.compute.enable &
                          (req_i.opt.compute.op == idma_pkg::COMPUTE_TRANSPOSE);
    assign req_handshake = valid_o & ready_i;
    assign first_request = (local_idx_q == '0) && (row_tile_idx_q == '0) &&
                           (col_tile_idx_q == '0);

    // Tile dimensions are powers of two, so edge classification only needs
    // shifts and masks. The request carries the original tensor dimensions.
    always_comb begin : proc_geometry
        logic [ModeW-1:0] mode;
        logic [WorkW-1:0] rows, cols;
        logic [WorkW-1:0] log2_ne;

        mode    = req_i.opt.compute.params.transpose.mode;
        rows    = WorkW'(req_i.opt.compute.params.transpose.tensor_m);
        cols    = WorkW'(req_i.opt.compute.params.transpose.tensor_n);
        log2_ne = WorkW'(Log2Strb) - WorkW'(mode);
        ne      = WorkW'(1) << log2_ne;
        ne_m1   = ne - 1'b1;
        row_tiles = (rows + ne_m1) >> log2_ne;
        col_tiles = (cols + ne_m1) >> log2_ne;
        remaining_rows = rows & ne_m1;
        remaining_cols = cols & ne_m1;
    end

    // Invalid edge requests do not contribute transpose data in either output
    // layout. Replaying them to known mapped addresses avoids unsafe accesses
    // without changing the generated data or strobes.
    assign invalid_read = is_transpose && (remaining_rows != '0) &&
                          (WorkW'(row_tile_idx_q) == row_tiles - 1'b1) &&
                          (WorkW'(local_idx_q) >= remaining_rows);
    assign invalid_write = is_transpose && (remaining_cols != '0) &&
                           (WorkW'(col_tile_idx_q) == col_tiles - 1'b1) &&
                           (WorkW'(local_idx_q) >= remaining_cols);
    assign last_request = is_transpose &&
                          (WorkW'(local_idx_q) == ne - 1'b1) &&
                          (WorkW'(row_tile_idx_q) == row_tiles - 1'b1) &&
                          (WorkW'(col_tile_idx_q) == col_tiles - 1'b1);

    // The stage is transparent to handshaking and all non-address payload.
    always_comb begin : proc_replay
        req_o = req_i;
        if (invalid_read) begin
            req_o.src_addr = safe_src_addr_q;
        end
        if (invalid_write) begin
            req_o.dst_addr = safe_dst_addr_q;
        end
    end
    assign valid_o = valid_i;
    assign ready_o = ready_i;

    // Mirror the transpose ND walk: local row, row tile, then column tile.
    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_position
        if (!rst_ni) begin
            local_idx_q     <= '0;
            row_tile_idx_q  <= '0;
            col_tile_idx_q  <= '0;
            safe_src_addr_q <= '0;
            safe_dst_addr_q <= '0;
        end else if (req_handshake && is_transpose) begin
            if (first_request) begin
                safe_src_addr_q <= req_i.src_addr;
                safe_dst_addr_q <= req_i.dst_addr;
            end

            if (last_request) begin
                local_idx_q    <= '0;
                row_tile_idx_q <= '0;
                col_tile_idx_q <= '0;
            end else if (WorkW'(local_idx_q) == ne - 1'b1) begin
                local_idx_q <= '0;
                if (WorkW'(row_tile_idx_q) == row_tiles - 1'b1) begin
                    row_tile_idx_q <= '0;
                    col_tile_idx_q <= col_tile_idx_q + 1'b1;
                end else begin
                    row_tile_idx_q <= row_tile_idx_q + 1'b1;
                end
            end else begin
                local_idx_q <= local_idx_q + 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    initial assert (StrbWidth >= 2 && (StrbWidth & (StrbWidth - 1)) == 0) else
        $fatal(1, "idma_transpose_req_replay: StrbWidth must be a power of two >= 2");
`endif

endmodule

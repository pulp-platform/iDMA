// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

`include "common_cells/registers.svh"

/// This module takes in an AXI R-channel, and reads descriptors from it.
/// Note that an using an address width other than 64 bits will need
/// modifications.
module idma_desc64_reader_gater #(
    parameter type flush_t = logic
)(
    input  logic   clk_i,
    input  logic   rst_ni,
    input  flush_t n_to_flush_i,
    input  logic   n_to_flush_valid_i,
    input  logic   r_valid_i,
    output logic   r_valid_o,
    input  logic   r_ready_i,
    output logic   r_ready_o,
    input  logic   r_last_i
);

flush_t n_to_flush_q, n_to_flush_d;
logic flush;
logic engage_q, engage_d;

assign flush = engage_q && (n_to_flush_q > '0 || (n_to_flush_valid_i && n_to_flush_i > '0));

// engange gating only after the last r transaction is done
always_comb begin
    engage_d = engage_q;
    if (n_to_flush_valid_i || n_to_flush_q == '0) begin
        engage_d = 1'b0;
    end else if (r_last_i && r_valid_i && r_ready_i) begin
        engage_d = 1'b1;
    end
end

always_comb begin
    n_to_flush_d = n_to_flush_q;
    if (r_last_i && r_valid_i && n_to_flush_q > '0 && engage_q) begin
        n_to_flush_d = n_to_flush_q - 1'b1;
    end
    if (n_to_flush_valid_i) begin
        n_to_flush_d = n_to_flush_i;
    end
end

`FF(n_to_flush_q, n_to_flush_d, 'b0);
`FF(engage_q, engage_d, 'b0);

assign r_valid_o = flush ? 1'b0 : r_valid_i;
assign r_ready_o = flush ? 1'b1 : r_ready_i;

endmodule

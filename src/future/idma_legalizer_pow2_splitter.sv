// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Tobias Senti <tsenti@ethz.ch>

/// Legalizer module implementing a power of 2 splitter
module idma_legalizer_pow2_splitter #(
    parameter int unsigned OffsetWidth   = 32'd2,
    parameter int unsigned PageAddrWidth = 32'd3,
    parameter type         addr_t        = logic,
    parameter type         len_t         = logic
)(
    /// Current address
    input  addr_t addr_i,
    /// Number of bytes left to transfer
    input  len_t  length_i,
    /// Set if the remaining transfer length is larger than what can be represented in len_t
    input  logic length_larger_i,
    /// How many bytes we can transfer in this beat
    output len_t bytes_to_transfer_o
);
    // How many bytes are left inside the word
    logic [OffsetWidth:0] bytes_in_word_left;
    assign bytes_in_word_left = ('d1 << OffsetWidth) - addr_i[OffsetWidth-1:0];

    // How many bytes are left inside the word and transfer
    logic [OffsetWidth:0] bytes_in_world_left_to_transfer;
    assign bytes_in_world_left_to_transfer = (!length_larger_i && bytes_in_word_left > length_i) ?
           length_i : bytes_in_word_left;

    // Find largest power of 2 that fits inside word -> For subword transfers
    len_t subword_bytes_to_transfer;
    always_comb begin
        subword_bytes_to_transfer = '0;
        for(int i = 0; i <= OffsetWidth; i++) begin
            if(bytes_in_world_left_to_transfer >= ('d1 << i)) begin
                subword_bytes_to_transfer = ('d1 << i);
            end
        end
    end

    // Find largest power of 2 that fits inside length -> For bursts
    len_t burst_bytes_to_transfer;
    always_comb begin
        burst_bytes_to_transfer = '0;
        for(int i = 0; i <= PageAddrWidth; i++) begin
            if(length_i >= ('d1 << i)) begin
                burst_bytes_to_transfer = ('d1 << i);
            end
        end
    end

    // Is the address word aligned?
    logic aligned_address;
    assign aligned_address = ('0 == addr_i[OffsetWidth-1:0]);

    // Determine bytes to transfer
    always_comb begin
        if (aligned_address) begin
            // Aligned address -> Burst
            if (length_larger_i) begin
                // Length is larger than a full burst -> Full burst
                bytes_to_transfer_o = 'd1 << PageAddrWidth;
            end else begin
                // Burst
                bytes_to_transfer_o = burst_bytes_to_transfer;
            end
        end else begin
            // Missaligned address -> Subword transfer
            bytes_to_transfer_o = subword_bytes_to_transfer;
        end
    end
endmodule

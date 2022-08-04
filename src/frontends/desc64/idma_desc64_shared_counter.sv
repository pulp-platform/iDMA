// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

`include "common_cells/registers.svh"
/// This module allows two domains to share a counter
/// One end can increment the counter, the other can
/// decrement it. This can be used as a lightweight
/// FIFO if the only data that would be transmitted is 1
/// Note that the counter wraps on overflow, but saturates
/// on underflow
module idma_desc64_shared_counter #(
    parameter int unsigned CounterWidth = 4
) (
    input  logic clk_i              ,
    input  logic rst_ni             ,
    /// Whether the internal counter should increment
    input  logic increment_i        ,
    /// Whether the internal counter should decrement
    input  logic decrement_i        ,
    /// Whether the internal counter is above zero
    output logic greater_than_zero_o
);

typedef logic [CounterWidth-1:0] counter_t;

counter_t counter_d, counter_q;
`FF(counter_q, counter_d, '0);

assign greater_than_zero_o = counter_q != '0;

always_comb begin
    counter_d = counter_q;
    unique casez ({increment_i, decrement_i, counter_q != 0})
        3'b11?: begin
            counter_d = counter_q;
        end
        3'b10?: begin
            counter_d = counter_q + 1;
        end
        3'b011: begin
            counter_d = counter_q - 1;
        end
        3'b010: begin
            // don't underflow
            counter_d = counter_q;
        end
        3'b00?: begin
            counter_d = counter_q;
        end
        default: ;
    endcase
end

endmodule

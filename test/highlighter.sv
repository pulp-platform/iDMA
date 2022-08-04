// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz <tbenz@ethz.ch>

module highlighter #(
    parameter type T = logic
)(
    input logic ready_i,
    input logic valid_i,
    input T data_i
);

    T in_wave;

    always_comb begin
        in_wave = 'Z;
        if (ready_i & valid_i) begin
            in_wave = data_i;
        end
    end

endmodule : highlighter

// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz <tbenz@ethz.ch>

module watchdog #(
    parameter int unsigned NumCycles
)(
    input logic clk_i,
    input logic valid_i,
    input logic ready_i
);

    int unsigned cnt;

    initial begin : wd
        // initialize counter
        cnt = NumCycles;

        // count down when inactive, restore on activity
        while (cnt > 0) begin
            if (valid_i & ready_i)
                cnt = NumCycles;
            else
                cnt--;
            @(posedge clk_i);
        end

        // tripped watchdog
        $fatal(1, "Tripped Watchdog (%m) at %dns, Inactivity for %d cycles", $time(), NumCycles);
    end

endmodule : watchdog

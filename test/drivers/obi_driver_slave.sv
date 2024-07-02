// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

`include "drivers/obi_driver_common.svh"

module obi_driver_slave #(
parameter obi_pkg::obi_cfg_t ObiCfg = obi_pkg::ObiDefaultConfig,
parameter time TA = 0ns, // stimuli application time
parameter time TT = 0ns  // stimuli test time
)(
    input clk_i,
    OBI_BUS_DV.Subordinate sif
);

function void reset();
endfunction

task cycle_start;
    #(TT - TA);
endtask

task cycle_end;
    @(posedge clk_i);
endtask

task recv_r_ar(
    output obi_ar_beat addr,
);
    cycle_end();
    #TA;
    sif.gnt = 1;
    cycle_start();
    while (sif.req != '1 || sif.we != 0) begin cycle_end(); cycle_start(); end
    addr = new;
    addr.addr = sif.addr;
    cycle_end();
    #TA;
    sif.gnt = 0;
endtask

task recv_w_ar(
    output obi_ar_beat data,
);
    cycle_end();
    #TA;
    sif.gnt = 1;
    cycle_start();
    while (sif.req != '1 || sif.we != 1) begin cycle_end(); cycle_start(); end
    data = new;
    data.addr = sif.addr;
    data.wdata = sif.wdata;
    cycle_end();
    #TA;
    sif.gnt = 0;
endtask

task send_r_rsp(
    input obi_r_resp data,
);
    cycle_end();
    #TA;
    sif.rdata = data.data;
    sif.rvalid = 1;
    cycle_start();
    // if (ObiCfg.UseRReady) begin
        while (sif.rready != 1'b1) begin cycle_end(); cycle_start(); end
    // end
    cycle_end();
    #TA;
    sif.rvalid = 0;
    sif.rdata = 0;
endtask

task send_w_rsp();
    cycle_end();
    #TA;
    sif.rvalid = 1;
    cycle_start();
    // if (ObiCfg.UseRReady) begin
        while (sif.rready != 1'b1) begin cycle_end(); cycle_start(); end
    // end
    cycle_end();
    #TA;
    sif.rvalid = 0;
endtask

endmodule

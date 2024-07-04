// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

`include "drivers/axi_driver_common.svh"

module axi_driver_slave #(
    parameter int  AW = 32,
    parameter int  DW = 32,
    parameter int  IW = 8,
    parameter int  UW = 1,
    parameter time TA = 0ns, // stimuli application time
    parameter time TT = 0ns  // stimuli test time
)(
    input clk_i,
    AXI_BUS_DV.Slave sif
);

typedef axi_ax_beat #(.AW(AW), .IW(IW), .UW(UW)) ax_beat_t;
typedef axi_w_beat  #(.DW(DW), .UW(UW))          w_beat_t;
typedef axi_b_beat  #(.IW(IW), .UW(UW))          b_beat_t;
typedef axi_r_beat  #(.DW(DW), .IW(IW), .UW(UW)) r_beat_t;

function void reset();
    sif.aw_ready  = '0;
    sif.w_ready   = '0;
    sif.b_id      = '0;
    sif.b_resp    = '0;
    sif.b_user    = '0;
    sif.b_valid   = '0;
    sif.ar_ready  = '0;
    sif.r_id      = '0;
    sif.r_data    = '0;
    sif.r_resp    = '0;
    sif.r_last    = '0;
    sif.r_user    = '0;
    sif.r_valid   = '0;
endfunction

task cycle_start;
    #TT;
endtask

task cycle_end;
    @(posedge clk_i);
endtask

/// Issue a beat on the B channel.
task send_b (
    input b_beat_t beat
);
    sif.b_id    <= #TA beat.b_id;
    sif.b_resp  <= #TA beat.b_resp;
    sif.b_user  <= #TA beat.b_user;
    sif.b_valid <= #TA 1;
    cycle_start();
    while (sif.b_ready != 1) begin cycle_end(); cycle_start(); end
    cycle_end();
    sif.b_id    <= #(TA - 1ns) '0;
    sif.b_resp  <= #(TA - 1ns) '0;
    sif.b_user  <= #(TA - 1ns) '0;
    sif.b_valid <= #(TA - 1ns) 0;
endtask

/// Issue a beat on the R channel.
task send_r (
    input r_beat_t beat
);
    sif.r_id    <= #TA beat.r_id;
    sif.r_data  <= #TA beat.r_data;
    sif.r_resp  <= #TA beat.r_resp;
    sif.r_last  <= #TA beat.r_last;
    sif.r_user  <= #TA beat.r_user;
    sif.r_valid <= #TA 1;
    cycle_start();
    while (sif.r_ready != 1) begin cycle_end(); cycle_start(); end
    cycle_end();
    sif.r_valid <= #(TA - 1ns) 0;
    sif.r_id    <= #(TA - 1ns) '0;
    sif.r_data  <= #(TA - 1ns) '0;
    sif.r_resp  <= #(TA - 1ns) '0;
    sif.r_last  <= #(TA - 1ns) '0;
    sif.r_user  <= #(TA - 1ns) '0;
endtask

/// Wait for a beat on the AW channel.
task recv_aw (
    output ax_beat_t beat
);
    sif.aw_ready <= #TA 1;
    cycle_start();
    while (sif.aw_valid != 1) begin cycle_end(); cycle_start(); end
    beat = new;
    beat.ax_id     = sif.aw_id;
    beat.ax_addr   = sif.aw_addr;
    beat.ax_len    = sif.aw_len;
    beat.ax_size   = sif.aw_size;
    beat.ax_burst  = sif.aw_burst;
    beat.ax_lock   = sif.aw_lock;
    beat.ax_cache  = sif.aw_cache;
    beat.ax_prot   = sif.aw_prot;
    beat.ax_qos    = sif.aw_qos;
    beat.ax_region = sif.aw_region;
    beat.ax_atop   = sif.aw_atop;
    beat.ax_user   = sif.aw_user;
    cycle_end();
    sif.aw_ready <= #(TA - 1ns) 0; // Avoid race condition once aw_ready gets set again (Verilator bug?)
endtask

/// Wait for a beat on the W channel.
task recv_w (
    output w_beat_t beat
);
    sif.w_ready <= #TA 1;
    cycle_start();
    while (sif.w_valid != 1) begin cycle_end(); cycle_start(); end
    beat = new;
    beat.w_data = sif.w_data;
    beat.w_strb = sif.w_strb;
    beat.w_last = sif.w_last;
    beat.w_user = sif.w_user;
    cycle_end();
    sif.w_ready <= #(TA - 1ns) 0; // Avoid race condition once w_ready gets set again (Verilator bug?)
endtask

/// Wait for a beat on the AR channel.
task recv_ar (
    output ax_beat_t beat
);
    sif.ar_ready <= #TA 1;
    cycle_start();
    while (sif.ar_valid != 1) begin cycle_end(); cycle_start(); end
    beat = new;
    beat.ax_id     = sif.ar_id;
    beat.ax_addr   = sif.ar_addr;
    beat.ax_len    = sif.ar_len;
    beat.ax_size   = sif.ar_size;
    beat.ax_burst  = sif.ar_burst;
    beat.ax_lock   = sif.ar_lock;
    beat.ax_cache  = sif.ar_cache;
    beat.ax_prot   = sif.ar_prot;
    beat.ax_qos    = sif.ar_qos;
    beat.ax_region = sif.ar_region;
    beat.ax_atop   = 'X;  // Not defined on the AR channel.
    beat.ax_user   = sif.ar_user;
    cycle_end();
    sif.ar_ready  <= #(TA - 1ns) 0; // Avoid race condition once ar_ready gets set again (Verilator bug?)
endtask

endmodule

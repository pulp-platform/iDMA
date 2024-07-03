// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

`include "drivers/axi_driver_common.svh"
`include "drivers/dpi_interfaces.svh"

module axi_read #(
    parameter type axi_req_t,
    parameter type axi_rsp_t,
    parameter int unsigned DataWidth           = 32'd32,
    parameter int unsigned AddrWidth           = 32'd32,
    parameter int unsigned UserWidth           = 32'd1,
    parameter int unsigned AxiIdWidth          = 32'd1,
    parameter time TA,
    parameter time TT
) (
    input axi_req_t axi_read_req,
    output axi_rsp_t axi_read_rsp,

    input logic clk_i
);

AXI_BUS_DV #(
    .AXI_ADDR_WIDTH(AddrWidth),
    .AXI_ID_WIDTH(AxiIdWidth),
    .AXI_DATA_WIDTH(DataWidth),
    .AXI_USER_WIDTH(UserWidth)
) axi_bus (clk_i);

`AXI_ASSIGN_FROM_REQ ( axi_bus, axi_read_req  );
`AXI_ASSIGN_TO_RESP( axi_read_rsp, axi_bus );

axi_driver_slave #(
    .AW(AddrWidth),
    .DW(DataWidth),
    .IW(AxiIdWidth),
    .UW(UserWidth),
    .TA(TA),
    .TT(TT)
) driver (
    .clk_i(clk_i),
    .sif(axi_bus)
);

typedef axi_ax_beat #(.AW(AddrWidth), .IW(AxiIdWidth), .UW(UserWidth)) ax_beat_t;
typedef axi_r_beat #(.DW(DataWidth), .IW(AxiIdWidth), .UW(UserWidth)) r_beat_t;

task automatic process_read(ax_beat_t beat);
    r_beat_t r_beat = new;
    int v;
    int delay;
    int actual_burst_len = beat.ax_len + 1;
    int bytes_per_beat = 2 ** beat.ax_size;

    assert(bytes_per_beat == DataWidth / 8) else $error("[AXI_R] Unsupported AXI data width");
    assert(beat.ax_burst != axi_pkg::BURST_WRAP) else $error("[AXI_R] WRAP bursts are not supported");

    for (int i = 0; i < actual_burst_len; i++) begin
        int addr = (beat.ax_burst == axi_pkg::BURST_FIXED) ? beat.ax_addr : beat.ax_addr + i * bytes_per_beat;
        
        idma_read(addr, v, delay);
        r_beat.r_data = v;
        if (i == actual_burst_len - 1) begin
            r_beat.r_last = 1;
        end
        // $display("[AXI_R] Sending R (beat %0d/%0d): %08x", (i + 1), actual_burst_len, r_beat.r_data);
        driver.send_r(r_beat);
    end
endtask

task automatic axi_process();
forever begin
    ax_beat_t ar_beat = new;

    driver.recv_ar(ar_beat);
    // $display("[AXI_R] Received AR with addr=%08x", ar_beat.ax_addr);

    // fork begin
    process_read(ar_beat);
    // end join_none
end
endtask

initial begin
    driver.reset();
    axi_process();
end

endmodule

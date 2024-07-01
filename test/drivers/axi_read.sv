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

task axi_process();
forever begin
    ax_beat_t ar_beat = new;
    r_beat_t r_beat = new;
    int v;
    int delay;

    driver.recv_ar(ar_beat);
    $display("[AXI_R] Received AR, %08x", ar_beat.ax_addr);

    fork begin
        idma_read(ar_beat.ax_addr, v, delay);
        r_beat.r_data = v;
        r_beat.r_last = 1;
        $display("[AXI_R] Sending R: %08x", r_beat.r_data);
        driver.send_r(r_beat);
        $display("[AXI_R] Sent R");
    end join
end
endtask

initial begin
    driver.reset();
    axi_process();
end

endmodule

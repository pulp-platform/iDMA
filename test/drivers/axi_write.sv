// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

`include "drivers/axi_driver_common.svh"
`include "drivers/dpi_interfaces.svh"

module axi_write #(
    parameter type axi_req_t,
    parameter type axi_rsp_t,
    parameter int unsigned DataWidth,
    parameter int unsigned AddrWidth,
    parameter int unsigned UserWidth,
    parameter int unsigned AxiIdWidth,
    parameter time TA,
    parameter time TT
)  (
    input axi_req_t axi_write_req,
    output axi_rsp_t axi_write_rsp,

    input logic clk_i
);

AXI_BUS_DV #(
    .AXI_ADDR_WIDTH(AddrWidth),
    .AXI_ID_WIDTH(AxiIdWidth),
    .AXI_DATA_WIDTH(DataWidth),
    .AXI_USER_WIDTH(UserWidth)
) axi_bus (clk_i);

`AXI_ASSIGN_FROM_REQ ( axi_bus, axi_write_req  );
`AXI_ASSIGN_TO_RESP( axi_write_rsp, axi_bus );

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
typedef axi_w_beat #(.DW(DataWidth), .UW(UserWidth)) w_beat_t;
typedef axi_b_beat #(.IW(AxiIdWidth), .UW(UserWidth)) b_beat_t;

task axi_process();
forever begin
    ax_beat_t aw_beat = new;
    w_beat_t w_beat = new;
    b_beat_t b_beat = new;

    driver.recv_aw(aw_beat);
    $display("[AXI_W] Received AW, %08x", aw_beat.ax_addr);

    driver.recv_w(w_beat);
    $display("[AXI_W] Received W, %08x", w_beat.w_data);

    idma_write(aw_beat.ax_addr, w_beat.w_data);

    b_beat.b_id = aw_beat.ax_id;
    b_beat.b_resp = 0;
    driver.send_b(b_beat);
    $display("[AXI_W] Sent B");
end
endtask

initial begin
    driver.reset();
    axi_process();
end

endmodule
// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

`include "drivers/obi_driver_common.svh"
`include "drivers/dpi_interfaces.svh"

module obi_write #(
    parameter type obi_req_t,
    parameter type obi_rsp_t,
    parameter time TA,
    parameter time TT
)  (
    input obi_req_t obi_write_req,
    output obi_rsp_t obi_write_rsp,

    input logic clk_i,
    input logic rst_ni
);

OBI_BUS_DV #(
    .OBI_CFG(obi_pkg::ObiDefaultConfig)
) obi_bus (clk_i, rst_ni);

`OBI_ASSIGN_FROM_REQ( obi_bus, obi_write_req, obi_pkg::ObiDefaultConfig );
`OBI_ASSIGN_TO_RSP( obi_write_rsp, obi_bus, obi_pkg::ObiDefaultConfig );

// TODO: Use a different OBI config to do this automatically
assign obi_bus.rready = obi_write_req.rready;

obi_driver_slave #(
    .TA(TA),
    .TT(TT)
) driver (
    .clk_i(clk_i),
    .sif(obi_bus)
);

semaphore chan_a;
semaphore chan_r;

task obi_process();
forever begin
    obi_ar_beat a = new;

    chan_a.get();

    driver.recv_w_ar(a);
    // $display("[OBI_W] Received write request: %08x to %08x", a.wdata, a.addr);

    idma_write(a.addr, a.wdata);

    chan_r.get();
    chan_a.put();

    driver.send_w_rsp();

    chan_r.put();
end
endtask

initial begin
    chan_a = new(1);
    chan_r = new(1);
    driver.reset();

    fork
        obi_process();
        obi_process();
    join
end

endmodule

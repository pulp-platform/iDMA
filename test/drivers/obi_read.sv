// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Liam Braun <libraun@student.ethz.ch>

`include "drivers/obi_driver_common.svh"
`include "drivers/dpi_interfaces.svh"

module obi_read #(
    parameter type obi_req_t,
    parameter type obi_rsp_t,
    parameter time TA,
    parameter time TT
) (
    input obi_req_t obi_read_req,
    output obi_rsp_t obi_read_rsp,

    input logic clk_i,
    input logic rst_ni
);

OBI_BUS_DV #(
    .OBI_CFG(obi_pkg::ObiDefaultConfig)
) obi_bus (clk_i, rst_ni);

`OBI_ASSIGN_FROM_REQ( obi_bus, obi_read_req, obi_pkg::ObiDefaultConfig );
`OBI_ASSIGN_TO_RSP( obi_read_rsp, obi_bus, obi_pkg::ObiDefaultConfig );

// TODO: Use a different OBI config to do this automatically
assign obi_bus.rready = obi_read_req.rready;

obi_driver_slave #(
    .TA(TA),
    .TT(TT)
) driver (
    .clk_i(clk_i),
    .sif(obi_bus)
);

semaphore chan_a;
semaphore chan_r;

task obi_process(int id);
forever begin
    obi_ar_beat a = new;
    obi_r_resp r_resp = new;
    int v;
    int delay;

    chan_a.get();
    driver.recv_r_ar(a);
    // $display("[OBI] [%d] Received A, %08x", id, a.addr);

    idma_read(a.addr, v, delay);

    chan_r.get();
    chan_a.put();

    r_resp.data = v;
    driver.send_r_rsp(r_resp);
    // $display("[OBI] [%d] Sent R", id);
    chan_r.put();
end
endtask

initial begin
    chan_a = new(1);
    chan_r = new(1);
    driver.reset();

    fork
        obi_process(1);
        obi_process(1);
    join
end

endmodule;
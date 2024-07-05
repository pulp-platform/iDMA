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

semaphore chan_aw;
semaphore chan_w;
semaphore chan_b;

task automatic axi_process(int id);
forever begin
    ax_beat_t aw_beat = new;
    w_beat_t w_beat = new;
    b_beat_t b_beat = new;
    int actual_burst_len, bytes_per_beat;

    chan_aw.get();
    driver.recv_aw(aw_beat);
    // $display("[AXI_W] [%0d] Received AW, %08x (%t)", id, aw_beat.ax_addr, $time);
    
    actual_burst_len = aw_beat.ax_len + 1;
    bytes_per_beat = 2 ** aw_beat.ax_size;

    assert(bytes_per_beat == DataWidth / 8) else $error("[AXI_W] Unsupported AXI data width");
    assert(aw_beat.ax_burst != axi_pkg::BURST_WRAP) else $error("[AXI_W] WRAP bursts are not supported");

    chan_w.get();
    chan_aw.put();

    for (int i = 0; i < actual_burst_len; i++) begin
        int addr = (aw_beat.ax_burst == axi_pkg::BURST_FIXED) ? aw_beat.ax_addr : aw_beat.ax_addr + i * bytes_per_beat;

        driver.recv_w(w_beat);
        // $display("[AXI_W] [%0d] Received W (beat %0d/%0d): %08x/%08x", id, (i + 1), actual_burst_len, addr, w_beat.w_data);
        idma_write(addr, w_beat.w_data);
    end

    chan_b.get();
    chan_w.put();

    b_beat.b_id = aw_beat.ax_id;
    b_beat.b_resp = 0;
    driver.send_b(b_beat);
    // $display("[AXI_W] [%0d] Sent B", id);
    chan_b.put();
end
endtask

initial begin
    chan_aw = new(1);
    chan_w = new(1);
    chan_b = new(1);
    driver.reset();

    fork
        axi_process(1);
        axi_process(2);
        axi_process(3);
    join
end

endmodule
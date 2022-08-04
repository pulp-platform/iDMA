// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

`include "common_cells/registers.svh"
/// Hacky register interface to AXI converter
module dma_reg_to_axi #(
  parameter type            axi_req_t = logic,
  parameter type            axi_rsp_t = logic,
  parameter type            reg_req_t = logic,
  parameter type            reg_rsp_t = logic,
  parameter axi_pkg::size_t ByteWidthInPowersOfTwo = 'd3
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  output axi_req_t axi_req_o,
  input  axi_rsp_t axi_rsp_i,
  input  reg_req_t reg_req_i,
  output reg_rsp_t reg_rsp_o
);
  logic a_acked_q, a_acked_d;
  logic d_acked_q, d_acked_d;
  logic a_valid;
  logic d_valid;
  logic a_ready;
  logic d_ready;


  always_comb begin
    if (a_acked_q && d_acked_q) begin
      a_acked_d = 1'b0;
      d_acked_d = 1'b0;
    end else begin
      if (a_ready) begin
        a_acked_d = 1'b1;
      end else begin
        a_acked_d = a_acked_q;
      end

      if (d_ready) begin
        d_acked_d = 1'b1;
      end else begin
        d_acked_d = d_acked_q;
      end
    end
  end

  always_comb begin
    axi_req_o = 0;

    axi_req_o.aw.id     = ~'0;
    axi_req_o.aw.addr   = reg_req_i.addr;
    axi_req_o.aw.len    = 'b0; // actual length is +1
    axi_req_o.aw.size   = ByteWidthInPowersOfTwo;
    axi_req_o.aw.burst  = axi_pkg::BURST_INCR;

    axi_req_o.w.data    = reg_req_i.wdata;
    axi_req_o.w.strb    = reg_req_i.wstrb;
    axi_req_o.w.last    = 1'b1;

    axi_req_o.ar.id     = ~'0;
    axi_req_o.ar.addr   = reg_req_i.addr;
    axi_req_o.ar.len    = 'b0; // actual length is +1
    axi_req_o.ar.size   = ByteWidthInPowersOfTwo;
    axi_req_o.ar.burst  = axi_pkg::BURST_INCR;

    axi_req_o.aw_valid  = reg_req_i.write  && a_valid;
    axi_req_o.w_valid   = reg_req_i.write  && d_valid;
    axi_req_o.b_ready   = 1'b1; /* always ready for notifications on B channel, as we ignore them */

    axi_req_o.ar_valid  = !reg_req_i.write && a_valid;
    axi_req_o.r_ready   = !reg_req_i.write && d_valid;
  end

  assign a_ready = (reg_req_i.write ? axi_rsp_i.aw_ready : axi_rsp_i.ar_ready) && reg_req_i.valid;
  assign d_ready = (reg_req_i.write ? axi_rsp_i.w_ready : axi_rsp_i.r_valid) && reg_req_i.valid;
  assign a_valid = reg_req_i.valid && !a_acked_q;
  assign d_valid = reg_req_i.valid && !d_acked_q;


  /* Ignore axi_rsp_i.r.id */
  assign reg_rsp_o.rdata     = axi_rsp_i.r.data;
  /* Ignore axi_rsp_i.r.resp */
  /* Ignore axi_rsp_i.r.last (ever only bursts of size 1) */
  /* Ignore axi_rsp_i.r.user */
  assign reg_rsp_o.error     = '0; /* swallow errors */
  /* check that we don't get any errors in the simulation */
  // pragma translate_off
`ifndef VERILATOR
  assert property (@(posedge clk_i) (axi_rsp_i.r_valid && axi_req_o.r_ready) |-> \
                  (axi_rsp_i.r.resp == axi_pkg::RESP_OKAY));
`endif
  // pragma translate_on
  assign reg_rsp_o.ready     = ( reg_req_i.write && axi_rsp_i.w_ready) ||
                               (!reg_req_i.write && axi_rsp_i.r_valid);

  `FF(a_acked_q, a_acked_d, '0);
  `FF(d_acked_q, d_acked_d, '0);

endmodule : dma_reg_to_axi

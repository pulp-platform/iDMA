// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Unit negtest for the MX output-queue guards. Quant=1 drives idma_otf_mxquant, Quant=0
// idma_otf_mxdequant; popping the empty output queue after reset must fire the guard
// $fatal. Not reachable black-box. The runner greps for the message.

`timescale 1ns/1ps

module tb_idma_mxclear #(
  parameter int unsigned StrbWidth = 32'd8,
  parameter bit          Quant     = 1'b1
);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [StrbWidth-1:0][7:0] data_i, data_o;
  logic                      valid_i, in_pop, out_valid, pop, busy;

  if (Quant) begin : g_quant
    idma_otf_mxquant #(.StrbWidth(StrbWidth), .Fp16En(1'b0)) i_dut (
      .clk_i(clk), .rst_ni(rst_n), .data_i(data_i), .tag_i('0), .valid_i(valid_i),
      .ready_o(in_pop), .data_o(data_o), .valid_o(out_valid), .ready_i(pop), .busy_o(busy)
    );
  end else begin : g_dequant
    idma_otf_mxdequant #(.StrbWidth(StrbWidth), .Fp16En(1'b0)) i_dut (
      .clk_i(clk), .rst_ni(rst_n), .data_i(data_i), .valid_i(valid_i), .tag_i('0),
      .pop_o(in_pop), .data_o(data_o), .beat_valid_o(out_valid), .beat_pop_i(pop),
      .busy_o(busy)
    );
  end

  initial begin
    data_i = '0; valid_i = 1'b0; pop = 1'b0;
    rst_n = 1'b0; repeat (4) @(posedge clk);
    rst_n = 1'b1; @(posedge clk);
    if (out_valid || busy) $fatal(1, "[MXCLR] precondition: unit not idle after reset");
    // pop without an output beat -> the guard $fatal must fire now
    pop = 1'b1;
    repeat (4) @(posedge clk);
    $fatal(1, "[MXCLR] FAIL: empty-output-queue guard stayed silent");
  end

  initial begin #10_000; $fatal(1, "[MXCLR] timeout"); end

endmodule

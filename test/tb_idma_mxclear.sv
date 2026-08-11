// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Unit negtest for the MX sub-units' overlap guard: feeds one beat so the unit
// holds a partial in-flight block, then asserts clear_i. The clear-with-in-flight
// $fatal must fire. The backend serializes transfers, so this state is not
// reachable black-box; the guard is exercised here directly. Quant=1 drives
// idma_otf_mxquant, Quant=0 idma_otf_mxdequant. The runner greps for the message.

`timescale 1ns/1ps

module tb_idma_mxclear #(
  parameter int unsigned StrbWidth = 32'd8,
  parameter bit          Quant     = 1'b1
);

  logic clk = 1'b0, rst_n = 1'b0, clear = 1'b0;
  always #5 clk = ~clk;

  logic [StrbWidth-1:0][7:0] data_i;
  logic                      valid_i, ready_o;
  logic [StrbWidth-1:0][7:0] data_o;
  logic [StrbWidth-1:0]      lane_valid_o;
  logic [StrbWidth-1:0]      lane_ready_i;
  logic                      busy_o;

  if (Quant) begin : g_quant
    idma_otf_mxquant #(.StrbWidth(StrbWidth), .Fp16En(1'b0)) i_dut (
      .clk_i(clk), .rst_ni(rst_n), .clear_i(clear), .src_fmt_i(idma_pkg::MX_FMT_FP32),
      .data_i(data_i), .valid_i(valid_i), .ready_o(ready_o),
      .data_o(data_o), .lane_valid_o(lane_valid_o), .lane_ready_i(lane_ready_i), .busy_o(busy_o)
    );
  end else begin : g_dequant
    idma_otf_mxdequant #(.StrbWidth(StrbWidth), .Fp16En(1'b0)) i_dut (
      .clk_i(clk), .rst_ni(rst_n), .clear_i(clear), .dst_fmt_i(idma_pkg::MX_FMT_FP32),
      .data_i(data_i), .valid_i(valid_i), .ready_o(ready_o),
      .data_o(data_o), .lane_valid_o(lane_valid_o), .lane_ready_i(lane_ready_i), .busy_o(busy_o)
    );
  end

  initial begin
    data_i = '0; valid_i = 1'b0; clear = 1'b0; lane_ready_i = '0;
    rst_n = 1'b0; repeat (4) @(posedge clk);
    rst_n = 1'b1; @(posedge clk);
    // one beat -> unit latches a partial block (below 32 elems / 33 bytes)
    data_i  = {StrbWidth{8'hA5}};
    valid_i = 1'b1;
    do @(posedge clk); while (!ready_o);
    valid_i = 1'b0;
    @(posedge clk);
    if (!busy_o) $fatal(1, "[MXCLR] precondition: unit not busy after one beat");
    // overlapping clear with in-flight state -> the guard $fatal must fire now
    clear = 1'b1;
    repeat (4) @(posedge clk);
    $fatal(1, "[MXCLR] FAIL: overlapping-clear guard stayed silent");
  end

  initial begin #10_000; $fatal(1, "[MXCLR] timeout"); end

endmodule

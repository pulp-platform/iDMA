// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Stage-1 plain-copy regression for the standalone single-head inst64 frontend.
/// Drives DMSRC/DMDST/DMCPY over the accelerator bus and verifies the copy in
/// the AXI sim memory. No compute.
module tb_idma_inst64_copy;
  import idma_inst64_tb_pkg::*;

  idma_inst64_base #(.DMATracing(0)) harness();

  localparam int unsigned TimeoutCycles = 20000;
  int unsigned errors = 0;

  task automatic run_copy(input addr_t src, input addr_t dst, input int unsigned len,
                          input byte start);
    tf_id_t tid;
    for (int i = 0; i < len; i++) harness.mem_write_byte(src + i, start + i[7:0]);
    for (int i = 0; i < len; i++) harness.mem_write_byte(dst + i, 8'h00);
    harness.drv_if.dma_set_source(src);
    harness.drv_if.dma_set_dest(dst);
    harness.drv_if.dma_start_copy(addr_t'(len), 2'b00, 3'd0, tid);
    harness.drv_if.dma_wait(tid, 0);
    for (int i = 0; i < len; i++) begin
      automatic logic [7:0] exp = start + i[7:0];
      automatic logic [7:0] got = harness.mem_read_byte(dst + i);
      if (got !== exp) begin
        if (errors < 10) $error("[COPY] mismatch at %0d: exp 0x%02x got 0x%02x", i, exp, got);
        errors++;
      end
    end
  endtask

  initial begin
    @(posedge harness.rst_n);
    repeat (10) @(posedge harness.clk);

    $display("=== inst64 plain-copy regression ===");
    run_copy(64'h8000_0000, 64'h9000_0000, 256,  8'hA0);  // word-multiple
    run_copy(64'h8001_0000, 64'h9001_0000, 4055, 8'h10);  // large, non-aligned length
    run_copy(64'h8002_0000, 64'h9002_0000, 7,    8'h30);  // tiny, sub-beat

    if (errors == 0) $display("[SV] inst64 copy: SUCCESS (3 transfers)");
    else             $fatal(1, "[SV] inst64 copy: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    repeat (TimeoutCycles) @(posedge harness.clk);
    $fatal(1, "[TIMEOUT] inst64 copy exceeded %0d cycles", TimeoutCycles);
  end

endmodule

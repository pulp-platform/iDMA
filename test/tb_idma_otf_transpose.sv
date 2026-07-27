// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Standalone self-checking testbench for idma_otf_transpose: checks a full
// M x N transpose of EB-byte elements (EB in {1,2,4}) against the DPI-C golden
// (idma_transpose_dpi.c). Sweeps a geometry list internally; M/N/EB are runtime
// DUT inputs, so one elaboration covers all geometries for a given StrbWidth/
// FullDuplex. Optional backpressure via +BP.

`timescale 1ns/1ps

module tb_idma_otf_transpose #(
  parameter int unsigned StrbWidth  = 32'd8,
  parameter bit          FullDuplex = 1'b1
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_transpose(input int m, input int n, input int e);
  import "DPI-C" function int  gm_get(input int idx);

  localparam logic [7:0] PAD = 8'hFF;

  // Geometry cases (M, N, EB); EB>StrbWidth cases skip.
  localparam int unsigned NCases = 4;
  localparam int unsigned Cases [NCases][3] = '{ '{13, 19, 1}, '{7, 5, 2}, '{5, 3, 4}, '{130, 70, 1} };

  logic clk = 1'b0, rst_n = 1'b0, clear = 1'b0;
  always #5 clk = ~clk;

  // runtime DUT control (held stable per case)
  logic [1:0]  mode_q;
  logic [11:0] m_q, n_q;

  logic [StrbWidth-1:0][7:0] din_data;
  logic                      din_valid, din_ready;
  logic [StrbWidth-1:0][7:0] dout_data;
  logic [StrbWidth-1:0]      dout_strb;
  logic                      dout_valid, dout_ready;

  // The stream driver and monitor share a clocking block so neither can race
  // sequential DUT logic when changing valid/ready or sampling a transferred beat.
  clocking stream_cb @(posedge clk);
    default input #1step output #0;
    input din_ready;
    output din_data, din_valid;
    input dout_data, dout_strb, dout_valid;
    output dout_ready;
  endclocking

  idma_otf_transpose #(
    .StrbWidth  (StrbWidth),
    .FullDuplex (FullDuplex)
  ) i_dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .clear_i         (clear),
    .transp_mode_i   (mode_q),
    .tensor_size_m_i (m_q),
    .tensor_size_n_i (n_q),
    .data_i          (din_data),
    .valid_i         (din_valid),
    .ready_o         (din_ready),
    .data_o          (dout_data),
    .strb_o          (dout_strb),
    .valid_o         (dout_valid),
    .ready_i         (dout_ready)
  );

  logic [7:0]  inb [];          // row-major input bytes (sized per case)
  bit          wrote [];        // per transposed-element coverage (sized per case)
  int unsigned errors = 0;      // running total across all cases
  bit          backpressure = 1'b0;

  task automatic drive_inputs(input int unsigned m, n, eb, ne, yt, nt);
    int unsigned beat = 0;
    logic [StrbWidth-1:0][7:0] beat_data;
    @(stream_cb);
    stream_cb.din_valid <= 1'b0;
    stream_cb.din_data <= '0;
    for (int unsigned ct = 0; ct < nt; ct++)
      for (int unsigned rt = 0; rt < yt; rt++)
        for (int unsigned row = 0; row < ne; row++) begin
          if (backpressure) begin
            stream_cb.din_valid <= 1'b0;
            repeat (beat % 3) @(stream_cb);
          end
          beat_data = '0;
          for (int unsigned c = 0; c < ne; c++) begin
            automatic int unsigned gr = rt*ne + row;
            automatic int unsigned gc = ct*ne + c;
            for (int unsigned b = 0; b < eb; b++)
              beat_data[c*eb + b] = (gr < m && gc < n) ? inb[(gr*n + gc)*eb + b] : PAD;
          end
          stream_cb.din_data <= beat_data;
          stream_cb.din_valid <= 1'b1;
          do @(stream_cb); while (!stream_cb.din_ready);
          beat++;
        end
    stream_cb.din_valid <= 1'b0;
    stream_cb.din_data <= '0;
  endtask

  task automatic capture_outputs(input int unsigned m, n, eb, ne, yt, nt);
    int unsigned beat = 0;
    @(stream_cb);
    stream_cb.dout_ready <= 1'b0;
    for (int unsigned ct = 0; ct < nt; ct++)
      for (int unsigned rt = 0; rt < yt; rt++)
        for (int unsigned k = 0; k < ne; k++) begin
          if (backpressure) begin
            stream_cb.dout_ready <= 1'b0;
            repeat (beat % 4) @(stream_cb);
          end
          stream_cb.dout_ready <= 1'b1;
          do @(stream_cb); while (!stream_cb.dout_valid);
          for (int unsigned e = 0; e < ne; e++) begin
            if (stream_cb.dout_strb[e*eb]) begin // element e valid (element-granular mask)
              automatic int unsigned tr = ct*ne + k;   // transposed row (= original col, 0..n-1)
              automatic int unsigned tc = rt*ne + e;   // transposed col (= original row, 0..m-1)
              if (tr >= n || tc >= m) begin
                errors++;
                if (errors <= 16) $display("STRB-ON-PAD beat(ct%0d rt%0d k%0d) elem %0d -> (%0d,%0d) OOB", ct, rt, k, e, tr, tc);
              end else begin
                for (int unsigned b = 0; b < eb; b++) begin
                  automatic int gold = gm_get((tr*m + tc)*eb + b);
                  if (int'(stream_cb.dout_data[e*eb + b]) !== gold) begin
                    errors++;
                    if (errors <= 16)
                      $display("MISMATCH T(%0d,%0d).b%0d=%0d golden=%0d",
                               tr, tc, b, stream_cb.dout_data[e*eb+b], gold);
                  end
                end
                wrote[tr*m + tc] = 1'b1;
              end
            end
          end
          beat++;
        end
    stream_cb.dout_ready <= 1'b0;
  endtask

  // Run one m x n transpose of eb-byte elements; returns the mismatch count.
  task automatic run_case(input int unsigned m, n, eb, output int unsigned errs);
    automatic int unsigned mode = (eb == 4) ? 2 : (eb == 2) ? 1 : 0;
    automatic int unsigned ne   = StrbWidth / eb;
    automatic int unsigned yt   = (m + ne - 1) / ne;
    automatic int unsigned nt   = (n + ne - 1) / ne;
    automatic int unsigned e0   = errors;

    inb   = new[m*n*eb];
    wrote = new[n*m];
    for (int unsigned i = 0; i < m*n*eb; i++) begin
      inb[i] = 8'((i * 7 + 3) & 8'hFF);
      gm_load(i, int'(inb[i]));
    end
    gm_transpose(m, n, eb);
    for (int unsigned i = 0; i < n*m; i++) wrote[i] = 1'b0;

    mode_q = 2'(mode); m_q = 12'(m); n_q = 12'(n);
    // clear the engine between cases (resets banks / walkers)
    clear = 1'b1; repeat (2) @(posedge clk); clear = 1'b0; @(posedge clk);

    $display("[TB] case M=%0d N=%0d EB=%0d (tile=%0d elems, %0dx%0d tiles) BP=%0d", m, n, eb, ne, yt, nt, backpressure);
    fork drive_inputs(m, n, eb, ne, yt, nt); capture_outputs(m, n, eb, ne, yt, nt); join

    for (int unsigned tr = 0; tr < n; tr++)
      for (int unsigned tc = 0; tc < m; tc++)
        if (!wrote[tr*m + tc]) begin
          errors++;
          if (errors <= 16) $display("MISSING transposed elem (%0d,%0d)", tr, tc);
        end
    errs = errors - e0;
  endtask

  initial begin
    automatic int unsigned total = 0, ce;
    din_valid = 1'b0; dout_ready = 1'b0; mode_q = '0; m_q = '0; n_q = '0;
    if ($test$plusargs("BP")) backpressure = 1'b1;

    rst_n = 1'b0; clear = 1'b1;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    clear = 1'b0;
    @(posedge clk);

    for (int unsigned k = 0; k < NCases; k++) begin
      if (Cases[k][2] > StrbWidth) continue;   // element must fit the bus
      run_case(Cases[k][0], Cases[k][1], Cases[k][2], ce);
      if (ce == 0) $display("[TB] PASS: %0dx%0d EB=%0d transpose matches DPI golden", Cases[k][0], Cases[k][1], Cases[k][2]);
      else         $display("[TB] FAIL: %0dx%0d EB=%0d (%0d errors)", Cases[k][0], Cases[k][1], Cases[k][2], ce);
      total += ce;
    end

    if (total == 0) $display("[TB] ALL PASS (%0d cases, StrbWidth=%0d, FullDuplex=%0d)", NCases, StrbWidth, FullDuplex);
    else            $fatal(1, "[TB] FAIL: %0d total errors", total);
    repeat (5) @(posedge clk);
    $finish;
  end

  initial begin
    #100000000;
    $fatal(1, "[TB] FAIL: timeout");
  end

endmodule

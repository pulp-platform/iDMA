// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Standalone self-checking testbench for idma_otf_transpose (element transpose,
// no iDMA backend / no protocol deps). Verifies a full M x N transpose of
// EB-byte elements (EB in {1,2,4} = int8/fp16/fp32), split into NE-square tiles
// (NE = StrbWidth/EB): input padded to full tiles, fed in (col-tile, row-tile,
// row) order; output collected through the engine's per-byte strb_o edge mask.
// Expected result comes from the DPI-C golden (idma_transpose_dpi.c). Checks
// correctness vs golden, full coverage, and no strobe asserted on padding.
// Optional two-sided backpressure via +BP. Override with -gM= -gN= -gEB=.

`timescale 1ns/1ps

module tb_idma_otf_transpose #(
  parameter int unsigned StrbWidth  = 32'd8,
  parameter bit          FullDuplex = 1'b1,
  parameter int unsigned M         = 32'd8,   // matrix rows (elements)
  parameter int unsigned N         = 32'd8,   // matrix cols (elements)
  parameter int unsigned EB        = 32'd1    // element size in bytes (1/2/4)
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_transpose(input int m, input int n, input int e);
  import "DPI-C" function int  gm_get(input int idx);

  localparam int unsigned MODE = (EB == 4) ? 2 : (EB == 2) ? 1 : 0;  // log2(EB)
  localparam int unsigned NE   = StrbWidth / EB;                     // elements/beat = tile side
  localparam int unsigned YT   = (M + NE - 1) / NE;                  // row-tiles
  localparam int unsigned NT   = (N + NE - 1) / NE;                  // col-tiles
  localparam int unsigned LR   = M % NE;
  localparam int unsigned LC   = N % NE;
  localparam logic [7:0]  PAD  = 8'hFF;

  logic clk = 1'b0, rst_n = 1'b0, clear = 1'b0;
  always #5 clk = ~clk;

  logic [StrbWidth-1:0][7:0] din_data;
  logic                      din_valid, din_ready;
  logic [StrbWidth-1:0][7:0] dout_data;
  logic [StrbWidth-1:0]      dout_strb;
  logic                      dout_valid, dout_ready;

  idma_otf_transpose #(
    .StrbWidth  (StrbWidth),
    .FullDuplex (FullDuplex)
  ) i_dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .clear_i         (clear),
    .transp_mode_i   (2'(MODE)),
    .tensor_size_m_i (12'(M)),
    .tensor_size_n_i (12'(N)),
    .data_i          (din_data),
    .valid_i         (din_valid),
    .ready_o         (din_ready),
    .data_o          (dout_data),
    .strb_o          (dout_strb),
    .valid_o         (dout_valid),
    .ready_i         (dout_ready)
  );

  logic [7:0] inb [M*N*EB];     // row-major input bytes
  bit         wrote [N*M];      // per transposed-element coverage
  int unsigned errors = 0;
  bit backpressure = 1'b0;

  task automatic drive_inputs();
    int unsigned beat = 0;
    din_valid = 1'b0; din_data = '0;
    @(posedge clk);
    for (int nt = 0; nt < NT; nt++)
      for (int rt = 0; rt < YT; rt++)
        for (int row = 0; row < NE; row++) begin
          if (backpressure) begin din_valid = 1'b0; repeat (beat % 3) @(posedge clk); end
          for (int c = 0; c < NE; c++) begin
            int gr = rt*NE + row;
            int gc = nt*NE + c;
            for (int b = 0; b < EB; b++)
              din_data[c*EB + b] = (gr < M && gc < N) ? inb[(gr*N + gc)*EB + b] : PAD;
          end
          din_valid = 1'b1;
          do @(posedge clk); while (!din_ready);
          beat++;
        end
    din_valid = 1'b0;
  endtask

  task automatic capture_outputs();
    int unsigned beat = 0;
    dout_ready = 1'b0;
    for (int nt = 0; nt < NT; nt++)
      for (int rt = 0; rt < YT; rt++)
        for (int k = 0; k < NE; k++) begin
          if (backpressure) begin dout_ready = 1'b0; repeat (beat % 4) @(posedge clk); end
          dout_ready = 1'b1;
          do @(posedge clk); while (!dout_valid);
          for (int e = 0; e < NE; e++) begin
            if (dout_strb[e*EB]) begin     // element e valid (element-granular mask)
              int tr = nt*NE + k;          // transposed row (= original col, 0..N-1)
              int tc = rt*NE + e;          // transposed col (= original row, 0..M-1)
              if (tr >= N || tc >= M) begin
                errors++;
                if (errors <= 16) $display("STRB-ON-PAD beat(nt%0d rt%0d k%0d) elem %0d -> (%0d,%0d) OOB", nt, rt, k, e, tr, tc);
              end else begin
                for (int b = 0; b < EB; b++) begin
                  automatic int gold = gm_get((tr*M + tc)*EB + b);
                  if (int'(dout_data[e*EB + b]) !== gold) begin
                    errors++;
                    if (errors <= 16) $display("MISMATCH T(%0d,%0d).b%0d=%0d golden=%0d", tr, tc, b, dout_data[e*EB+b], gold);
                  end
                end
                wrote[tr*M + tc] = 1'b1;
              end
            end
          end
          beat++;
        end
    @(posedge clk);
    dout_ready = 1'b0;
  endtask

  initial begin
    for (int i = 0; i < M*N*EB; i++) inb[i] = 8'((i * 7 + 3) & 8'hFF);  // varied stimulus
    for (int i = 0; i < M*N*EB; i++) gm_load(i, int'(inb[i]));
    gm_transpose(M, N, EB);
    for (int i = 0; i < N*M; i++) wrote[i] = 1'b0;

    din_valid = 1'b0; dout_ready = 1'b0;
    if ($test$plusargs("BP")) backpressure = 1'b1;
    $display("[TB] idma_otf_transpose M=%0d N=%0d EB=%0d (tile=%0d elems, %0dx%0d tiles, LR=%0d LC=%0d) BP=%0d",
             M, N, EB, NE, YT, NT, LR, LC, backpressure);

    rst_n = 1'b0; clear = 1'b1;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    clear = 1'b0;
    @(posedge clk);

    fork drive_inputs(); capture_outputs(); join

    for (int tr = 0; tr < N; tr++)
      for (int tc = 0; tc < M; tc++)
        if (!wrote[tr*M + tc]) begin
          errors++;
          if (errors <= 16) $display("MISSING transposed elem (%0d,%0d)", tr, tc);
        end

    if (errors == 0) $display("[TB] PASS: %0dx%0d EB=%0d transpose matches DPI golden", M, N, EB);
    else             $display("[TB] FAIL: %0d errors", errors);

    repeat (5) @(posedge clk);
    $finish;
  end

  initial begin
    #5000000;
    $display("[TB] FAIL: timeout");
    $finish;
  end

endmodule

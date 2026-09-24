// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Standalone self-checking testbench for idma_otf_transpose: checks a full
// M x N transpose of EB-byte elements (EB in {1,2,4,8}) against the DPI-C golden
// (idma_transpose_dpi.c). Sweeps a geometry list internally; M/N/EB are runtime
// DUT inputs, so one elaboration covers all geometries for a given StrbWidth/
// FullDuplex. Optional backpressure via +BP=1. A second phase checks back-to-back matrix rates.

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
  localparam int unsigned NCases = 5;
  localparam int unsigned Cases [NCases][3] = '{ '{13, 19, 1}, '{7, 5, 2},
                                                 '{5, 3, 4}, '{130, 70, 1}, '{9, 6, 8} };

  // Back-to-back phase: single tiles of one geometry, then of changing geometry
  localparam int unsigned NumB2bTiles = 12;
  localparam int unsigned LogSw       = $clog2(StrbWidth);
  // Rate bounds in beats per 1000 cycles; one bank serializes fill and drain, two overlap them
  localparam int unsigned MaxTileRateFd0     = 600;
  localparam int unsigned MinTileRateFd1     = 950;
  localparam int unsigned MinVaryTileRateFd1 = 700;

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

  task automatic drive_inputs(input int unsigned m, input int unsigned n,
                              input int unsigned eb, input int unsigned ne,
                              input int unsigned yt, input int unsigned nt);
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

  task automatic capture_outputs(input int unsigned m, input int unsigned n,
                                 input int unsigned eb, input int unsigned ne,
                                 input int unsigned yt, input int unsigned nt);
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
                if (errors <= 16)
                  $display("STRB-ON-PAD beat(ct%0d rt%0d k%0d) elem %0d -> (%0d,%0d) OOB",
                           ct, rt, k, e, tr, tc);
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
  task automatic run_case(input int unsigned m, input int unsigned n,
                          input int unsigned eb, output int unsigned errs);
    automatic int unsigned mode = (eb == 8) ? 3 : (eb == 4) ? 2 : (eb == 2) ? 1 : 0;
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

    $display("[TB] case M=%0d N=%0d EB=%0d (tile=%0d elems, %0dx%0d tiles) BP=%0d",
             m, n, eb, ne, yt, nt, backpressure);
    fork drive_inputs(m, n, eb, ne, yt, nt); capture_outputs(m, n, eb, ne, yt, nt); join

    for (int unsigned tr = 0; tr < n; tr++)
      for (int unsigned tc = 0; tc < m; tc++)
        if (!wrote[tr*m + tc]) begin
          errors++;
          if (errors <= 16) $display("MISSING transposed elem (%0d,%0d)", tr, tc);
        end
    errs = errors - e0;
  endtask

  // One matrix of a back-to-back sequence
  typedef struct {
    int unsigned m, n, eb;
  } geom_t;

  function automatic geom_t mk_geom(input int unsigned m, input int unsigned n,
                                    input int unsigned eb);
    geom_t g;
    g.m  = m;
    g.n  = n;
    g.eb = eb;
    return g;
  endfunction

  // Expected output beats of a back-to-back sequence (data valid under strb only)
  logic [StrbWidth-1:0][7:0] exp_data [$];
  logic [StrbWidth-1:0]      exp_strb [$];
  longint unsigned           out_first, out_last, out_beats;

  // Build the padded input beats and golden output beats of one matrix
  task automatic build_matrix(input geom_t g, input int unsigned salt,
                              ref logic [StrbWidth-1:0][7:0] in_beats [$]);
    automatic int unsigned ne = StrbWidth / g.eb;
    automatic int unsigned yt = (g.m + ne - 1) / ne;
    automatic int unsigned nt = (g.n + ne - 1) / ne;
    automatic logic [7:0]  mat [] = new[g.m * g.n * g.eb];
    automatic logic [StrbWidth-1:0][7:0] beat;
    automatic logic [StrbWidth-1:0]      strb;
    for (int unsigned i = 0; i < g.m * g.n * g.eb; i++) begin
      mat[i] = 8'(((i + salt) * 13 + 5) & 8'hFF);
      gm_load(i, int'(mat[i]));
    end
    gm_transpose(g.m, g.n, g.eb);
    for (int unsigned ct = 0; ct < nt; ct++)
      for (int unsigned rt = 0; rt < yt; rt++) begin
        for (int unsigned row = 0; row < ne; row++) begin
          beat = '0;
          for (int unsigned c = 0; c < ne; c++)
            for (int unsigned b = 0; b < g.eb; b++)
              beat[c*g.eb + b] = (rt*ne + row < g.m && ct*ne + c < g.n) ?
                                 mat[((rt*ne + row)*g.n + ct*ne + c)*g.eb + b] : PAD;
          in_beats.push_back(beat);
        end
        for (int unsigned k = 0; k < ne; k++) begin
          beat = '0;
          strb = '0;
          for (int unsigned e = 0; e < ne; e++)
            for (int unsigned b = 0; b < g.eb; b++)
              if (ct*ne + k < g.n && rt*ne + e < g.m) begin
                strb[e*g.eb + b] = 1'b1;
                beat[e*g.eb + b] = 8'(gm_get(((ct*ne + k)*g.m + rt*ne + e)*g.eb + b));
              end
          exp_data.push_back(beat);
          exp_strb.push_back(strb);
        end
      end
  endtask

  // Stream a matrix list without clear; returns mismatches, rate in beats per 1000 cycles
  task automatic run_b2b(input string name, input geom_t seq [$], input bit bp,
                         output int unsigned errs, output int unsigned rate);
    automatic logic [StrbWidth-1:0][7:0] in_beats [$];
    automatic int unsigned first_beat [$];
    automatic int unsigned e0 = errors;
    automatic longint unsigned total_beats;
    exp_data.delete();
    exp_strb.delete();
    foreach (seq[j]) begin
      first_beat.push_back(in_beats.size());
      build_matrix(seq[j], 17 * j + 1, in_beats);
    end
    total_beats = exp_data.size();
    out_beats = 0;
    clear = 1'b1; repeat (2) @(posedge clk); clear = 1'b0; @(posedge clk);
    fork
      begin : drive
        automatic int unsigned j = 0;
        @(stream_cb);
        foreach (in_beats[i]) begin
          if (bp) begin
            stream_cb.din_valid <= 1'b0;
            repeat (i % 3) @(stream_cb);
          end
          if (j < seq.size() && i == first_beat[j]) begin
            // new geometry with the matrix's first beat, after the DUT sampled this edge
            mode_q <= (seq[j].eb == 8) ? 2'd3 : (seq[j].eb == 4) ? 2'd2 :
                      (seq[j].eb == 2) ? 2'd1 : 2'd0;
            m_q    <= 12'(seq[j].m);
            n_q    <= 12'(seq[j].n);
            j++;
          end
          stream_cb.din_data  <= in_beats[i];
          stream_cb.din_valid <= 1'b1;
          do @(stream_cb); while (!stream_cb.din_ready);
        end
        stream_cb.din_valid <= 1'b0;
        stream_cb.din_data  <= '0;
      end
      begin : monitor
        automatic longint unsigned cyc = 0;
        @(stream_cb);
        stream_cb.dout_ready <= 1'b1;
        while (out_beats < total_beats) begin
          if (bp) begin
            stream_cb.dout_ready <= 1'b0;
            repeat (out_beats % 4) begin @(stream_cb); cyc++; end
            stream_cb.dout_ready <= 1'b1;
          end
          do begin @(stream_cb); cyc++; end while (!stream_cb.dout_valid);
          if (out_beats == 0) out_first = cyc;
          out_last = cyc;
          if (stream_cb.dout_strb !== exp_strb[out_beats]) begin
            errors++;
            if (errors <= 16) $display("[B2B] %s beat %0d STRB %h exp %h", name, out_beats,
                                       stream_cb.dout_strb, exp_strb[out_beats]);
          end
          for (int unsigned p = 0; p < StrbWidth; p++)
            if (exp_strb[out_beats][p] && stream_cb.dout_data[p] !== exp_data[out_beats][p]) begin
              errors++;
              if (errors <= 16) $display("[B2B] %s beat %0d byte %0d = %h exp %h", name,
                                         out_beats, p, stream_cb.dout_data[p],
                                         exp_data[out_beats][p]);
            end
          out_beats++;
        end
        stream_cb.dout_ready <= 1'b0;
      end
    join
    errs = errors - e0;
    rate = int'((1000 * total_beats) / (out_last - out_first + 1));
    $display("[B2B] %s: %0d matrices, %0d beats in %0d cycles = %.3f beat/cycle BP=%0d %s",
             name, seq.size(), total_beats, out_last - out_first + 1, real'(rate) / 1000.0, bp,
             (errs == 0) ? "PASS" : "FAIL");
  endtask

  // All back-to-back sequences, each with and without backpressure
  task automatic run_b2b_all(output int unsigned errs);
    automatic geom_t same [$], vary [$], multi [$], big [$];
    automatic int unsigned e, rate_same, rate_vary, rate_big, rate;
    automatic int unsigned ne;
    errs = 0;
    for (int unsigned t = 0; t < NumB2bTiles; t++)
      same.push_back(mk_geom(StrbWidth, StrbWidth, 1));
    // cycle the element modes the bus supports; M, N vary within one tile
    for (int unsigned t = 0; t < NumB2bTiles; t++) begin
      automatic int unsigned eb = 1 << (t % ((LogSw < 3 ? LogSw : 3) + 1));
      ne = StrbWidth / eb;
      vary.push_back(mk_geom((t % 3 == 0) ? ne : 1 + (t * 5) % ne,
                             (t % 4 == 1) ? ne : 1 + (t * 3) % ne, eb));
    end
    multi.push_back(mk_geom(13, 19, 1));
    multi.push_back(mk_geom(4 * StrbWidth, 4 * StrbWidth, 1));
    if (StrbWidth >= 2) multi.push_back(mk_geom(7, 5, 2));
    if (StrbWidth >= 4) multi.push_back(mk_geom(5, 3, 4));
    multi.push_back(mk_geom(3 * StrbWidth + 1, 2 * StrbWidth - 1, 1));
    if (StrbWidth >= 8) multi.push_back(mk_geom(9, 6, 8));
    big.push_back(mk_geom(8 * StrbWidth, 8 * StrbWidth, 1));

    run_b2b("single-tile same geometry", same, 1'b0, e, rate_same); errs += e;
    run_b2b("single-tile same geometry", same, 1'b1, e, rate);      errs += e;
    run_b2b("single-tile varying geometry", vary, 1'b0, e, rate_vary); errs += e;
    run_b2b("single-tile varying geometry", vary, 1'b1, e, rate);      errs += e;
    run_b2b("multi-tile varying geometry", multi, 1'b0, e, rate); errs += e;
    run_b2b("multi-tile varying geometry", multi, 1'b1, e, rate); errs += e;
    run_b2b("one 64-tile matrix", big, 1'b0, e, rate_big); errs += e;

    if (FullDuplex && (rate_same < MinTileRateFd1 || rate_vary < MinVaryTileRateFd1 ||
                       rate_big < MinTileRateFd1)) begin
      errs++;
      $display("[B2B] FAIL: FD=1 rate %0d/%0d/%0d below %0d/%0d/%0d per 1000 cycles", rate_same,
               rate_vary, rate_big, MinTileRateFd1, MinVaryTileRateFd1, MinTileRateFd1);
    end
    if (!FullDuplex && (rate_same > MaxTileRateFd0 || rate_vary > MaxTileRateFd0 ||
                        rate_big > MaxTileRateFd0)) begin
      errs++;
      $display("[B2B] FAIL: FD=0 rate %0d/%0d/%0d above %0d per 1000 cycles",
               rate_same, rate_vary, rate_big, MaxTileRateFd0);
    end
  endtask

  initial begin
    automatic int unsigned total = 0, ce;
    automatic int unsigned bp_arg = 0;
    din_valid = 1'b0; dout_ready = 1'b0; mode_q = '0; m_q = '0; n_q = '0;
    if ($value$plusargs("BP=%d", bp_arg)) backpressure = (bp_arg != 0);

    rst_n = 1'b0; clear = 1'b1;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    clear = 1'b0;
    @(posedge clk);

    for (int unsigned k = 0; k < NCases; k++) begin
      if (Cases[k][2] > StrbWidth) continue;   // element must fit the bus
      run_case(Cases[k][0], Cases[k][1], Cases[k][2], ce);
      if (ce == 0) $display("[TB] PASS: %0dx%0d EB=%0d transpose matches DPI golden",
                            Cases[k][0], Cases[k][1], Cases[k][2]);
      else         $display("[TB] FAIL: %0dx%0d EB=%0d (%0d errors)",
                            Cases[k][0], Cases[k][1], Cases[k][2], ce);
      total += ce;
    end

    run_b2b_all(ce);
    total += ce;

    if (total == 0) $display("[TB] ALL PASS (%0d cases, StrbWidth=%0d, FullDuplex=%0d)",
                             NCases, StrbWidth, FullDuplex);
    else            $fatal(1, "[TB] FAIL: %0d total errors", total);
    repeat (5) @(posedge clk);
    $finish;
  end

  initial begin
    #100000000;
    $fatal(1, "[TB] FAIL: timeout");
  end

endmodule

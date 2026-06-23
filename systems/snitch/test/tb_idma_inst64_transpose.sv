// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>

/// End-to-end on-the-fly transpose through the inst64 frontend over the OBI/
/// TCDM port (and AXI->OBI): DMCPY transpose decode -> opt.compute ->
/// idma_transpose_midend (address-gen) -> idma_nd_midend -> backend -> memory.
/// Sweeps a geometry list in one elaboration (one run per structural config,
/// i.e. per BankSkew). Checks transposed data, bank-skew padding, back-to-back
/// geometry leak (consecutive cases), cross-transfer compute leak, and reject.
module tb_idma_inst64_transpose #(
  parameter bit BankSkew = 1'b0
);
  import idma_inst64_tb_pkg::*;

  localparam int unsigned StrbWidth = AxiDataWidth/8;

  // TCDM/OBI region (addr_map routes < 0x1000_0000 to the OBI/TCDM port);
  // ASRC is an external matrix in the AXI (ToSoC) region for the AXI->OBI case.
  localparam addr_t TSRC = 64'h0000_1000;
  localparam addr_t TDST = 64'h0040_0000;
  localparam addr_t CPY  = 64'h0080_0000;
  localparam addr_t ASRC = 64'h8000_0000;

  // Geometry cases (M, N, EB) swept in one elaboration: int8/fp16/fp32, square/
  // rectangular/odd; 32x8 EB4 and 64x4 EB2 trigger the BankSkew pitch pad.
  localparam int unsigned NC = 8;
  localparam int unsigned Cases [NC][3] = '{
    '{ 8,  8, 1}, '{ 6,  5, 1}, '{16, 16, 1}, '{ 5,  7, 2},
    '{10,  6, 2}, '{12,  8, 4}, '{32,  8, 4}, '{64,  4, 2}
  };

  idma_inst64_base #(.ComputeEnable('{transpose: 1'b1}), .AddrGenTranspose(1'b1),
                     .BankSkew(BankSkew)) harness();

  int unsigned errs = 0;

  // backend burst counter (address-gen issues M*N one-element bursts)
  longint unsigned burst_cnt = 0;
  always @(posedge harness.clk)
    if (harness.i_dut.idma_req_valid[0] && harness.i_dut.idma_req_ready[0]) burst_cnt++;

  // Unique per-element fingerprint: byte b of element idx encodes (idx>>8b), so
  // a mis-permutation cannot hide behind a value collision.
  function automatic logic [7:0] fp(input int unsigned idx, input int unsigned b);
    return 8'((idx >> (8*b)) & 32'hFF);
  endfunction

  // padded dst row pitch (matches idma_transpose_midend BankSkew rule): pad by
  // one bus-word of elements when mm*eb is an even number of bus words
  function automatic int unsigned skew_pitch(input int unsigned mm, input int unsigned eb);
    if (BankSkew && ((mm*eb) % (2*StrbWidth) == 0)) return mm + StrbWidth/eb;
    else return mm;
  endfunction

  // memory backdoors selected by protocol: OBI (TCDM) vs AXI (ToSoC)
  task automatic seed_byte(input bit obi, input addr_t a, input logic [7:0] d);
    if (obi) harness.obi_write_byte(a, d); else harness.mem_write_byte(a, d);
  endtask
  function automatic logic [7:0] peek_byte(input bit obi, input addr_t a);
    return obi ? harness.obi_read_byte(a) : harness.mem_read_byte(a);
  endfunction

  // Run one mm x nn (eb-byte element) transpose src -> dst via address-gen.
  // src_obi/dst_obi pick the TCDM(OBI) vs external(AXI) memory.
  task automatic do_transpose(input int unsigned mm, input int unsigned nn, input int unsigned eb,
                              input addr_t src, input addr_t dst,
                              input bit src_obi, input bit dst_obi);
    tf_id_t tid;
    longint unsigned c0, cyc, b0;
    int unsigned mp, mode;
    mp   = skew_pitch(mm, eb);
    mode = (eb == 4) ? 2 : (eb == 2) ? 1 : 0;
    for (int unsigned idx = 0; idx < mm*nn; idx++)
      for (int unsigned b = 0; b < eb; b++)
        seed_byte(src_obi, src + idx*eb + b, fp(idx, b));
    // dst is an N x mp transpose (mp == M unless bank-skew pads the pitch)
    for (int unsigned k = 0; k < nn*mp*eb; k++)
      seed_byte(dst_obi, dst + k, 8'hCC);

    c0 = harness.drv_if.cycle_counter; b0 = burst_cnt;
    harness.drv_if.dma_transpose(src, dst, 12'(mm), 12'(nn), 2'(mode), 3'd0, tid);
    harness.drv_if.dma_wait(tid, 0);
    harness.drv_if.dma_wait_idle(0);   // ensure all writes retired before reading
    cyc = harness.drv_if.cycle_counter - c0;
    $display("  %0dx%0d EB=%0d %s->%s pitch=%0d: bursts=%0d (exp %0d) cycles=%0d", mm, nn, eb,
             src_obi ? "OBI" : "AXI", dst_obi ? "OBI" : "AXI", mp, burst_cnt-b0, mm*nn, cyc);

    // out_T[c][r] == in[r][c] at dst row pitch mp
    for (int unsigned c = 0; c < nn; c++)
      for (int unsigned r = 0; r < mm; r++)
        for (int unsigned b = 0; b < eb; b++) begin
          automatic logic [7:0] got = peek_byte(dst_obi, dst + (c*mp + r)*eb + b);
          automatic logic [7:0] exp = peek_byte(src_obi, src + (r*nn + c)*eb + b);
          if (got !== exp) begin
            errs++;
            if (errs <= 12)
              $display("[TP] data mismatch %0dx%0d out_T[%0d][%0d].b%0d=%02h exp %02h",
                       mm, nn, c, r, b, got, exp);
          end
        end
    // bank-skew padding (columns r in [mm, mp)) must stay sentinel
    for (int unsigned c = 0; c < nn; c++)
      for (int unsigned r = mm; r < mp; r++)
        for (int unsigned b = 0; b < eb; b++)
          if (peek_byte(dst_obi, dst + (c*mp + r)*eb + b) !== 8'hCC) begin
            errs++;
            if (errs <= 12) $display("[TP] skew padding clobbered %0dx%0d [%0d][%0d]", mm, nn, c, r);
          end
  endtask

  initial begin
    @(posedge harness.rst_n);
    repeat (10) @(posedge harness.clk);
    $display("=== inst64 transpose (BankSkew=%0d, StrbWidth=%0d) ===", BankSkew, StrbWidth);

    // geometry sweep, OBI->OBI (consecutive cases also cover back-to-back leak)
    for (int unsigned k = 0; k < NC; k++)
      do_transpose(Cases[k][0], Cases[k][1], Cases[k][2], TSRC, TDST, 1'b1, 1'b1);

    // AXI->OBI: load an external matrix into TCDM transposed
    do_transpose(16, 12, 4, ASRC, TDST, 1'b0, 1'b1);

    // cross-transfer compute leak: a plain OBI copy must NOT inherit opt.compute
    begin
      automatic int unsigned len = 128;
      tf_id_t tid2;
      for (int unsigned k = 0; k < len; k++) harness.obi_write_byte(TSRC + k, 8'hE0 + k[4:0]);
      for (int unsigned k = 0; k < len; k++) harness.obi_write_byte(CPY  + k, 8'h00);
      harness.drv_if.dma_set_source(TSRC);
      harness.drv_if.dma_set_dest(CPY);
      harness.drv_if.dma_start_copy(addr_t'(len), 2'b00, 3'd0, tid2);
      harness.drv_if.dma_wait(tid2, 0);
      harness.drv_if.dma_wait_idle(0);
      for (int unsigned k = 0; k < len; k++)
        if (harness.obi_read_byte(CPY + k) !== harness.obi_read_byte(TSRC + k)) begin
          errs++;
          if (errs <= 12) $display("[TP] leak: post-transpose copy wrong at %0d", k);
        end
    end

    // malformed transpose requests: error response, nothing launched
    begin
      logic err;
      longint unsigned b_rej;
      b_rej = burst_cnt;
      harness.drv_if.dma_transpose_err(TSRC, TDST, 12'd8, 12'd8, 2'd3, 3'd0, err);
      if (!err) begin errs++; $display("[TP] reject fail: reserved mode 3"); end
      harness.drv_if.dma_transpose_err(TSRC, TDST, 12'd0, 12'd8, 2'd0, 3'd0, err);
      if (!err) begin errs++; $display("[TP] reject fail: M == 0"); end
      harness.drv_if.dma_transpose_err(TSRC, TDST + 64'd1, 12'd8, 12'd8, 2'd0, 3'd0, err);
      if (!err) begin errs++; $display("[TP] reject fail: unaligned dst"); end
      repeat (50) @(posedge harness.clk);
      if (burst_cnt != b_rej) begin
        errs++; $display("[TP] reject fail: rejected request launched bursts");
      end
    end

    if (errs == 0) $display("[TP] PASS: %0d-case sweep + AXI->OBI + no-leak + reject OK", NC);
    else           $fatal(1, "[TP] FAIL: %0d mismatches", errs);
    $finish;
  end

  initial begin
    repeat (1_000_000) @(posedge harness.clk);
    $fatal(1, "[TIMEOUT] inst64 transpose");
  end

endmodule

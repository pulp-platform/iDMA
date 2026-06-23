// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>

/// End-to-end on-the-fly transpose through the inst64 frontend:
/// accelerator bus -> DMCPY transpose decode -> opt.compute -> transpose_midend
/// -> nd_midend -> rw_axi+compute backend -> axi_sim_mem. Checks transposed
/// data, padding integrity, multi-tile geometry, back-to-back (geometry leak),
/// and cross-transfer compute leak.
module tb_idma_inst64_transpose #(
  parameter int unsigned M  = 40,   // matrix rows (elements)
  parameter int unsigned N  = 70,   // matrix cols (elements)
  parameter int unsigned EB = 4     // element size in bytes (1/2/4)
);
  import idma_inst64_tb_pkg::*;

  localparam int unsigned StrbWidth = AxiDataWidth/8;
  localparam int unsigned NE   = StrbWidth/EB;
  localparam int unsigned MODE = (EB==4) ? 2 : (EB==2) ? 1 : 0;

  // TCDM/OBI region (addr_map routes < 0x1000_0000 to the OBI/TCDM port);
  // ASRC is an external matrix in the AXI (ToSoC) region for the AXI->OBI case.
  localparam addr_t TSRC = 64'h0000_1000;
  localparam addr_t TDST = 64'h0040_0000;
  localparam addr_t CPY  = 64'h0080_0000;
  localparam addr_t ASRC = 64'h8000_0000;

  idma_inst64_base #(.ComputeEnable('{transpose: 1'b1}), .AddrGenTranspose(1'b1)) harness();

  int unsigned errs = 0;

  // backend burst counter (proves the full NumDim=4 walk: NE*YT*NT bursts/tile-rows)
  longint unsigned burst_cnt = 0;
  always @(posedge harness.clk)
    if (harness.i_dut.idma_req_valid[0] && harness.i_dut.idma_req_ready[0]) burst_cnt++;

  // Unique per-element fingerprint: byte b of element idx encodes (idx>>8b).
  // Distinguishes distinct source elements so a mis-permutation cannot hide
  // behind a value collision (a plain byte ramp aliases mod 256).
  function automatic logic [7:0] fp(input int unsigned idx, input int unsigned b);
    return 8'((idx >> (8*b)) & 32'hFF);
  endfunction

  // memory backdoors selected by protocol: OBI (TCDM) vs AXI (ToSoC)
  task automatic seed_byte(input bit obi, input addr_t a, input logic [7:0] d);
    if (obi) harness.obi_write_byte(a, d); else harness.mem_write_byte(a, d);
  endtask
  function automatic logic [7:0] peek_byte(input bit obi, input addr_t a);
    return obi ? harness.obi_read_byte(a) : harness.mem_read_byte(a);
  endfunction

  // Run one transpose of an mm x nn matrix src -> dst (address-gen, contiguous
  // N x M output). src_obi/dst_obi pick the TCDM(OBI) vs external(AXI) memory.
  task automatic do_transpose(input int unsigned mm, input int unsigned nn,
                              input addr_t src, input addr_t dst,
                              input bit src_obi, input bit dst_obi);
    tf_id_t tid;
    longint unsigned c0, cyc, b0;
    for (int unsigned idx = 0; idx < mm*nn; idx++)
      for (int unsigned b = 0; b < EB; b++)
        seed_byte(src_obi, src + idx*EB + b, fp(idx, b));
    // address-gen output is a contiguous N x M transpose (pitch M, no padding)
    for (int unsigned k = 0; k < nn*mm*EB; k++)
      seed_byte(dst_obi, dst + k, 8'hCC);

    c0 = harness.drv_if.cycle_counter; b0 = burst_cnt;
    harness.drv_if.dma_transpose(src, dst, 12'(mm), 12'(nn), 2'(MODE), 3'd0, tid);
    harness.drv_if.dma_wait(tid, 0);
    harness.drv_if.dma_wait_idle(0);   // ensure all writes retired before reading
    cyc = harness.drv_if.cycle_counter - c0;
    $display("  transpose %0dx%0d %s->%s: bursts=%0d (exp M*N=%0d) cycles=%0d", mm, nn,
             src_obi ? "OBI" : "AXI", dst_obi ? "OBI" : "AXI", burst_cnt-b0, mm*nn, cyc);

    // out_T[c][r] == in[r][c], dst contiguous N x M (pitch M)
    for (int unsigned c = 0; c < nn; c++)
      for (int unsigned r = 0; r < mm; r++)
        for (int unsigned b = 0; b < EB; b++) begin
          automatic logic [7:0] got = peek_byte(dst_obi, dst + (c*mm + r)*EB + b);
          automatic logic [7:0] exp = peek_byte(src_obi, src + (r*nn + c)*EB + b);
          if (got !== exp) begin
            errs++;
            if (errs <= 12)
              $display("[TP] data mismatch out_T[%0d][%0d].b%0d=%02h exp %02h", c, r, b, got, exp);
          end
        end
  endtask

  initial begin
    @(posedge harness.rst_n);
    repeat (10) @(posedge harness.clk);

    $display("=== inst64 transpose EB=%0d ===", EB);

    // 1. OBI->OBI: transpose a tile within L1/TCDM (the Snitch DMA case)
    do_transpose(M, N, TSRC, TDST, 1'b1, 1'b1);

    // 2. AXI->OBI: load an external matrix into TCDM transposed
    do_transpose(M, N, ASRC, TDST + 64'h0010_0000, 1'b0, 1'b1);

    // 3. back-to-back (swapped shape, fresh dst): catch geometry/state leak
    do_transpose(N, M, TSRC + 64'h0010_0000, TDST + 64'h0020_0000, 1'b1, 1'b1);

    // 4. cross-transfer compute leak: a plain copy after transposes must NOT
    //    inherit opt.compute (default-zeroed). Verify a 1:1 OBI copy.
    begin
      automatic int unsigned len = 128;
      tf_id_t tid2;
      for (int unsigned k = 0; k < len; k++) harness.obi_write_byte(TSRC + k, 8'hE0 + k[4:0]);
      for (int unsigned k = 0; k < len; k++) harness.obi_write_byte(CPY + k, 8'h00);
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

    // 5. malformed transpose requests: error response, nothing launched
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
      // a valid transpose must still work after rejections
      do_transpose(8, 8, TSRC + 64'h0030_0000, TDST + 64'h0030_0000, 1'b1, 1'b1);
    end

    if (errs == 0) $display("[TP] PASS: transpose data + padding + back-to-back + no-leak OK");
    else           $fatal(1, "[TP] FAIL: %0d mismatches", errs);
    $finish;
  end

  initial begin
    repeat (400000) @(posedge harness.clk);
    $fatal(1, "[TIMEOUT] inst64 transpose");
  end

endmodule

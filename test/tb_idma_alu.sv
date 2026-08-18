// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Directed byte-wise ALU campaign on the rw_axi backend: every function over a
// set of geometries (aligned, misaligned bases, partial tail beats, page
// crossings, multi-burst lengths, single bytes) plus a back-to-back run that
// switches the function per transfer. Byte-exact against the DPI-C golden;
// canary bytes around each destination catch out-of-bounds writes; an AXI shim
// injects random per-channel stalls.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_alu
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter int unsigned StallPct   = 30,
  parameter bit          RAWCoupling = 1'b1,
  parameter bit          Verbose     = 1'b0
);

  import "DPI-C" function void alu_gm_load(input int idx, input int val);
  import "DPI-C" function void alu_gm_run(input int func, input int imm, input int len);
  import "DPI-C" function int  alu_gm_get(input int idx);

  `include "include/tb_idma_mx_common.svh"

  // random-stall shim: a channel's go bit may rise any cycle but only falls after its handshake
  logic aw_go, w_go, ar_go, b_go, r_go;
  function automatic logic go_next(input logic go, input logic vld, input logic rdy);
    if (go && vld && !rdy) return 1'b1;
    return ($urandom_range(99) >= StallPct);
  endfunction
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) {aw_go, w_go, ar_go, b_go, r_go} <= '0;
    else begin
      aw_go <= go_next(aw_go, axi_req.aw_valid,    axi_rsp_mem.aw_ready);
      w_go  <= go_next(w_go,  axi_req.w_valid,     axi_rsp_mem.w_ready);
      ar_go <= go_next(ar_go, axi_req.ar_valid,    axi_rsp_mem.ar_ready);
      b_go  <= go_next(b_go,  axi_rsp_mem.b_valid, axi_req.b_ready);
      r_go  <= go_next(r_go,  axi_rsp_mem.r_valid, axi_req.r_ready);
    end
  end
  always_comb begin
    axi_req_mem = axi_req;
    axi_rsp     = axi_rsp_mem;
    axi_req_mem.aw_valid = axi_req.aw_valid & aw_go;
    axi_req_mem.w_valid  = axi_req.w_valid  & w_go;
    axi_req_mem.ar_valid = axi_req.ar_valid & ar_go;
    axi_req_mem.b_ready  = axi_req.b_ready  & b_go;
    axi_req_mem.r_ready  = axi_req.r_ready  & r_go;
    axi_rsp.aw_ready     = axi_rsp_mem.aw_ready & aw_go;
    axi_rsp.w_ready      = axi_rsp_mem.w_ready  & w_go;
    axi_rsp.ar_ready     = axi_rsp_mem.ar_ready & ar_go;
    axi_rsp.b_valid      = axi_rsp_mem.b_valid  & b_go;
    axi_rsp.r_valid      = axi_rsp_mem.r_valid  & r_go;
  end

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{alu: 1'b1, alu_mul: 1'b1, default: '0}),
    .ComputeTuning('1),
    .RAWCouplingAvail(RAWCoupling), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(3),
    .MemSysDepth(0),
    .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t), .idma_eh_req_t(idma_eh_req_t),
    .idma_busy_t(idma_busy_t), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .write_meta_channel_t(write_meta_channel_t), .read_meta_channel_t(read_meta_channel_t)
  ) i_idma_backend (
    .clk_i(clk), .rst_ni(rst_n),
    .idma_req_i(idma_req), .req_valid_i(req_valid), .req_ready_o(req_ready),
    .idma_rsp_o(idma_rsp), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
    .idma_eh_req_i(idma_eh_req), .eh_req_valid_i(eh_req_valid), .eh_req_ready_o(eh_req_ready),
    .axi_read_req_o(axi_read_req), .axi_read_rsp_i(axi_read_rsp),
    .axi_write_req_o(axi_write_req), .axi_write_rsp_i(axi_write_rsp), .busy_o(busy)
  );

  int unsigned rsp_cnt;
  always @(posedge clk) if (rsp_valid && rsp_ready) rsp_cnt <= rsp_cnt + 1;

  localparam int unsigned NumFuncs = 7;
  localparam idma_pkg::alu_func_e Funcs [NumFuncs] = '{
    ALU_NOT, ALU_ADDI, ALU_SUBI, ALU_MULI, ALU_ANDI, ALU_ORI, ALU_XORI};
  localparam int unsigned Margin = 32;
  localparam logic [7:0] Canary = 8'hC5;

  function automatic logic [7:0] src_gen(input int unsigned i, input int unsigned seed);
    return 8'(((i + seed) * 32'd2654435761) >> 13);
  endfunction

  // launch one ALU transfer without waiting for its response (drive at TA, sample at TT)
  task automatic launch(input addr_t src, input addr_t dst, input int unsigned len,
                        input logic en, input idma_pkg::alu_func_e func, input logic [7:0] imm);
    automatic idma_req_t req = '0;
    req.length   = tf_len_t'(len);
    req.src_addr = src;
    req.dst_addr = dst;
    req.opt.src_protocol = idma_pkg::AXI;
    req.opt.dst_protocol = idma_pkg::AXI;
    req.opt.src.burst    = axi_pkg::BURST_INCR;
    req.opt.dst.burst    = axi_pkg::BURST_INCR;
    req.opt.beo.decouple_rw = 1'b1;
    req.opt.beo.decouple_aw = 1'b1;
    req.opt.compute.enable  = en;
    req.opt.compute.op      = idma_pkg::COMPUTE_ALU;
    req.opt.compute.params.alu.func = func;
    req.opt.compute.params.alu.imm  = imm;
    req.opt.last            = 1'b1;
    @(posedge clk); #TA;
    idma_req  = req;
    req_valid = 1'b1;
    #(TT - TA);
    while (!req_ready) begin @(posedge clk); #TT; end
    @(posedge clk); #TA;
    req_valid = 1'b0;
    idma_req  = '0;
  endtask

  task automatic wait_rsps(input int unsigned n);
    while (rsp_cnt < n) @(posedge clk);
    repeat (10) @(posedge clk);
  endtask

  // fill src (and the golden input) with a seeded pattern, dst and margins with canaries
  task automatic prepare(input addr_t src, input addr_t dst, input int unsigned len,
                         input int unsigned seed);
    for (int unsigned i = 0; i < len; i++) begin
      wr_mem(src + i, src_gen(i, seed));
      alu_gm_load(int'(i), int'(src_gen(i, seed)));
    end
    for (int unsigned i = 0; i < len + 2 * Margin; i++) wr_mem(dst - Margin + i, Canary);
  endtask

  // byte-exact destination check plus the canary margins; returns the error count
  function automatic int unsigned check(input int unsigned geo, input idma_pkg::alu_func_e func,
                                        input addr_t dst, input int unsigned len);
    automatic int unsigned errs = 0;
    for (int unsigned i = 0; i < len; i++)
      if (rd_mem(dst + i) !== 8'(alu_gm_get(int'(i)))) begin
        errs++;
        if (errs <= 8) $display("[ALU] geo%0d func=%0d dst[%0d] = %02h exp %02h", geo, func, i,
                                rd_mem(dst + i), 8'(alu_gm_get(int'(i))));
      end
    for (int unsigned i = 0; i < Margin; i++) begin
      if (rd_mem(dst - Margin + i) !== Canary) begin
        errs++;
        if (errs <= 8) $display("[ALU] geo%0d func=%0d canary before dst clobbered", geo, func);
      end
      if (rd_mem(dst + len + i) !== Canary) begin
        errs++;
        if (errs <= 8) $display("[ALU] geo%0d func=%0d canary after dst clobbered", geo, func);
      end
    end
    return errs;
  endfunction

  // one function over one geometry, waited
  task automatic run_case(input int unsigned geo, input idma_pkg::alu_func_e func,
                          input logic [7:0] imm, input addr_t src, input addr_t dst,
                          input int unsigned len, input int unsigned seed,
                          inout int unsigned errs);
    automatic int unsigned base = rsp_cnt;
    if (Verbose)
      $display("[ALU] geo%0d func=%0d imm=%02h src=%h dst=%h len=%0d @%0t", geo, func, imm, src,
               dst, len, $time);
    prepare(src, dst, len, seed);
    alu_gm_run(int'(func), int'(imm), int'(len));
    launch(src, dst, len, 1'b1, func, imm);
    wait_rsps(base + 1);
    errs += check(geo, func, dst, len);
  endtask

  localparam addr_t SrcBase = 'h0001_0000, DstBase = 'h0009_0000;

  // geometry list: source offset, destination offset, length
  localparam int unsigned NumGeos = 9;
  localparam int unsigned GeoSrcOff [NumGeos] = '{0, 1, 0, 5, 4096 - 7, 1, 7, 0, StrbWidth / 2};
  localparam int unsigned GeoDstOff [NumGeos] = '{0, 0, 3, 2, 4096 - 3, 2, 6, 0, StrbWidth / 2};
  localparam int unsigned GeoLen    [NumGeos] = '{
    4 * StrbWidth,      // aligned, whole beats
    3 * StrbWidth + 5,  // misaligned src, tail beat
    2 * StrbWidth + 1,  // misaligned dst
    7 * StrbWidth + 3,  // both misaligned
    3 * StrbWidth + 2,  // read and write page crossings
    9000,               // multi-burst, both misaligned
    1,                  // single byte
    StrbWidth - 1,      // sub-beat, aligned
    StrbWidth           // half-beat offsets
  };

  initial begin
    automatic int unsigned errs = 0, seed = 0, base;
    automatic addr_t src, dst;
    automatic logic [7:0] imm;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0; rsp_cnt = 0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    // every function over every geometry
    for (int unsigned g = 0; g < NumGeos; g++) begin
      for (int unsigned f = 0; f < NumFuncs; f++) begin
        src = SrcBase + GeoSrcOff[g];
        dst = DstBase + GeoDstOff[g];
        imm = 8'(seed * 37 + 3);
        run_case(g, Funcs[f], imm, src, dst, GeoLen[g], seed, errs);
        seed++;
      end
    end

    // back-to-back (reported as geo NumGeos): switch the function per transfer without waiting
    base = rsp_cnt;
    for (int unsigned f = 0; f < NumFuncs; f++) begin
      src = SrcBase + 4 * StrbWidth * f + 1;
      dst = DstBase + (4 * StrbWidth + 2 * Margin) * f + 2;
      for (int unsigned i = 0; i < 3 * StrbWidth; i++) wr_mem(src + i, src_gen(i, 100 + f));
      for (int unsigned i = 0; i < 3 * StrbWidth + 2 * Margin; i++)
        wr_mem(dst - Margin + i, Canary);
      launch(src, dst, 3 * StrbWidth, 1'b1, Funcs[f], 8'(f + 1));
    end
    wait_rsps(base + NumFuncs);
    for (int unsigned f = 0; f < NumFuncs; f++) begin
      src = SrcBase + 4 * StrbWidth * f + 1;
      dst = DstBase + (4 * StrbWidth + 2 * Margin) * f + 2;
      for (int unsigned i = 0; i < 3 * StrbWidth; i++)
        alu_gm_load(int'(i), int'(src_gen(i, 100 + f)));
      alu_gm_run(int'(Funcs[f]), int'(f + 1), int'(3 * StrbWidth));
      errs += check(NumGeos, Funcs[f], dst, 3 * StrbWidth);
    end

    // a plain copy after compute must be a verbatim copy again
    base = rsp_cnt;
    src = SrcBase + 3; dst = DstBase + 5;
    for (int unsigned i = 0; i < 2 * StrbWidth + 3; i++) wr_mem(src + i, src_gen(i, 999));
    for (int unsigned i = 0; i < 2 * StrbWidth + 3 + 2 * Margin; i++)
      wr_mem(dst - Margin + i, Canary);
    launch(src, dst, 2 * StrbWidth + 3, 1'b0, ALU_NOT, 8'h00);
    wait_rsps(base + 1);
    for (int unsigned i = 0; i < 2 * StrbWidth + 3; i++)
      if (rd_mem(dst + i) !== src_gen(i, 999)) begin
        errs++; if (errs <= 8) $display("[ALU] plain copy dst[%0d] = %02h", i, rd_mem(dst + i));
      end

    if (errs == 0) $display("[ALU] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else $fatal(1, "[ALU] %0d errors (StrbWidth=%0d)", errs, StrbWidth);
    $finish;
  end

  initial begin #50ms; $fatal(1, "[ALU] timeout"); end

endmodule

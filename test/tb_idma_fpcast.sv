// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Element-cast campaign on the rw_axi backend: every cast op over whole-beat lengths
// (short, page-crossing, multi-burst) with element vectors that sweep the exponent range
// and hit the corner cases (+-0, +-Inf, quiet and signalling NaN, subnormals, exact
// rounding ties, saturation boundaries), plus back-to-back casts that switch the op.
// Byte-exact against the DPI-C golden (host FPU); canary bytes around each destination;
// an AXI shim injects random per-channel stalls.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_fpcast
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter int unsigned StallPct   = 30,
  parameter bit          Verbose    = 1'b0
);

  import "DPI-C" function void cast_gm_load(input int idx, input int val);
  import "DPI-C" function int  cast_gm_run(input int op, input int in_bytes);
  import "DPI-C" function int  cast_gm_get(input int idx);

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
    .ComputeOps(idma_pkg::compute_enable_t'{fpcast: 1'b1, default: '0}),
    .ComputeTuning('1),
    .RAWCouplingAvail(1'b1), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
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

  localparam int unsigned NumOps = 7;
  localparam idma_pkg::compute_op_e Ops [NumOps] = '{
    COMPUTE_CAST_FP32_I8, COMPUTE_CAST_FP32_I16, COMPUTE_CAST_FP32_BF16, COMPUTE_CAST_BF16_I8,
    COMPUTE_CAST_BF16_I16, COMPUTE_CAST_BF16_FP32, COMPUTE_CAST_FP16_FP32};
  localparam int unsigned Margin = 32;
  localparam logic [7:0] Canary = 8'hC5;

  function automatic logic [31:0] hash32(input int unsigned i);
    automatic logic [31:0] h = 32'(i) * 32'd2654435761;
    return h ^ (h >> 15) ^ (32'(i) * 32'd40503);
  endfunction

  // FP32 element: corner cases every 16th, otherwise sign/exponent/mantissa swept independently
  function automatic logic [31:0] fp32_gen(input int unsigned i);
    automatic logic [31:0] h = hash32(i);
    case (i % 16)
      0:  return 32'h0000_0000;                       // +0
      1:  return 32'h8000_0000;                       // -0
      2:  return 32'h7F80_0000;                       // +Inf
      3:  return 32'hFF80_0000;                       // -Inf
      4:  return 32'h7FC0_0000 | (h & 32'h003F_FFFF); // qNaN
      5:  return 32'h7F80_0001 | (h & 32'h001F_FFFF); // sNaN
      6:  return {h[31], 8'd0, 23'd1 | h[22:0]};      // subnormal
      7:  return {h[31], 8'd126, 23'd0};              // +-0.5 (tie to even 0)
      8:  return {h[31], 8'd127, 23'h400000};         // +-1.5 (tie to even 2)
      9:  return {h[31], 8'd133, 23'h7F0000};         // +-127.5 (int8 saturation edge)
      10: return {h[31], 8'd141, 23'h7FFF00};         // +-32767.5 (int16 saturation edge)
      11: return {h[31], 8'd134, 23'h008000};         // +-128.5 (int8 negative edge)
      12: return {h[31], h[30:23], 15'd0, h[15], 16'h8000} ^ (32'(h[16]) << 16); // bf16 tie
      13: return {h[31], 8'(120 + (i % 20)), h[22:0]}; // small magnitudes around 1
      14: return {h[31], 8'(127 + (i % 18)), h[22:0]}; // magnitudes up to 2^17
      default: return h;
    endcase
  endfunction

  // 16-bit element (BF16 or FP16 bit pattern): specials every 8th, else swept
  function automatic logic [15:0] h16_gen(input int unsigned i);
    automatic logic [31:0] h = hash32(i + 4096);
    case (i % 8)
      0: return 16'h0000;                 // +0
      1: return 16'h8000;                 // -0
      2: return {h[15], 8'hFF, 7'd0};     // Inf (bf16) / NaN (fp16)
      3: return {h[15], 8'hFF, 7'h40};    // NaN (bf16) / NaN (fp16)
      4: return {h[15], 5'd0, 10'd1 | h[9:0]}; // subnormal (fp16) / tiny normal (bf16)
      5: return {h[15], 5'd31, 10'd0};    // fp16 Inf / bf16 large
      6: return {h[15], 8'(120 + (i % 16)), h[6:0]}; // bf16 near 1
      default: return h[15:0];
    endcase
  endfunction

  // launch one cast (drive at TA, sample at TT)
  task automatic launch(input addr_t src, input addr_t dst, input int unsigned len,
                        input idma_pkg::compute_op_e op);
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
    req.opt.compute.enable  = 1'b1;
    req.opt.compute.op      = op;
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

  // fill src (and the golden input) with elements of the op's source format
  task automatic prepare(input idma_pkg::compute_op_e op, input addr_t src, input addr_t dst,
                         input int unsigned len, input int unsigned out_len,
                         input int unsigned seed, input bit canaries = 1'b1);
    automatic logic [31:0] w;
    automatic logic [15:0] h;
    if (idma_pkg::compute_in_bytes(op) == 4) begin
      for (int unsigned e = 0; e < len / 4; e++) begin
        w = fp32_gen(e + seed);
        for (int unsigned b = 0; b < 4; b++) begin
          wr_mem(src + e*4 + b, w[b*8 +: 8]);
          cast_gm_load(int'(e*4 + b), int'(w[b*8 +: 8]));
        end
      end
    end else begin
      for (int unsigned e = 0; e < len / 2; e++) begin
        h = h16_gen(e + seed);
        for (int unsigned b = 0; b < 2; b++) begin
          wr_mem(src + e*2 + b, h[b*8 +: 8]);
          cast_gm_load(int'(e*2 + b), int'(h[b*8 +: 8]));
        end
      end
    end
    if (canaries)
      for (int unsigned i = 0; i < out_len + 2 * Margin; i++) wr_mem(dst - Margin + i, Canary);
  endtask

  // byte-exact destination check plus the canary margins; returns the error count
  function automatic int unsigned check(input int unsigned geo, input idma_pkg::compute_op_e op,
                                        input addr_t dst, input int unsigned out_len);
    automatic int unsigned errs = 0;
    for (int unsigned i = 0; i < out_len; i++)
      if (rd_mem(dst + i) !== 8'(cast_gm_get(int'(i)))) begin
        errs++;
        if (errs <= 8) $display("[CAST] geo%0d op=%0d dst[%0d] = %02h exp %02h", geo, op, i,
                                rd_mem(dst + i), 8'(cast_gm_get(int'(i))));
      end
    for (int unsigned i = 0; i < Margin; i++) begin
      if (rd_mem(dst - Margin + i) !== Canary) begin
        errs++;
        if (errs <= 8) $display("[CAST] geo%0d op=%0d canary before dst clobbered", geo, op);
      end
      if (rd_mem(dst + out_len + i) !== Canary) begin
        errs++;
        if (errs <= 8) $display("[CAST] geo%0d op=%0d canary after dst clobbered", geo, op);
      end
    end
    return errs;
  endfunction

  function automatic int unsigned out_bytes(input idma_pkg::compute_op_e op,
                                            input int unsigned len);
    return (len / idma_pkg::compute_in_bytes(op)) * idma_pkg::compute_out_bytes(op);
  endfunction

  // one op over one geometry, waited
  task automatic run_case(input int unsigned geo, input idma_pkg::compute_op_e op,
                          input addr_t src, input addr_t dst, input int unsigned len,
                          input int unsigned seed, inout int unsigned errs);
    automatic int unsigned base = rsp_cnt, olen = out_bytes(op, len), golen;
    if (Verbose)
      $display("[CAST] geo%0d op=%0d src=%h dst=%h len=%0d @%0t", geo, op, src, dst, len, $time);
    prepare(op, src, dst, len, olen, seed);
    golen = cast_gm_run(int'(op), int'(len));
    if (golen != olen) begin
      errs++; $display("[CAST] geo%0d op=%0d golden length %0d != %0d", geo, op, golen, olen);
    end
    launch(src, dst, len, op);
    wait_rsps(base + 1);
    errs += check(geo, op, dst, olen);
  endtask

  localparam addr_t SrcBase = 'h0001_0000, DstBase = 'h0009_0000;
  // beat-aligned pitch between back-to-back destinations (largest output plus canaries)
  localparam int unsigned B2bPitch = ((16 * StrbWidth + 2 * Margin + StrbWidth - 1) / StrbWidth)
                                     * StrbWidth;

  // geometry list: source offset, destination offset, length (all whole beats)
  localparam int unsigned NumGeos = 5;
  localparam int unsigned GeoSrcOff [NumGeos] = '{0, 4096 - 2 * StrbWidth, 0, StrbWidth, 0};
  localparam int unsigned GeoDstOff [NumGeos] = '{0, 0, 4096 - StrbWidth, 2 * StrbWidth, 0};
  localparam int unsigned GeoLen    [NumGeos] = '{
    4 * StrbWidth,        // short
    5 * StrbWidth,        // read crosses a page
    6 * StrbWidth,        // write crosses a page (for expanding casts also the read)
    StrbWidth,            // single beat
    4096 + 3 * StrbWidth  // multi-burst
  };

  initial begin
    automatic int unsigned errs = 0, seed = 0, base;
    automatic addr_t src, dst;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0; rsp_cnt = 0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    for (int unsigned g = 0; g < NumGeos; g++) begin
      for (int unsigned o = 0; o < NumOps; o++) begin
        src = SrcBase + GeoSrcOff[g];
        dst = DstBase + GeoDstOff[g];
        run_case(g, Ops[o], src, dst, GeoLen[g], seed, errs);
        seed += 64;
      end
    end

    // back-to-back: switch the op per transfer without waiting, disjoint destinations
    base = rsp_cnt;
    for (int unsigned o = 0; o < NumOps; o++) begin
      src = SrcBase + 8 * StrbWidth * o;
      dst = DstBase + B2bPitch * o;
      prepare(Ops[o], src, dst, 4 * StrbWidth, out_bytes(Ops[o], 4 * StrbWidth), 700 + 64 * o);
      launch(src, dst, 4 * StrbWidth, Ops[o]);
    end
    wait_rsps(base + NumOps);
    for (int unsigned o = 0; o < NumOps; o++) begin
      src = SrcBase + 8 * StrbWidth * o;
      dst = DstBase + B2bPitch * o;
      prepare(Ops[o], src, dst, 4 * StrbWidth, 0, 700 + 64 * o, 1'b0);
      void'(cast_gm_run(int'(Ops[o]), int'(4 * StrbWidth)));
      errs += check(NumGeos, Ops[o], dst, out_bytes(Ops[o], 4 * StrbWidth));
    end

    if (errs == 0) $display("[CAST] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else $fatal(1, "[CAST] %0d errors (StrbWidth=%0d)", errs, StrbWidth);
    $finish;
  end

  initial begin #50ms; $fatal(1, "[CAST] timeout"); end

endmodule

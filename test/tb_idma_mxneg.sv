// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Negative tests: each NegCase issues one illegal compute request and expects
// the matching legalizer guard assert to report (compile with +define+INC_ASSERT).
// The runner greps the transcript for the assert name; case 9 provokes transfer
// overlap and expects the mxquant sub-unit's clear-with-in-flight-state fatal.
// Cases 14-17 cover the ALU (op or multiplier compiled out, undefined function, two-operand
// function without a second read head), 18-19 the casts (odd length, unit compiled out).

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_mxneg
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter int unsigned NegCase    = 1,
  parameter bit          EnDequant  = 1'b1,
  parameter bit          EnFp16     = 1'b1,
  parameter bit          EnAlu      = 1'b1,
  parameter bit          EnAluMul   = 1'b1,
  parameter bit          EnCast     = 1'b1
);

  `include "include/tb_idma_mx_common.svh"

  assign axi_req_mem = axi_req;
  assign axi_rsp     = axi_rsp_mem;


  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{transpose: 1'b1, mxquant: 1'b1, mxfp16: EnFp16,
                                            mxdequant: EnDequant, alu: EnAlu, alu_mul: EnAluMul,
                                            dual: 1'b1, fpcast: EnCast, default: '0}),
    .ComputeTuning('1),
    .RAWCouplingAvail(1'b1), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(StrbWidth),
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

  task automatic issue(input addr_t src, input addr_t dst, input int unsigned L,
                       input idma_pkg::compute_op_e op,
                       input idma_pkg::protocol_e src_prot, input idma_pkg::protocol_e dst_prot,
                       input bit wait_done, input logic [3:0] alu_func = 4'd0);
    idma_req = '0;
    idma_req.length   = tf_len_t'(L);
    idma_req.src_addr = src;
    idma_req.dst_addr = dst;
    idma_req.opt.src_protocol = src_prot;
    idma_req.opt.dst_protocol = dst_prot;
    idma_req.opt.src.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.beo.decouple_rw = 1'b1;
    idma_req.opt.beo.decouple_aw = 1'b1;
    idma_req.opt.compute.enable  = (op != idma_pkg::COMPUTE_NONE);
    idma_req.opt.compute.op      = op;
    idma_req.opt.compute.params.alu.func = idma_pkg::alu_func_e'(alu_func);
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    if (wait_done) while (!(rsp_valid && rsp_ready)) @(posedge clk);
  endtask

  localparam addr_t Src = 'h0001_0000, Dst = 'h0005_0000;

  initial begin
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    for (int unsigned i = 0; i < 8192; i++) i_axi_sim_mem.mem[Src + i] = 8'(i);
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    case (NegCase)
      1: issue(Src, Dst, 100, idma_pkg::COMPUTE_MXQUANT, idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      2: issue(Src + 1, Dst, 128, idma_pkg::COMPUTE_MXQUANT, idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      3: issue(Src, Dst + 1, 128, idma_pkg::COMPUTE_MXQUANT, idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      4: issue(Src, Dst, 64, idma_pkg::COMPUTE_MXQUANT_FP16, idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      5: issue(Src, Dst, 33, idma_pkg::COMPUTE_MXDEQUANT, idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      6: issue(Src, Dst, 33 * StrbWidth, idma_pkg::COMPUTE_MXDEQUANT,
               idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      7: issue(Src, Dst, 128, idma_pkg::COMPUTE_MXQUANT, idma_pkg::OBI, idma_pkg::AXI, 1'b0);
      8: issue(Src, Dst, 128, idma_pkg::COMPUTE_MXQUANT, idma_pkg::AXI, idma_pkg::OBI, 1'b0);
      10: issue(Src, Dst, 4 * StrbWidth, idma_pkg::COMPUTE_TRANSPOSE,
                idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      11: issue(Src, Dst, 32'd264 << 22, idma_pkg::COMPUTE_MXDEQUANT,
                idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      12: issue(Src, Dst, 33 * StrbWidth, idma_pkg::COMPUTE_MXDEQUANT_FP16,
                idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      13: issue(Src, Dst, 64, idma_pkg::COMPUTE_MXQUANT_FP16,
                idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      14: issue(Src, Dst, 64, idma_pkg::COMPUTE_ALU, idma_pkg::AXI, idma_pkg::AXI, 1'b0,
                4'(idma_pkg::ALU_ADDI));
      15: issue(Src, Dst, 64, idma_pkg::COMPUTE_ALU, idma_pkg::AXI, idma_pkg::AXI, 1'b0,
                4'(idma_pkg::ALU_MULI));
      16: issue(Src, Dst, 64, idma_pkg::COMPUTE_ALU, idma_pkg::AXI, idma_pkg::AXI, 1'b0, 4'hF);
      17: issue(Src, Dst, 64, idma_pkg::COMPUTE_ALU, idma_pkg::AXI, idma_pkg::AXI, 1'b0,
                4'(idma_pkg::ALU_ADD));
      18: issue(Src, Dst, StrbWidth + 4, idma_pkg::COMPUTE_CAST_FP32_I8,
                idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      19: issue(Src, Dst, 4 * StrbWidth, idma_pkg::COMPUTE_CAST_BF16_FP32,
                idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      default: $fatal(1, "[MXNEG] unknown NegCase %0d", NegCase);
    endcase

    repeat (3000) @(posedge clk);
    $display("[MXNEG] case %0d done", NegCase);
    $finish();
  end

  initial begin #10_000_000; $display("[MXNEG] case %0d done (timeout)", NegCase); $finish(); end

endmodule

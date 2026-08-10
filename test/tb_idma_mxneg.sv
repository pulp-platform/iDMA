// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Negative tests: each NegCase issues one illegal compute request and expects
// the matching legalizer guard assert to report (compile with +define+INC_ASSERT).
// The runner greps the transcript for the assert name; case 9 provokes transfer
// overlap and expects the mxquant sub-unit's clear-with-in-flight-state fatal.

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
  parameter bit          EnDequant  = 1'b1
);

  localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
  localparam int unsigned StrbWidth = DataWidth / 8;

  typedef logic [AddrWidth-1:0]  addr_t;
  typedef logic [DataWidth-1:0]  data_t;
  typedef logic [StrbWidth-1:0]  strb_t;
  typedef logic [AxiIdWidth-1:0] id_t;
  typedef logic [UserWidth-1:0]  user_t;
  typedef logic [TFLenWidth-1:0] tf_len_t;

  `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)
  `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
  `AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

  typedef struct packed { axi_ar_chan_t ar_chan; } axi_read_meta_channel_t;
  typedef struct packed { axi_read_meta_channel_t axi; } read_meta_channel_t;
  typedef struct packed { axi_aw_chan_t aw_chan; } axi_write_meta_channel_t;
  typedef struct packed { axi_write_meta_channel_t axi; } write_meta_channel_t;

  logic clk, rst_n;
  idma_req_t    idma_req;    logic req_valid, req_ready;
  idma_rsp_t    idma_rsp;    logic rsp_valid, rsp_ready;
  idma_eh_req_t idma_eh_req; logic eh_req_valid, eh_req_ready;
  axi_req_t axi_read_req, axi_write_req, axi_req;
  axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp;
  idma_busy_t busy;

  assign idma_eh_req = '0;
  assign eh_req_valid = 1'b0;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  axi_rw_join #(.axi_req_t(axi_req_t), .axi_resp_t(axi_rsp_t)) i_axi_rw_join (
    .clk_i(clk), .rst_ni(rst_n),
    .slv_read_req_i(axi_read_req),  .slv_read_resp_o(axi_read_rsp),
    .slv_write_req_i(axi_write_req), .slv_write_resp_o(axi_write_rsp),
    .mst_req_o(axi_req), .mst_resp_i(axi_rsp)
  );

  axi_sim_mem #(
    .AddrWidth(AddrWidth), .DataWidth(DataWidth), .IdWidth(AxiIdWidth), .UserWidth(UserWidth),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
  ) i_axi_sim_mem (
    .clk_i(clk), .rst_ni(rst_n), .axi_req_i(axi_req), .axi_rsp_o(axi_rsp),
    .mon_r_last_o(), .mon_r_beat_count_o(), .mon_r_user_o(), .mon_r_id_o(),
    .mon_r_data_o(), .mon_r_addr_o(), .mon_r_valid_o(),
    .mon_w_last_o(), .mon_w_beat_count_o(), .mon_w_user_o(), .mon_w_id_o(),
    .mon_w_data_o(), .mon_w_addr_o(), .mon_w_valid_o()
  );

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{transpose: 1'b1, mxquant: 1'b1,
                                            mxdequant: EnDequant, default: '0}),
    .ComputeFullDuplex(1'b1),
    .RAWCouplingAvail(1'b1), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(StrbWidth), .MemSysDepth(0),
    .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t), .idma_eh_req_t(idma_eh_req_t),
    .idma_busy_t(idma_busy_t), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .write_meta_channel_t(write_meta_channel_t), .read_meta_channel_t(read_meta_channel_t)
  ) i_idma_backend (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .idma_req_i(idma_req), .req_valid_i(req_valid), .req_ready_o(req_ready),
    .idma_rsp_o(idma_rsp), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
    .idma_eh_req_i(idma_eh_req), .eh_req_valid_i(eh_req_valid), .eh_req_ready_o(eh_req_ready),
    .axi_read_req_o(axi_read_req), .axi_read_rsp_i(axi_read_rsp),
    .axi_write_req_o(axi_write_req), .axi_write_rsp_i(axi_write_rsp), .busy_o(busy)
  );

  task automatic issue(input addr_t src, input addr_t dst, input int unsigned L,
                       input idma_pkg::compute_op_e op,
                       input idma_pkg::protocol_e src_prot, input idma_pkg::protocol_e dst_prot,
                       input bit wait_done);
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
      9: begin  // overlap: second transfer issued while the quant drain is still in flight
        issue(Src, Dst, 24 * 128, idma_pkg::COMPUTE_MXQUANT, idma_pkg::AXI, idma_pkg::AXI, 1'b0);
        issue(Src, Dst + 'h2000, 512, idma_pkg::COMPUTE_NONE, idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      end
      10: issue(Src, Dst, 4 * StrbWidth, idma_pkg::COMPUTE_TRANSPOSE,
                idma_pkg::AXI, idma_pkg::AXI, 1'b0);
      default: $fatal(1, "[MXNEG] unknown NegCase %0d", NegCase);
    endcase

    repeat (3000) @(posedge clk);
    $display("[MXNEG] case %0d done", NegCase);
    $finish();
  end

  initial begin #10_000_000; $display("[MXNEG] case %0d done (timeout)", NegCase); $finish(); end

endmodule

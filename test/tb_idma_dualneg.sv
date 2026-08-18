// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Negative tests for the operand pair on the two-read-head backend: each NegCase issues
// one illegal request sequence and expects the matching legalizer guard to report
// (compile with +define+INC_ASSERT). Case 1: the partner carries another op; 2: another
// length; 3: the same read head; 4: a two-operand op without the second stream elaborated.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_dualneg
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter int unsigned NegCase    = 1,
  parameter bit          EnDual     = 1'b1
);

  localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam int unsigned NumHeads  = 2;
  localparam int unsigned NumBuses  = NumHeads + 1;

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
  idma_busy_t   busy;
  axi_req_t [NumBuses-1:0] axi_req;
  axi_rsp_t [NumBuses-1:0] axi_rsp;

  assign idma_eh_req  = '0;
  assign eh_req_valid = 1'b0;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  for (genvar i = 0; i < NumBuses; i++) begin : gen_bus
    axi_sim_mem #(
      .AddrWidth(AddrWidth), .DataWidth(DataWidth), .IdWidth(AxiIdWidth), .UserWidth(UserWidth),
      .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
      .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
    ) i_axi_sim_mem (
      .clk_i(clk), .rst_ni(rst_n), .axi_req_i(axi_req[i]), .axi_rsp_o(axi_rsp[i]),
      .mon_r_last_o(), .mon_r_beat_count_o(), .mon_r_user_o(), .mon_r_id_o(),
      .mon_r_data_o(), .mon_r_addr_o(), .mon_r_valid_o(),
      .mon_w_last_o(), .mon_w_beat_count_o(), .mon_w_user_o(), .mon_w_id_o(),
      .mon_w_data_o(), .mon_w_addr_o(), .mon_w_valid_o()
    );
  end

  idma_backend_2r_axi_w_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{alu: 1'b1, alu_mul: 1'b1, dual: EnDual, default: '0}),
    .ComputeTuning('1),
    .RAWCouplingAvail(1'b0), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
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
    .axi_read_req_o(axi_req[NumHeads-1:0]), .axi_read_rsp_i(axi_rsp[NumHeads-1:0]),
    .axi_write_req_o(axi_req[NumHeads]), .axi_write_rsp_i(axi_rsp[NumHeads]), .busy_o(busy)
  );

  task automatic issue(input addr_t src, input addr_t dst, input int unsigned len,
                       input idma_pkg::alu_func_e func, input int unsigned head);
    automatic idma_req_t req = '0;
    req.length   = tf_len_t'(len);
    req.src_addr = src;
    req.dst_addr = dst;
    req.opt.src_protocol = idma_pkg::AXI;
    req.opt.dst_protocol = idma_pkg::AXI;
    req.opt.src_head     = multihead_t'(head);
    req.opt.src.burst    = axi_pkg::BURST_INCR;
    req.opt.dst.burst    = axi_pkg::BURST_INCR;
    req.opt.beo.decouple_rw = 1'b1;
    req.opt.beo.decouple_aw = 1'b1;
    req.opt.compute.enable  = 1'b1;
    req.opt.compute.op      = idma_pkg::COMPUTE_ALU;
    req.opt.compute.params.alu.func = func;
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

  localparam addr_t SrcA = 'h0001_0000, SrcB = 'h0003_0000, Dst = 'h0009_0000;

  initial begin
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    for (int unsigned i = 0; i < 4096; i++) begin
      gen_bus[0].i_axi_sim_mem.mem[SrcA + i] = 8'(i);
      gen_bus[1].i_axi_sim_mem.mem[SrcB + i] = 8'(i);
    end
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    case (NegCase)
      1: begin
        issue(SrcA, Dst, 64, idma_pkg::ALU_ADD, 0);
        issue(SrcB, Dst, 64, idma_pkg::ALU_SUB, 1);
      end
      2: begin
        issue(SrcA, Dst, 64, idma_pkg::ALU_ADD, 0);
        issue(SrcB, Dst, 96, idma_pkg::ALU_ADD, 1);
      end
      3: begin
        issue(SrcA, Dst, 64, idma_pkg::ALU_ADD, 0);
        issue(SrcB, Dst, 64, idma_pkg::ALU_ADD, 0);
      end
      4: issue(SrcA, Dst, 64, idma_pkg::ALU_ADD, 0);
      default: $fatal(1, "[DUALNEG] unknown NegCase %0d", NegCase);
    endcase

    repeat (3000) @(posedge clk);
    $display("[DUALNEG] case %0d done", NegCase);
    $finish();
  end

  initial begin #10ms; $display("[DUALNEG] case %0d done (timeout)", NegCase); $finish(); end

endmodule

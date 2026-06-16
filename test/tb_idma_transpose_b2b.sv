// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// End-to-end back-to-back transpose regression: two transposes of one source to
// DIFFERENT dst bases through the ND midend -> rw_axi backend -> axi_sim_mem. A
// stale base across transfers would leave the second dst untouched. Both checked.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_transpose_b2b
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth = 32,
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned UserWidth = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter int unsigned M  = 6,
  parameter int unsigned N  = 8,
  parameter int unsigned EB = 1
);

  localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam int unsigned NE   = StrbWidth / EB;
  localparam int unsigned MODE = (EB == 4) ? 2 : (EB == 2) ? 1 : 0;
  localparam int unsigned YT   = (M + NE - 1) / NE;
  localparam int unsigned NT   = (N + NE - 1) / NE;
  localparam int unsigned MP   = YT * NE;
  localparam int unsigned NumDim = 4;
  localparam logic [NumDim-1:0][31:0] RepWidths = '{default: 32'd16};

  typedef logic [AddrWidth-1:0]  addr_t;
  typedef logic [DataWidth-1:0]  data_t;
  typedef logic [StrbWidth-1:0]  strb_t;
  typedef logic [AxiIdWidth-1:0] id_t;
  typedef logic [UserWidth-1:0]  user_t;
  typedef logic [TFLenWidth-1:0] tf_len_t;
  typedef logic [31:0]           reps_t;

  `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)
  `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
  `AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, addr_t)

  typedef struct packed { axi_ar_chan_t ar_chan; } axi_read_meta_channel_t;
  typedef struct packed { axi_read_meta_channel_t axi; } read_meta_channel_t;
  typedef struct packed { axi_aw_chan_t aw_chan; } axi_write_meta_channel_t;
  typedef struct packed { axi_write_meta_channel_t axi; } write_meta_channel_t;

  logic clk, rst_n;
  idma_req_t   idma_req;   logic req_valid, req_ready;
  idma_rsp_t   idma_rsp;   logic rsp_valid, rsp_ready;
  idma_eh_req_t idma_eh_req; logic eh_req_valid, eh_req_ready;
  idma_nd_req_t nd_req;    logic nd_req_valid, nd_req_ready;
  idma_rsp_t   nd_rsp;     logic nd_rsp_valid, nd_rsp_ready;
  axi_req_t axi_read_req, axi_write_req, axi_req, axi_req_mem;
  axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp, axi_rsp_mem;
  idma_busy_t busy; logic nd_busy;

  assign idma_eh_req = '0;
  assign eh_req_valid = 1'b0;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  axi_rw_join #(.axi_req_t(axi_req_t), .axi_resp_t(axi_rsp_t)) i_axi_rw_join (
    .clk_i(clk), .rst_ni(rst_n),
    .slv_read_req_i(axi_read_req),  .slv_read_resp_o(axi_read_rsp),
    .slv_write_req_i(axi_write_req), .slv_write_resp_o(axi_write_rsp),
    .mst_req_o(axi_req), .mst_resp_i(axi_rsp)
  );
  assign axi_req_mem = axi_req;
  assign axi_rsp     = axi_rsp_mem;

  axi_sim_mem #(
    .AddrWidth(AddrWidth), .DataWidth(DataWidth), .IdWidth(AxiIdWidth), .UserWidth(UserWidth),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
  ) i_axi_sim_mem (
    .clk_i(clk), .rst_ni(rst_n), .axi_req_i(axi_req_mem), .axi_rsp_o(axi_rsp_mem),
    .mon_r_last_o(), .mon_r_beat_count_o(), .mon_r_user_o(), .mon_r_id_o(),
    .mon_r_data_o(), .mon_r_addr_o(), .mon_r_valid_o(),
    .mon_w_last_o(), .mon_w_beat_count_o(), .mon_w_user_o(), .mon_w_id_o(),
    .mon_w_data_o(), .mon_w_addr_o(), .mon_w_valid_o()
  );

  idma_nd_midend #(
    .NumDim(NumDim), .addr_t(addr_t), .idma_req_t(idma_req_t),
    .idma_rsp_t(idma_rsp_t), .idma_nd_req_t(idma_nd_req_t), .RepWidths(RepWidths)
  ) i_nd_midend (
    .clk_i(clk), .rst_ni(rst_n),
    .nd_req_i(nd_req), .nd_req_valid_i(nd_req_valid), .nd_req_ready_o(nd_req_ready),
    .nd_rsp_o(nd_rsp), .nd_rsp_valid_o(nd_rsp_valid), .nd_rsp_ready_i(nd_rsp_ready),
    .burst_req_o(idma_req), .burst_req_valid_o(req_valid), .burst_req_ready_i(req_ready),
    .burst_rsp_i(idma_rsp), .burst_rsp_valid_i(rsp_valid), .burst_rsp_ready_o(rsp_ready),
    .busy_o(nd_busy)
  );

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
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

  stream_watchdog #(.NumCycles(4000)) i_r_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));
  stream_watchdog #(.NumCycles(4000)) i_w_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));

  addr_t sb = 'h0000_1000;

  task automatic wr_mem(input addr_t a, input logic [7:0] d); i_axi_sim_mem.mem[a] = d; endtask
  function automatic logic [7:0] rd_mem(input addr_t a);
    return i_axi_sim_mem.mem.exists(a) ? i_axi_sim_mem.mem[a] : 8'hxx;
  endfunction

  // one transpose of the source at sb -> dst base `db`; returns error count
  task automatic do_transpose(input addr_t db, output int unsigned errs);
    errs = 0;
    // pre-fill full padded dst extent with sentinel
    for (int unsigned i = 0; i < NT*NE; i++)
      for (int unsigned j = 0; j < MP; j++)
        for (int unsigned b = 0; b < EB; b++)
          wr_mem(db + (i*MP + j)*EB + b, 8'hCC);
    nd_req = '0;
    nd_req.burst_req.length   = tf_len_t'(NE*EB);
    nd_req.burst_req.src_addr = sb;
    nd_req.burst_req.dst_addr = db;
    nd_req.burst_req.opt.src_protocol = idma_pkg::AXI;
    nd_req.burst_req.opt.dst_protocol = idma_pkg::AXI;
    nd_req.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    nd_req.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    nd_req.burst_req.opt.beo.decouple_rw = 1'b1;
    nd_req.burst_req.opt.beo.decouple_aw = 1'b1;
    nd_req.burst_req.opt.compute.enable                  = 1'b1;
    nd_req.burst_req.opt.compute.op                      = idma_pkg::COMPUTE_TRANSPOSE;
    nd_req.burst_req.opt.compute.params.transpose.mode     = 2'(MODE);
    nd_req.burst_req.opt.compute.params.transpose.tensor_m = 12'(M);
    nd_req.burst_req.opt.compute.params.transpose.tensor_n = 12'(N);
    nd_req.burst_req.opt.last         = 1'b1;
    nd_req.d_req[0].reps = reps_t'(NE); nd_req.d_req[0].src_strides = addr_t'(int'(N*EB));                       nd_req.d_req[0].dst_strides = addr_t'(int'(MP*EB));
    nd_req.d_req[1].reps = reps_t'(YT); nd_req.d_req[1].src_strides = addr_t'(int'(N*EB));                       nd_req.d_req[1].dst_strides = addr_t'(int'(NE*EB) - int'((NE-1)*MP*EB));
    nd_req.d_req[2].reps = reps_t'(NT); nd_req.d_req[2].src_strides = addr_t'(int'(NE*EB) - int'((YT*NE-1)*N*EB)); nd_req.d_req[2].dst_strides = addr_t'(int'(MP*EB) - int'((YT-1)*NE*EB));
    nd_req_valid = 1'b1;
    do @(posedge clk); while (!nd_req_ready);   // drop valid the cycle accept is seen (compliant)
    nd_req_valid = 1'b0;
    nd_req = '0;
    while (!(nd_rsp_valid && nd_rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    // data + padding checks
    for (int unsigned c = 0; c < N; c++)
      for (int unsigned r = 0; r < M; r++)
        for (int unsigned b = 0; b < EB; b++)
          if (rd_mem(db + (c*MP + r)*EB + b) !== rd_mem(sb + (r*N + c)*EB + b)) begin
            errs++; if (errs <= 8) $display("[B2BT] @db=%0h MISMATCH out_T[%0d][%0d].b%0d=%02h exp %02h", db, c, r, b, rd_mem(db+(c*MP+r)*EB+b), rd_mem(sb+(r*N+c)*EB+b));
          end
    for (int unsigned i = 0; i < NT*NE; i++)
      for (int unsigned j = 0; j < MP; j++)
        if (i >= N || j >= M)
          for (int unsigned b = 0; b < EB; b++)
            if (rd_mem(db + (i*MP + j)*EB + b) !== 8'hCC) begin
              errs++; if (errs <= 8) $display("[B2BT] @db=%0h PADDING CLOBBERED row=%0d col=%0d", db, i, j);
            end
  endtask

  initial begin
    automatic int unsigned e1, e2;
    automatic addr_t db1 = 'h0000_4000;
    automatic addr_t db2 = 'h0000_8000;   // DIFFERENT base — a stale-addr bug misplaces xfer 2
    nd_req_valid = 1'b0; nd_rsp_ready = 1'b1; nd_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);
    for (int unsigned r = 0; r < M; r++)
      for (int unsigned c = 0; c < N; c++)
        for (int unsigned b = 0; b < EB; b++)
          wr_mem(sb + (r*N + c)*EB + b, 8'((( (r*N+c)*EB + b )*7 + 3) & 8'hFF));

    $display("[B2BT] transfer 1 -> db=%0h", db1);
    do_transpose(db1, e1);
    $display("[B2BT] transfer 2 (back-to-back) -> db=%0h", db2);
    do_transpose(db2, e2);

    if (e1 == 0 && e2 == 0)
      $display("[B2BT] PASS: two back-to-back %0dx%0d EB=%0d transposes both correct (xfer2 landed at its own dst)", M, N, EB);
    else
      $fatal(1, "[B2BT] FAIL: xfer1 errs=%0d xfer2 errs=%0d", e1, e2);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #5_000_000; $fatal(1, "[B2BT] timeout"); end

endmodule

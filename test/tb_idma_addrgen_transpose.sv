// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Address-gen transpose (no engine): rw_axi transposes M x N via a swapped-stride ND program.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_addrgen_transpose
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth   = 32,
  parameter int unsigned AddrWidth   = 32,
  parameter int unsigned UserWidth   = 1,
  parameter int unsigned AxiIdWidth  = 12,
  parameter int unsigned TFLenWidth  = 32,
  parameter int unsigned BufferDepth = 3
);

  localparam time TA  = 1ns;
  localparam time TT  = 9ns;
  localparam time TCK = 10ns;

  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam int unsigned AxIF      = 8;
  // base burst = 1 element (dim 0); two repetition dims (col, row) => NumDim=3
  localparam int unsigned NumDim    = 3;
  localparam logic [NumDim-1:0][31:0] RepWidths = '{default: 32'd16};

  // Geometry cases (M, N, EB): square, rectangular, odd; int8/fp16/fp32 each
  // with square + rectangular coverage.
  localparam int unsigned NCases = 12;
  localparam int unsigned Cases [NCases][3] = '{
    '{ 4,  4, 1}, '{ 8,  8, 1}, '{ 8,  4, 1}, '{ 4,  8, 1},
    '{ 6,  5, 1}, '{ 5,  7, 2}, '{ 3,  9, 4}, '{16, 16, 1},
    '{ 8,  8, 2}, '{ 8,  8, 4}, '{10,  6, 2}, '{12,  8, 4}
  };

  // ── Types ──
  typedef logic [AddrWidth-1:0]   addr_t;
  typedef logic [DataWidth-1:0]   data_t;
  typedef logic [StrbWidth-1:0]   strb_t;
  typedef logic [AxiIdWidth-1:0]  id_t;
  typedef logic [UserWidth-1:0]   user_t;
  typedef logic [TFLenWidth-1:0]  tf_len_t;
  typedef logic [31:0]            reps_t;

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

  // ── Signals ──
  logic clk, rst_n;
  idma_req_t   idma_req;   logic req_valid, req_ready;
  idma_rsp_t   idma_rsp;   logic rsp_valid, rsp_ready;
  idma_eh_req_t idma_eh_req; logic eh_req_valid, eh_req_ready;
  idma_nd_req_t tp_req;    logic tp_valid, tp_ready;          // TB -> transpose midend
  idma_nd_req_t nd_req;    logic nd_req_valid, nd_req_ready;  // transpose midend -> nd midend
  idma_rsp_t   nd_rsp;     logic nd_rsp_valid, nd_rsp_ready;
  axi_req_t axi_read_req, axi_write_req, axi_req, axi_req_mem;
  axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp, axi_rsp_mem;
  idma_busy_t busy; logic nd_busy;

  assign idma_eh_req = '0;
  assign eh_req_valid = 1'b0;

  // ── Clock / reset ──
  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  // ── AXI sim memory (read+write joined) ──
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

  // ── Transpose midend (RTL UNDER TEST): expands the transpose request into the
  //    swapped-stride ND program; the nd_midend + backend just execute it ──
  idma_transpose_midend #(
    .NumDim(NumDim), .AddrGenTranspose(1'b1), .StrbWidth(StrbWidth),
    .addr_t(addr_t), .idma_nd_req_t(idma_nd_req_t)
  ) i_xpose_midend (
    .nd_req_i(tp_req), .valid_i(tp_valid), .ready_o(tp_ready),
    .nd_req_o(nd_req), .valid_o(nd_req_valid), .ready_i(nd_req_ready)
  );

  // ── ND midend: walks the swapped-stride program into 1-element bursts ──
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

  // ── Backend (rw_axi), plain copy — NO compute engine ──
  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(BufferDepth),
    .RAWCouplingAvail(1'b1), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(AxIF), .MemSysDepth(0),
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

  // ── Stimulus + check via sim-memory backdoor ──
  addr_t sb = 'h0000_1000;
  addr_t db = 'h0000_8000;

  task automatic wr_mem(input addr_t a, input logic [7:0] d); i_axi_sim_mem.mem[a] = d; endtask
  function automatic logic [7:0] rd_mem(input addr_t a);
    return i_axi_sim_mem.mem.exists(a) ? i_axi_sim_mem.mem[a] : 8'hxx;
  endfunction

  // Run one M x N transpose of EB-byte elements; returns the mismatch count.
  task automatic run_case(input int unsigned m, input int unsigned n, input int unsigned eb,
                          input bit corrupt, output int unsigned errs);
    errs = 0;

    // init source matrix (row-major, m x n elements of eb bytes), unique fingerprint
    for (int unsigned r = 0; r < m; r++)
      for (int unsigned c = 0; c < n; c++)
        for (int unsigned b = 0; b < eb; b++)
          wr_mem(sb + (r*n + c)*eb + b, 8'((( (r*n+c)*eb + b )*7 + 3) & 8'hFF));
    // sentinel-fill the contiguous N x M dst
    for (int unsigned k = 0; k < n*m*eb; k++) wr_mem(db + k, 8'hCC);

    // Drive a transpose request THROUGH idma_transpose_midend (it computes the
    // swapped-stride program); the TB sets only the compute fields + addresses,
    // NOT the strides — so the midend's expansion is what gets exercised.
    tp_req = '0;
    tp_req.burst_req.src_addr = sb;
    tp_req.burst_req.dst_addr = db;
    tp_req.burst_req.opt.src_protocol = idma_pkg::AXI;
    tp_req.burst_req.opt.dst_protocol = idma_pkg::AXI;
    tp_req.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    tp_req.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    tp_req.burst_req.opt.beo.decouple_rw  = 1'b1;
    tp_req.burst_req.opt.beo.decouple_aw  = 1'b1;
    tp_req.burst_req.opt.last             = 1'b1;
    tp_req.burst_req.opt.compute.enable                    = 1'b1;
    tp_req.burst_req.opt.compute.op                        = idma_pkg::COMPUTE_TRANSPOSE;
    tp_req.burst_req.opt.compute.params.transpose.mode     = 2'(eb == 4 ? 2 : eb == 2 ? 1 : 0);
    tp_req.burst_req.opt.compute.params.transpose.tensor_m = 12'(m);
    tp_req.burst_req.opt.compute.params.transpose.tensor_n = 12'(n);

    $display("[AG] case %0dx%0d EB=%0d (via transpose_midend, %0d elements)", m, n, eb, m*n);
    tp_valid = 1'b1;
    do @(posedge clk); while (!tp_ready);
    tp_valid = 1'b0;
    tp_req = '0;

    while (!(nd_rsp_valid && nd_rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);

    // negative control: flip one dst byte so the checker MUST report a mismatch
    if (corrupt) wr_mem(db, ~rd_mem(db));

    // check: out_T[c][r] == in[r][c], dst contiguous N x M (pitch M)
    for (int unsigned c = 0; c < n; c++)
      for (int unsigned r = 0; r < m; r++)
        for (int unsigned b = 0; b < eb; b++) begin
          automatic logic [7:0] got = rd_mem(db + (c*m + r)*eb + b);
          automatic logic [7:0] exp = rd_mem(sb + (r*n + c)*eb + b);
          if (got !== exp) begin
            errs++;
            if (errs <= 12) $display("[AG] MISMATCH out_T[%0d][%0d].b%0d=%02h exp %02h", c, r, b, got, exp);
          end
        end
  endtask

  initial begin
    automatic int unsigned total = 0;
    automatic int unsigned ce;
    tp_valid = 1'b0; nd_rsp_ready = 1'b1; tp_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    for (int unsigned k = 0; k < NCases; k++) begin
      if (Cases[k][2] > StrbWidth) continue;
      run_case(Cases[k][0], Cases[k][1], Cases[k][2], 1'b0, ce);
      if (ce == 0) $display("[AG] PASS: %0dx%0d EB=%0d", Cases[k][0], Cases[k][1], Cases[k][2]);
      else         $display("[AG] FAIL: %0dx%0d EB=%0d (%0d mismatches)", Cases[k][0], Cases[k][1], Cases[k][2], ce);
      total += ce;
    end

    // negative control: a corrupted dst MUST be caught, else the checker is vacuous
    run_case(8, 8, 1, 1'b1, ce);
    if (ce == 0) $fatal(1, "[AG] negative control FAILED: checker is vacuous");
    $display("[AG] negative control OK: corrupted dst caught (%0d mismatches)", ce);

    if (total == 0) $display("[AG] ALL PASS (%0d cases + neg-control, StrbWidth=%0d)", NCases, StrbWidth);
    else            $fatal(1, "[AG] FAIL: %0d total mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #100_000_000; $fatal(1, "[AG] timeout"); end

endmodule

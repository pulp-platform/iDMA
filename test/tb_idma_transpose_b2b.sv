// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// End-to-end back-to-back transpose regression: per geometry, two transposes
// with different layout modes and destination bases pass through the transpose
// and ND midends, safe edge replay, rw_axi backend, and axi_sim_mem. This catches
// stale base addresses as well as stale compact/padded configuration.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_transpose_b2b
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 32,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32
);

  localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam int unsigned NumDim = 4;
  localparam logic [NumDim-1:0][31:0] RepWidths = '{default: 32'd16};

  // Geometry cases (M, N, EB); EB>StrbWidth cases skip.
  localparam int unsigned NCases = 4;
  localparam int unsigned Cases [NCases][3] = '{ '{6, 8, 1}, '{8, 8, 1}, '{13, 19, 1}, '{5, 5, 2} };

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
  idma_req_t   nd_burst_req, idma_req;
  logic        nd_burst_valid, nd_burst_ready, req_valid, req_ready;
  idma_rsp_t   idma_rsp;   logic rsp_valid, rsp_ready;
  idma_eh_req_t idma_eh_req; logic eh_req_valid, eh_req_ready;
  idma_nd_req_t transpose_req, nd_req;
  logic         transpose_req_valid, transpose_req_ready, nd_req_valid, nd_req_ready;
  idma_rsp_t   nd_rsp;     logic nd_rsp_valid, nd_rsp_ready;
  axi_req_t axi_read_req, axi_write_req, axi_req, axi_req_mem;
  axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp, axi_rsp_mem;
  idma_busy_t busy; logic nd_busy;

  assign idma_eh_req = '0;
  assign eh_req_valid = 1'b0;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  // Keep testbench drives and samples out of the DUT's active clocking region.
  clocking req_rsp_cb @(posedge clk);
    default input #1step output #0;
    input transpose_req_ready;
    output transpose_req_valid;
    output transpose_req;
    input nd_rsp_valid, nd_rsp_ready;
  endclocking

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

  // Convert the matrix dimensions and layout bit into the tiled ND walk.
  idma_transpose_midend #(
    .NumDim(NumDim), .StrbWidth(StrbWidth), .addr_t(addr_t), .idma_nd_req_t(idma_nd_req_t)
  ) i_transpose_midend (
    .nd_req_i(transpose_req), .valid_i(transpose_req_valid), .ready_o(transpose_req_ready),
    .nd_req_o(nd_req), .valid_o(nd_req_valid), .ready_i(nd_req_ready)
  );

  idma_nd_midend #(
    .NumDim(NumDim), .addr_t(addr_t), .idma_req_t(idma_req_t),
    .idma_rsp_t(idma_rsp_t), .idma_nd_req_t(idma_nd_req_t), .RepWidths(RepWidths)
  ) i_nd_midend (
    .clk_i(clk), .rst_ni(rst_n),
    .nd_req_i(nd_req), .nd_req_valid_i(nd_req_valid), .nd_req_ready_o(nd_req_ready),
    .nd_rsp_o(nd_rsp), .nd_rsp_valid_o(nd_rsp_valid), .nd_rsp_ready_i(nd_rsp_ready),
    .burst_req_o(nd_burst_req), .burst_req_valid_o(nd_burst_valid),
    .burst_req_ready_i(nd_burst_ready),
    .burst_rsp_i(idma_rsp), .burst_rsp_valid_i(rsp_valid), .burst_rsp_ready_o(rsp_ready),
    .busy_o(nd_busy)
  );

  // Replay descriptors for nonexistent partial-tile rows before they reach AXI.
  idma_transpose_req_replay #(
    .StrbWidth(StrbWidth), .idma_req_t(idma_req_t)
  ) i_transpose_req_replay (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(nd_burst_req), .valid_i(nd_burst_valid), .ready_o(nd_burst_ready),
    .req_o(idma_req), .valid_o(req_valid), .ready_i(req_ready)
  );

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1), .ComputeOps(idma_pkg::compute_enable_t'{transpose: 1'b1}),
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

  stream_watchdog #(.NumCycles(4000)) i_r_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));
  stream_watchdog #(.NumCycles(4000)) i_w_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));

  addr_t sb = 'h0000_1000;

  task automatic wr_mem(input addr_t a, input logic [7:0] d); i_axi_sim_mem.mem[a] = d; endtask
  function automatic logic [7:0] rd_mem(input addr_t a);
    return i_axi_sim_mem.mem.exists(a) ? i_axi_sim_mem.mem[a] : 8'hxx;
  endfunction

  task automatic send_transpose_req(input idma_nd_req_t req);
    @(req_rsp_cb);
    req_rsp_cb.transpose_req <= req;
    req_rsp_cb.transpose_req_valid <= 1'b1;
    do @(req_rsp_cb); while (!req_rsp_cb.transpose_req_ready);
    req_rsp_cb.transpose_req <= '0;
    req_rsp_cb.transpose_req_valid <= 1'b0;
  endtask

  task automatic wait_nd_rsp;
    while (!(req_rsp_cb.nd_rsp_valid && req_rsp_cb.nd_rsp_ready)) @(req_rsp_cb);
  endtask

  // One transpose to `db` in the selected layout; returns its error count.
  task automatic do_transpose(input int unsigned m, input int unsigned n, input int unsigned eb,
                              input bit compact, input addr_t db, output int unsigned errs);
    automatic int unsigned ne   = StrbWidth / eb;
    automatic int unsigned mode = (eb == 4) ? 2 : (eb == 2) ? 1 : 0;
    automatic int unsigned yt   = (m + ne - 1) / ne;
    automatic int unsigned nt   = (n + ne - 1) / ne;
    automatic int unsigned mp   = yt * ne;
    automatic int unsigned dp   = compact ? m : mp;
    errs = 0;
    // Back the padded envelope in both modes. Bytes beyond the compact matrix
    // become guards against stale strides or nonzero edge writes.
    for (int unsigned i = 0; i < nt*ne; i++)
      for (int unsigned j = 0; j < mp; j++)
        for (int unsigned b = 0; b < eb; b++)
          wr_mem(db + (i*mp + j)*eb + b, 8'hCC);
    transpose_req = '0;
    transpose_req.burst_req.src_addr = sb;
    transpose_req.burst_req.dst_addr = db;
    transpose_req.burst_req.opt.src_protocol = idma_pkg::AXI;
    transpose_req.burst_req.opt.dst_protocol = idma_pkg::AXI;
    transpose_req.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    transpose_req.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    transpose_req.burst_req.opt.beo.decouple_rw = 1'b1;
    transpose_req.burst_req.opt.beo.decouple_aw = 1'b1;
    transpose_req.burst_req.opt.compute.enable                    = 1'b1;
    transpose_req.burst_req.opt.compute.op                        = idma_pkg::COMPUTE_TRANSPOSE;
    transpose_req.burst_req.opt.compute.params.transpose.compact  = compact;
    transpose_req.burst_req.opt.compute.params.transpose.mode     = 2'(mode);
    transpose_req.burst_req.opt.compute.params.transpose.tensor_m = 12'(m);
    transpose_req.burst_req.opt.compute.params.transpose.tensor_n = 12'(n);
    transpose_req.burst_req.opt.last = 1'b1;

    send_transpose_req(transpose_req);
    wait_nd_rsp();
    repeat (20) @(posedge clk);
    // Check data at either compact or padded destination row pitch.
    for (int unsigned c = 0; c < n; c++)
      for (int unsigned r = 0; r < m; r++)
        for (int unsigned b = 0; b < eb; b++)
          if (rd_mem(db + (c*dp + r)*eb + b) !== rd_mem(sb + (r*n + c)*eb + b)) begin
            errs++; if (errs <= 8) $display("[B2BT] @db=%0h MISMATCH out_T[%0d][%0d].b%0d", db, c, r, b);
          end
    // Padded holes or the tail after a compact matrix must remain untouched.
    for (int unsigned byte_idx = 0; byte_idx < nt*ne*mp*eb; byte_idx++)
      if (byte_idx >= n*dp*eb ||
          (!compact && ((byte_idx / eb) / mp >= n || (byte_idx / eb) % mp >= m)))
        if (rd_mem(db + byte_idx) !== 8'hCC) begin
          errs++;
          if (errs <= 8)
            $display("[B2BT] @db=%0h UNUSED DESTINATION BYTE CLOBBERED at +0x%0h",
                     db, byte_idx);
        end
  endtask

  initial begin
    automatic int unsigned total = 0, e1, e2;
    automatic addr_t db1 = 'h0000_4000;
    automatic addr_t db2 = 'h0000_8000;   // DIFFERENT base — a stale-addr bug misplaces xfer 2
    automatic int unsigned m, n, eb;
    automatic bit first_compact;
    transpose_req_valid = 1'b0; nd_rsp_ready = 1'b1; transpose_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    for (int unsigned k = 0; k < NCases; k++) begin
      m = Cases[k][0]; n = Cases[k][1]; eb = Cases[k][2];
      if (eb > StrbWidth) continue;
      // (re)init source for this geometry
      for (int unsigned r = 0; r < m; r++)
        for (int unsigned c = 0; c < n; c++)
          for (int unsigned b = 0; b < eb; b++)
            wr_mem(sb + (r*n + c)*eb + b, 8'((( (r*n+c)*eb + b )*7 + 3) & 8'hFF));
      // Alternate the order so both padded->compact and compact->padded
      // transitions are covered while retaining distinct destination bases.
      first_compact = bit'(k & 1);
      $display("[B2BT] %0dx%0d EB=%0d: compact=%0d -> db=%0h, compact=%0d -> db=%0h",
               m, n, eb, first_compact, db1, !first_compact, db2);
      do_transpose(m, n, eb, first_compact, db1, e1);
      do_transpose(m, n, eb, !first_compact, db2, e2);
      if (e1 == 0 && e2 == 0)
        $display("[B2BT] PASS: %0dx%0d EB=%0d both layouts correct back-to-back", m, n, eb);
      else                    $display("[B2BT] FAIL: %0dx%0d EB=%0d xfer1=%0d xfer2=%0d", m, n, eb, e1, e2);
      total += e1 + e2;
    end

    if (total == 0) $display("[B2BT] ALL PASS (%0d mixed-layout cases, StrbWidth=%0d)",
                             NCases, StrbWidth);
    else            $fatal(1, "[B2BT] FAIL: %0d total mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #50_000_000; $fatal(1, "[B2BT] timeout"); end

endmodule

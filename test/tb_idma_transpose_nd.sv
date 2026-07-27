// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Self-checking multi-tile transpose testbench: transpose midend -> generic ND
// midend -> safe edge replay -> rw_axi backend -> axi_sim_mem. Exercises full
// M x N transposes with compact and tile-padded destinations.
// Reference: out_T[c][r] = in[r][c].

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_transpose_nd
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
  // transpose buffers a full NE-beat tile before the first write; NE <= StrbWidth
  localparam int unsigned AxIF      = StrbWidth;
  localparam int unsigned NumDim    = 4;                     // 1D + {row, row-tile, col-tile}
  localparam logic [NumDim-1:0][31:0] RepWidths = '{default: 32'd16};

  // Geometry cases (M, N, EB) swept in one elaboration: aligned + edge
  // (M or N not a multiple of NE) for int8/fp16/fp32. EB>StrbWidth cases skip.
  localparam int unsigned NCases = 13;
  localparam int unsigned Cases [NCases][3] = '{
    '{ 8,  8, 1}, '{16, 16, 1}, '{16,  8, 1}, '{ 8,  8, 2}, '{ 6,  8, 1},
    '{ 8,  6, 1}, '{ 6,  6, 1}, '{ 5,  7, 1}, '{10,  6, 1}, '{ 5,  5, 2},
    '{32, 24, 1}, '{ 9,  5, 4}, '{13, 19, 1}
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
  idma_req_t   nd_burst_req, idma_req;
  logic        nd_burst_valid, nd_burst_ready, req_valid, req_ready;
  idma_rsp_t   idma_rsp;   logic rsp_valid, rsp_ready;
  idma_eh_req_t idma_eh_req; logic eh_req_valid, eh_req_ready;
  idma_nd_req_t transpose_req_to_midend, transpose_req_from_tb, nd_req;
  logic         transpose_req_valid, transpose_req_ready, nd_req_valid, nd_req_ready;
  idma_rsp_t   nd_rsp;     logic nd_rsp_valid, nd_rsp_ready;
  axi_req_t axi_read_req, axi_write_req, axi_req, axi_req_mem;
  axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp, axi_rsp_mem;
  idma_busy_t busy; logic nd_busy;

  assign idma_eh_req = '0;
  assign eh_req_valid = 1'b0;

  initial begin
    $dumpfile("dump.fst");
    $dumpvars(0, tb_idma_transpose_nd);
  end

  // ── Clock / reset ──
  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  // Sample DUT outputs immediately before the active edge and apply requests
  // after it, so the driver cannot race the DUT's sequential handshake logic.
  clocking req_rsp_cb @(posedge clk);
    default input #1step output #0;
    input transpose_req_ready;
    output transpose_req_valid;
    output transpose_req_to_midend;
    input nd_rsp_valid, nd_rsp_ready;
  endclocking

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

  // Expand the transpose dimensions and selected destination layout into the
  // four-dimensional walk consumed by the generic ND midend.
  idma_transpose_midend #(
    .NumDim(NumDim), .StrbWidth(StrbWidth), .addr_t(addr_t), .idma_nd_req_t(idma_nd_req_t)
  ) i_transpose_midend (
    .nd_req_i(transpose_req_to_midend), .valid_i(transpose_req_valid), .ready_o(transpose_req_ready),
    .nd_req_o(nd_req), .valid_o(nd_req_valid), .ready_i(nd_req_ready)
  );

  // ── ND midend: expanded transpose descriptor -> 1D bursts ──
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

  // Partial edge tiles still contain a full tile's descriptors. Redirect the
  // descriptors for invalid rows to mapped addresses before issuing them.
  idma_transpose_req_replay #(
    .StrbWidth(StrbWidth), .idma_req_t(idma_req_t)
  ) i_transpose_req_replay (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(nd_burst_req), .valid_i(nd_burst_valid), .ready_o(nd_burst_ready),
    .req_o(idma_req), .valid_o(req_valid), .ready_i(req_ready)
  );

  // ── Backend (rw_axi) with transpose engine ──
  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(BufferDepth),
    .EnableCompute(1'b1), .ComputeOps(idma_pkg::compute_enable_t'{transpose: 1'b1}),
    .ComputeFullDuplex(1'b1),
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

  // watchdogs to surface deadlocks rather than hang forever
  stream_watchdog #(.NumCycles(2000)) i_r_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));
  stream_watchdog #(.NumCycles(2000)) i_w_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));

  // ── Stimulus + check via sim-memory backdoor ──
  addr_t sb = 'h0000_1000;
  addr_t db = 'h0000_4000;

  // Every AW (including zero-strobe edge rows) must stay in the backed padded
  // envelope. Compact mode additionally checks that bytes outside its smaller
  // logical footprint remain untouched.
  logic  chk_active = 1'b0;
  addr_t chk_db, chk_aw_hi;
  always @(posedge clk) if (rst_n && chk_active && axi_write_req.aw_valid && axi_write_rsp.aw_ready) begin
    if (axi_write_req.aw.addr < chk_db || axi_write_req.aw.addr >= chk_aw_hi)
      $fatal(1, "[TPN] AW 0x%0h outside dst alloc [0x%0h,0x%0h) — would DECERR on a strict slave",
             axi_write_req.aw.addr, chk_db, chk_aw_hi);
  end

  task automatic wr_mem(input addr_t a, input logic [7:0] d); i_axi_sim_mem.mem[a] = d; endtask
  function automatic logic [7:0] rd_mem(input addr_t a);
    return i_axi_sim_mem.mem.exists(a) ? i_axi_sim_mem.mem[a] : 8'hxx;
  endfunction

  task automatic send_transpose_req(input idma_nd_req_t req);
    @(req_rsp_cb);
    req_rsp_cb.transpose_req_to_midend <= req;
    req_rsp_cb.transpose_req_valid <= 1'b1;
    do @(req_rsp_cb); while (!req_rsp_cb.transpose_req_ready);
    req_rsp_cb.transpose_req_to_midend <= '0;
    req_rsp_cb.transpose_req_valid <= 1'b0;
  endtask

  task automatic wait_nd_rsp;
    while (!(req_rsp_cb.nd_rsp_valid && req_rsp_cb.nd_rsp_ready)) @(req_rsp_cb);
  endtask

  // Run one M x N transpose in either compact or tile-padded destination layout.
  task automatic run_case(input int unsigned m, input int unsigned n, input int unsigned eb,
                          input bit compact, output int unsigned errs);
    automatic int unsigned ne   = StrbWidth / eb;        // tile side (elements)
    automatic int unsigned mode = (eb == 4) ? 2 : (eb == 2) ? 1 : 0;
    automatic int unsigned yt   = (m + ne - 1) / ne;     // row-tiles
    automatic int unsigned nt   = (n + ne - 1) / ne;     // col-tiles
    automatic int unsigned mp   = yt * ne;               // padded Aᵀ row pitch (StrbWidth-aligned)
    automatic int unsigned dp   = compact ? m : mp;      // selected Aᵀ row pitch
    errs = 0;

    // init source matrix (row-major, m x n elements of eb bytes)
    for (int unsigned r = 0; r < m; r++)
      for (int unsigned c = 0; c < n; c++)
        for (int unsigned b = 0; b < eb; b++)
          wr_mem(sb + (r*n + c)*eb + b, 8'((( (r*n+c)*eb + b )*7 + 3) & 8'hFF));

    // Always back the full padded envelope. Compact mode must only modify its
    // n*m prefix; the remainder acts as a guard against stray edge writes.
    for (int unsigned i = 0; i < nt*ne; i++)
      for (int unsigned j = 0; j < mp; j++)
        for (int unsigned b = 0; b < eb; b++)
          wr_mem(db + (i*mp + j)*eb + b, 8'hCC);

    // arm the AW-bounds guard for this case
    chk_db     = db;
    chk_aw_hi  = db + addr_t'(nt*ne*mp*eb);
    chk_active = 1'b1;

    // The transpose midend derives all reps and strides from this base request.
    transpose_req_from_tb = '0;
    transpose_req_from_tb.burst_req.src_addr = sb;
    transpose_req_from_tb.burst_req.dst_addr = db;
    transpose_req_from_tb.burst_req.opt.src_protocol = idma_pkg::AXI;
    transpose_req_from_tb.burst_req.opt.dst_protocol = idma_pkg::AXI;
    transpose_req_from_tb.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    transpose_req_from_tb.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    transpose_req_from_tb.burst_req.opt.beo.decouple_rw = 1'b1;
    transpose_req_from_tb.burst_req.opt.beo.decouple_aw = 1'b1;
    transpose_req_from_tb.burst_req.opt.beo.src_max_llen = '0;
    transpose_req_from_tb.burst_req.opt.beo.dst_max_llen = '0;
    transpose_req_from_tb.burst_req.opt.compute.enable                    = 1'b1;
    transpose_req_from_tb.burst_req.opt.compute.op                        = idma_pkg::COMPUTE_TRANSPOSE;
    transpose_req_from_tb.burst_req.opt.compute.params.transpose.compact  = compact;
    transpose_req_from_tb.burst_req.opt.compute.params.transpose.mode     = 2'(mode);
    transpose_req_from_tb.burst_req.opt.compute.params.transpose.tensor_m = 12'(m);
    transpose_req_from_tb.burst_req.opt.compute.params.transpose.tensor_n = 12'(n);
    transpose_req_from_tb.burst_req.opt.last = 1'b1;

    $display("[TPN] case %0dx%0d EB=%0d compact=%0d (NE=%0d, %0dx%0d tiles)",
             m, n, eb, compact, ne, yt, nt);

    send_transpose_req(transpose_req_from_tb);

    // wait for ND completion + drain
    wait_nd_rsp();
    repeat (20) @(posedge clk);
    chk_active = 1'b0;

    // Check the transposed matrix using the selected destination row pitch.
    for (int unsigned c = 0; c < n; c++)
      for (int unsigned r = 0; r < m; r++)
        for (int unsigned b = 0; b < eb; b++) begin
          automatic logic [7:0] got = rd_mem(db + (c*dp + r)*eb + b);
          automatic logic [7:0] exp = rd_mem(sb + (r*n + c)*eb + b);
          if (got !== exp) begin
            errs++;
            if (errs <= 12) $display("[TPN] MISMATCH out_T[%0d][%0d].b%0d=%02h exp %02h", c, r, b, got, exp);
          end
        end
    // Everything outside the selected logical layout remains sentinel. In
    // padded mode this checks holes; in compact mode it checks the entire tail.
    for (int unsigned byte_idx = 0; byte_idx < nt*ne*mp*eb; byte_idx++)
      if (byte_idx >= n*dp*eb ||
          (!compact && ((byte_idx / eb) / mp >= n || (byte_idx / eb) % mp >= m)))
        if (rd_mem(db + byte_idx) !== 8'hCC) begin
          errs++;
          if (errs <= 12)
            $display("[TPN] UNUSED DESTINATION BYTE CLOBBERED at +0x%0h", byte_idx);
        end
  endtask

  initial begin
    automatic int unsigned total = 0;
    automatic int unsigned ce;
    transpose_req_valid = 1'b0; nd_rsp_ready = 1'b1; transpose_req_from_tb = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    for (int unsigned k = 0; k < NCases; k++) begin
      if (Cases[k][2] > StrbWidth) continue;   // element must fit the bus
      for (int unsigned compact = 0; compact < 2; compact++) begin
        run_case(Cases[k][0], Cases[k][1], Cases[k][2], bit'(compact), ce);
        if (ce == 0)
          $display("[TPN] PASS: %0dx%0d EB=%0d compact=%0d",
                   Cases[k][0], Cases[k][1], Cases[k][2], compact);
        else
          $display("[TPN] FAIL: %0dx%0d EB=%0d compact=%0d (%0d mismatches)",
                   Cases[k][0], Cases[k][1], Cases[k][2], compact, ce);
        total += ce;
      end
    end

    if (total == 0) $display("[TPN] ALL PASS (%0d geometries x 2 layouts, StrbWidth=%0d)",
                             NCases, StrbWidth);
    else            $fatal(1, "[TPN] FAIL: %0d total mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #100_000_000; $fatal(1, "[TPN] timeout"); end

endmodule

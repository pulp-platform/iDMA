// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Self-checking multi-tile transpose testbench: idma_nd_midend (NumDim=4,
// transposed-stride program) -> idma_backend_rw_axi -> axi_sim_mem, exercising
// a full M x N transpose end-to-end. Reference: out_T[c][r] = in[r][c].
// Sweeps a list of geometries internally (one elaboration per bus width).

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

  // ── ND midend: ND transpose descriptor -> 1D bursts ──
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

  // ── Backend (rw_axi) with transpose engine ──
  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(BufferDepth),
    .RAWCouplingAvail(1'b1), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(AxIF), .MemSysDepth(0),
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

  // watchdogs to surface deadlocks rather than hang forever
  stream_watchdog #(.NumCycles(2000)) i_r_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));
  stream_watchdog #(.NumCycles(2000)) i_w_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));

  // ── Stimulus + check via sim-memory backdoor ──
  addr_t sb = 'h0000_1000;
  addr_t db = 'h0000_4000;

  // every AW (incl. wstrb=0 padding rows) must stay in the active case's padded
  // dst allocation [chk_db, chk_aw_hi) — else a strict slave would DECERR
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

  // Run one M x N transpose of EB-byte elements; returns the mismatch count.
  task automatic run_case(input int unsigned m, input int unsigned n, input int unsigned eb,
                          output int unsigned errs);
    automatic int unsigned ne   = StrbWidth / eb;        // tile side (elements)
    automatic int unsigned mode = (eb == 4) ? 2 : (eb == 2) ? 1 : 0;
    automatic int unsigned yt   = (m + ne - 1) / ne;     // row-tiles
    automatic int unsigned nt   = (n + ne - 1) / ne;     // col-tiles
    automatic int unsigned mp   = yt * ne;               // padded Aᵀ row pitch (StrbWidth-aligned)
    errs = 0;

    // init source matrix (row-major, m x n elements of eb bytes)
    for (int unsigned r = 0; r < m; r++)
      for (int unsigned c = 0; c < n; c++)
        for (int unsigned b = 0; b < eb; b++)
          wr_mem(sb + (r*n + c)*eb + b, 8'((( (r*n+c)*eb + b )*7 + 3) & 8'hFF));

    // sentinel-fill the full padded Aᵀ extent; padding cols/rows must stay sentinel
    for (int unsigned i = 0; i < nt*ne; i++)
      for (int unsigned j = 0; j < mp; j++)
        for (int unsigned b = 0; b < eb; b++)
          wr_mem(db + (i*mp + j)*eb + b, 8'hCC);

    // arm the AW-bounds guard for this case
    chk_db     = db;
    chk_aw_hi  = db + addr_t'(nt*ne*mp*eb);
    chk_active = 1'b1;

    // ── transposed-stride ND program (routing-plan §4.2) ──
    nd_req = '0;
    nd_req.burst_req.length   = tf_len_t'(ne*eb);   // one tile-row = StrbWidth bytes
    nd_req.burst_req.src_addr = sb;
    nd_req.burst_req.dst_addr = db;
    nd_req.burst_req.opt.src_protocol = idma_pkg::AXI;
    nd_req.burst_req.opt.dst_protocol = idma_pkg::AXI;
    nd_req.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
    nd_req.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    nd_req.burst_req.opt.beo.decouple_rw = 1'b1;
    nd_req.burst_req.opt.beo.decouple_aw = 1'b1;
    nd_req.burst_req.opt.beo.src_max_llen = '0;
    nd_req.burst_req.opt.beo.dst_max_llen = '0;
    nd_req.burst_req.opt.compute.enable                    = 1'b1;
    nd_req.burst_req.opt.compute.op                        = idma_pkg::COMPUTE_TRANSPOSE;
    nd_req.burst_req.opt.compute.params.transpose.mode     = 2'(mode);
    nd_req.burst_req.opt.compute.params.transpose.tensor_m = 12'(m);
    nd_req.burst_req.opt.compute.params.transpose.tensor_n = 12'(n);
    nd_req.burst_req.opt.last         = 1'b1;
    // ND midend strides are INCREMENTAL deltas (added on dim roll-over), NOT
    // absolute pitches. Aᵀ uses padded pitch mp*eb (aligned writes); src keeps
    // n*eb (misaligned reads coalesce in the pre-engine buffer).
    nd_req.d_req[0].reps        = reps_t'(ne);
    nd_req.d_req[0].src_strides = addr_t'(int'(n*eb));
    nd_req.d_req[0].dst_strides = addr_t'(int'(mp*eb));
    nd_req.d_req[1].reps        = reps_t'(yt);
    nd_req.d_req[1].src_strides = addr_t'(int'(n*eb));
    nd_req.d_req[1].dst_strides = addr_t'(int'(ne*eb) - int'((ne-1)*mp*eb));
    nd_req.d_req[2].reps        = reps_t'(nt);
    nd_req.d_req[2].src_strides = addr_t'(int'(ne*eb) - int'((yt*ne-1)*n*eb));
    nd_req.d_req[2].dst_strides = addr_t'(int'(mp*eb) - int'((yt-1)*ne*eb));

    $display("[TPN] case %0dx%0d EB=%0d (NE=%0d, %0dx%0d tiles)", m, n, eb, ne, yt, nt);
    nd_req_valid = 1'b1;
    // drop valid on accept; holding it one cycle past makes the midend re-walk the request
    do @(posedge clk); while (!nd_req_ready);
    nd_req_valid = 1'b0;
    nd_req = '0;

    // wait for ND completion + drain
    while (!(nd_rsp_valid && nd_rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    chk_active = 1'b0;

    // check 1 (data): out_T[c][r] == in[r][c], Aᵀ at padded pitch mp
    for (int unsigned c = 0; c < n; c++)
      for (int unsigned r = 0; r < m; r++)
        for (int unsigned b = 0; b < eb; b++) begin
          automatic logic [7:0] got = rd_mem(db + (c*mp + r)*eb + b);
          automatic logic [7:0] exp = rd_mem(sb + (r*n + c)*eb + b);
          if (got !== exp) begin
            errs++;
            if (errs <= 12) $display("[TPN] MISMATCH out_T[%0d][%0d].b%0d=%02h exp %02h", c, r, b, got, exp);
          end
        end
    // check 2: padding cols [m,mp) and padding rows [n,nt*ne) must stay sentinel
    for (int unsigned i = 0; i < nt*ne; i++)
      for (int unsigned j = 0; j < mp; j++)
        if (i >= n || j >= m)
          for (int unsigned b = 0; b < eb; b++) begin
            automatic logic [7:0] got = rd_mem(db + (i*mp + j)*eb + b);
            if (got !== 8'hCC) begin
              errs++;
              if (errs <= 12) $display("[TPN] PADDING CLOBBERED at row=%0d col=%0d b%0d=%02h (exp CC)", i, j, b, got);
            end
          end
  endtask

  initial begin
    automatic int unsigned total = 0;
    automatic int unsigned ce;
    nd_req_valid = 1'b0; nd_rsp_ready = 1'b1; nd_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    for (int unsigned k = 0; k < NCases; k++) begin
      if (Cases[k][2] > StrbWidth) continue;   // element must fit the bus
      run_case(Cases[k][0], Cases[k][1], Cases[k][2], ce);
      if (ce == 0) $display("[TPN] PASS: %0dx%0d EB=%0d", Cases[k][0], Cases[k][1], Cases[k][2]);
      else         $display("[TPN] FAIL: %0dx%0d EB=%0d (%0d mismatches)", Cases[k][0], Cases[k][1], Cases[k][2], ce);
      total += ce;
    end

    if (total == 0) $display("[TPN] ALL PASS (%0d cases, StrbWidth=%0d)", NCases, StrbWidth);
    else            $fatal(1, "[TPN] FAIL: %0d total mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #100_000_000; $fatal(1, "[TPN] timeout"); end

endmodule

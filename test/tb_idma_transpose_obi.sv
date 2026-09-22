// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// OBI-destination transpose testbench: idma_nd_midend -> idma_backend_rw_obi ->
// obi_sim_mem, the same geometry sweep as tb_idma_transpose_nd on a write port
// that must honour the compute strobe. Edge tiles emit partial (and all-zero)
// strobes, so the padding and the guard bands either side of the destination
// must stay sentinel; a dropped mask_ext shows up there, not in the payload.

`include "axi/typedef.svh"
`include "idma/typedef.svh"
`include "obi/typedef.svh"

module tb_idma_transpose_obi
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

  // guard band sentinel-filled either side of the destination allocation
  localparam int unsigned GuardBytes = 64;
  localparam logic [7:0]  PadFill    = 8'hCC;
  localparam logic [7:0]  GuardFill  = 8'h3C;

  // Geometry cases swept in one elaboration: aligned and edge, int8 and fp16
  localparam int unsigned NCases = 13;
  localparam int unsigned Cases [NCases][3] = '{
    '{ 8,  8, 1}, '{16, 16, 1}, '{16,  8, 1}, '{ 8,  8, 2}, '{ 6,  8, 1},
    '{ 8,  6, 1}, '{ 6,  6, 1}, '{ 5,  7, 1}, '{10,  6, 1}, '{ 5,  5, 2},
    '{32, 24, 1}, '{ 9,  5, 4}, '{13, 19, 1}
  };

  // -- Types --
  typedef logic [7:0]             byte_t;
  typedef logic [AddrWidth-1:0]   addr_t;
  typedef logic [DataWidth-1:0]   data_t;
  typedef logic [StrbWidth-1:0]   strb_t;
  typedef logic [AxiIdWidth-1:0]  id_t;
  typedef logic [UserWidth-1:0]   user_t;
  typedef logic [TFLenWidth-1:0]  tf_len_t;
  typedef logic [31:0]            reps_t;

  `OBI_TYPEDEF_MINIMAL_A_OPTIONAL(a_optional_t)
  `OBI_TYPEDEF_MINIMAL_R_OPTIONAL(r_optional_t)
  `OBI_TYPEDEF_TYPE_A_CHAN_T(obi_a_chan_t, addr_t, data_t, strb_t, id_t, a_optional_t)
  `OBI_TYPEDEF_TYPE_R_CHAN_T(obi_r_chan_t, data_t, id_t, r_optional_t)
  `OBI_TYPEDEF_REQ_T(obi_req_t, obi_a_chan_t)
  `OBI_TYPEDEF_RSP_T(obi_rsp_t, obi_r_chan_t)

  // UseRReady=1 so the sim memory honours the backend's rready
  function automatic obi_pkg::obi_cfg_t tb_obi_cfg();
    tb_obi_cfg = obi_pkg::obi_default_cfg(AddrWidth, DataWidth, AxiIdWidth,
                                          obi_pkg::ObiMinimalOptionalConfig);
    tb_obi_cfg.UseRReady = 1'b1;
  endfunction
  localparam obi_pkg::obi_cfg_t ObiCfg = tb_obi_cfg();

  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, addr_t)

  typedef struct packed { obi_a_chan_t a_chan; } obi_read_meta_channel_t;
  typedef struct packed { obi_read_meta_channel_t obi; } read_meta_channel_t;
  typedef struct packed { obi_a_chan_t a_chan; } obi_write_meta_channel_t;
  typedef struct packed { obi_write_meta_channel_t obi; } write_meta_channel_t;

  // -- Signals --
  logic clk, rst_n;
  idma_req_t    idma_req;    logic req_valid, req_ready;
  idma_rsp_t    idma_rsp;    logic rsp_valid, rsp_ready;
  idma_eh_req_t idma_eh_req; logic eh_req_valid, eh_req_ready;
  idma_nd_req_t nd_req;      logic nd_req_valid, nd_req_ready;
  idma_rsp_t    nd_rsp;      logic nd_rsp_valid, nd_rsp_ready;
  obi_req_t obi_read_req, obi_write_req;
  obi_rsp_t obi_read_rsp, obi_write_rsp;
  idma_busy_t busy; logic nd_busy;

  assign idma_eh_req  = '0;
  assign eh_req_valid = 1'b0;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  // -- OBI sim memories: source in the read mem, destination in the write mem --
  obi_sim_mem #(
    .ObiCfg(ObiCfg), .obi_req_t(obi_req_t), .obi_rsp_t(obi_rsp_t), .obi_r_chan_t(obi_r_chan_t),
    .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
  ) i_obi_read_sim_mem (
    .clk_i(clk), .rst_ni(rst_n), .obi_req_i(obi_read_req), .obi_rsp_o(obi_read_rsp),
    .mon_valid_o(), .mon_we_o(), .mon_addr_o(), .mon_wdata_o(), .mon_be_o(), .mon_id_o()
  );

  obi_sim_mem #(
    .ObiCfg(ObiCfg), .obi_req_t(obi_req_t), .obi_rsp_t(obi_rsp_t), .obi_r_chan_t(obi_r_chan_t),
    .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
  ) i_obi_write_sim_mem (
    .clk_i(clk), .rst_ni(rst_n), .obi_req_i(obi_write_req), .obi_rsp_o(obi_write_rsp),
    .mon_valid_o(), .mon_we_o(), .mon_addr_o(), .mon_wdata_o(), .mon_be_o(), .mon_id_o()
  );

  // -- ND midend: ND transpose descriptor -> 1D bursts --
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

  // -- Backend (rw_obi) with transpose engine --
  idma_backend_rw_obi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1),
    .BufferDepth(BufferDepth),
    .EnableCompute(1'b1), .ComputeOps(idma_pkg::compute_enable_t'{transpose: 1'b1, default: '0}),
    .ComputeTuning('1),
    .RAWCouplingAvail(1'b0), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0),
    .NumAxInFlight(AxIF), .MemSysDepth(0),
    .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t), .idma_eh_req_t(idma_eh_req_t),
    .idma_busy_t(idma_busy_t), .obi_req_t(obi_req_t), .obi_rsp_t(obi_rsp_t),
    .write_meta_channel_t(write_meta_channel_t), .read_meta_channel_t(read_meta_channel_t)
  ) i_idma_backend (
    .clk_i(clk), .rst_ni(rst_n),
    .idma_req_i(idma_req), .req_valid_i(req_valid), .req_ready_o(req_ready),
    .idma_rsp_o(idma_rsp), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
    .idma_eh_req_i(idma_eh_req), .eh_req_valid_i(eh_req_valid), .eh_req_ready_o(eh_req_ready),
    .obi_read_req_o(obi_read_req), .obi_read_rsp_i(obi_read_rsp),
    .obi_write_req_o(obi_write_req), .obi_write_rsp_i(obi_write_rsp), .busy_o(busy)
  );

  // watchdogs to surface deadlocks rather than hang forever
  stream_watchdog #(.NumCycles(4000)) i_r_wd (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(obi_read_req.req), .ready_i(obi_read_rsp.gnt));
  stream_watchdog #(.NumCycles(4000)) i_w_wd (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(obi_write_req.req), .ready_i(obi_write_rsp.gnt));

  // -- Stimulus + check via sim-memory backdoor --
  addr_t sb = 'h0000_1000;
  addr_t db = 'h0000_4000;

  // every write address must stay inside the active case destination allocation
  logic  chk_active = 1'b0;
  addr_t chk_db, chk_hi;
  always @(posedge clk)
    if (rst_n && chk_active && obi_write_req.req && obi_write_rsp.gnt && obi_write_req.a.we) begin
      if (obi_write_req.a.addr < chk_db || obi_write_req.a.addr >= chk_hi)
        $fatal(1, "[TPO] write 0x%0h outside dst alloc [0x%0h,0x%0h)",
               obi_write_req.a.addr, chk_db, chk_hi);
    end

  task automatic wr_src(input addr_t a, input byte_t d); i_obi_read_sim_mem.mem[a] = d; endtask
  function automatic byte_t rd_src(input addr_t a);
    return i_obi_read_sim_mem.mem.exists(a) ? i_obi_read_sim_mem.mem[a] : 8'hxx;
  endfunction
  task automatic wr_dst(input addr_t a, input byte_t d); i_obi_write_sim_mem.mem[a] = d; endtask
  function automatic byte_t rd_dst(input addr_t a);
    return i_obi_write_sim_mem.mem.exists(a) ? i_obi_write_sim_mem.mem[a] : 8'hxx;
  endfunction

  // Run one M x N transpose of EB-byte elements; returns the mismatch count.
  task automatic run_case(input int unsigned m, input int unsigned n, input int unsigned eb,
                          output int unsigned errs);
    automatic int unsigned ne   = StrbWidth / eb;        // tile side (elements)
    automatic int unsigned mode = (eb == 4) ? 2 : (eb == 2) ? 1 : 0;
    automatic int unsigned yt   = (m + ne - 1) / ne;     // row-tiles
    automatic int unsigned nt   = (n + ne - 1) / ne;     // col-tiles
    automatic int unsigned mp   = yt * ne;               // padded transposed row pitch
    automatic int unsigned ext  = nt*ne*mp*eb;           // padded destination extent in bytes
    errs = 0;

    // seed the source window beat-aligned either side, reads are word-based
    for (int unsigned i = 0; i < m*n*eb + 2*StrbWidth; i++)
      wr_src(sb - addr_t'(StrbWidth) + addr_t'(i), 8'hE7);
    for (int unsigned r = 0; r < m; r++)
      for (int unsigned c = 0; c < n; c++)
        for (int unsigned b = 0; b < eb; b++)
          wr_src(sb + (r*n + c)*eb + b, 8'((((r*n+c)*eb + b)*7 + 3) & 8'hFF));

    // sentinel-fill the padded destination extent plus a guard band either side
    for (int unsigned i = 0; i < ext; i++) wr_dst(db + addr_t'(i), PadFill);
    for (int unsigned i = 0; i < GuardBytes; i++) begin
      wr_dst(db - addr_t'(GuardBytes) + addr_t'(i), GuardFill);
      wr_dst(db + addr_t'(ext) + addr_t'(i), GuardFill);
    end

    chk_db     = db;
    chk_hi     = db + addr_t'(ext);
    chk_active = 1'b1;

    // -- transposed-stride ND program --
    nd_req = '0;
    nd_req.burst_req.length   = tf_len_t'(ne*eb);   // one tile-row = StrbWidth bytes
    nd_req.burst_req.src_addr = sb;
    nd_req.burst_req.dst_addr = db;
    nd_req.burst_req.opt.src_protocol = idma_pkg::OBI;
    nd_req.burst_req.opt.dst_protocol = idma_pkg::OBI;
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
    // ND midend strides are incremental deltas, not absolute pitches
    nd_req.d_req[0].reps        = reps_t'(ne);
    nd_req.d_req[0].src_strides = addr_t'(int'(n*eb));
    nd_req.d_req[0].dst_strides = addr_t'(int'(mp*eb));
    nd_req.d_req[1].reps        = reps_t'(yt);
    nd_req.d_req[1].src_strides = addr_t'(int'(n*eb));
    nd_req.d_req[1].dst_strides = addr_t'(int'(ne*eb) - int'((ne-1)*mp*eb));
    nd_req.d_req[2].reps        = reps_t'(nt);
    nd_req.d_req[2].src_strides = addr_t'(int'(ne*eb) - int'((yt*ne-1)*n*eb));
    nd_req.d_req[2].dst_strides = addr_t'(int'(mp*eb) - int'((yt-1)*ne*eb));

    $display("[TPO] case %0dx%0d EB=%0d (NE=%0d, %0dx%0d tiles)", m, n, eb, ne, yt, nt);
    nd_req_valid = 1'b1;
    // drop valid on accept; holding it one cycle past makes the midend re-walk the request
    do @(posedge clk); while (!nd_req_ready);
    nd_req_valid = 1'b0;
    nd_req = '0;

    while (!(nd_rsp_valid && nd_rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    chk_active = 1'b0;

    // check 1 (data): out_T[c][r] == in[r][c], transposed at padded pitch mp
    for (int unsigned c = 0; c < n; c++)
      for (int unsigned r = 0; r < m; r++)
        for (int unsigned b = 0; b < eb; b++) begin
          automatic byte_t got = rd_dst(db + (c*mp + r)*eb + b);
          automatic byte_t exp = rd_src(sb + (r*n + c)*eb + b);
          if (got !== exp) begin
            errs++;
            if (errs <= 12)
              $display("[TPO] MISMATCH out_T[%0d][%0d].b%0d=%02h exp %02h", c, r, b, got, exp);
          end
        end
    // check 2: padding cols [m,mp) and padding rows [n,nt*ne) must stay sentinel
    for (int unsigned i = 0; i < nt*ne; i++)
      for (int unsigned j = 0; j < mp; j++)
        if (i >= n || j >= m)
          for (int unsigned b = 0; b < eb; b++) begin
            automatic byte_t got = rd_dst(db + (i*mp + j)*eb + b);
            if (got !== PadFill) begin
              errs++;
              if (errs <= 12)
                $display("[TPO] PADDING CLOBBERED at row=%0d col=%0d b%0d=%02h (exp %02h)",
                         i, j, b, got, PadFill);
            end
          end
    // check 3: the guard bands either side of the allocation must stay untouched
    for (int unsigned i = 0; i < GuardBytes; i++) begin
      automatic byte_t lo = rd_dst(db - addr_t'(GuardBytes) + addr_t'(i));
      automatic byte_t hi = rd_dst(db + addr_t'(ext) + addr_t'(i));
      if (lo !== GuardFill) begin
        errs++;
        if (errs <= 12) $display("[TPO] GUARD CLOBBERED below dst at -%0d = %02h (exp %02h)",
                                 GuardBytes - i, lo, GuardFill);
      end
      if (hi !== GuardFill) begin
        errs++;
        if (errs <= 12) $display("[TPO] GUARD CLOBBERED above dst at +%0d = %02h (exp %02h)",
                                 i, hi, GuardFill);
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
      if (ce == 0) $display("[TPO] PASS: %0dx%0d EB=%0d", Cases[k][0], Cases[k][1], Cases[k][2]);
      else         $display("[TPO] FAIL: %0dx%0d EB=%0d (%0d mismatches)",
                            Cases[k][0], Cases[k][1], Cases[k][2], ce);
      total += ce;
    end

    if (total == 0) $display("[TPO] ALL PASS (%0d cases, StrbWidth=%0d)", NCases, StrbWidth);
    else            $fatal(1, "[TPO] FAIL: %0d total mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #100_000_000; $fatal(1, "[TPO] timeout"); end

endmodule

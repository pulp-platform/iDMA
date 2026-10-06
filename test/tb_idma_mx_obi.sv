// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// MX data and scale planes over OBI and AXI: every op, element format and group size for each
// source and destination port pair of the inst64 backend, every byte and the canaries around the
// planes checked against the DPI-C golden, one at a time and back to back with short copies.

`include "axi/typedef.svh"
`include "idma/typedef.svh"
`include "obi/typedef.svh"

module tb_idma_mx_obi
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  /// Share of cycles in which the OBI grants, AXI AR/AW/B and the backend response are held off
  parameter int unsigned StallPct   = 25,
  /// Backend timing cuts (idma_pkg::timing_cuts_t bits)
  parameter logic [$bits(idma_pkg::timing_cuts_t)-1:0] Cuts = '0
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_load_scale(input int idx, input int val);
  import "DPI-C" function void gm_mxquant_cfg(input int num_blocks, input int fp16, input int elem,
                                              input int rceil, input int poison_dis);
  import "DPI-C" function void gm_mxdequant_cfg(input int num_blocks, input int fp16,
                                                input int elem);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_get_scale(input int idx);
  import "DPI-C" function int  gm_stim_fp16(input int e, input int total, input int salt);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

  localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam bit          Fp16      = StrbWidth <= 64;

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

  `IDMA_TYPEDEF_INIT_ALL(init, AddrWidth, DataWidth, StrbWidth, AxiIdWidth)

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

  // meta channels as idma_inst64_top builds them for this backend
  typedef struct packed { axi_ar_chan_t   ar_chan;  } axi_read_meta_channel_t;
  typedef struct packed { obi_a_chan_t    a_chan;   } obi_read_meta_channel_t;
  typedef struct packed { init_req_chan_t req_chan; } init_read_meta_channel_t;
  typedef struct packed {
    axi_read_meta_channel_t  axi;
    obi_read_meta_channel_t  obi;
    init_read_meta_channel_t init;
  } read_meta_channel_t;
  typedef struct packed { axi_aw_chan_t aw_chan; } axi_write_meta_channel_t;
  typedef struct packed { obi_a_chan_t  a_chan;  } obi_write_meta_channel_t;
  typedef struct packed {
    axi_write_meta_channel_t axi;
    obi_write_meta_channel_t obi;
  } write_meta_channel_t;

  logic clk, rst_n, rst_gen_n, rst_dly_n;
  idma_req_t  idma_req; logic req_valid, req_ready;
  idma_rsp_t  idma_rsp; logic rsp_valid, rsp_ready;
  idma_busy_t busy;
  axi_req_t   axi_read_req, axi_write_req, axi_req, axi_req_mem;
  axi_rsp_t   axi_read_rsp, axi_write_rsp, axi_rsp, axi_rsp_mem;
  init_req_t  init_read_req;
  init_rsp_t  init_read_rsp;
  obi_req_t   obi_read_req, obi_write_req, obi_read_req_mem, obi_write_req_mem;
  obi_rsp_t   obi_read_rsp, obi_write_rsp, obi_read_rsp_mem, obi_write_rsp_mem;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_gen_n));
  assign #(TA) rst_dly_n = rst_gen_n;
  assign rst_n = rst_gen_n & rst_dly_n;

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
    .clk_i(clk), .rst_ni(rst_n), .axi_req_i(axi_req_mem), .axi_rsp_o(axi_rsp_mem),
    .mon_r_last_o(), .mon_r_beat_count_o(), .mon_r_user_o(), .mon_r_id_o(),
    .mon_r_data_o(), .mon_r_addr_o(), .mon_r_valid_o(),
    .mon_w_last_o(), .mon_w_beat_count_o(), .mon_w_user_o(), .mon_w_id_o(),
    .mon_w_data_o(), .mon_w_addr_o(), .mon_w_valid_o()
  );

  // one draw per channel and cycle; a go bit only falls after its handshake
  function automatic logic go_next(input logic go, input logic vld, input logic rdy);
    if (go && vld && !rdy) return 1'b1;
    return $urandom_range(99) >= StallPct;
  endfunction

  logic ar_go, aw_go, b_go, rsp_go;
  logic [1:0] obi_go;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) {ar_go, aw_go, b_go, obi_go} <= '0;
    else begin
      ar_go <= go_next(ar_go, axi_req.ar_valid, axi_rsp_mem.ar_ready);
      aw_go <= go_next(aw_go, axi_req.aw_valid, axi_rsp_mem.aw_ready);
      b_go  <= go_next(b_go,  axi_rsp_mem.b_valid, axi_req.b_ready);
      // the grant is withheld at random, also while no request is up
      obi_go <= {$urandom_range(99) >= StallPct, $urandom_range(99) >= StallPct};
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rsp_go <= 1'b1;
    else        rsp_go <= $urandom_range(99) >= StallPct;
  end

  always_comb begin
    axi_req_mem           = axi_req;
    axi_rsp               = axi_rsp_mem;
    axi_req_mem.ar_valid  = axi_req.ar_valid & ar_go;
    axi_req_mem.aw_valid  = axi_req.aw_valid & aw_go;
    axi_rsp.ar_ready      = axi_rsp_mem.ar_ready & ar_go;
    axi_rsp.aw_ready      = axi_rsp_mem.aw_ready & aw_go;
    axi_req_mem.b_ready   = axi_req.b_ready & b_go;
    axi_rsp.b_valid       = axi_rsp_mem.b_valid & b_go;
    obi_read_req_mem      = obi_read_req;
    obi_read_req_mem.req  = obi_read_req.req & obi_go[0];
    obi_read_rsp          = obi_read_rsp_mem;
    obi_read_rsp.gnt      = obi_read_rsp_mem.gnt & obi_go[0];
    obi_write_req_mem     = obi_write_req;
    obi_write_req_mem.req = obi_write_req.req & obi_go[1];
    obi_write_rsp         = obi_write_rsp_mem;
    obi_write_rsp.gnt     = obi_write_rsp_mem.gnt & obi_go[1];
  end

  obi_sim_mem #(
    .ObiCfg(ObiCfg), .obi_req_t(obi_req_t), .obi_rsp_t(obi_rsp_t), .obi_r_chan_t(obi_r_chan_t),
    .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
  ) i_obi_read_sim_mem (
    .clk_i(clk), .rst_ni(rst_n), .obi_req_i(obi_read_req_mem), .obi_rsp_o(obi_read_rsp_mem),
    .mon_valid_o(), .mon_we_o(), .mon_addr_o(), .mon_wdata_o(), .mon_be_o(), .mon_id_o()
  );

  obi_sim_mem #(
    .ObiCfg(ObiCfg), .obi_req_t(obi_req_t), .obi_rsp_t(obi_rsp_t), .obi_r_chan_t(obi_r_chan_t),
    .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
  ) i_obi_write_sim_mem (
    .clk_i(clk), .rst_ni(rst_n), .obi_req_i(obi_write_req_mem), .obi_rsp_o(obi_write_rsp_mem),
    .mon_valid_o(), .mon_we_o(), .mon_addr_o(), .mon_wdata_o(), .mon_be_o(), .mon_id_o()
  );

  assign init_read_rsp = '0;

  idma_backend_r_init_rw_axi_rw_obi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{mxquant: 1'b1, mxdequant: 1'b1, mxfp16: Fp16,
                                            default: '0}),
    .ComputeTuning('1), .TimingCuts(idma_pkg::timing_cuts_t'(Cuts)),
    .RAWCouplingAvail(1'b0), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(8),
    .MemSysDepth(16),
    .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t), .idma_eh_req_t(idma_eh_req_t),
    .idma_busy_t(idma_busy_t), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .init_req_t(init_req_t), .init_rsp_t(init_rsp_t),
    .obi_req_t(obi_req_t), .obi_rsp_t(obi_rsp_t),
    .write_meta_channel_t(write_meta_channel_t), .read_meta_channel_t(read_meta_channel_t)
  ) i_idma_backend (
    .clk_i(clk), .rst_ni(rst_n),
    .idma_req_i(idma_req), .req_valid_i(req_valid), .req_ready_o(req_ready),
    .idma_rsp_o(idma_rsp), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready & rsp_go),
    .idma_eh_req_i('0), .eh_req_valid_i(1'b0), .eh_req_ready_o(),
    .axi_read_req_o(axi_read_req), .axi_read_rsp_i(axi_read_rsp),
    .init_read_req_o(init_read_req), .init_read_rsp_i(init_read_rsp),
    .obi_read_req_o(obi_read_req), .obi_read_rsp_i(obi_read_rsp),
    .axi_write_req_o(axi_write_req), .axi_write_rsp_i(axi_write_rsp),
    .obi_write_req_o(obi_write_req), .obi_write_rsp_i(obi_write_rsp),
    .busy_o(busy)
  );

  // a busy backend must move a beat every NumCycles
  logic progress;
  assign progress = (busy == '0) |
                    (axi_req.r_ready & axi_rsp.r_valid) | (axi_req.w_valid & axi_rsp.w_ready) |
                    (obi_read_req.req & obi_read_rsp.gnt) | (obi_write_req.req & obi_write_rsp.gnt);
  stream_watchdog #(.NumCycles(5000)) i_progress_wd (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(1'b1), .ready_i(progress));

  typedef struct {
    bit          dq;
    bit          fp16;
    bit          g32;
    mx_elem_e    elem;
    bit          rceil;
    bit          pdis;
    protocol_e   sp;
    protocol_e   dp;
    int unsigned nblk;
    addr_t       src;
    addr_t       dst;
    int          soff;
    int unsigned cp;
  } xfer_t;

  // expected bytes per memory (0: AXI, 1: OBI); any other byte in a checked window is a canary
  logic [7:0] exp_mem [2][addr_t];
  int unsigned win_m [$];
  addr_t       win_lo [$];
  addr_t       win_hi [$];
  int unsigned salt;

  function automatic int unsigned mi(input protocol_e p);
    return (p == idma_pkg::OBI) ? 32'd1 : 32'd0;
  endfunction

  // sources: AXI or OBI read memory; destinations: AXI or OBI write memory
  task automatic wr_src(input protocol_e p, input addr_t a, input logic [7:0] d);
    if (p == idma_pkg::OBI) i_obi_read_sim_mem.mem[a] = d; else i_axi_sim_mem.mem[a] = d;
  endtask
  task automatic wr_dst(input int unsigned m, input addr_t a, input logic [7:0] d);
    if (m == 1) i_obi_write_sim_mem.mem[a] = d; else i_axi_sim_mem.mem[a] = d;
  endtask
  function automatic logic [7:0] rd_dst(input int unsigned m, input addr_t a);
    if (m == 1) return i_obi_write_sim_mem.mem.exists(a) ? i_obi_write_sim_mem.mem[a] : 8'hxx;
    return i_axi_sim_mem.mem.exists(a) ? i_axi_sim_mem.mem[a] : 8'hxx;
  endfunction

  function automatic addr_t scl_base(input xfer_t x);
    return ((x.dq ? x.src : x.dst) & ~addr_t'(MxScaleSlotBytes - 1)) + addr_t'(x.soff * 64);
  endfunction

  function automatic idma_req_t req_of(input xfer_t x);
    automatic idma_req_t r = '0;
    r.length   = tf_len_t'(x.dq ? x.nblk * 32 : x.nblk * (x.fp16 ? 64 : 128));
    r.src_addr = x.src;
    r.dst_addr = x.dst;
    r.opt.axi_id       = id_t'($urandom);
    r.opt.src_protocol = x.sp;
    r.opt.dst_protocol = x.dp;
    r.opt.src.burst    = axi_pkg::BURST_INCR;
    r.opt.dst.burst    = axi_pkg::BURST_INCR;
    r.opt.beo.decouple_rw = 1'b1;
    r.opt.beo.decouple_aw = 1'b1;
    r.opt.last = 1'b1;
    if (x.cp != 0) begin
      r.length = tf_len_t'(x.cp);
      return r;
    end
    r.opt.compute.enable = 1'b1;
    r.opt.compute.op     = x.dq ? (x.fp16 ? COMPUTE_MXDEQUANT_FP16 : COMPUTE_MXDEQUANT)
                                : (x.fp16 ? COMPUTE_MXQUANT_FP16 : COMPUTE_MXQUANT);
    r.opt.compute.params.mx.group      = x.g32 ? MX_GROUP_G32 : MX_GROUP_G64;
    r.opt.compute.params.mx.elem_fmt   = x.elem;
    r.opt.compute.params.mx.rceil      = x.rceil;
    r.opt.compute.params.mx.poison_dis = x.pdis;
    r.scale_addr = scl_base(x);
    return r;
  endfunction

  task automatic window(input int unsigned m, input addr_t lo, input addr_t hi);
    for (addr_t a = lo; a < hi; a++) if (!exp_mem[m].exists(a)) wr_dst(m, a, 8'hA5);
    win_m.push_back(m);
    win_lo.push_back(lo);
    win_hi.push_back(hi);
  endtask

  // writes the source of x and records the bytes x must produce
  task automatic prepare(input xfer_t x);
    automatic int unsigned ne = x.nblk * 32;
    automatic int unsigned eb = x.fp16 ? 2 : 4;
    automatic int unsigned m  = mi(x.dp);
    automatic logic [7:0] dat [];
    automatic logic [7:0] scl [];
    salt++;
    if (x.cp != 0) begin
      // obi_sim_mem reads a whole beat as X when its first byte was never written
      for (addr_t a = x.src & ~addr_t'(StrbWidth - 1); a < x.src + addr_t'(x.cp); a++)
        wr_src(x.sp, a, 8'($urandom));
      for (int unsigned i = 0; i < x.cp; i++) begin
        automatic logic [7:0] v = 8'($urandom);
        wr_src(x.sp, x.src + addr_t'(i), v);
        exp_mem[m][x.dst + addr_t'(i)] = v;
      end
      window(m, x.dst - 128, x.dst + addr_t'(x.cp) + 128);
      return;
    end
    for (int unsigned e = 0; e < ne; e++) begin
      automatic logic [31:0] v = x.fp16 ? 32'(gm_stim_fp16(int'(e), int'(ne), int'(salt)))
                                        : 32'(gm_stim_fp32(int'(e), int'(ne), int'(salt)));
      for (int unsigned b = 0; b < eb; b++) begin
        gm_load(int'(e * eb + b), int'(v[8*b +: 8]));
        if (!x.dq) wr_src(x.sp, x.src + addr_t'(e * eb + b), v[8*b +: 8]);
      end
    end
    gm_mxquant_cfg(int'(x.nblk), int'(x.fp16), int'(x.elem), int'(x.rceil), int'(x.pdis));
    dat = new[ne];
    scl = new[x.nblk];
    for (int unsigned i = 0; i < ne; i++) dat[i] = 8'(gm_get(int'(i)));
    for (int unsigned k = 0; k < x.nblk; k++) scl[k] = 8'(gm_get_scale(int'(k)));
    if (!x.dq) begin
      for (int unsigned k = 0; k < x.nblk; k++) exp_mem[m][scl_base(x) + addr_t'(k)] = scl[k];
      for (int unsigned i = 0; i < ne; i++) exp_mem[m][x.dst + addr_t'(i)] = dat[i];
      window(m, x.dst - 128, x.dst + addr_t'(ne) + 128);
      window(m, scl_base(x) - 128, scl_base(x) + addr_t'(x.nblk) + 128);
    end else begin
      for (int unsigned k = 0; k < x.nblk; k++) begin
        wr_src(x.sp, scl_base(x) + addr_t'(k), scl[k]);
        gm_load_scale(int'(k), int'(scl[k]));
      end
      for (int unsigned i = 0; i < ne; i++) begin
        wr_src(x.sp, x.src + addr_t'(i), dat[i]);
        gm_load(int'(i), int'(dat[i]));
      end
      gm_mxdequant_cfg(int'(x.nblk), int'(x.fp16), int'(x.elem));
      for (int unsigned i = 0; i < ne * eb; i++)
        exp_mem[m][x.dst + addr_t'(i)] = 8'(gm_get(int'(i)));
      window(m, x.dst - 128, x.dst + addr_t'(ne * eb) + 128);
    end
  endtask

  task automatic issue(input xfer_t x);
    #(TA);
    idma_req  = req_of(x);
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    #(TA);
    req_valid = 1'b0;
    idma_req  = '0;
  endtask

  task automatic check(input string tag, output int unsigned errs);
    errs = 0;
    foreach (win_lo[w])
      for (addr_t a = win_lo[w]; a < win_hi[w]; a++) begin
        automatic int unsigned m = win_m[w];
        automatic logic [7:0]  e = exp_mem[m].exists(a) ? exp_mem[m][a] : 8'hA5;
        if (rd_dst(m, a) !== e) begin
          errs++;
          if (errs <= 8) $display("[MXOBI] %s %s[%0h] = %02h exp %02h%s", tag, m ? "obi" : "axi",
                                  a, rd_dst(m, a), e, exp_mem[m].exists(a) ? "" : " (canary)");
        end
      end
    exp_mem[0].delete();
    exp_mem[1].delete();
    win_m.delete();
    win_lo.delete();
    win_hi.delete();
  endtask

  // one transfer at a time, or a batch issued back to back
  task automatic run(input string tag, input xfer_t xs [$], output int unsigned errs);
    automatic int unsigned nrsp = 0, nerr = 0;
    foreach (xs[i]) prepare(xs[i]);
    fork
      foreach (xs[i]) issue(xs[i]);
      while (nrsp < xs.size()) begin
        @(posedge clk);
        if (rsp_valid && rsp_ready && rsp_go) begin
          nrsp++;
          if (idma_rsp.error) nerr++;
        end
      end
    join
    repeat (20) @(posedge clk);
    check(tag, errs);
    errs += nerr;
    $display("[MXOBI] %s: %0d transfers, %0d mismatches, %0d error responses", tag, xs.size(),
             errs - nerr, nerr);
  endtask

  function automatic string pname(input protocol_e p);
    return (p == idma_pkg::OBI) ? "obi" : "axi";
  endfunction

  localparam int unsigned NumN = 6;
  localparam int unsigned Ns [NumN] = '{1, 3, 33, 64, 65, 97};

  initial begin
    automatic protocol_e   prot [2] = '{idma_pkg::AXI, idma_pkg::OBI};
    automatic int unsigned total = 0, runs = 0, ci = 0, e;
    automatic xfer_t b2b [$];
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0; salt = 0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    foreach (prot[s]) foreach (prot[d])
      for (int dq = 0; dq < 2; dq++)
        for (int f16 = 0; f16 < 2; f16++)
          for (int el = 0; el < 2; el++) begin
            if (f16 && !Fp16) continue;
            for (int k = 0; k < 2; k++) begin
              automatic xfer_t x;
              x.dq = dq; x.fp16 = f16; x.elem = mx_elem_e'(el);
              x.sp = prot[s]; x.dp = prot[d];
              x.nblk = Ns[(ci + 3 * k) % NumN];
              x.g32 = (ci + k) % 2; x.rceil = !dq && (ci % 3 == 1); x.pdis = !dq && (ci % 5 == 2);
              x.src = 32'h0001_0000;
              x.dst = (k == 1) ? 32'h0010_0FC0 & ~32'(StrbWidth - 1) : 32'h0010_0000;
              x.soff = k ? -32'sd3 : 32'sd80;
              x.cp = 0;
              if (dq) begin x.src = 32'h0010_0000; x.dst = 32'h0020_0000; end
              run($sformatf("%s%0d %s G%0d %s->%s n=%0d%s%s", dq ? "dq" : "q", f16 ? 16 : 32,
                            x.elem.name(), x.g32 ? 32 : 64, pname(x.sp), pname(x.dp), x.nblk,
                            x.rceil ? " rceil" : "", x.pdis ? " pdis" : ""), '{x}, e);
              total += e; runs++;
            end
            ci++;
          end

    // unaligned copies on every port pair through the compute backend
    foreach (prot[s]) foreach (prot[d])
      for (int k = 0; k < 4; k++) begin
        automatic xfer_t x;
        x.sp = prot[s]; x.dp = prot[d];
        x.src = 32'h0003_0000 + addr_t'($urandom_range(0, 127));
        x.dst = 32'h0030_0000 + addr_t'($urandom_range(0, 127));
        x.cp = $urandom_range(1, 300);
        run($sformatf("copy %s->%s %0d B %0h->%0h", pname(x.sp), pname(x.dp), x.cp, x.src, x.dst),
            '{x}, e);
        total += e; runs++;
      end

    // back to back: quant, dequant and short copies on every port pair, interleaved
    for (int i = 0; i < 48; i++) begin
      automatic xfer_t x;
      x.dq = i % 3 == 2; x.fp16 = Fp16 && (i % 2 == 0); x.elem = mx_elem_e'(i % 4 == 1);
      x.g32 = (i % 5) < 2; x.nblk = x.dq ? Ns[i % NumN] : 1 + (i % 7);
      x.rceil = i % 6 == 0; x.pdis = i % 9 == 0;
      x.sp = prot[i % 2]; x.dp = prot[(i / 2) % 2];
      x.src = 32'h0001_0000 + i * 32'h0001_0000;
      x.dst = 32'h0100_0000 + i * 32'h0002_0000;
      x.soff = (i % 2) ? -32'sd96 : 32'sd512;
      x.cp = 0;
      if (i % 8 == 7) begin
        x.cp = $urandom_range(1, 300);
        x.src += addr_t'($urandom_range(0, 127));
        x.dst += addr_t'($urandom_range(0, 127));
      end
      b2b.push_back(x);
    end
    run("b2b mix", b2b, e);
    total += e; runs++;

    if (total == 0) $display("[MXOBI] ALL PASS (%0d runs, StrbWidth=%0d, StallPct=%0d, Cuts=%0h)",
                             runs, StrbWidth, StallPct, Cuts);
    else            $fatal(1, "[MXOBI] FAIL: %0d mismatches over %0d runs", total, runs);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #400_000_000; $fatal(1, "[MXOBI] timeout"); end

`include "include/tb_idma_mx_axi_mon_macro.svh"
`IDMA_MX_AXI_MON_BIND(idma_backend_r_init_rw_axi_rw_obi)

endmodule

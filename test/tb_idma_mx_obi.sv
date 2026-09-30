// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// MX quant/dequant over OBI: the inst64 backend (r_init_rw_axi_rw_obi) runs every
// size-changing op for each AXI/OBI source and destination pair, checked byte-exact
// against the DPI-C golden (idma_mxquant_dpi.c). Guard bands either side of the
// destination catch a partial tail beat written with a full strobe. StallObi throttles
// the OBI grants.

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
  parameter bit          StallObi   = 1'b1
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_mxquant(input int num_blocks);
  import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
  import "DPI-C" function void gm_mxdequant(input int num_blocks);
  import "DPI-C" function void gm_mxdequant_fp16(input int num_blocks);
  import "DPI-C" function int  gm_get(input int idx);
  import "DPI-C" function int  gm_stim_fp16(input int e, input int total, input int salt);
  import "DPI-C" function int  gm_stim_fp32(input int e, input int total, input int salt);

  localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
  localparam int unsigned StrbWidth  = DataWidth / 8;
  localparam bit          Fp16       = (StrbWidth <= 64);
  localparam int unsigned GuardBytes = 2 * StrbWidth;
  localparam logic [7:0]  DstFill    = 8'hA5;

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

  logic clk, rst_n;
  idma_req_t    idma_req;    logic req_valid, req_ready;
  idma_rsp_t    idma_rsp;    logic rsp_valid, rsp_ready;
  idma_busy_t   busy;
  axi_req_t axi_read_req, axi_write_req, axi_req;
  axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp;
  init_req_t init_read_req;
  init_rsp_t init_read_rsp;
  obi_req_t obi_read_req, obi_write_req, obi_read_req_mem, obi_write_req_mem;
  obi_rsp_t obi_read_rsp, obi_write_rsp, obi_read_rsp_mem, obi_write_rsp_mem;

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

  // OBI grant throttle: the manager holds req, the memory only sees it when not stalled
  logic [1:0] obi_stall;
  always_ff @(posedge clk) begin
    obi_stall[0] <= #TA StallObi && ($urandom_range(0, 3) == 0);
    obi_stall[1] <= #TA StallObi && ($urandom_range(0, 3) == 0);
  end

  always_comb begin
    obi_read_req_mem      = obi_read_req;
    obi_read_req_mem.req  = obi_read_req.req & ~obi_stall[0];
    obi_read_rsp          = obi_read_rsp_mem;
    obi_read_rsp.gnt      = obi_read_rsp_mem.gnt & ~obi_stall[0];
    obi_write_req_mem     = obi_write_req;
    obi_write_req_mem.req = obi_write_req.req & ~obi_stall[1];
    obi_write_rsp         = obi_write_rsp_mem;
    obi_write_rsp.gnt     = obi_write_rsp_mem.gnt & ~obi_stall[1];
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
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b0), .BufferDepth(3),
    .EnableCompute(1'b1),
    .ComputeOps(idma_pkg::compute_enable_t'{mxquant: 1'b1, mxdequant: 1'b1, mxfp16: Fp16,
                                            default: '0}),
    .ComputeTuning('1),
    .RAWCouplingAvail(1'b0), .HardwareLegalizer(1'b1), .RejectZeroTransfers(1'b1),
    .ErrorCap(idma_pkg::NO_ERROR_HANDLING), .PrintFifoInfo(1'b0), .NumAxInFlight(3),
    .MemSysDepth(16),
    .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t), .idma_eh_req_t(idma_eh_req_t),
    .idma_busy_t(idma_busy_t), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .init_req_t(init_req_t), .init_rsp_t(init_rsp_t),
    .obi_req_t(obi_req_t), .obi_rsp_t(obi_rsp_t),
    .write_meta_channel_t(write_meta_channel_t), .read_meta_channel_t(read_meta_channel_t)
  ) i_idma_backend (
    .clk_i(clk), .rst_ni(rst_n),
    .idma_req_i(idma_req), .req_valid_i(req_valid), .req_ready_o(req_ready),
    .idma_rsp_o(idma_rsp), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
    .idma_eh_req_i('0), .eh_req_valid_i(1'b0), .eh_req_ready_o(),
    .axi_read_req_o(axi_read_req), .axi_read_rsp_i(axi_read_rsp),
    .init_read_req_o(init_read_req), .init_read_rsp_i(init_read_rsp),
    .obi_read_req_o(obi_read_req), .obi_read_rsp_i(obi_read_rsp),
    .axi_write_req_o(axi_write_req), .axi_write_rsp_i(axi_write_rsp),
    .obi_write_req_o(obi_write_req), .obi_write_rsp_i(obi_write_rsp),
    .busy_o(busy)
  );

  // a hang surfaces as a watchdog trip: a busy backend must move a beat every NumCycles
  logic progress;
  assign progress = (busy == '0) |
                    (axi_req.r_ready & axi_rsp.r_valid) | (axi_req.w_valid & axi_rsp.w_ready) |
                    (obi_read_req.req & obi_read_rsp.gnt) | (obi_write_req.req & obi_write_rsp.gnt);
  stream_watchdog #(.NumCycles(2000)) i_progress_wd (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(1'b1), .ready_i(progress));

  // byte accessors: sources live in the AXI memory or the OBI read memory,
  // destinations in the AXI memory or the OBI write memory
  task automatic wr_src(input protocol_e p, input addr_t a, input logic [7:0] d);
    if (p == idma_pkg::OBI) i_obi_read_sim_mem.mem[a] = d; else i_axi_sim_mem.mem[a] = d;
  endtask
  task automatic wr_dst(input protocol_e p, input addr_t a, input logic [7:0] d);
    if (p == idma_pkg::OBI) i_obi_write_sim_mem.mem[a] = d; else i_axi_sim_mem.mem[a] = d;
  endtask
  function automatic logic [7:0] rd_dst(input protocol_e p, input addr_t a);
    if (p == idma_pkg::OBI)
      return i_obi_write_sim_mem.mem.exists(a) ? i_obi_write_sim_mem.mem[a] : 8'hxx;
    return i_axi_sim_mem.mem.exists(a) ? i_axi_sim_mem.mem[a] : 8'hxx;
  endfunction

  function automatic int unsigned in_bytes(input compute_op_e op);
    return idma_pkg::compute_in_bytes(op);
  endfunction
  function automatic int unsigned out_bytes(input compute_op_e op);
    return idma_pkg::compute_out_bytes(op);
  endfunction

  // Stage num_blocks of stimulus for op in the source and golden model, run the
  // transfer, and compare the destination plus the guard bands; returns mismatches.
  task automatic run_op(input compute_op_e op, input protocol_e sp, input protocol_e dp,
                        input addr_t src, input addr_t dst, input int unsigned num_blocks,
                        input int unsigned salt, output int unsigned errs);
    automatic int unsigned L  = num_blocks * in_bytes(op);
    automatic int unsigned WL = num_blocks * out_bytes(op);
    automatic logic [15:0] h;
    automatic logic [31:0] w;
    automatic logic [7:0]  b, exp;
    errs = 0;
    unique case (op)
      COMPUTE_MXQUANT_FP16: begin
        for (int unsigned el = 0; el < num_blocks*32; el++) begin
          h = 16'(gm_stim_fp16(int'(el), int'(num_blocks*32), int'(salt)));
          for (int unsigned k = 0; k < 2; k++) begin
            wr_src(sp, src + el*2 + k, h[k*8 +: 8]);
            gm_load(int'(el*2 + k), int'(h[k*8 +: 8]));
          end
        end
        gm_mxquant(int'(num_blocks));
      end
      COMPUTE_MXQUANT: begin
        for (int unsigned el = 0; el < num_blocks*32; el++) begin
          w = 32'(gm_stim_fp32(int'(el), int'(num_blocks*32), int'(salt)));
          for (int unsigned k = 0; k < 4; k++) begin
            wr_src(sp, src + el*4 + k, w[k*8 +: 8]);
            gm_load(int'(el*4 + k), int'(w[k*8 +: 8]));
          end
        end
        gm_mxquant_fp32(int'(num_blocks));
      end
      COMPUTE_MXDEQUANT, COMPUTE_MXDEQUANT_FP16: begin
        // the dequant input is a golden quantized stream, requantized from fresh stimulus
        for (int unsigned el = 0; el < num_blocks*32; el++) begin
          w = 32'(gm_stim_fp32(int'(el), int'(num_blocks*32), int'(salt)));
          for (int unsigned k = 0; k < 4; k++) gm_load(int'(el*4 + k), int'(w[k*8 +: 8]));
        end
        gm_mxquant_fp32(int'(num_blocks));
        for (int unsigned i = 0; i < L; i++) begin
          b = 8'(gm_get(int'(i)));
          wr_src(sp, src + i, b);
          gm_load(int'(i), int'(b));
        end
        if (op == COMPUTE_MXDEQUANT) gm_mxdequant(int'(num_blocks));
        else                         gm_mxdequant_fp16(int'(num_blocks));
      end
      default: $fatal(1, "[MXOBI] unsupported op %s", op.name());
    endcase
    for (int unsigned i = 0; i < WL + 2*GuardBytes; i++)
      wr_dst(dp, dst - GuardBytes + i, DstFill);

    idma_req = '0;
    idma_req.length   = tf_len_t'(L);
    idma_req.src_addr = src;
    idma_req.dst_addr = dst;
    idma_req.opt.src_protocol = sp;
    idma_req.opt.dst_protocol = dp;
    idma_req.opt.src.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.compute.enable = 1'b1;
    idma_req.opt.compute.op     = op;
    idma_req.opt.last           = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    if (idma_rsp.error) begin
      errs++;
      $display("[MXOBI] %s %s->%s: error response", op.name(), sp.name(), dp.name());
    end
    repeat (20) @(posedge clk);

    for (int unsigned i = 0; i < WL + 2*GuardBytes; i++) begin
      b   = rd_dst(dp, dst - GuardBytes + i);
      exp = (i < GuardBytes || i >= GuardBytes + WL) ? DstFill : 8'(gm_get(int'(i - GuardBytes)));
      if (b !== exp) begin
        errs++;
        if (errs <= 8)
          $display("[MXOBI] %s %s->%s nb=%0d: dst%0d = %02h exp %02h%s", op.name(), sp.name(),
                   dp.name(), num_blocks, int'(i) - int'(GuardBytes), b, exp,
                   (i < GuardBytes || i >= GuardBytes + WL) ? " (guard)" : "");
      end
    end
    $display("[MXOBI] %s %s->%s nb=%0d L=%0d WL=%0d: %0d mismatches", op.name(), sp.name(),
             dp.name(), num_blocks, L, WL, errs);
  endtask

  initial begin
    automatic protocol_e   prot [2] = '{idma_pkg::AXI, idma_pkg::OBI};
    automatic int unsigned total = 0, runs = 0, e;
    automatic int unsigned salt = 1;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    foreach (prot[s]) foreach (prot[d]) begin
      // odd block counts leave a partial tail beat; the dequant input must be beat-aligned
      if (Fp16) begin
        run_op(COMPUTE_MXQUANT_FP16, prot[s], prot[d], 'h0001_0000, 'h0005_0000, 3, salt++, e);
        total += e; runs++;
        run_op(COMPUTE_MXQUANT_FP16, prot[s], prot[d], 'h0001_0000, 'h0005_0000,
               2*StrbWidth + 1, salt++, e);
        total += e; runs++;
        run_op(COMPUTE_MXDEQUANT_FP16, prot[s], prot[d], 'h0002_0000, 'h0006_0000,
               StrbWidth, salt++, e);
        total += e; runs++;
      end
      run_op(COMPUTE_MXQUANT, prot[s], prot[d], 'h0001_0000, 'h0005_0000, 5, salt++, e);
      total += e; runs++;
      // the AXI write crosses a 4 KiB page
      run_op(COMPUTE_MXQUANT, prot[s], prot[d], 'h0003_0000, 'h0007_0F80, 2*StrbWidth - 1,
             salt++, e);
      total += e; runs++;
      run_op(COMPUTE_MXDEQUANT, prot[s], prot[d], 'h0002_0000, 'h0006_0000, StrbWidth, salt++, e);
      total += e; runs++;
      run_op(COMPUTE_MXDEQUANT, prot[s], prot[d], 'h0002_0000, 'h0008_0000, 2*StrbWidth,
             salt++, e);
      total += e; runs++;
    end

    if (total == 0) $display("[MXOBI] ALL PASS (%0d runs, StrbWidth=%0d, StallObi=%0d)",
                             runs, StrbWidth, StallObi);
    else            $fatal(1, "[MXOBI] FAIL: %0d mismatches over %0d runs", total, runs);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #400_000_000; $fatal(1, "[MXOBI] timeout"); end

endmodule

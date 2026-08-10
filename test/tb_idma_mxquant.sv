// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// End-to-end FP16 -> MXFP8 quantization test: COMPUTE_MXQUANT_FP16 drives
// 64B (32 FP16 elems) -> 33B (E8M0 scale + 32 E5M2) blocks through the rw_axi
// backend. Checked byte-exact against the DPI-C golden (idma_mxquant_dpi.c).
// Watchdogs surface a hang; one run crosses a 4K page boundary.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_mxquant
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32
);

  import "DPI-C" function void gm_load(input int idx, input int val);
  import "DPI-C" function void gm_mxquant(input int num_blocks);
  import "DPI-C" function void gm_mxquant_fp32(input int num_blocks);
  import "DPI-C" function int  gm_get(input int idx);

  localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam int unsigned BlkInBytes  = 64; // 32 FP16 elems
  localparam int unsigned BlkOutBytes = 33;

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
  axi_req_t axi_read_req, axi_write_req, axi_req, axi_req_mem;
  axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp, axi_rsp_mem;
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

  idma_backend_rw_axi #(
    .CombinedShifter(1'b0), .DataWidth(DataWidth), .AddrWidth(AddrWidth), .AxiIdWidth(AxiIdWidth),
    .UserWidth(UserWidth), .TFLenWidth(TFLenWidth), .MaskInvalidData(1'b1), .BufferDepth(3),
    .EnableCompute(1'b1), .ComputeOps(idma_pkg::compute_enable_t'{mxquant: 1'b1, default: '0}),
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

  stream_watchdog #(.NumCycles(8000)) i_r_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));
  stream_watchdog #(.NumCycles(8000)) i_w_wd (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));

  task automatic wr_mem(input addr_t a, input logic [7:0] d); i_axi_sim_mem.mem[a] = d; endtask
  function automatic logic [7:0] rd_mem(input addr_t a);
    return i_axi_sim_mem.mem.exists(a) ? i_axi_sim_mem.mem[a] : 8'hxx;
  endfunction

  // deterministic FP16 normal for global element index e
  function automatic logic [15:0] fp16_gen(input int unsigned e);
    automatic logic [15:0] sgn = 16'((e & 1) << 15);
    automatic logic [15:0] exp = 16'((1 + (e % 30)) << 10);
    automatic logic [15:0] man = 16'((e * 53) & 10'h3FF);
    return sgn | exp | man;
  endfunction

  // deterministic FP32 pattern; last 8 elements cover zero/subnormal/Inf/NaN/max
  function automatic logic [31:0] fp32_gen(input int unsigned e, input int unsigned total);
    if (e + 8 >= total) begin
      unique case (e % 8)
        0: return 32'h0000_0000;
        1: return 32'h8000_0000;
        2: return 32'h0000_0345;
        3: return 32'h7F80_0000;
        4: return 32'hFF80_0000;
        5: return 32'h7FC1_2345;
        6: return 32'h7F7F_FFFF;
        7: return 32'h0080_0000;
      endcase
    end
    return 32'((e & 1) << 31) | 32'(((64 + (e % 128)) & 8'hFF) << 23) | 32'((e * 2654435761) & 23'h7FFFFF);
  endfunction

  // one num_blocks FP16->MXFP8 transfer; returns error count
  task automatic do_mxquant(input addr_t src, input addr_t dst, input int unsigned num_blocks,
                            output int unsigned errs);
    automatic int unsigned L  = num_blocks * BlkInBytes;
    automatic int unsigned WL = num_blocks * BlkOutBytes;
    automatic logic [15:0] h;
    errs = 0;
    for (int unsigned el = 0; el < num_blocks*32; el++) begin
      h = fp16_gen(el);
      wr_mem(src + el*2,     h[7:0]);
      wr_mem(src + el*2 + 1, h[15:8]);
      gm_load(int'(el*2),     int'(h[7:0]));
      gm_load(int'(el*2 + 1), int'(h[15:8]));
    end
    gm_mxquant(int'(num_blocks));
    for (int unsigned i = 0; i < WL; i++) wr_mem(dst + i, 8'hA5);
    idma_req = '0;
    idma_req.length   = tf_len_t'(L);
    idma_req.src_addr = src;
    idma_req.dst_addr = dst;
    idma_req.opt.src_protocol = idma_pkg::AXI;
    idma_req.opt.dst_protocol = idma_pkg::AXI;
    idma_req.opt.src.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.beo.decouple_rw = 1'b1;
    idma_req.opt.beo.decouple_aw = 1'b1;
    idma_req.opt.compute.enable  = 1'b1;
    idma_req.opt.compute.op      = idma_pkg::COMPUTE_MXQUANT_FP16;
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    for (int unsigned i = 0; i < WL; i++)
      if (rd_mem(dst + i) !== 8'(gm_get(int'(i)))) begin
        errs++; if (errs <= 8) $display("[MXQ] dst[%0d] blk%0d.%0d = %02h exp %02h",
                                        i, i/BlkOutBytes, i%BlkOutBytes, rd_mem(dst+i), 8'(gm_get(int'(i))));
      end
  endtask

  // one num_blocks FP32->MXFP8 transfer; returns error count
  task automatic do_mxquant_fp32(input addr_t src, input addr_t dst, input int unsigned num_blocks,
                                 output int unsigned errs);
    automatic int unsigned L  = num_blocks * 128;
    automatic int unsigned WL = num_blocks * BlkOutBytes;
    automatic logic [31:0] w;
    errs = 0;
    for (int unsigned el = 0; el < num_blocks*32; el++) begin
      w = fp32_gen(el, num_blocks*32);
      for (int unsigned b = 0; b < 4; b++) begin
        wr_mem(src + el*4 + b, w[b*8 +: 8]);
        gm_load(int'(el*4 + b), int'(w[b*8 +: 8]));
      end
    end
    gm_mxquant_fp32(int'(num_blocks));
    for (int unsigned i = 0; i < WL; i++) wr_mem(dst + i, 8'hA5);
    idma_req = '0;
    idma_req.length   = tf_len_t'(L);
    idma_req.src_addr = src;
    idma_req.dst_addr = dst;
    idma_req.opt.src_protocol = idma_pkg::AXI;
    idma_req.opt.dst_protocol = idma_pkg::AXI;
    idma_req.opt.src.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.dst.burst    = axi_pkg::BURST_INCR;
    idma_req.opt.beo.decouple_rw = 1'b1;
    idma_req.opt.beo.decouple_aw = 1'b1;
    idma_req.opt.compute.enable  = 1'b1;
    idma_req.opt.compute.op      = idma_pkg::COMPUTE_MXQUANT;
    idma_req.opt.last            = 1'b1;
    req_valid = 1'b1;
    do @(posedge clk); while (!req_ready);
    req_valid = 1'b0;
    idma_req = '0;
    while (!(rsp_valid && rsp_ready)) @(posedge clk);
    repeat (20) @(posedge clk);
    for (int unsigned i = 0; i < WL; i++)
      if (rd_mem(dst + i) !== 8'(gm_get(int'(i)))) begin
        errs++; if (errs <= 8) $display("[MXQ] fp32 dst[%0d] blk%0d.%0d = %02h exp %02h",
                                        i, i/BlkOutBytes, i%BlkOutBytes, rd_mem(dst+i), 8'(gm_get(int'(i))));
      end
  endtask

  initial begin
    automatic int unsigned total = 0, e1, e2, e3;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    if (StrbWidth <= 64) begin
      do_mxquant('h0000_2000, 'h0000_4000, 8, e1);   // 8 blocks, aligned
      do_mxquant('h0000_6000, 'h0000_0F80, 6, e2);   // write (198B) crosses 4K boundary
    end else begin
      e1 = 0; e2 = 0;                                // FP16 quant capped at StrbWidth 64
    end
    do_mxquant_fp32('h0000_A000, 'h0000_D000, 8, e3);
    total = e1 + e2 + e3;

    if (total == 0) $display("[MXQ] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else            $fatal(1, "[MXQ] FAIL: %0d mismatches", total);
    repeat (5) @(posedge clk);
    $finish();
  end

  initial begin #80_000_000; $fatal(1, "[MXQ] timeout"); end

endmodule

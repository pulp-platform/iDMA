// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Dual-operand compute on the two-read-head backend (idma_backend_2r_axi_w_axi):
// a two-operand ALU transfer reads operand a on one head, its operand-only partner
// request reads operand b on the other head, and the joined stream is written once.
// Every two-operand function runs over aligned, differently misaligned, page-crossing,
// tail-beat and multi-burst geometries, on both head assignments, under random
// per-channel AXI stalls on all three ports; single-operand ops and plain copies on
// either head interleave with the pairs. Byte-exact against the DPI-C golden; the
// destination is checked at the first operand's response, so it also proves that the
// partner's response never overtakes it.

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_dual
  import idma_pkg::*;
#(
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned AddrWidth  = 32,
  parameter int unsigned UserWidth  = 1,
  parameter int unsigned AxiIdWidth = 12,
  parameter int unsigned TFLenWidth = 32,
  parameter int unsigned StallPct   = 30,
  parameter bit          Verbose    = 1'b0
);

  import "DPI-C" function void alu_gm_load(input int idx, input int val);
  import "DPI-C" function void alu_gm_load_b(input int idx, input int val);
  import "DPI-C" function void alu_gm_run(input int func, input int imm, input int len);
  import "DPI-C" function int  alu_gm_get(input int idx);

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

  // bus 0/1: read heads, bus 2: write port; each behind a random-stall shim
  axi_req_t [NumBuses-1:0] axi_req, axi_req_mem;
  axi_rsp_t [NumBuses-1:0] axi_rsp, axi_rsp_mem;

  assign idma_eh_req  = '0;
  assign eh_req_valid = 1'b0;

  clk_rst_gen #(.ClkPeriod(TCK), .RstClkCycles(1)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  // random-stall shim: a channel's go bit may rise any cycle but only falls after its handshake
  logic [NumBuses-1:0] aw_go, w_go, ar_go, b_go, r_go;
  function automatic logic go_next(input logic go, input logic vld, input logic rdy);
    if (go && vld && !rdy) return 1'b1;
    return ($urandom_range(99) >= StallPct);
  endfunction
  for (genvar i = 0; i < NumBuses; i++) begin : gen_bus
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) {aw_go[i], w_go[i], ar_go[i], b_go[i], r_go[i]} <= '0;
      else begin
        aw_go[i] <= go_next(aw_go[i], axi_req[i].aw_valid,    axi_rsp_mem[i].aw_ready);
        w_go[i]  <= go_next(w_go[i],  axi_req[i].w_valid,     axi_rsp_mem[i].w_ready);
        ar_go[i] <= go_next(ar_go[i], axi_req[i].ar_valid,    axi_rsp_mem[i].ar_ready);
        b_go[i]  <= go_next(b_go[i],  axi_rsp_mem[i].b_valid, axi_req[i].b_ready);
        r_go[i]  <= go_next(r_go[i],  axi_rsp_mem[i].r_valid, axi_req[i].r_ready);
      end
    end
    always_comb begin
      axi_req_mem[i] = axi_req[i];
      axi_rsp[i]     = axi_rsp_mem[i];
      axi_req_mem[i].aw_valid = axi_req[i].aw_valid & aw_go[i];
      axi_req_mem[i].w_valid  = axi_req[i].w_valid  & w_go[i];
      axi_req_mem[i].ar_valid = axi_req[i].ar_valid & ar_go[i];
      axi_req_mem[i].b_ready  = axi_req[i].b_ready  & b_go[i];
      axi_req_mem[i].r_ready  = axi_req[i].r_ready  & r_go[i];
      axi_rsp[i].aw_ready     = axi_rsp_mem[i].aw_ready & aw_go[i];
      axi_rsp[i].w_ready      = axi_rsp_mem[i].w_ready  & w_go[i];
      axi_rsp[i].ar_ready     = axi_rsp_mem[i].ar_ready & ar_go[i];
      axi_rsp[i].b_valid      = axi_rsp_mem[i].b_valid  & b_go[i];
      axi_rsp[i].r_valid      = axi_rsp_mem[i].r_valid  & r_go[i];
    end

    axi_sim_mem #(
      .AddrWidth(AddrWidth), .DataWidth(DataWidth), .IdWidth(AxiIdWidth), .UserWidth(UserWidth),
      .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
      .WarnUninitialized(1'b0), .ClearErrOnAccess(1'b1), .ApplDelay(TA), .AcqDelay(TT)
    ) i_axi_sim_mem (
      .clk_i(clk), .rst_ni(rst_n), .axi_req_i(axi_req_mem[i]), .axi_rsp_o(axi_rsp_mem[i]),
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
    .ComputeOps(idma_pkg::compute_enable_t'{alu: 1'b1, alu_mul: 1'b1, dual: 1'b1, default: '0}),
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

  int unsigned rsp_cnt;
  always @(posedge clk) if (rsp_valid && rsp_ready) rsp_cnt <= rsp_cnt + 1;

  // memory accessors (generate instances cannot be indexed by a variable)
  task automatic wr_mem(input int unsigned bus, input addr_t a, input logic [7:0] d);
    case (bus)
      0: gen_bus[0].i_axi_sim_mem.mem[a] = d;
      1: gen_bus[1].i_axi_sim_mem.mem[a] = d;
      default: gen_bus[2].i_axi_sim_mem.mem[a] = d;
    endcase
  endtask
  function automatic logic [7:0] rd_wmem(input addr_t a);
    return gen_bus[2].i_axi_sim_mem.mem.exists(a) ? gen_bus[2].i_axi_sim_mem.mem[a] : 8'hxx;
  endfunction

  localparam int unsigned NumFuncs = 7;
  localparam idma_pkg::alu_func_e Funcs [NumFuncs] = '{
    ALU_ADD, ALU_SUB, ALU_MUL, ALU_AND, ALU_OR, ALU_XOR, ALU_AXPY};
  localparam int unsigned Margin = 32;
  localparam logic [7:0] Canary = 8'hC5;

  function automatic logic [7:0] src_gen(input int unsigned i, input int unsigned seed);
    return 8'(((i + seed) * 32'd2654435761) >> 13);
  endfunction

  // launch one transfer without waiting for its response (drive at TA, sample at TT)
  task automatic launch(input addr_t src, input addr_t dst, input int unsigned len,
                        input logic en, input idma_pkg::alu_func_e func, input logic [7:0] imm,
                        input int unsigned head);
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
    req.opt.compute.enable  = en;
    req.opt.compute.op      = idma_pkg::COMPUTE_ALU;
    req.opt.compute.params.alu.func = func;
    req.opt.compute.params.alu.imm  = imm;
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

  task automatic wait_rsps(input int unsigned n);
    while (rsp_cnt < n) @(posedge clk);
  endtask

  // fill operand a (head bus ha) and b (head bus hb) plus the goldens; canaries around dst
  task automatic prepare(input int unsigned ha, input addr_t src_a, input int unsigned hb,
                         input addr_t src_b, input addr_t dst, input int unsigned len,
                         input int unsigned seed);
    for (int unsigned i = 0; i < len; i++) begin
      wr_mem(ha, src_a + i, src_gen(i, seed));
      alu_gm_load(int'(i), int'(src_gen(i, seed)));
      wr_mem(hb, src_b + i, src_gen(i, seed + 4096));
      alu_gm_load_b(int'(i), int'(src_gen(i, seed + 4096)));
    end
    for (int unsigned i = 0; i < len + 2 * Margin; i++) wr_mem(2, dst - Margin + i, Canary);
  endtask

  // byte-exact destination check plus the canary margins; returns the error count
  function automatic int unsigned check(input int unsigned geo, input idma_pkg::alu_func_e func,
                                        input addr_t dst, input int unsigned len);
    automatic int unsigned errs = 0;
    for (int unsigned i = 0; i < len; i++)
      if (rd_wmem(dst + i) !== 8'(alu_gm_get(int'(i)))) begin
        errs++;
        if (errs <= 8) $display("[DUAL] geo%0d func=%0d dst[%0d] = %02h exp %02h", geo, func, i,
                                rd_wmem(dst + i), 8'(alu_gm_get(int'(i))));
      end
    for (int unsigned i = 0; i < Margin; i++) begin
      if (rd_wmem(dst - Margin + i) !== Canary) begin
        errs++;
        if (errs <= 8) $display("[DUAL] geo%0d func=%0d canary before dst clobbered", geo, func);
      end
      if (rd_wmem(dst + len + i) !== Canary) begin
        errs++;
        if (errs <= 8) $display("[DUAL] geo%0d func=%0d canary after dst clobbered", geo, func);
      end
    end
    return errs;
  endfunction

  // one pair over one geometry; dst is checked at the first response, the partner's must follow
  task automatic run_pair(input int unsigned geo, input idma_pkg::alu_func_e func,
                          input logic [7:0] imm, input int unsigned ha, input addr_t src_a,
                          input int unsigned hb, input addr_t src_b, input addr_t dst,
                          input int unsigned len, input int unsigned seed,
                          inout int unsigned errs);
    automatic int unsigned base = rsp_cnt;
    if (Verbose)
      $display("[DUAL] geo%0d func=%0d imm=%02h a=h%0d:%h b=h%0d:%h dst=%h len=%0d @%0t", geo,
               func, imm, ha, src_a, hb, src_b, dst, len, $time);
    prepare(ha, src_a, hb, src_b, dst, len, seed);
    alu_gm_run(int'(func), int'(imm), int'(len));
    launch(src_a, dst, len, 1'b1, func, imm, ha);
    launch(src_b, dst, len, 1'b1, func, imm, hb);
    wait_rsps(base + 1);
    errs += check(geo, func, dst, len);
    wait_rsps(base + 2);
    repeat (5) @(posedge clk);
  endtask

  localparam addr_t SrcABase = 'h0001_0000, SrcBBase = 'h0003_0000, DstBase = 'h0009_0000;

  // geometry list: operand a offset, operand b offset, destination offset, length
  localparam int unsigned NumGeos = 8;
  localparam int unsigned GeoAOff [NumGeos] = '{0, 1, 4096 - 7, 5, 7, 0, StrbWidth / 2, 3};
  localparam int unsigned GeoBOff [NumGeos] = '{0, 3, 0, 6, 2, 0, StrbWidth / 2 + 1, 4096 - 2};
  localparam int unsigned GeoDOff [NumGeos] = '{0, 2, 4096 - 3, 7, 6, 0, 1, 5};
  localparam int unsigned GeoLen  [NumGeos] = '{
    4 * StrbWidth,      // aligned, whole beats
    3 * StrbWidth + 5,  // all three misaligned differently, tail beat
    5 * StrbWidth + 2,  // a and dst cross a page, b aligned
    9000,               // multi-burst: more bursts than any queue holds
    1,                  // single byte
    StrbWidth - 1,      // sub-beat, aligned
    StrbWidth,          // half-beat offsets
    2 * StrbWidth + 3   // b crosses a page
  };

  initial begin
    automatic int unsigned errs = 0, seed = 0, base;
    automatic addr_t src_a, src_b, dst;
    automatic logic [7:0] imm;
    req_valid = 1'b0; rsp_ready = 1'b1; idma_req = '0; rsp_cnt = 0;
    @(posedge rst_n);
    repeat (5) @(posedge clk);

    // every two-operand function over every geometry, a on head 0 and b on head 1
    for (int unsigned g = 0; g < NumGeos; g++) begin
      for (int unsigned f = 0; f < NumFuncs; f++) begin
        src_a = SrcABase + GeoAOff[g];
        src_b = SrcBBase + GeoBOff[g];
        dst   = DstBase + GeoDOff[g];
        imm   = 8'(seed * 37 + 3);
        run_pair(g, Funcs[f], imm, 0, src_a, 1, src_b, dst, GeoLen[g], seed, errs);
        seed++;
      end
    end

    // heads swapped: a on head 1, b on head 0
    for (int unsigned g = 0; g < NumGeos; g += 2) begin
      src_a = SrcABase + GeoAOff[g];
      src_b = SrcBBase + GeoBOff[g];
      dst   = DstBase + GeoDOff[g];
      imm   = 8'(seed * 37 + 3);
      run_pair(NumGeos + g, Funcs[g % NumFuncs], imm, 1, src_a, 0, src_b, dst, GeoLen[g], seed,
               errs);
      seed++;
    end

    // single-operand ops and plain copies keep working on either head, before and after pairs
    for (int unsigned h = 0; h < NumHeads; h++) begin
      base  = rsp_cnt;
      src_a = SrcABase + 3;
      dst   = DstBase + 5;
      for (int unsigned i = 0; i < 3 * StrbWidth + 2; i++) begin
        wr_mem(h, src_a + i, src_gen(i, 900 + h));
        alu_gm_load(int'(i), int'(src_gen(i, 900 + h)));
      end
      for (int unsigned i = 0; i < 3 * StrbWidth + 2 + 2 * Margin; i++)
        wr_mem(2, dst - Margin + i, Canary);
      alu_gm_run(int'(ALU_XORI), 8'h5A, int'(3 * StrbWidth + 2));
      launch(src_a, dst, 3 * StrbWidth + 2, 1'b1, ALU_XORI, 8'h5A, h);
      wait_rsps(base + 1);
      errs += check(2 * NumGeos + h, ALU_XORI, dst, 3 * StrbWidth + 2);

      base = rsp_cnt;
      for (int unsigned i = 0; i < 2 * StrbWidth + 1 + 2 * Margin; i++)
        wr_mem(2, dst - Margin + i, Canary);
      launch(src_a, dst, 2 * StrbWidth + 1, 1'b0, ALU_NOT, 8'h00, h);
      wait_rsps(base + 1);
      for (int unsigned i = 0; i < 2 * StrbWidth + 1; i++)
        if (rd_wmem(dst + i) !== src_gen(i, 900 + h)) begin
          errs++;
          if (errs <= 8) $display("[DUAL] copy h%0d dst[%0d] = %02h", h, i, rd_wmem(dst + i));
        end
    end

    // a pair immediately followed by a plain copy on head 1 (config change drains the pair)
    base  = rsp_cnt;
    src_a = SrcABase + 1;
    src_b = SrcBBase + 2;
    dst   = DstBase + 3;
    prepare(0, src_a, 1, src_b, dst, 5 * StrbWidth + 1, 777);
    alu_gm_run(int'(ALU_AXPY), 8'h07, int'(5 * StrbWidth + 1));
    for (int unsigned i = 0; i < 2 * StrbWidth; i++) wr_mem(1, SrcBBase + 'h1000 + i, 8'(i));
    for (int unsigned i = 0; i < 2 * StrbWidth + 2 * Margin; i++)
      wr_mem(2, DstBase + 'h1000 - Margin + i, Canary);
    launch(src_a, dst, 5 * StrbWidth + 1, 1'b1, ALU_AXPY, 8'h07, 0);
    launch(src_b, dst, 5 * StrbWidth + 1, 1'b1, ALU_AXPY, 8'h07, 1);
    launch(SrcBBase + 'h1000, DstBase + 'h1000, 2 * StrbWidth, 1'b0, ALU_NOT, 8'h00, 1);
    wait_rsps(base + 3);
    errs += check(2 * NumGeos + 2, ALU_AXPY, dst, 5 * StrbWidth + 1);
    for (int unsigned i = 0; i < 2 * StrbWidth; i++)
      if (rd_wmem(DstBase + 'h1000 + i) !== 8'(i)) begin
        errs++;
        if (errs <= 8) $display("[DUAL] copy after pair dst[%0d] = %02h", i,
                                rd_wmem(DstBase + 'h1000 + i));
      end

    if (errs == 0) $display("[DUAL] ALL PASS (StrbWidth=%0d)", StrbWidth);
    else $fatal(1, "[DUAL] %0d errors (StrbWidth=%0d)", errs, StrbWidth);
    $finish;
  end

  initial begin #50ms; $fatal(1, "[DUAL] timeout"); end

endmodule

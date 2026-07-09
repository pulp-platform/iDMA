// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Self-checking testbench for the iDMA register frontend (idma_reg32_3d, apb4-flat).
// Drives the APB config slave against a controllable backend stub and checks the
// non-blocking next_id launch contract: the config read completes promptly (even
// under backend backpressure) and the launch fires exactly once when the arbiter
// grants. A per-read watchdog guards against any read that hangs.

`include "apb/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_reg_frontend import idma_pkg::*; #(
  // number of streams the elaborated DUT exposes (checked at instantiation)
  parameter int unsigned NumStreams = 32'd1
);

  // --------------------------------------------------------------------------
  // Parameters
  // --------------------------------------------------------------------------
  localparam time         TCK            = 10ns;
  localparam int unsigned CfgAddrWidth   = 32'd32;
  localparam int unsigned CfgDataWidth   = 32'd32;
  localparam int unsigned CfgStrbWidth   = CfgDataWidth / 32'd8;
  localparam int unsigned IdCounterWidth = 32'd32;
  localparam int unsigned NumRegs        = 32'd1;
  // idma data-path (reg32_3d: 32-bit data, 3 ND dims)
  localparam int unsigned AddrWidth      = 32'd32;
  localparam int unsigned DataWidth      = 32'd32;
  localparam int unsigned NumDim         = 32'd3;
  localparam int unsigned RepWidth       = 32'd32;
  // bounded-latency bound for a non-blocking next_id read: it must complete within
  // this many config-clock cycles of the ACCESS phase even while req_ready_i is low.
  localparam int unsigned MaxReadLatency = 32'd2;
  // watchdog bound: any next_id APB read that does not complete within this many
  // config-clock cycles is a hang (the non-blocking read completes in <= 2 cycles).
  localparam int unsigned DeadlockCycles = 32'd2000;

  // register map (idma_reg32_3d_addrmap_pkg): base + per-stream stride 0x4
  localparam logic [31:0] REG_CONF       = 32'h0000_0000;
  localparam logic [31:0] REG_STATUS0    = 32'h0000_0004;
  localparam logic [31:0] REG_NEXT_ID0   = 32'h0000_0044;
  localparam logic [31:0] REG_DONE_ID0   = 32'h0000_0084;
  localparam logic [31:0] REG_DST_ADDR   = 32'h0000_00D0;
  localparam logic [31:0] REG_SRC_ADDR   = 32'h0000_00D4;
  localparam logic [31:0] REG_LENGTH     = 32'h0000_00D8;

  function automatic logic [31:0] reg_next_id(input int unsigned s);
    return REG_NEXT_ID0 + 32'(s) * 32'h4;
  endfunction
  function automatic logic [31:0] reg_done_id(input int unsigned s);
    return REG_DONE_ID0 + 32'(s) * 32'h4;
  endfunction

  // --------------------------------------------------------------------------
  // Types
  // --------------------------------------------------------------------------
  typedef logic [CfgAddrWidth-1:0] cfg_addr_t;
  typedef logic [CfgDataWidth-1:0] cfg_data_t;
  typedef logic [CfgStrbWidth-1:0] cfg_strb_t;

  `APB_TYPEDEF_REQ_T(cfg_apb_req_t, cfg_addr_t, cfg_data_t, cfg_strb_t)
  `APB_TYPEDEF_RESP_T(cfg_apb_rsp_t, cfg_data_t)

  localparam int unsigned StrbWidth   = DataWidth / 32'd8;
  localparam int unsigned OffsetWidth = $clog2(StrbWidth);
  typedef logic [AddrWidth-1:0]   addr_t;
  typedef logic [StrbWidth-1:0]   strb_t;
  typedef logic [OffsetWidth-1:0] offset_t;
  typedef logic [RepWidth-1:0]    strides_t;
  typedef logic [RepWidth-1:0]    reps_t;
  typedef logic [AddrWidth-1:0]   tf_len_t;
  typedef logic                   idma_user_t;

  `IDMA_TYPEDEF_OPTIONS_T(options_t, logic)
  `IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, addr_t, options_t, idma_user_t)
  `IDMA_TYPEDEF_D_REQ_T(idma_d_req_t, reps_t, strides_t)
  `IDMA_TYPEDEF_ND_REQ_T(idma_nd_req_t, idma_req_t, idma_d_req_t)

  typedef logic [IdCounterWidth-1:0] cnt_width_t;

  // --------------------------------------------------------------------------
  // Clock / reset
  // --------------------------------------------------------------------------
  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #(TCK/2) clk = ~clk;
  end

  // --------------------------------------------------------------------------
  // DUT nets
  // --------------------------------------------------------------------------
  cfg_apb_req_t [NumRegs-1:0] apb_req;
  cfg_apb_rsp_t [NumRegs-1:0] apb_rsp;

  idma_nd_req_t dma_req;
  logic         req_valid;
  logic         req_ready;              // driven by the backend stub
  cnt_width_t   next_id;                // from the id gen
  logic [(NumStreams>1?$clog2(NumStreams):1)-1:0] stream_idx;
  cnt_width_t   [NumStreams-1:0] done_id;
  idma_busy_t   [NumStreams-1:0] busy;
  logic         [NumStreams-1:0] midend_busy;

  // --------------------------------------------------------------------------
  // Transfer-id generator (owns the next/completed counters). Reset next=2.
  // issue on an accepted launch, retire on a modeled backend completion.
  // --------------------------------------------------------------------------
  logic issue;
  logic retire;

  idma_transfer_id_gen #(
    .IdWidth ( IdCounterWidth )
  ) i_id_gen (
    .clk_i       ( clk       ),
    .rst_ni      ( rst_n     ),
    .issue_i     ( issue     ),
    .retire_i    ( retire    ),
    .next_o      ( next_id   ),
    .completed_o ( done_id[0] )
  );
  // multi-stream: id gen models stream 0; other streams share the same completed
  // counter here (the DUT only compares per-stream done_id on read-back).
  for (genvar s = 1; s < NumStreams; s++) begin : gen_done_other
    assign done_id[s] = done_id[0];
  end

  // an accepted launch is the arbiter handshake; also the SW "id-advance" event
  assign issue = req_valid & req_ready;

  // --------------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------------
  idma_reg32_3d #(
    .NumRegs        ( NumRegs        ),
    .NumStreams     ( NumStreams     ),
    .IdCounterWidth ( IdCounterWidth ),
    .apb_req_t      ( cfg_apb_req_t  ),
    .apb_rsp_t      ( cfg_apb_rsp_t  ),
    .dma_req_t      ( idma_nd_req_t  )
  ) i_dut (
    .clk_i          ( clk         ),
    .rst_ni         ( rst_n       ),
    .dma_ctrl_req_i ( apb_req     ),
    .dma_ctrl_rsp_o ( apb_rsp     ),
    .dma_req_o      ( dma_req     ),
    .req_valid_o    ( req_valid   ),
    .req_ready_i    ( req_ready   ),
    .next_id_i      ( next_id     ),
    .stream_idx_o   ( stream_idx  ),
    .done_id_i      ( done_id     ),
    .busy_i         ( busy        ),
    .midend_busy_i  ( midend_busy )
  );

  // --------------------------------------------------------------------------
  // Backend stub. `req_ready` is directly controllable by the tests. On each
  // accepted launch (req_valid & req_ready) the emitted ND request is captured
  // and enqueued with a retire-deadline; when its timer expires it is retired in
  // order via the id gen so `done_id` advances. `busy`/`midend_busy` follow the
  // outstanding count. A single-entry timer is enough — launches are retired FIFO
  // and only re-armed once the previous one drains, which keeps ordering exact.
  // --------------------------------------------------------------------------
  idma_nd_req_t captured_q[$];          // every accepted launch, for self-check
  int unsigned  outstanding;            // in-flight (not yet retired) launches
  int unsigned  retire_delay;           // clocks a launch stays in flight
  logic         backend_auto_retire;    // if 0, retirement is suppressed
  int           retire_timer;           // -1 == no launch currently timing out

  assign busy[0]        = (outstanding != 0) ? '1 : '0;
  assign midend_busy[0] = (outstanding != 0) ? 1'b1 : 1'b0;
  for (genvar s = 1; s < NumStreams; s++) begin : gen_busy_other
    assign busy[s]        = busy[0];
    assign midend_busy[s] = midend_busy[0];
  end

  initial begin
    outstanding         = 0;
    retire_timer        = -1;
    retire_delay        = 3;
    backend_auto_retire = 1'b1;
    retire              = 1'b0;
  end

  // Unified backend model: capture launches, count outstanding, and retire FIFO.
  always @(posedge clk) begin
    automatic bit accept    = rst_n && req_valid && req_ready;
    automatic bit do_retire = 1'b0;

    retire <= 1'b0;
    if (!rst_n) begin
      outstanding  <= 0;
      retire_timer <= -1;
    end else begin
      // 1) capture an accepted launch
      if (accept)
        captured_q.push_back(dma_req);

      // 2) advance / fire the retire timer
      if (backend_auto_retire && retire_timer == 0) begin
        retire       <= 1'b1;
        do_retire     = 1'b1;
        retire_timer <= -1;     // re-armed below if launches remain
      end else if (retire_timer > 0) begin
        retire_timer <= retire_timer - 1;
      end

      // 3) update outstanding count (+accept, -retire)
      outstanding <= outstanding + (accept ? 1 : 0) - (do_retire ? 1 : 0);

      // 4) arm the timer whenever a launch is waiting and none is timing out
      if (backend_auto_retire) begin
        automatic int unsigned next_out =
            outstanding + (accept ? 1 : 0) - (do_retire ? 1 : 0);
        if ((retire_timer < 0 || do_retire) && next_out > 0)
          retire_timer <= retire_delay;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Watchdog: fatal if a next_id APB read stays outstanding too long.
  // `nxt_read_active` is raised by apb_read on a next_id address and cleared
  // when pready completes it.
  // --------------------------------------------------------------------------
  logic        nxt_read_active;
  int unsigned nxt_read_watchdog;
  initial begin
    nxt_read_active   = 1'b0;
    nxt_read_watchdog = 0;
  end
  always @(posedge clk) begin
    if (!rst_n) begin
      nxt_read_watchdog <= 0;
    end else if (nxt_read_active) begin
      nxt_read_watchdog <= nxt_read_watchdog + 1;
      if (nxt_read_watchdog > DeadlockCycles) begin
        $fatal(1, "DEADLOCK: next_id read did not complete within %0d cycles",
               DeadlockCycles);
      end
    end else begin
      nxt_read_watchdog <= 0;
    end
  end

  // --------------------------------------------------------------------------
  // Global "launch accepted" pulse counter: an accepted launch is one arbiter
  // handshake (issue). Used by the launch-integrity scoreboard and by the
  // driver to wait for id-advance before re-launching.
  // --------------------------------------------------------------------------
  int unsigned launch_accept_count;
  int unsigned launch_acc_base;         // accept-count snapshot taken at a launch read
  always @(posedge clk) begin
    if (!rst_n) launch_accept_count <= 0;
    else if (issue) launch_accept_count <= launch_accept_count + 1;
  end

  // --------------------------------------------------------------------------
  // APB driver
  // --------------------------------------------------------------------------
  task automatic apb_idle();
    apb_req[0].psel    = 1'b0;
    apb_req[0].penable = 1'b0;
    apb_req[0].pwrite  = 1'b0;
    apb_req[0].paddr   = '0;
    apb_req[0].pwdata  = '0;
    apb_req[0].pstrb   = '0;
    apb_req[0].pprot   = '0;
  endtask

  // Strict APB4 master. `access_cycles` (out) counts the ACCESS-phase config cycles
  // a read waited for pready, so a test can bound the read latency. One APB
  // transaction == one CPUIF request (a guaranteed idle cycle follows).
  task automatic apb_xact(input  bit          write,
                          input  logic [31:0] addr,
                          input  logic [31:0] wdata,
                          output logic [31:0] rdata,
                          output int unsigned access_cycles,
                          input  bit          is_next_id = 1'b0);
    access_cycles = 0;
    // SETUP phase: psel high, penable low, for one cycle
    @(negedge clk);
    apb_req[0].psel    = 1'b1;
    apb_req[0].penable = 1'b0;
    apb_req[0].pwrite  = write;
    apb_req[0].paddr   = addr;
    apb_req[0].pwdata  = wdata;
    apb_req[0].pstrb   = write ? '1 : '0;
    apb_req[0].pprot   = '0;
    if (is_next_id) nxt_read_active = 1'b1;

    // ACCESS phase: raise penable, then wait for pready at the posedge. Count the
    // ACCESS-phase cycles until pready — for a next_id read this is the read latency
    // the non-blocking contract bounds (must not depend on req_ready_i).
    @(negedge clk);
    apb_req[0].penable = 1'b1;
    forever begin
      @(posedge clk);
      access_cycles = access_cycles + 1;
      if (apb_rsp[0].pready) begin
        rdata = apb_rsp[0].prdata;      // sample in the completing cycle
        break;
      end
    end
    // retire the transaction: return to IDLE immediately (no extra held posedge)
    apb_idle();
    if (is_next_id) nxt_read_active = 1'b0;
    // mandatory idle cycle so the FSM's is_active fully drops with psel low
    @(negedge clk);
  endtask

  task automatic apb_write(input logic [31:0] addr, input logic [31:0] data);
    logic [31:0] dummy;
    int unsigned cyc;
    apb_xact(1'b1, addr, data, dummy, cyc);
  endtask

  // APB4 read that respects pready; `cyc` returns the ACCESS-phase cycle count.
  task automatic apb_read(input  logic [31:0] addr,
                          output logic [31:0] data,
                          output int unsigned cyc,
                          input  bit          is_next_id = 1'b0);
    apb_xact(1'b0, addr, 32'h0, data, cyc, is_next_id);
  endtask

  // --------------------------------------------------------------------------
  // High-level helpers
  // --------------------------------------------------------------------------
  task automatic program_transfer(input logic [31:0] src,
                                   input logic [31:0] dst,
                                   input logic [31:0] len);
    // conf: plain 1D incremental copy, ND disabled
    apb_write(REG_CONF,     32'h0);
    apb_write(REG_SRC_ADDR, src);
    apb_write(REG_DST_ADDR, dst);
    apb_write(REG_LENGTH,   len);
  endtask

  // launch: read next_id (the transfer trigger, non-blocking); returns id and the
  // ACCESS-phase latency in `cyc`. Snapshots the accept count before the read so
  // an accept coinciding with the (non-blocking) read is still observed.
  task automatic launch(output logic [31:0] id, output int unsigned cyc,
                        input int unsigned s = 0);
    launch_acc_base = launch_accept_count;
    apb_read(reg_next_id(s), id, cyc, .is_next_id(1'b1));
  endtask

  // wait until the launch read since the last launch() has been accepted (the
  // arbiter grant / id-advance). SW confirms acceptance before re-launching.
  task automatic wait_launch_accepted();
    int unsigned tries;
    tries = 0;
    while (launch_accept_count == launch_acc_base) begin
      @(posedge clk);
      tries++;
      if (tries > 1000)
        $fatal(1, "wait_launch_accepted: launch never accepted");
    end
  endtask

  task automatic read_done(output logic [31:0] id, input int unsigned s = 0);
    int unsigned cyc;
    apb_read(reg_done_id(s), id, cyc);
  endtask

  // poll done_id until it reaches `id` (or a bounded number of tries)
  task automatic poll_done(input logic [31:0] id, input int unsigned s = 0);
    logic [31:0] d;
    int unsigned tries;
    tries = 0;
    do begin
      read_done(d, s);
      tries++;
      if (tries > 1000)
        $fatal(1, "poll_done: done_id never reached %0d (last %0d)", id, d);
    end while (d != id);
  endtask

  // --------------------------------------------------------------------------
  // Bookkeeping for the test program
  // --------------------------------------------------------------------------
  int unsigned errors;
  int unsigned checks;

  task automatic check_eq(input logic [63:0] got, input logic [63:0] exp,
                          input string msg);
    checks++;
    if (got !== exp) begin
      errors++;
      $error("[FAIL] %s: got 0x%0h, expected 0x%0h", msg, got, exp);
    end else begin
      $display("[ ok ] %s = 0x%0h", msg, got);
    end
  endtask

  // --------------------------------------------------------------------------
  // Test program
  // --------------------------------------------------------------------------
  logic [31:0] id0, id1, id2, id3;
  logic [31:0] exp_id;                   // id gen next_o snapshot before a launch
  logic [31:0] prev_id;                  // last returned id, for monotonic checks
  int unsigned rcyc;                     // last read's ACCESS-phase cycle count

  initial begin : test
    errors = 0;
    checks = 0;
    apb_idle();
    req_ready = 1'b1;

    // reset
    rst_n = 1'b0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    $display("=====================================================");
    $display(" tb_idma_reg_frontend  (NumStreams=%0d)", NumStreams);
    $display("=====================================================");

    // ------------------------------------------------------------------
    // Test 1 — Basic launch (backend ready), non-blocking read
    // ------------------------------------------------------------------
    $display("\n--- Test 1: basic launch ---");
    backend_auto_retire = 1'b1;
    req_ready           = 1'b1;
    captured_q.delete();
    program_transfer(32'h1000_0000, 32'h2000_0000, 32'h0000_0040);
    // id gen resets next=2, so the very first launch must return id 2
    exp_id = next_id;
    check_eq(exp_id, 32'd2, "Test1 id gen resets next=2");
    launch(id0, rcyc);
    // the launch returns exactly the id that was pending
    check_eq(id0, exp_id, "Test1 first launch id == next_id");
    // non-blocking: the read completed within the bounded latency
    check_eq(rcyc <= MaxReadLatency, 1'b1, "Test1 read within bounded latency");
    wait_launch_accepted();
    prev_id = id0;
    // exactly one launch captured, with the programmed geometry
    check_eq(captured_q.size(), 32'd1, "Test1 launch count");
    if (captured_q.size() > 0) begin
      check_eq(captured_q[0].burst_req.src_addr, 32'h1000_0000, "Test1 src_addr");
      check_eq(captured_q[0].burst_req.dst_addr, 32'h2000_0000, "Test1 dst_addr");
      check_eq(captured_q[0].burst_req.length,   32'h0000_0040, "Test1 length");
    end
    poll_done(id0);
    $display("[ ok ] Test1 done_id reached %0d", id0);

    // ------------------------------------------------------------------
    // Test 2 — Non-blocking read under backpressure (core gate)
    // The next_id read MUST complete promptly (bounded latency) even while
    // req_ready_i is held LOW. On a blocking template this FAILS.
    // ------------------------------------------------------------------
    $display("\n--- Test 2: non-blocking read under backpressure ---");
    backend_auto_retire = 1'b0;       // no auto retire while we hold the stall
    captured_q.delete();
    // model a busy backend: hold req_ready LOW so the arbiter cannot grant
    req_ready = 1'b0;
    program_transfer(32'h3000_0000, 32'h4000_0000, 32'h0000_0080);
    exp_id = next_id;                 // id that this launch returns
    // the read completes despite req_ready low — the non-blocking property
    launch(id1, rcyc);
    check_eq(rcyc <= MaxReadLatency, 1'b1, "Test2 read within bounded latency (BP)");
    check_eq(id1, exp_id, "Test2 launch id == pre-stall next_id");
    check_eq(id1, prev_id + 32'd1, "Test2 id monotonic after Test1");
    prev_id = id1;
    // the launch is held pending (not yet granted): id must not have advanced yet
    check_eq(next_id, exp_id, "Test2 id held (no issue) while req_ready low");
    // release backpressure — the held launch now completes exactly once
    req_ready = 1'b1;
    wait_launch_accepted();
    check_eq(captured_q.size(), 32'd1, "Test2 launch accepted exactly once");
    if (captured_q.size() > 0) begin
      check_eq(captured_q[0].burst_req.src_addr, 32'h3000_0000, "Test2 src_addr held");
      check_eq(captured_q[0].burst_req.length,   32'h0000_0080, "Test2 length held");
    end
    // let it retire and confirm the reg block is still live afterwards
    backend_auto_retire = 1'b1;
    poll_done(id1);
    $display("[ ok ] Test2 completed after backpressure, block still live");

    // ------------------------------------------------------------------
    // Test 2b — Launch integrity: a launch is never dropped when the grant
    // is late. Hold req_ready low for several cycles AFTER a next_id read,
    // then release; the latch must fire the launch EXACTLY ONCE.
    // ------------------------------------------------------------------
    $display("\n--- Test 2b: launch integrity (late grant, no drop) ---");
    backend_auto_retire = 1'b0;
    captured_q.delete();
    req_ready = 1'b0;
    program_transfer(32'h7000_0000, 32'h8000_0000, 32'h0000_00C0);
    exp_id = next_id;
    begin
      int unsigned acc_before;
      acc_before = launch_accept_count;
      // single next_id read (one launch), completes non-blocking under BP
      launch(id3, rcyc);
      check_eq(rcyc <= MaxReadLatency, 1'b1, "Test2b read within bounded latency (BP)");
      check_eq(id3, exp_id, "Test2b launch id == next_id");
      // hold the grant off for several cycles: the launch must stay pending, not drop
      repeat (12) @(posedge clk);
      check_eq(launch_accept_count, acc_before, "Test2b no accept while req_ready low");
      check_eq(req_valid, 1'b1, "Test2b req_valid held high across late grant");
      check_eq(captured_q.size(), 32'd0, "Test2b nothing captured before grant");
      // release: exactly one accept, exactly one captured launch
      req_ready = 1'b1;
      wait_launch_accepted();
      check_eq(launch_accept_count, acc_before + 32'd1, "Test2b launch fired exactly once");
    end
    // give the arbiter a settle cycle, then confirm no second spurious launch
    repeat (4) @(posedge clk);
    check_eq(captured_q.size(), 32'd1, "Test2b exactly one launch captured");
    if (captured_q.size() > 0) begin
      check_eq(captured_q[0].burst_req.src_addr, 32'h7000_0000, "Test2b src_addr held");
      check_eq(captured_q[0].burst_req.length,   32'h0000_00C0, "Test2b length held");
    end
    check_eq(id3, prev_id + 32'd1, "Test2b id monotonic");
    prev_id = id3;
    backend_auto_retire = 1'b1;
    poll_done(id3);
    $display("[ ok ] Test2b launch fired exactly once after late grant");

    // ------------------------------------------------------------------
    // Test 3 — Multi-stream (only meaningful when NumStreams > 1)
    // stream_idx_o must point at the launching stream until the grant lands.
    // ------------------------------------------------------------------
    if (NumStreams > 1) begin
      int unsigned held1_cnt;          // cycles stream_idx==1 while pending
      logic        bad_idx;            // stream_idx ever pointed at a wrong stream
      int unsigned acc_before;
      $display("\n--- Test 3: multi-stream stream_idx held until grant ---");
      backend_auto_retire = 1'b0;
      captured_q.delete();
      req_ready = 1'b0;
      program_transfer(32'h5000_0000, 32'h6000_0000, 32'h0000_0100);
      exp_id     = next_id;
      held1_cnt  = 0;
      bad_idx    = 1'b0;
      acc_before = launch_accept_count;
      launch(id2, rcyc, 1);            // launch on stream 1 (non-blocking read)
      check_eq(rcyc <= MaxReadLatency, 1'b1, "Test3 read within bounded latency (BP)");
      // while the launch is pending (req_valid high, grant withheld) stream_idx==1
      repeat (12) begin
        @(posedge clk);
        if (req_valid && !req_ready) begin
          if (stream_idx == 1) held1_cnt++;
          else                 bad_idx = 1'b1;   // wrong / dropped stream index
        end
      end
      check_eq(held1_cnt >= 32'd8, 1'b1, "Test3 stream_idx held == 1 across stall");
      check_eq(bad_idx, 1'b0, "Test3 stream_idx never pointed at wrong stream");
      // release: exactly one accept on stream 1
      req_ready = 1'b1;
      wait_launch_accepted();
      check_eq(launch_accept_count, acc_before + 32'd1, "Test3 stream1 accepted once");
      check_eq(id2, exp_id, "Test3 stream1 launch id == next_id");
      check_eq(id2, prev_id + 32'd1, "Test3 id monotonic");
      prev_id = id2;
      check_eq(captured_q.size(), 32'd1, "Test3 stream1 captured once");
      backend_auto_retire = 1'b1;
      poll_done(id2, 1);
      $display("[ ok ] Test3 multi-stream launch completed");
    end else begin
      $display("\n--- Test 3: skipped (NumStreams == 1) ---");
    end

    // ------------------------------------------------------------------
    // Test 4 — Back-to-back launches, monotonic ids, in-order done.
    // Non-blocking: after each launch the driver waits for the id-advance
    // (accept) before re-programming and re-launching.
    // ------------------------------------------------------------------
    $display("\n--- Test 4: back-to-back launches ---");
    backend_auto_retire = 1'b1;
    req_ready           = 1'b1;
    captured_q.delete();
    begin
      logic [31:0] ids[4];
      for (int unsigned k = 0; k < 4; k++) begin
        program_transfer(32'h1000 + k*32'h100, 32'h9000 + k*32'h100, 32'h40 + k*32'h10);
        launch(ids[k], rcyc);
        check_eq(rcyc <= MaxReadLatency, 1'b1, $sformatf("Test4 read[%0d] bounded latency", k));
        wait_launch_accepted();        // model SW confirming id-advance before re-launch
      end
      // exactly four accepted launches, each id one more than the last
      check_eq(captured_q.size(), 32'd4, "Test4 four launches captured");
      for (int unsigned k = 0; k < 4; k++) begin
        check_eq(ids[k], prev_id + 32'd1 + k, $sformatf("Test4 id[%0d] monotonic", k));
        if (k < captured_q.size()) begin
          check_eq(captured_q[k].burst_req.src_addr, 32'h1000 + k*32'h100,
                   $sformatf("Test4 src[%0d]", k));
          check_eq(captured_q[k].burst_req.length, 32'h40 + k*32'h10,
                   $sformatf("Test4 len[%0d]", k));
        end
      end
      prev_id = ids[3];
      // done_id must advance in order to the last id
      poll_done(ids[3]);
      $display("[ ok ] Test4 done_id advanced in order to %0d", ids[3]);
    end

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat (5) @(negedge clk);
    $display("\n=====================================================");
    $display(" checks run : %0d", checks);
    $display(" errors     : %0d", errors);
    if (errors == 0)
      $display(" RESULT     : PASS");
    else
      $display(" RESULT     : FAIL");
    $display("=====================================================");
    if (errors != 0)
      $fatal(1, "tb_idma_reg_frontend FAILED with %0d error(s)", errors);
    $finish;
  end

  // global safety net: kill a run that hangs entirely (belt-and-braces with the
  // per-read watchdog, in case a hang happens outside a tracked next_id read).
  initial begin
    #(TCK * 200000);
    $fatal(1, "GLOBAL TIMEOUT: testbench did not finish");
  end

endmodule

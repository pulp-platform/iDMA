// Copyright 2026 Mark Hampton.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Mark Hampton <mark.hampton@ieee.org>

// Runs a linked chain through the desc64 prefetch frontend and the rw_axi
// backend, configured by idma_desc64_synth_pkg, and checks what software relies
// on: every chained destination holds its source bytes, every chained status
// word is written, and a descriptor that follows the chain in memory but is not
// linked from it is left alone.
//
// One APB job at 0x100 submits 13 descriptors, 32 bytes apart. Descriptor i
// copies 8 bytes from 0x800 + 8*i to 0x900 + 8*i. All ports use ID 0 and answer
// in order. The descriptor port accepts reads back to back; the payload read
// port holds ARREADY low until cycle 47, which lets the prefetcher run ahead.

module tb_idma_desc64_chain #(
  parameter int unsigned BackendDepth = 5
);
  import idma_desc64_synth_pkg::*;

  localparam int unsigned ChainLength = 13;
  localparam int unsigned MemoryBytes = 16384;
  localparam int unsigned RunCycles   = 320;

  typedef struct packed { axi_ar_chan_t ar_chan; } read_axi_t;
  typedef struct packed { read_axi_t axi; } read_meta_t;
  typedef struct packed { axi_aw_chan_t aw_chan; } write_axi_t;
  typedef struct packed { write_axi_t axi; } write_meta_t;

  logic clk = 1'b0, rst_n = 1'b0;
  apb_req_t cfg_req = '0;
  apb_resp_t cfg_rsp;
  axi_req_t desc_req, read_req, write_req;
  axi_rsp_t desc_rsp, read_rsp, write_rsp;
  idma_req_t idma_req;
  idma_rsp_t idma_rsp;
  idma_pkg::idma_busy_t busy;
  logic idma_req_valid, idma_req_ready, idma_rsp_valid, idma_rsp_ready;

  idma_desc64_top #(
    .AddrWidth        ( AddrWidth        ),
    .DataWidth        ( DataWidth        ),
    .AxiIdWidth       ( IdWidth          ),
    .idma_req_t       ( idma_req_t       ),
    .idma_rsp_t       ( idma_rsp_t       ),
    .axi_req_t        ( axi_req_t        ),
    .axi_rsp_t        ( axi_rsp_t        ),
    .axi_ar_chan_t    ( axi_ar_chan_t    ),
    .axi_r_chan_t     ( axi_r_chan_t     ),
    .apb_req_t        ( apb_req_t        ),
    .apb_rsp_t        ( apb_resp_t       ),
    .InputFifoDepth   ( InputFifoDepth   ),
    .PendingFifoDepth ( PendingFifoDepth ),
    .BackendDepth     ( BackendDepth     )
  ) i_desc64 (
    .clk_i            ( clk            ),
    .rst_ni           ( rst_n          ),
    .master_req_o     ( desc_req       ),
    .master_rsp_i     ( desc_rsp       ),
    .axi_ar_id_i      ( '0             ),
    .axi_aw_id_i      ( '0             ),
    .slave_req_i      ( cfg_req        ),
    .slave_rsp_o      ( cfg_rsp        ),
    .idma_req_o       ( idma_req       ),
    .idma_req_valid_o ( idma_req_valid ),
    .idma_req_ready_i ( idma_req_ready ),
    .idma_rsp_i       ( idma_rsp       ),
    .idma_rsp_valid_i ( idma_rsp_valid ),
    .idma_rsp_ready_o ( idma_rsp_ready ),
    .idma_busy_i      ( |busy          ),
    .irq_o            (                )
  );

  idma_backend_rw_axi #(
    .DataWidth            ( DataWidth                ),
    .AddrWidth            ( AddrWidth                ),
    .UserWidth            ( UserWidth                ),
    .AxiIdWidth           ( IdWidth                  ),
    .TFLenWidth           ( TFLenWidth               ),
    .NumAxInFlight        ( 2                        ),
    .BufferDepth          ( 3                        ),
    .idma_req_t           ( idma_req_t               ),
    .idma_rsp_t           ( idma_rsp_t               ),
    .idma_eh_req_t        ( idma_pkg::idma_eh_req_t  ),
    .idma_busy_t          ( idma_pkg::idma_busy_t    ),
    .axi_req_t            ( axi_req_t                ),
    .axi_rsp_t            ( axi_rsp_t                ),
    .read_meta_channel_t  ( read_meta_t              ),
    .write_meta_channel_t ( write_meta_t             )
  ) i_backend (
    .clk_i           ( clk            ),
    .rst_ni          ( rst_n          ),
    .idma_req_i      ( idma_req       ),
    .req_valid_i     ( idma_req_valid ),
    .req_ready_o     ( idma_req_ready ),
    .idma_rsp_o      ( idma_rsp       ),
    .rsp_valid_o     ( idma_rsp_valid ),
    .rsp_ready_i     ( idma_rsp_ready ),
    .idma_eh_req_i   ( '0             ),
    .eh_req_valid_i  ( 1'b0           ),
    .eh_req_ready_o  (                ),
    .axi_read_req_o  ( read_req       ),
    .axi_read_rsp_i  ( read_rsp       ),
    .axi_write_req_o ( write_req      ),
    .axi_write_rsp_i ( write_rsp      ),
    .busy_o          ( busy           )
  );

  // ---------------------------------------------------------------------------
  // Memory
  // ---------------------------------------------------------------------------
  byte unsigned memory [MemoryBytes];
  int unsigned cycle = 0, submitted = 0, completed = 0;

  function automatic data_t load_word(addr_t addr);
    int unsigned base = int'(addr) & ~7;
    for (int unsigned lane = 0; lane < 8; lane++) begin
      load_word[8*lane +: 8] = memory[(base + lane) % MemoryBytes];
    end
  endfunction

  task automatic store_word(int unsigned addr, data_t word);
    for (int unsigned lane = 0; lane < 8; lane++) begin
      memory[addr + lane] = word[8*lane +: 8];
    end
  endtask

  function automatic int unsigned desc_addr(int unsigned i);
    return 'h100 + 32*i;
  endfunction
  function automatic int unsigned src_addr(int unsigned i);
    return 'h800 + 8*i;
  endfunction
  function automatic int unsigned dst_addr(int unsigned i);
    return 'h900 + 8*i;
  endfunction

  // ---------------------------------------------------------------------------
  // AXI targets
  // ---------------------------------------------------------------------------
  // Descriptor port: queue every accepted AR, answer each with four ordered beats.
  addr_t fetch_queue [32];
  int unsigned fetch_head = 0, fetch_tail = 0, desc_beats;
  logic desc_active = 1'b0;
  addr_t desc_raddr;
  // Status writes: one AW and one W at a time, B once both have arrived.
  logic status_aw = 1'b0, status_w = 1'b0;
  addr_t status_addr;
  data_t status_data;
  strb_t status_strb;
  id_t status_id;
  // Payload read port.
  logic read_active = 1'b0;
  addr_t read_addr;
  id_t read_id;
  int unsigned read_beats, read_beat_bytes;
  // Payload write port: AW on cycle % 3 == 0, W on cycle % 3 == 1, B three cycles later.
  logic aw_pending = 1'b0, w_pending = 1'b0, b_pending = 1'b0, write_last;
  addr_t write_addr;
  data_t write_data;
  strb_t write_strb;
  id_t write_id;
  int unsigned b_delay = 0, write_beats, write_beat_bytes, write_index = 0;
  addr_t buf_addr [256];
  data_t buf_data [256];
  strb_t buf_strb [256];

  always_comb begin
    desc_rsp           = '0;
    desc_rsp.ar_ready  = fetch_tail - fetch_head < 32;
    desc_rsp.r_valid   = desc_active;
    desc_rsp.r.data    = load_word(desc_raddr);
    desc_rsp.r.last    = desc_beats == 1;
    desc_rsp.aw_ready  = !status_aw;
    desc_rsp.w_ready   = !status_w;
    desc_rsp.b_valid   = status_aw && status_w;
    desc_rsp.b.id      = status_id;

    read_rsp           = '0;
    read_rsp.ar_ready  = !read_active && cycle >= 47;
    read_rsp.r_valid   = read_active;
    read_rsp.r.id      = read_id;
    read_rsp.r.data    = load_word(read_addr);
    read_rsp.r.last    = read_beats == 1;

    write_rsp          = '0;
    write_rsp.aw_ready = !aw_pending && !b_pending && cycle % 3 == 0;
    write_rsp.w_ready  = !w_pending && !b_pending && cycle % 3 == 1;
    write_rsp.b_valid  = b_pending && b_delay == 0;
    write_rsp.b.id     = write_id;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      if (desc_req.ar_valid && desc_rsp.ar_ready) begin
        if (desc_req.ar.id != 0 || desc_req.ar.len != 3 || desc_req.ar.size != 3 ||
            desc_req.ar.burst != 1) begin
          $fatal(1, "unexpected descriptor AR geometry");
        end
        fetch_queue[fetch_tail % 32] <= desc_req.ar.addr;
        fetch_tail <= fetch_tail + 1;
      end
      if (!desc_active && fetch_head != fetch_tail) begin
        desc_active <= 1'b1;
        desc_raddr  <= fetch_queue[fetch_head % 32];
        desc_beats  <= 4;
        fetch_head  <= fetch_head + 1;
      end else if (desc_rsp.r_valid && desc_req.r_ready) begin
        desc_active <= desc_beats > 1;
        desc_raddr  <= desc_raddr + 8;
        desc_beats  <= desc_beats - 1;
      end

      if (desc_req.aw_valid && desc_rsp.aw_ready) begin
        status_aw   <= 1'b1;
        status_addr <= desc_req.aw.addr;
        status_id   <= desc_req.aw.id;
      end
      if (desc_req.w_valid && desc_rsp.w_ready) begin
        status_w    <= 1'b1;
        status_data <= desc_req.w.data;
        status_strb <= desc_req.w.strb;
      end
      if (desc_rsp.b_valid && desc_req.b_ready) begin
        for (int unsigned lane = 0; lane < 8; lane++) begin
          if (status_strb[lane]) begin
            memory[(int'(status_addr) & ~7) + lane] <= status_data[8*lane +: 8];
          end
        end
        status_aw <= 1'b0;
        status_w  <= 1'b0;
      end

      if (read_req.ar_valid && read_rsp.ar_ready) begin
        read_active     <= 1'b1;
        read_id         <= read_req.ar.id;
        read_addr       <= read_req.ar.addr;
        read_beats      <= int'(read_req.ar.len) + 1;
        read_beat_bytes <= 1 << read_req.ar.size;
      end else if (read_rsp.r_valid && read_req.r_ready) begin
        read_active <= read_beats > 1;
        read_addr   <= (read_addr / addr_t'(read_beat_bytes) + 1) * addr_t'(read_beat_bytes);
        read_beats  <= read_beats - 1;
      end

      if (write_req.aw_valid && write_rsp.aw_ready) begin
        if (write_req.aw.burst != 1) $fatal(1, "expected an incrementing AW");
        write_beats      <= int'(write_req.aw.len) + 1;
        write_beat_bytes <= 1 << write_req.aw.size;
        write_index      <= 0;
        aw_pending       <= 1'b1;
        write_id         <= write_req.aw.id;
        write_addr       <= write_req.aw.addr;
      end
      if (write_req.w_valid && write_rsp.w_ready) begin
        write_last <= write_req.w.last;
        w_pending  <= 1'b1;
        write_data <= write_req.w.data;
        write_strb <= write_req.w.strb;
      end
      if (aw_pending && w_pending) begin
        if (write_last !== (write_beats == 1)) $fatal(1, "WLAST disagrees with AWLEN");
        buf_addr[write_index] <= write_addr;
        buf_data[write_index] <= write_data;
        buf_strb[write_index] <= write_strb;
        write_index <= write_index + 1;
        write_beats <= write_beats - 1;
        write_addr  <= (write_addr / addr_t'(write_beat_bytes) + 1) * addr_t'(write_beat_bytes);
        w_pending   <= 1'b0;
        if (write_beats == 1) begin
          aw_pending <= 1'b0;
          b_pending  <= 1'b1;
          b_delay    <= 3;
        end
      end else if (b_pending && b_delay > 0) begin
        b_delay <= b_delay - 1;
      end else if (write_rsp.b_valid && write_req.b_ready) begin
        // Writes become visible when their B is accepted.
        for (int unsigned beat = 0; beat < write_index; beat++) begin
          for (int unsigned lane = 0; lane < 8; lane++) begin
            if (buf_strb[beat][lane]) begin
              memory[(int'(buf_addr[beat]) & ~7) + lane] <= buf_data[beat][8*lane +: 8];
            end
          end
        end
        b_pending <= 1'b0;
      end

      if (idma_req_valid && idma_req_ready) submitted <= submitted + 1;
      if (idma_rsp_valid && idma_rsp_ready) completed <= completed + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Stimulus and checks
  // ---------------------------------------------------------------------------
  task automatic tick();
    #5;
    clk = 1'b1;
    #5;
    clk = 1'b0;
    cycle++;
  endtask

  initial begin
    automatic int unsigned failures = 0;
    byte unsigned source [MemoryBytes];

    for (int unsigned addr = 0; addr < MemoryBytes; addr++) begin
      memory[addr] = 8'(addr * 61 + addr / 256);
    end
    // {flags, length}, next, source, destination. Flags 0x6a: no IRQ. The record
    // at index ChainLength follows the chain in memory but is not linked from it.
    for (int unsigned i = 0; i <= ChainLength; i++) begin
      store_word(desc_addr(i),      64'h0000_006a_0000_0008);
      store_word(desc_addr(i) + 8,  i >= ChainLength - 1 ? '1 : addr_t'(desc_addr(i + 1)));
      store_word(desc_addr(i) + 16, addr_t'(src_addr(i)));
      store_word(desc_addr(i) + 24, addr_t'(dst_addr(i)));
    end
    foreach (memory[a]) source[a] = memory[a];

    repeat (3) tick();
    rst_n = 1'b1;
    // APB write of the chain head to desc_addr.
    cfg_req.psel   = 1'b1;
    cfg_req.pwrite = 1'b1;
    cfg_req.pwdata = 'h100;
    cfg_req.pstrb  = '1;
    tick();
    cfg_req.penable = 1'b1;
    tick();
    cfg_req = '0;
    repeat (RunCycles) tick();

    $display("[DESC64] %0d descriptors submitted, %0d completed", submitted, completed);
    for (int unsigned i = 0; i <= ChainLength; i++) begin
      logic copied, marked;
      copied = 1'b1;
      marked = 1'b1;
      for (int unsigned lane = 0; lane < 8; lane++) begin
        if (memory[dst_addr(i) + lane] != source[src_addr(i) + lane]) copied = 1'b0;
        if (memory[desc_addr(i) + lane] != 8'hff) marked = 1'b0;
      end
      if (i == ChainLength) begin
        if (copied || marked) begin
          failures++;
          $display("[DESC64] unlinked descriptor at 0x%0h: %s, %s", desc_addr(i),
                   copied ? "destination written" : "destination untouched",
                   marked ? "status word written" : "status word untouched");
        end
      end else if (!copied || !marked) begin
        failures++;
        $display("[DESC64] descriptor %0d at 0x%0h: destination %s, status word %s", i,
                 desc_addr(i), copied ? "copied" : "NOT copied",
                 marked ? "marked complete" : "NOT marked complete");
      end
    end
    if (failures != 0) begin
      $fatal(1, "[DESC64] FAIL: %0d descriptors with a wrong outcome", failures);
    end
    $display("[DESC64] ALL PASS");
    $finish;
  end

endmodule

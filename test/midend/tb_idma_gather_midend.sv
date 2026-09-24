// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Bowen Wang <bowwang@iis.ee.ethz.ch>

`include "idma/typedef.svh"

/// Unit check for idma_gather_midend. Random gathers (all index widths, index counts around
/// the word boundary, misaligned index bases) are interleaved with passthrough requests and
/// rejected gathers. Every emitted ND request is compared against a golden model, and every
/// response against the expected in-order sequence, including a downstream error that must
/// surface on the merged gather response. The index memory, the ND sink and the response
/// sink stall at random; `+PERF=1` disables the stalls and checks one request per cycle.
module tb_idma_gather_midend #(
    parameter int unsigned IdxDataWidth      = 32'd512,
    parameter int unsigned NumIdxOutstanding = 32'd4,
    parameter int unsigned AddrWidth         = 32'd64
);
    import idma_pkg::*;

    localparam int unsigned NumDim    = 32'd2;
    localparam int unsigned WordBytes = IdxDataWidth / 8;
    localparam int unsigned IdxLat    = 32'd3;
    localparam int unsigned NumCases  = 32'd64;
    localparam int unsigned PerfIdx   = 32'd256;

    typedef logic [AddrWidth-1:0]    addr_t;
    typedef logic [31:0]             tf_len_t;
    typedef logic [2:0]              id_t;
    typedef logic [31:0]             reps_t;
    typedef logic [IdxDataWidth-1:0] idx_data_t;

    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
    `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, addr_t)
    `IDMA_TYPEDEF_GATHER_OPT_T(idma_gather_opt_t, addr_t)
    `IDMA_TYPEDEF_GATHER_REQ_T(idma_gather_req_t, idma_nd_req_t, idma_gather_opt_t)

    typedef struct {
        logic  error;
        logic  reject;
        addr_t burst_addr;
    } exp_rsp_t;

    typedef struct {
        longint unsigned due;
        idx_data_t       data;
    } idx_beat_t;

    typedef struct {
        longint unsigned due;
        idma_rsp_t       rsp;
    } nd_beat_t;

    logic clk = 1'b0;
    logic rst_n;
    always #5ns clk = ~clk;

    bit perf;

    //--------------------------------------
    // DUT
    //--------------------------------------
    idma_gather_req_t gather_req;
    logic             gather_req_valid, gather_req_ready;
    idma_rsp_t        gather_rsp;
    logic             gather_rsp_valid, gather_rsp_ready;
    idma_nd_req_t     nd_req;
    logic             nd_req_valid, nd_req_ready;
    idma_rsp_t        nd_rsp;
    logic             nd_rsp_valid, nd_rsp_ready;
    logic             idx_req, idx_gnt, idx_rvalid;
    addr_t            idx_addr;
    idx_data_t        idx_rdata;
    logic             busy;

    idma_gather_midend #(
        .NumDim             ( NumDim             ),
        .IdxDataWidth       ( IdxDataWidth       ),
        .NumIdxOutstanding  ( NumIdxOutstanding  ),
        .NumXferOutstanding ( 32'd4              ),
        .addr_t             ( addr_t             ),
        .idma_rsp_t         ( idma_rsp_t         ),
        .idma_nd_req_t      ( idma_nd_req_t      ),
        .idma_gather_req_t  ( idma_gather_req_t  )
    ) i_dut (
        .clk_i              ( clk              ),
        .rst_ni             ( rst_n            ),
        .gather_req_i       ( gather_req       ),
        .gather_req_valid_i ( gather_req_valid ),
        .gather_req_ready_o ( gather_req_ready ),
        .gather_rsp_o       ( gather_rsp       ),
        .gather_rsp_valid_o ( gather_rsp_valid ),
        .gather_rsp_ready_i ( gather_rsp_ready ),
        .nd_req_o           ( nd_req           ),
        .nd_req_valid_o     ( nd_req_valid     ),
        .nd_req_ready_i     ( nd_req_ready     ),
        .nd_rsp_i           ( nd_rsp           ),
        .nd_rsp_valid_i     ( nd_rsp_valid     ),
        .nd_rsp_ready_o     ( nd_rsp_ready     ),
        .idx_req_o          ( idx_req          ),
        .idx_addr_o         ( idx_addr         ),
        .idx_gnt_i          ( idx_gnt          ),
        .idx_rvalid_i       ( idx_rvalid       ),
        .idx_rdata_i        ( idx_rdata        ),
        .busy_o             ( busy             )
    );

    //--------------------------------------
    // Stimulus and golden model
    //--------------------------------------
    logic [7:0]       idx_mem [addr_t];
    idma_gather_req_t stim_q  [$];
    idma_nd_req_t     exp_req_q [$];
    exp_rsp_t         exp_rsp_q [$];
    // per emitted ND request: inject a downstream error on its response
    bit               inj_err_q [$];

    int unsigned errors   = 0;
    int unsigned num_reqs = 0;
    int unsigned num_rsps = 0;

    function automatic bit chance(input int unsigned percent);
        return !perf && (($urandom % 100) < percent);
    endfunction

    function automatic addr_t rand_addr();
        return addr_t'({$urandom, $urandom}) & addr_t'(64'h0000_ffff_ffff_ff00);
    endfunction

    /// Queue one request and its expected downstream requests and response
    task automatic add_gather(
        input int unsigned num_idx,
        input int unsigned width,
        input int unsigned lane_off,
        input addr_t       src_stride,
        input addr_t       idx_base,
        input bit          reject,
        input bit          misalign,
        input int          err_at
    );
        idma_gather_req_t r;
        idma_nd_req_t     e;
        exp_rsp_t         x;
        int unsigned      eb;
        addr_t            base;
        addr_t            idx_val;
        int unsigned      shift;

        eb    = 1 << width;
        base  = idx_base + addr_t'(lane_off * eb);
        shift = 0;
        while ((src_stride >> shift) > 1) shift++;

        r = '0;
        r.nd_req.burst_req.length   = tf_len_t'(1 + ($urandom % 256));
        r.nd_req.burst_req.src_addr = rand_addr();
        r.nd_req.burst_req.dst_addr = rand_addr();
        r.nd_req.burst_req.opt.axi_id = id_t'($urandom);
        r.nd_req.d_req[0].reps        = reps_t'(num_idx);
        r.nd_req.d_req[0].src_strides = src_stride;
        r.nd_req.d_req[0].dst_strides = addr_t'($urandom % 1024);
        r.gather.enable    = 1'b1;
        r.gather.idx_width = 2'(width);
        r.gather.idx_addr  = misalign ? base | addr_t'(1) : base;
        stim_q.push_back(r);

        x = '{error: 1'b0, reject: reject, burst_addr: '0};
        if (reject) begin
            x.error = 1'b1;
        end else begin
            for (int unsigned i = 0; i < num_idx; i++) begin
                idx_val = addr_t'({$urandom, $urandom});
                if (width < 3) idx_val &= (addr_t'(1) << (8*eb)) - 1;
                for (int unsigned b = 0; b < eb; b++) begin
                    idx_mem[base + i*eb + b] = idx_val[8*b +: 8];
                end
                e = r.nd_req;
                e.burst_req.src_addr = r.nd_req.burst_req.src_addr + (idx_val << shift);
                e.burst_req.dst_addr = r.nd_req.burst_req.dst_addr +
                                       addr_t'(i) * r.nd_req.d_req[0].dst_strides;
                e.d_req[0].reps = reps_t'(1);
                exp_req_q.push_back(e);
                inj_err_q.push_back(err_at == int'(i));
                if (err_at == int'(i)) begin
                    x.error      = 1'b1;
                    x.burst_addr = e.burst_req.src_addr;
                end
            end
        end
        exp_rsp_q.push_back(x);
    endtask

    task automatic add_passthrough();
        idma_gather_req_t r;
        exp_rsp_t         x;
        r = '0;
        r.nd_req.burst_req.length     = tf_len_t'(1 + ($urandom % 4096));
        r.nd_req.burst_req.src_addr   = rand_addr();
        r.nd_req.burst_req.dst_addr   = rand_addr();
        r.nd_req.d_req[0].reps        = reps_t'($urandom % 8);
        r.nd_req.d_req[0].src_strides = addr_t'($urandom);
        r.nd_req.d_req[0].dst_strides = addr_t'($urandom);
        r.gather.idx_width = 2'($urandom);
        r.gather.idx_addr  = rand_addr();
        stim_q.push_back(r);
        exp_req_q.push_back(r.nd_req);
        inj_err_q.push_back(1'b0);
        x = '{error: 1'b0, reject: 1'b0, burst_addr: '0};
        exp_rsp_q.push_back(x);
    endtask

    task automatic build_cases();
        addr_t       region;
        int unsigned lanes, n, off;
        region = addr_t'(64'h1000_0000);
        for (int unsigned c = 0; c < NumCases; c++) begin
            int unsigned width;
            width = c % 4;
            lanes = WordBytes >> width;
            case ((c / 4) % 8)
                0: n = 1;
                1: n = 2;
                2: n = lanes - 1 > 0 ? lanes - 1 : 1;
                3: n = lanes;
                4: n = lanes + 1;
                5: n = 2*lanes + 3;
                default: n = 1 + ($urandom % 200);
            endcase
            off = (c % 3 == 0) ? 0 : $urandom % lanes;
            add_gather(n, width, off, addr_t'(1) << ($urandom % 13), region, 1'b0, 1'b0,
                       (c == 21 || c == 42) ? int'($urandom % n) : -1);
            region += addr_t'(64'h10000);
            if (c % 5 == 0) add_passthrough();
        end
        // rejects: no indices, stride not a power of two, zero stride, misaligned index base
        add_gather(0, 1, 0, addr_t'(64), region, 1'b1, 1'b0, -1);
        add_gather(4, 0, 0, addr_t'(24), region, 1'b1, 1'b0, -1);
        add_gather(4, 2, 0, addr_t'(0), region, 1'b1, 1'b0, -1);
        add_gather(4, 2, 0, addr_t'(64), region, 1'b1, 1'b1, -1);
        add_passthrough();
        // back-to-back gathers with no passthrough in between
        for (int unsigned k = 0; k < 4; k++) begin
            region += addr_t'(64'h10000);
            add_gather(5 + k*7, k % 4, 1, addr_t'(128), region, 1'b0, 1'b0, -1);
        end
    endtask

    //--------------------------------------
    // Upstream driver
    //--------------------------------------
    always @(posedge clk) begin : proc_drive
        if (!rst_n) begin
            gather_req_valid <= 1'b0;
            gather_req       <= '0;
        end else if (!gather_req_valid || gather_req_ready) begin
            if (stim_q.size() != 0 && !chance(20)) begin
                gather_req_valid <= 1'b1;
                gather_req       <= stim_q.pop_front();
            end else begin
                gather_req_valid <= 1'b0;
            end
        end
    end

    //--------------------------------------
    // Index memory: random grant, in-order responses after a fixed latency
    //--------------------------------------
    idx_beat_t       idx_pipe [$];
    longint unsigned cycle = 0;

    always @(posedge clk) cycle <= cycle + 1;

    logic gnt_roll;
    always @(posedge clk) gnt_roll <= !chance(30);

    always_comb begin
        idx_gnt    = rst_n && gnt_roll;
        idx_rvalid = idx_pipe.size() != 0 && idx_pipe[0].due <= cycle;
        idx_rdata  = idx_rvalid ? idx_pipe[0].data : '0;
    end

    always @(posedge clk) begin : proc_idx_mem
        if (rst_n) begin
            if (idx_rvalid) void'(idx_pipe.pop_front());
            if (idx_req && idx_gnt) begin
                idx_beat_t beat;
                if (idx_addr % WordBytes != 0) begin
                    $error("[GATHER] unaligned index read 0x%0h", idx_addr);
                    errors++;
                end
                beat.due = cycle + IdxLat + (chance(30) ? $urandom % 4 : 0);
                if (idx_pipe.size() != 0 && beat.due < idx_pipe[$].due) beat.due = idx_pipe[$].due;
                for (int unsigned b = 0; b < WordBytes; b++) begin
                    beat.data[8*b +: 8] = idx_mem.exists(idx_addr + b) ? idx_mem[idx_addr + b] : '0;
                end
                idx_pipe.push_back(beat);
            end
        end
    end

    //--------------------------------------
    // ND sink: compare against the golden request, answer in order
    //--------------------------------------
    nd_beat_t nd_pipe [$];
    logic     nd_ready_roll;

    assign nd_req_ready = rst_n && nd_ready_roll;
    always @(posedge clk) nd_ready_roll <= !chance(25);

    always @(posedge clk) begin : proc_nd_sink
        if (rst_n && nd_req_valid && nd_req_ready) begin
            idma_nd_req_t exp;
            nd_beat_t     beat;
            num_reqs++;
            if (exp_req_q.size() == 0) begin
                $error("[GATHER] unexpected ND request src 0x%0h", nd_req.burst_req.src_addr);
                errors++;
            end else begin
                exp = exp_req_q.pop_front();
                if (nd_req !== exp) begin
                    if (errors < 10) begin
                        $error({"[GATHER] ND request %0d: src 0x%0h/0x%0h dst 0x%0h/0x%0h ",
                                "len %0d/%0d reps %0d/%0d"},
                               num_reqs, nd_req.burst_req.src_addr, exp.burst_req.src_addr,
                               nd_req.burst_req.dst_addr, exp.burst_req.dst_addr,
                               nd_req.burst_req.length, exp.burst_req.length,
                               nd_req.d_req[0].reps, exp.d_req[0].reps);
                    end
                    errors++;
                end
                beat.due = cycle + 1 + (chance(40) ? $urandom % 8 : 0);
                if (nd_pipe.size() != 0 && beat.due < nd_pipe[$].due) beat.due = nd_pipe[$].due;
                beat.rsp      = '0;
                beat.rsp.last = 1'b1;
                if (inj_err_q.pop_front()) begin
                    beat.rsp.error          = 1'b1;
                    beat.rsp.pld.err_type   = BUS_READ;
                    beat.rsp.pld.burst_addr = nd_req.burst_req.src_addr;
                end
                nd_pipe.push_back(beat);
            end
        end
    end

    always_comb begin
        nd_rsp_valid = nd_pipe.size() != 0 && nd_pipe[0].due <= cycle;
        nd_rsp       = nd_rsp_valid ? nd_pipe[0].rsp : '0;
    end

    always @(posedge clk) begin
        if (rst_n && nd_rsp_valid && nd_rsp_ready) void'(nd_pipe.pop_front());
    end

    //--------------------------------------
    // Response sink
    //--------------------------------------
    logic rsp_ready_roll;
    assign gather_rsp_ready = rst_n && rsp_ready_roll;
    always @(posedge clk) rsp_ready_roll <= !chance(25);

    always @(posedge clk) begin : proc_rsp_sink
        if (rst_n && gather_rsp_valid && gather_rsp_ready) begin
            exp_rsp_t x;
            num_rsps++;
            if (exp_rsp_q.size() == 0) begin
                $error("[GATHER] unexpected response");
                errors++;
            end else begin
                x = exp_rsp_q.pop_front();
                if (gather_rsp.error !== x.error || gather_rsp.last !== 1'b1 ||
                    (x.reject && gather_rsp.pld.err_type !== ND_MIDEND) ||
                    (x.error && !x.reject && gather_rsp.pld.burst_addr !== x.burst_addr)) begin
                    $error("[GATHER] response %0d: error %0b/%0b type %0d addr 0x%0h/0x%0h",
                           num_rsps, gather_rsp.error, x.error, gather_rsp.pld.err_type,
                           gather_rsp.pld.burst_addr, x.burst_addr);
                    errors++;
                end
            end
        end
    end

    //--------------------------------------
    // Sequence
    //--------------------------------------
    initial begin : proc_test
        longint unsigned t0, t1;
        int unsigned     perf_arg;
        perf = 1'b0;
        if ($value$plusargs("PERF=%d", perf_arg)) perf = (perf_arg != 0);
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;

        if (perf) begin
            // one long 16-bit gather with no stalls
            add_gather(PerfIdx, 1, 0, addr_t'(256), addr_t'(64'h2000_0000), 1'b0, 1'b0, -1);
        end else begin
            build_cases();
        end

        @(posedge clk);
        t0 = cycle;
        while (exp_rsp_q.size() != 0 || busy) begin
            @(posedge clk);
            if (cycle - t0 > 200000) $fatal(1, "[GATHER] timeout, %0d responses pending",
                                            exp_rsp_q.size());
        end
        t1 = cycle;

        if (exp_req_q.size() != 0) begin
            $error("[GATHER] %0d expected ND requests never emitted", exp_req_q.size());
            errors++;
        end
        if (perf) begin
            $display("[GATHER] %0d indices in %0d cycles", PerfIdx, t1 - t0);
            if (t1 - t0 > PerfIdx + 32) begin
                $error("[GATHER] throughput below one request per cycle");
                errors++;
            end
        end
        if (errors != 0) $fatal(1, "[GATHER] FAILED: %0d errors", errors);
        $display("[GATHER] %0d ND requests, %0d responses checked", num_reqs, num_rsps);
        $display("[GATHER] ALL PASS");
        $finish;
    end

endmodule

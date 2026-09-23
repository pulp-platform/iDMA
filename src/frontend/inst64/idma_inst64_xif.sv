// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

/// CV-X-IF coprocessor port of the `inst64` frontend: the issue, register, commit, and result
/// subset with coupled issue and register (`X_ISSUE_REGISTER_SPLIT` = 0) and 32-bit operands.
/// Only committed instructions reach the shared decoder, so a killed one leaves no trace.
module idma_inst64_xif #(
    /// Number of channels; a channel immediate at or above it is rejected
    parameter int unsigned NumChannels    = 32'd1,
    /// The backend has the on-the-fly compute datapath; without it DMOPC is rejected
    parameter bit          EnableCompute  = 1'b0,
    /// The backend has the INIT read port; without it DMINIT is rejected
    parameter bit          EnableInit     = 1'b1,
    parameter type         x_issue_req_t  = logic,
    parameter type         x_issue_resp_t = logic,
    parameter type         x_register_t   = logic,
    parameter type         x_commit_t     = logic,
    parameter type         x_result_t     = logic,
    /// Decoder request; `data_op`, `data_arga`, `data_argb`
    parameter type         dec_req_t      = logic,
    /// Decoder response; `data`, `error`
    parameter type         dec_rsp_t      = logic
) (
    input  logic          clk_i,
    input  logic          rst_ni,
    // CV-X-IF issue
    input  x_issue_req_t  x_issue_req_i,
    output x_issue_resp_t x_issue_resp_o,
    input  logic          x_issue_valid_i,
    output logic          x_issue_ready_o,
    // CV-X-IF register
    input  x_register_t   x_register_i,
    input  logic          x_register_valid_i,
    output logic          x_register_ready_o,
    // CV-X-IF commit
    input  x_commit_t     x_commit_i,
    input  logic          x_commit_valid_i,
    // CV-X-IF result
    output x_result_t     x_result_o,
    output logic          x_result_valid_o,
    input  logic          x_result_ready_i,
    // inst64 decoder
    output dec_req_t      dec_req_o,
    output logic          dec_req_valid_o,
    input  logic          dec_req_ready_i,
    input  dec_rsp_t      dec_rsp_i,
    input  logic          dec_rsp_valid_i,
    output logic          dec_rsp_ready_o
);

    localparam int unsigned IdWidth     = $bits(x_issue_req_i.id);
    localparam int unsigned HartIdWidth = $bits(x_issue_req_i.hartid);
    localparam int unsigned NumRs       = $bits(x_register_i.rs_valid);
    localparam int unsigned RsWidth     = $bits(x_register_i.rs) / NumRs;
    localparam int unsigned RdWidth     = $bits(x_result_o.data);
    localparam int unsigned NumRegRead  = $bits(x_issue_resp_o.register_read);
    localparam int unsigned ChanWidth   = idma_inst64_snitch_pkg::ImmChanWidth;

    /// An accepted instruction on its way to the decoder
    typedef struct packed {
        dec_req_t               req;
        logic [HartIdWidth-1:0] hartid;
        logic [IdWidth-1:0]     id;
        logic [4:0]             rd;
        logic                   writeback;
    } entry_t;

    //--------------------------------------
    // Accept
    //--------------------------------------
    idma_inst64_snitch_pkg::attr_t attr;
    logic [ChanWidth-1:0]          imm_chan;
    logic                          supported;
    logic                          accept;
    logic                          rs_ok;

    assign attr     = idma_inst64_snitch_pkg::inst_attr(x_issue_req_i.instr);
    assign imm_chan = x_issue_req_i.instr[idma_inst64_snitch_pkg::ImmChanLsb +: ChanWidth];

    // From the instruction word and the build alone; an rs-independent op reject belongs here
    assign supported = (EnableCompute | ~attr.req_compute) & (EnableInit | ~attr.req_init) &
                       (~attr.imm | (32'(imm_chan) < NumChannels));
    assign accept    = attr.known & supported;

    // Coupled issue and register: wait for the operands the instruction reads, never for rs3
    assign rs_ok = x_register_valid_i &
                   (&(x_register_i.rs_valid[1:0] | ~attr.register_read[1:0]));

    //--------------------------------------
    // Commit buffer
    //--------------------------------------
    entry_t in_entry, src, buf_q, buf_d;
    logic   buf_valid_q, buf_valid_d;
    logic   buf_cmt_q, buf_cmt_d;
    logic   issue_ok, in_hs, cmt_in, cmt_buf;
    logic   src_valid, dec_fire, res_ready;

    // RV32 sign-extends the operands into the 64-bit decoder request, as Snitch does
    always_comb begin : proc_in_entry
        in_entry                = '0;
        in_entry.req.data_op    = x_issue_req_i.instr;
        in_entry.req.data_arga  = {{32{x_register_i.rs[0][31]}}, x_register_i.rs[0]};
        in_entry.req.data_argb  = {{32{x_register_i.rs[1][31]}}, x_register_i.rs[1]};
        in_entry.hartid         = x_issue_req_i.hartid;
        in_entry.id             = x_issue_req_i.id;
        in_entry.rd             = x_issue_req_i.instr[11:7];
        in_entry.writeback      = attr.writeback;
    end

    // Only the single entry stalls issue; not the decoder, which would loop through commit
    assign issue_ok = rs_ok & ~buf_valid_q;
    assign in_hs    = x_issue_valid_i & accept & issue_ok;

    assign cmt_in  = x_commit_valid_i & in_hs & (x_commit_i.id == x_issue_req_i.id) &
                     (x_commit_i.hartid == x_issue_req_i.hartid);
    assign cmt_buf = x_commit_valid_i & buf_valid_q & (x_commit_i.id == buf_q.id) &
                     (x_commit_i.hartid == buf_q.hartid);

    // A committed entry goes first; otherwise an issue committed in its own cycle bypasses
    assign src       = buf_valid_q ? buf_q : in_entry;
    assign src_valid = buf_valid_q ? buf_cmt_q : (cmt_in & ~x_commit_i.commit_kill);

    // Every retired instruction takes a result slot, one without writeback included
    assign dec_req_o       = src.req;
    assign dec_req_valid_o = src_valid & (src.writeback | res_ready);
    assign dec_fire        = dec_req_valid_o & dec_req_ready_i;

    always_comb begin : proc_buffer
        buf_d       = buf_q;
        buf_valid_d = buf_valid_q;
        buf_cmt_d   = buf_cmt_q;
        if (buf_valid_q) begin
            if (dec_fire) begin
                buf_valid_d = 1'b0;
            end else if (cmt_buf) begin
                buf_valid_d = ~x_commit_i.commit_kill;
                buf_cmt_d   = ~x_commit_i.commit_kill;
            end
        end
        // Park an accepted instruction unless it retired or was killed in its issue cycle
        if (in_hs && !dec_fire && !(cmt_in && x_commit_i.commit_kill)) begin
            buf_d       = in_entry;
            buf_valid_d = 1'b1;
            buf_cmt_d   = cmt_in;
        end
    end

    `FF(buf_q,       buf_d,       '0,   clk_i, rst_ni)
    `FF(buf_valid_q, buf_valid_d, 1'b0, clk_i, rst_ni)
    `FF(buf_cmt_q,   buf_cmt_d,   1'b0, clk_i, rst_ni)

    //--------------------------------------
    // Issue and register response
    //--------------------------------------
    // A foreign instruction is rejected at once, so it never stalls another coprocessor
    assign x_issue_ready_o    = ~accept | issue_ok;
    assign x_register_ready_o = accept & issue_ok;

    always_comb begin : proc_issue_resp
        x_issue_resp_o = '0;
        if (x_issue_valid_i && accept) begin
            x_issue_resp_o.accept        = 1'b1;
            x_issue_resp_o.writeback     = attr.writeback;
            x_issue_resp_o.register_read = NumRegRead'(attr.register_read);
        end
    end

    //--------------------------------------
    // Result
    //--------------------------------------
    x_result_t res_d;

    always_comb begin : proc_result
        res_d        = '0;
        res_d.hartid = src.hartid;
        res_d.id     = src.id;
        res_d.rd     = src.rd;
        res_d.we     = src.writeback;
        res_d.data   = src.writeback ? dec_rsp_i.data[RdWidth-1:0] : '0;
    end

    assign dec_rsp_ready_o = res_ready;

    // Registered, so no path runs from the register port to the result port
    cc_spill_register #(
        .data_t  ( x_result_t )
    ) i_result_spill_register (
        .clk_i,
        .rst_ni,
        .clr_i   ( 1'b0             ),
        .valid_i ( dec_fire         ),
        .ready_o ( res_ready        ),
        .data_i  ( res_d            ),
        .valid_o ( x_result_valid_o ),
        .ready_i ( x_result_ready_i ),
        .data_o  ( x_result_o       )
    );

    //--------------------------------------
    // Assertions
    //--------------------------------------
    if (RsWidth != 32'd32 || NumRs < 32'd2 || RdWidth != 32'd32) begin : gen_width_check
        $fatal(1, "idma_inst64_xif: needs 32-bit registers and at least rs1 and rs2");
    end

    // The decoder answers exactly the retired writeback instructions, in the same cycle
    `ASSERT(XifDecoderRspInstant, dec_rsp_valid_i == (dec_fire & src.writeback), clk_i, !rst_ni)
    `ASSERT(XifDecoderRspError, dec_rsp_valid_i |-> !dec_rsp_i.error, clk_i, !rst_ni)
    // Coupled issue and register carry the same instruction
    `ASSERT(XifRegisterId, x_issue_valid_i & x_register_valid_i |->
            x_register_i.id == x_issue_req_i.id, clk_i, !rst_ni)

`ifndef SYNTHESIS
    // Per-id protocol state: idle, accepted, committed; a result retires a committed id
    localparam logic [1:0] IdIdle      = 2'd0;
    localparam logic [1:0] IdAccepted  = 2'd1;
    localparam logic [1:0] IdCommitted = 2'd2;

    logic [2**IdWidth-1:0][1:0] id_state_q, id_state_d;
    logic                       res_hs;

    assign res_hs = x_result_valid_o & x_result_ready_i;

    always_comb begin : proc_id_state
        id_state_d = id_state_q;
        if (res_hs) id_state_d[x_result_o.id] = IdIdle;
        if (in_hs)  id_state_d[x_issue_req_i.id] = IdAccepted;
        if (x_commit_valid_i && id_state_d[x_commit_i.id] == IdAccepted) begin
            id_state_d[x_commit_i.id] = x_commit_i.commit_kill ? IdIdle : IdCommitted;
        end
    end

    `FF(id_state_q, id_state_d, '0, clk_i, rst_ni)

    // An accepted id is not in flight, unless its result retires in this very cycle
    `ASSERT(XifIdReuse, in_hs |-> id_state_q[x_issue_req_i.id] == IdIdle ||
            (res_hs && x_result_o.id == x_issue_req_i.id), clk_i, !rst_ni)
    // No result before commit, and at most one result per accepted instruction
    `ASSERT(XifResultCommitted, res_hs |-> id_state_q[x_result_o.id] == IdCommitted,
            clk_i, !rst_ni)
    // A parked instruction reaches the decoder only once committed, and a killed one never
    `ASSERT(XifFireCommitted, dec_req_valid_o & buf_valid_q |->
            id_state_q[buf_q.id] == IdCommitted, clk_i, !rst_ni)
`endif

endmodule

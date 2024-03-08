// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Tobias Senti <tsenti@ethz.ch>

`include "idma/guard.svh"
module idma_tilelink2axi_bridge #(
    parameter int unsigned DataWidth  = 64, 
    parameter int unsigned AddrWidth  = 32,
    parameter int unsigned IdWidth    = 7,
    parameter type    tilelink_req_t  = logic,
    parameter type    tilelink_rsp_t  = logic,
    parameter type         axi_req_t  = logic,
    parameter type         axi_rsp_t  = logic
)(
    input  logic clk_i,
    input  logic rst_ni,

    input  tilelink_req_t tilelink_req_i,
    output tilelink_rsp_t tilelink_rsp_o,

    output axi_req_t axi_req_o,
    input  axi_rsp_t axi_rsp_i
);
    `IDMA_NONSYNTH_BLOCK(
        if(DataWidth != 64) $fatal(1, "DataWidth has to be 64 bits!");
        if(AddrWidth != 32) $fatal(1, "AddrWidth has to be 32 bits!");
        if(  IdWidth != 12) $fatal(1, "IdWidth has to be 4+3+5 bits!");

        assert property ( @(posedge clk_i) disable iff (!rst_ni) (tilelink_req_i.a_valid && (tilelink_req_i.a.mask != '1)) -> ($countones(tilelink_req_i.a.mask) == ('d1 << tilelink_req_i.a.size)) )
            else $fatal (1, "Tilelink Mask Error! Address: %X Mask: %X Ones: %d Size: %d", tilelink_req_i.a.address, tilelink_req_i.a.mask, $countones(tilelink_req_i.a.mask), ('d1 << tilelink_req_i.a.size));
    )

    assign axi_req_o.aw.addr[0] = 1'b0;
    assign axi_req_o.ar.addr[0] = 1'b0;
    assign axi_req_o.aw.user    = '0;
    assign axi_req_o.ar.user    = '0;
    assign axi_req_o.w.user     = '0;
    assign axi_req_o.ar.region  = '0;
    assign axi_req_o.aw.region  = '0;
    assign axi_req_o.aw.atop    = '0;

    // AXI Sim Mem does not handle smaller values of size properly
    assign axi_req_o.aw.size = $clog2(DataWidth / 8);
    assign axi_req_o.ar.size = $clog2(DataWidth / 8);

    TLToAXI4 i_tl_to_axi4 (
        .clock (clk_i),
        .reset (!rst_ni),

        // TileLink A
        .auto_in_a_ready(tilelink_rsp_o.a_ready),
        .auto_in_a_valid(tilelink_req_i.a_valid),
        .auto_in_a_bits_opcode(tilelink_req_i.a.opcode),
        .auto_in_a_bits_param(tilelink_req_i.a.param),
        .auto_in_a_bits_size(tilelink_req_i.a.size),
        .auto_in_a_bits_source((tilelink_req_i.a.source[4:0] % 5'd4) + 5'd8),
        .auto_in_a_bits_address(tilelink_req_i.a.address[31:1]),
        .auto_in_a_bits_user_amba_prot_bufferable(1'b0),
        .auto_in_a_bits_user_amba_prot_modifiable(1'b0),
        .auto_in_a_bits_user_amba_prot_readalloc(1'b0),
        .auto_in_a_bits_user_amba_prot_writealloc(1'b0),
        .auto_in_a_bits_user_amba_prot_privileged(1'b0),
        .auto_in_a_bits_user_amba_prot_secure(1'b0),
        .auto_in_a_bits_user_amba_prot_fetch(1'b0),
        .auto_in_a_bits_mask(tilelink_req_i.a.mask),
        .auto_in_a_bits_data(tilelink_req_i.a.data),
        .auto_in_a_bits_corrupt(tilelink_req_i.a.corrupt),

        // TileLink D
        .auto_in_d_ready(tilelink_req_i.d_ready),
        .auto_in_d_valid(tilelink_rsp_o.d_valid),
        .auto_in_d_bits_opcode(tilelink_rsp_o.d.opcode),
        .auto_in_d_bits_size(tilelink_rsp_o.d.size),
        .auto_in_d_bits_source(tilelink_rsp_o.d.source),
        .auto_in_d_bits_denied(tilelink_rsp_o.d.denied),
        .auto_in_d_bits_data(tilelink_rsp_o.d.data),
        .auto_in_d_bits_corrupt(tilelink_rsp_o.d.corrupt),

        .auto_out_aw_ready(axi_rsp_i.aw_ready),
        .auto_out_aw_valid(axi_req_o.aw_valid),
        .auto_out_aw_bits_id(axi_req_o.aw.id[7:5]),
        .auto_out_aw_bits_addr(axi_req_o.aw.addr[31:1]),
        .auto_out_aw_bits_len(axi_req_o.aw.len),
        .auto_out_aw_bits_size(),
        .auto_out_aw_bits_burst(axi_req_o.aw.burst),
        .auto_out_aw_bits_lock(axi_req_o.aw.lock),
        .auto_out_aw_bits_cache(axi_req_o.aw.cache),
        .auto_out_aw_bits_prot(axi_req_o.aw.prot),
        .auto_out_aw_bits_qos(axi_req_o.aw.qos),
        .auto_out_aw_bits_echo_tl_state_size(axi_req_o.aw.id[11:8]),
        .auto_out_aw_bits_echo_tl_state_source(axi_req_o.aw.id[4:0]),

        .auto_out_w_ready(axi_rsp_i.w_ready),
        .auto_out_w_valid(axi_req_o.w_valid),
        .auto_out_w_bits_data(axi_req_o.w.data),
        .auto_out_w_bits_strb(axi_req_o.w.strb),
        .auto_out_w_bits_last(axi_req_o.w.last),

        .auto_out_b_ready(axi_req_o.b_ready),
        .auto_out_b_valid(axi_rsp_i.b_valid),
        .auto_out_b_bits_id(axi_rsp_i.b.id[7:5]),
        .auto_out_b_bits_resp(axi_rsp_i.b.resp),
        .auto_out_b_bits_echo_tl_state_size(axi_rsp_i.b.id[11:8]),
        .auto_out_b_bits_echo_tl_state_source(axi_rsp_i.b.id[4:0]),

        .auto_out_ar_ready(axi_rsp_i.ar_ready),
        .auto_out_ar_valid(axi_req_o.ar_valid),
        .auto_out_ar_bits_id(axi_req_o.ar.id[7:5]),
        .auto_out_ar_bits_addr(axi_req_o.ar.addr[31:1]),
        .auto_out_ar_bits_len(axi_req_o.ar.len),
        .auto_out_ar_bits_size(),
        .auto_out_ar_bits_burst(axi_req_o.ar.burst),
        .auto_out_ar_bits_lock(axi_req_o.ar.lock),
        .auto_out_ar_bits_cache(axi_req_o.ar.cache),
        .auto_out_ar_bits_prot(axi_req_o.ar.prot),
        .auto_out_ar_bits_qos(axi_req_o.ar.qos),
        .auto_out_ar_bits_echo_tl_state_size(axi_req_o.ar.id[11:8]),
        .auto_out_ar_bits_echo_tl_state_source(axi_req_o.ar.id[4:0]),

        .auto_out_r_ready(axi_req_o.r_ready),
        .auto_out_r_valid(axi_rsp_i.r_valid),
        .auto_out_r_bits_id(axi_rsp_i.r.id[7:5]),
        .auto_out_r_bits_data(axi_rsp_i.r.data),
        .auto_out_r_bits_resp(axi_rsp_i.r.resp),
        .auto_out_r_bits_last(axi_rsp_i.r.last),
        .auto_out_r_bits_echo_tl_state_size(axi_rsp_i.r.id[11:8]),
        .auto_out_r_bits_echo_tl_state_source(axi_rsp_i.r.id[4:0])
    );
endmodule

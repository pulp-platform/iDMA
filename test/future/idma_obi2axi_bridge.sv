// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Tobias Senti <tsenti@ethz.ch>

module idma_obi2axi_bridge #(
    parameter int unsigned   DataWidth  = 32,
    parameter int unsigned   AddrWidth  = 32,
    parameter int unsigned   UserWidth  = 1,
    parameter int unsigned   IdWidth    = 1,
    parameter type           obi_req_t  = logic,
    parameter type           obi_rsp_t  = logic,
    parameter type           axi_req_t  = logic,
    parameter type           axi_rsp_t  = logic
)(
    input   logic     clk_i,
    input   logic     rst_ni,

    input   obi_req_t obi_req_i,
    output  obi_rsp_t obi_rsp_o,

    output  axi_req_t axi_req_o,
    input   axi_rsp_t axi_rsp_i
);

    assign axi_req_o.aw.atop = '0;

    idma_tb_per2axi #(
        .NB_CORES       ( 4             ),
        .PER_ADDR_WIDTH ( AddrWidth     ),
        .PER_ID_WIDTH   ( IdWidth       ),
        .AXI_ADDR_WIDTH ( AddrWidth     ),
        .AXI_DATA_WIDTH ( DataWidth     ),
        .AXI_USER_WIDTH ( UserWidth     ),
        .AXI_ID_WIDTH   ( IdWidth       ),
        .AXI_STRB_WIDTH ( DataWidth / 8 )
    ) i_per2axi (
        .clk_i                  ( clk_i               ),
        .rst_ni                 ( rst_ni              ),
        .test_en_i              ( 1'b0                ),

        .per_slave_req_i        ( obi_req_i.req       ),
        .per_slave_add_i        ( obi_req_i.a.addr    ),
        .per_slave_we_i         ( !obi_req_i.a.we     ),
        .per_slave_wdata_i      ( obi_req_i.a.wdata   ),
        .per_slave_be_i         ( obi_req_i.a.be      ),
        .per_slave_id_i         ( obi_req_i.a.aid     ),
        .per_slave_gnt_o        ( obi_rsp_o.gnt       ),

        .per_slave_r_valid_o    ( obi_rsp_o.rvalid    ),
        .per_slave_r_opc_o      (                     ),
        .per_slave_r_id_o       ( obi_rsp_o.r.rid     ),
        .per_slave_r_rdata_o    ( obi_rsp_o.r.rdata   ),
        .per_slave_r_ready_i    ( obi_req_i.rready    ),

        .axi_master_aw_valid_o  ( axi_req_o.aw_valid  ),
        .axi_master_aw_addr_o   ( axi_req_o.aw.addr   ),
        .axi_master_aw_prot_o   ( axi_req_o.aw.prot   ),
        .axi_master_aw_region_o ( axi_req_o.aw.region ),
        .axi_master_aw_len_o    ( axi_req_o.aw.len    ),
        .axi_master_aw_size_o   ( axi_req_o.aw.size   ),
        .axi_master_aw_burst_o  ( axi_req_o.aw.burst  ),
        .axi_master_aw_lock_o   ( axi_req_o.aw.lock   ),
        .axi_master_aw_cache_o  ( axi_req_o.aw.cache  ),
        .axi_master_aw_qos_o    ( axi_req_o.aw.qos    ),
        .axi_master_aw_id_o     ( axi_req_o.aw.id     ),
        .axi_master_aw_user_o   ( axi_req_o.aw.user   ),
        .axi_master_aw_ready_i  ( axi_rsp_i.aw_ready  ), 

        .axi_master_ar_valid_o  ( axi_req_o.ar_valid  ),
        .axi_master_ar_addr_o   ( axi_req_o.ar.addr   ),
        .axi_master_ar_prot_o   ( axi_req_o.ar.prot   ),
        .axi_master_ar_region_o ( axi_req_o.ar.region ),
        .axi_master_ar_len_o    ( axi_req_o.ar.len    ),
        .axi_master_ar_size_o   ( axi_req_o.ar.size   ),
        .axi_master_ar_burst_o  ( axi_req_o.ar.burst  ),
        .axi_master_ar_lock_o   ( axi_req_o.ar.lock   ),
        .axi_master_ar_cache_o  ( axi_req_o.ar.cache  ),
        .axi_master_ar_qos_o    ( axi_req_o.ar.qos    ),
        .axi_master_ar_id_o     ( axi_req_o.ar.id     ),
        .axi_master_ar_user_o   ( axi_req_o.ar.user   ),
        .axi_master_ar_ready_i  ( axi_rsp_i.ar_ready  ), 

        .axi_master_w_valid_o   ( axi_req_o.w_valid   ),
        .axi_master_w_data_o    ( axi_req_o.w.data    ),
        .axi_master_w_strb_o    ( axi_req_o.w.strb    ),
        .axi_master_w_user_o    ( axi_req_o.w.user    ),
        .axi_master_w_last_o    ( axi_req_o.w.last    ),
        .axi_master_w_ready_i   ( axi_rsp_i.w_ready   ),

        .axi_master_r_valid_i   ( axi_rsp_i.r_valid   ),
        .axi_master_r_data_i    ( axi_rsp_i.r.data    ),
        .axi_master_r_resp_i    ( axi_rsp_i.r.resp    ),
        .axi_master_r_last_i    ( axi_rsp_i.r.last    ),
        .axi_master_r_id_i      ( axi_rsp_i.r.id      ),
        .axi_master_r_user_i    ( axi_rsp_i.r.user    ),
        .axi_master_r_ready_o   ( axi_req_o.r_ready   ),

        .axi_master_b_valid_i   ( axi_rsp_i.b_valid   ),
        .axi_master_b_resp_i    ( axi_rsp_i.b.resp    ),
        .axi_master_b_id_i      ( axi_rsp_i.b.id      ),
        .axi_master_b_user_i    ( axi_rsp_i.b.user    ),
        .axi_master_b_ready_o   ( axi_req_o.b_ready   ),

        .busy_o                 ( /* NOT CONNECTED */ )
    );

    // assign error signal
    assign obi_rsp_o.r.err = 1'b0;

endmodule

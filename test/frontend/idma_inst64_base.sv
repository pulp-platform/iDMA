// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Reusable harness around `idma_inst64_top`: clock/reset, the accelerator-bus driver and
/// one AXI plus one OBI simulation memory per channel.
module idma_inst64_base #(
    parameter int unsigned DMATracing = idma_inst64_tb_pkg::DMATracing,
    /// TCDM (OBI) window; every address outside it decodes to ToSoC, i.e. AXI
    parameter logic [63:0] TcdmStart = 64'h0000_0000_1000_0000,
    parameter logic [63:0] TcdmEnd   = 64'h0000_0000_1001_0000
);
    import idma_inst64_tb_pkg::*;

    logic clk;
    logic rst_n;

    clk_rst_gen #(
        .ClkPeriod   ( Period      ),
        .RstClkCycles( ResetCycles )
    ) i_clock_reset_generator (
        .clk_o ( clk   ),
        .rst_no( rst_n )
    );

    idma_inst64_drv_if drv_if (
        .clk  ( clk   ),
        .rst_n( rst_n )
    );

    axi_req_t    [NumChannels-1:0] axi_req;
    axi_resp_t   [NumChannels-1:0] axi_res;
    obi_req_t    [NumChannels-1:0] obi_req;
    obi_res_t    [NumChannels-1:0] obi_res;
    dma_events_t [NumChannels-1:0] events;
    logic        [NumChannels-1:0] busy;

    // TCDMAliasEnable defaults to 0, so addr_map_i holds exactly one rule. It must name a
    // real TCDM window: an all-zero rule is NOT a miss, cc_addr_decode reads end_addr == 0
    // as "end of address space" and would route every address to TCDMDMA (OBI).
    // Anything outside the window falls back to default_idx_i = ToSoC, i.e. AXI.
    addr_rule_t [0:0] addr_map;
    assign addr_map[0] = '{idx: idma_pkg::TCDMDMA, start_addr: TcdmStart, end_addr: TcdmEnd};

    idma_inst64_top #(
        .AxiDataWidth    ( AxiDataWidth    ),
        .AxiAddrWidth    ( AxiAddrWidth    ),
        .AxiUserWidth    ( AxiUserWidth    ),
        .AxiIdWidth      ( AxiIdWidth      ),
        .NumAxInFlight   ( NumAxInFlight   ),
        .DMAReqFifoDepth ( DMAReqFifoDepth ),
        .NumChannels     ( NumChannels     ),
        .DMATracing      ( DMATracing      ),
        .axi_ar_chan_t   ( axi_ar_chan_t   ),
        .axi_aw_chan_t   ( axi_aw_chan_t   ),
        .axi_req_t       ( axi_req_t       ),
        .axi_res_t       ( axi_resp_t      ),
        .init_req_chan_t ( init_req_chan_t ),
        .init_rsp_chan_t ( init_rsp_chan_t ),
        .init_req_t      ( init_req_t      ),
        .init_rsp_t      ( init_rsp_t      ),
        .obi_a_chan_t    ( obi_a_chan_t    ),
        .obi_r_chan_t    ( obi_r_chan_t    ),
        .obi_req_t       ( obi_req_t       ),
        .obi_res_t       ( obi_res_t       ),
        .acc_req_t       ( acc_req_t       ),
        .acc_res_t       ( acc_res_t       ),
        .dma_events_t    ( dma_events_t    ),
        .addr_rule_t     ( addr_rule_t     )
    ) i_dut (
        .clk_i           ( clk                  ),
        .rst_ni          ( rst_n                ),
        .axi_req_o       ( axi_req              ),
        .axi_res_i       ( axi_res              ),
        .obi_req_o       ( obi_req              ),
        .obi_res_i       ( obi_res              ),
        .busy_o          ( busy                 ),
        .acc_req_i       ( drv_if.acc_req       ),
        .acc_req_valid_i ( drv_if.acc_req_valid ),
        .acc_req_ready_o ( drv_if.acc_req_ready ),
        .acc_res_o       ( drv_if.acc_res       ),
        .acc_res_valid_o ( drv_if.acc_res_valid ),
        .acc_res_ready_i ( drv_if.acc_res_ready ),
        .hart_id_i       ( 32'h0                ),
        .events_o        ( events               ),
        .addr_map_i      ( addr_map             )
    );

    //--------------------------------------
    // Memory subsystem
    //--------------------------------------
    for (genvar c = 0; c < NumChannels; c++) begin : gen_mem_ch
        axi_sim_mem #(
            .AddrWidth         ( AxiAddrWidth ),
            .DataWidth         ( AxiDataWidth ),
            .IdWidth           ( AxiIdWidth   ),
            .UserWidth         ( AxiUserWidth ),
            .axi_req_t         ( axi_req_t    ),
            .axi_rsp_t         ( axi_resp_t   ),
            .WarnUninitialized ( 1'b0         ),
            .ClearErrOnAccess  ( 1'b1         ),
            .ApplDelay         ( ApplDelay    ),
            .AcqDelay          ( AcqDelay     )
        ) i_axi_sim_mem (
            .clk_i             ( clk        ),
            .rst_ni            ( rst_n      ),
            .axi_req_i         ( axi_req[c] ),
            .axi_rsp_o         ( axi_res[c] ),
            .mon_w_valid_o     ( /* NC */   ),
            .mon_w_addr_o      ( /* NC */   ),
            .mon_w_data_o      ( /* NC */   ),
            .mon_w_id_o        ( /* NC */   ),
            .mon_w_user_o      ( /* NC */   ),
            .mon_w_beat_count_o( /* NC */   ),
            .mon_w_last_o      ( /* NC */   ),
            .mon_r_valid_o     ( /* NC */   ),
            .mon_r_addr_o      ( /* NC */   ),
            .mon_r_data_o      ( /* NC */   ),
            .mon_r_id_o        ( /* NC */   ),
            .mon_r_user_o      ( /* NC */   ),
            .mon_r_beat_count_o( /* NC */   ),
            .mon_r_last_o      ( /* NC */   )
        );

        // Real OBI slave, not a '0 tie-off: a tie-off holds gnt low, so a mis-decoded
        // transfer would hang instead of failing visibly.
        obi_sim_mem #(
            .ObiCfg            ( ObiCfg     ),
            .obi_req_t         ( obi_req_t  ),
            .obi_rsp_t         ( obi_res_t  ),
            .obi_r_chan_t      ( obi_r_chan_t ),
            .WarnUninitialized ( 1'b0       ),
            .ClearErrOnAccess  ( 1'b1       ),
            .ApplDelay         ( ApplDelay  ),
            .AcqDelay          ( AcqDelay   )
        ) i_obi_sim_mem (
            .clk_i       ( clk        ),
            .rst_ni      ( rst_n      ),
            .obi_req_i   ( obi_req[c] ),
            .obi_rsp_o   ( obi_res[c] ),
            .mon_valid_o ( /* NC */   ),
            .mon_we_o    ( /* NC */   ),
            .mon_addr_o  ( /* NC */   ),
            .mon_wdata_o ( /* NC */   ),
            .mon_be_o    ( /* NC */   ),
            .mon_id_o    ( /* NC */   )
        );
    end

    //--------------------------------------
    // AXI memory helpers (channel 0)
    //--------------------------------------
    task automatic mem_init_pattern(
        input addr_t      base_addr,
        input int         num_bytes,
        input logic [7:0] pattern
    );
        for (int i = 0; i < num_bytes; i++) begin
            gen_mem_ch[0].i_axi_sim_mem.mem[base_addr + i] = pattern;
        end
    endtask

    task automatic mem_write_byte(
        input addr_t addr,
        input byte   data
    );
        gen_mem_ch[0].i_axi_sim_mem.mem[addr] = data;
    endtask

    function automatic logic [7:0] mem_read_byte(input addr_t addr);
        if (gen_mem_ch[0].i_axi_sim_mem.mem.exists(addr)) begin
            return gen_mem_ch[0].i_axi_sim_mem.mem[addr];
        end else begin
            return 8'hXX;
        end
    endfunction

endmodule

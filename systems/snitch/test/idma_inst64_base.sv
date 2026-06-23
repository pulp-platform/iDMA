// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Base harness for the standalone single-head inst64 frontend.
/// Clock/reset, the accelerator-bus driver, the upstream idma_inst64_top DUT,
/// and one axi_sim_mem per channel. No Snitch cluster, no multi-head.
module idma_inst64_base #(
    parameter int unsigned DMATracing = idma_inst64_tb_pkg::DMATracing,
    parameter idma_pkg::compute_enable_t ComputeEnable = '0,
    parameter bit AddrGenTranspose = 1'b0
);
  import idma_inst64_tb_pkg::*;
  import idma_inst64_snitch_pkg::*;

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

  axi_req_t  [NumChannels-1:0] axi_req;
  axi_resp_t [NumChannels-1:0] axi_res;
  obi_req_t  [NumChannels-1:0] obi_req;
  obi_res_t  [NumChannels-1:0] obi_res;
  dma_events_t [NumChannels-1:0] events;
  logic      [NumChannels-1:0] busy;

  // route the test's AXI range via the default idx (ToSoC=AXI); the single rule
  // maps an unused low TCDM range to OBI so the OBI port stays idle
  addr_rule_t addr_map;
  assign addr_map = '{
    idx:        idma_pkg::TCDMDMA,
    start_addr: 64'h0000_0000,
    end_addr:   64'h1000_0000
  };

  idma_inst64_top #(
    .AxiDataWidth    ( AxiDataWidth    ),
    .AxiAddrWidth    ( AxiAddrWidth    ),
    .AxiUserWidth    ( AxiUserWidth    ),
    .AxiIdWidth      ( AxiIdWidth      ),
    .NumAxInFlight   ( NumAxInFlight   ),
    .DMAReqFifoDepth ( DMAReqFifoDepth ),
    .NumChannels     ( NumChannels     ),
    .DMATracing      ( DMATracing      ),
    .ComputeEnable   ( ComputeEnable   ),
    .AddrGenTranspose( AddrGenTranspose ),
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
    .testmode_i      ( 1'b0                 ),
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

  for (genvar c = 0; c < NumChannels; c++) begin : gen_mem_ch
    axi_sim_mem #(
      .AddrWidth         ( AxiAddrWidth ),
      .DataWidth         ( AxiDataWidth ),
      .IdWidth           ( AxiIdWidth   ),
      .UserWidth         ( AxiUserWidth ),
      .axi_req_t         ( axi_req_t    ),
      .axi_rsp_t         ( axi_resp_t   ),
      .WarnUninitialized ( 1'b1         ),
      .ClearErrOnAccess  ( 1'b1         ),
      .ApplDelay         ( ApplDelay    ),
      .AcqDelay          ( AcqDelay     )
    ) i_axi_sim_mem (
      .clk_i             ( clk          ),
      .rst_ni            ( rst_n        ),
      .axi_req_i         ( axi_req[c]   ),
      .axi_rsp_o         ( axi_res[c]   ),
      .mon_w_valid_o     (              ),
      .mon_w_addr_o      (              ),
      .mon_w_data_o      (              ),
      .mon_w_id_o        (              ),
      .mon_w_user_o      (              ),
      .mon_w_beat_count_o(              ),
      .mon_w_last_o      (              ),
      .mon_r_valid_o     (              ),
      .mon_r_addr_o      (              ),
      .mon_r_data_o      (              ),
      .mon_r_id_o        (              ),
      .mon_r_user_o      (              ),
      .mon_r_beat_count_o(              ),
      .mon_r_last_o      (              )
    );

    // L1/TCDM model: connected but idle for the AXI-routed copy/transpose tests
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
      .mon_valid_o (            ),
      .mon_we_o    (            ),
      .mon_addr_o  (            ),
      .mon_wdata_o (            ),
      .mon_be_o    (            ),
      .mon_id_o    (            )
    );
  end

  // Memory helpers (channel 0)
  task automatic mem_write_byte(input addr_t addr, input byte data);
    gen_mem_ch[0].i_axi_sim_mem.mem[addr] = data;
  endtask

  function automatic logic [7:0] mem_read_byte(input addr_t addr);
    if (gen_mem_ch[0].i_axi_sim_mem.mem.exists(addr)) return gen_mem_ch[0].i_axi_sim_mem.mem[addr];
    else return 8'hXX;
  endfunction

endmodule

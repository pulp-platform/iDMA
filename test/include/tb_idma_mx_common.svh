// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Shared skeleton for the MX compute testbenches: parameter-derived types,
// clock/reset, R/W join, the AXI memory (on the axi_*_mem pair) and byte
// accessors. The including testbench couples axi_req/axi_rsp to the *_mem
// pair (directly or through a stall shim) and instantiates the backend.
// Expects DataWidth/AddrWidth/UserWidth/AxiIdWidth/TFLenWidth parameters.

localparam time TA = 1ns, TT = 9ns, TCK = 10ns;
localparam int unsigned StrbWidth = DataWidth / 8;

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

task automatic wr_mem(input addr_t a, input logic [7:0] d); i_axi_sim_mem.mem[a] = d; endtask
function automatic logic [7:0] rd_mem(input addr_t a);
  return i_axi_sim_mem.mem.exists(a) ? i_axi_sim_mem.mem[a] : 8'hxx;
endfunction

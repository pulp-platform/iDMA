// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "axi/typedef.svh"
`include "obi/typedef.svh"

/// Lint/elaboration wrapper for the snitch_cluster-gated idma_inst64_top.
/// idma_inst64_top is a fully type-parameterized generic with no concrete
/// instance in the public tree, so no lint tool can elaborate it standalone.
/// This binds concrete AXI/OBI/INIT/acc types (transpose enabled) and ties the
/// ports off so public CI can elaborate the frontend:
///   verilator --lint-only --top-module idma_inst64_lint
/// It carries no behaviour; it exists only to give the generic a concrete top.
module idma_inst64_lint #(
    parameter int unsigned AxiDataWidth = 32'd512,
    parameter int unsigned AxiAddrWidth = 32'd64,
    parameter int unsigned AxiUserWidth = 32'd1,
    parameter int unsigned AxiIdWidth   = 32'd3,
    parameter int unsigned NumChannels  = 32'd1
)(
    input  logic clk_i,
    input  logic rst_ni
);

  typedef logic [AxiAddrWidth-1:0]   axi_addr_t;
  typedef logic [AxiDataWidth-1:0]   axi_data_t;
  typedef logic [AxiDataWidth/8-1:0] axi_strb_t;
  typedef logic [AxiUserWidth-1:0]   axi_user_t;
  typedef logic [AxiIdWidth-1:0]     axi_id_t;

  `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, axi_addr_t, axi_id_t, axi_user_t)
  `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, axi_data_t, axi_strb_t, axi_user_t)
  `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, axi_id_t, axi_user_t)
  `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, axi_addr_t, axi_id_t, axi_user_t)
  `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, axi_data_t, axi_id_t, axi_user_t)
  `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
  `AXI_TYPEDEF_RESP_T(axi_resp_t, axi_b_chan_t, axi_r_chan_t)

  typedef logic [AxiDataWidth/8-1:0] obi_strb_t;
  `OBI_TYPEDEF_MINIMAL_A_OPTIONAL(obi_a_optional_t)
  `OBI_TYPEDEF_MINIMAL_R_OPTIONAL(obi_r_optional_t)
  `OBI_TYPEDEF_TYPE_A_CHAN_T(obi_a_chan_t, axi_addr_t, axi_data_t, obi_strb_t, axi_id_t,
                             obi_a_optional_t)
  `OBI_TYPEDEF_TYPE_R_CHAN_T(obi_r_chan_t, axi_data_t, axi_id_t, obi_r_optional_t)
  `OBI_TYPEDEF_REQ_T(obi_req_t, obi_a_chan_t)
  `OBI_TYPEDEF_RSP_T(obi_res_t, obi_r_chan_t)

  // INIT meta-channel types (mirror src/db/idma_init.yml)
  typedef struct packed {
    logic [AxiAddrWidth-1:0]   cfg;
    logic [AxiDataWidth-1:0]   term;
    logic [AxiDataWidth/8-1:0] strb;
    logic [AxiIdWidth-1:0]     id;
  } init_req_chan_t;
  typedef struct packed { init_req_chan_t req_chan; logic req_valid; logic rsp_ready; } init_req_t;
  typedef struct packed { logic [AxiDataWidth-1:0] init; } init_rsp_chan_t;
  typedef struct packed { init_rsp_chan_t rsp_chan; logic rsp_valid; logic req_ready; } init_rsp_t;

  typedef axi_pkg::xbar_rule_64_t addr_rule_t;

  // Snitch accelerator bus (the inst64 frontend decodes data_op/argb)
  typedef struct packed {
    logic [31:0] id;
    logic [31:0] data_op;
    logic [63:0] data_arga;
    logic [63:0] data_argb;
  } acc_req_t;
  typedef struct packed { logic [31:0] id; logic [63:0] data; logic error; } acc_res_t;

  typedef struct packed {
    logic           aw_valid, aw_ready, aw_done, aw_stall;
    axi_pkg::len_t  aw_len;
    axi_pkg::size_t aw_size;
    logic           ar_valid, ar_ready, ar_done, ar_stall;
    axi_pkg::len_t  ar_len;
    axi_pkg::size_t ar_size;
    logic           r_valid, r_ready, r_done, r_bw, r_stall;
    logic           w_valid, w_ready, w_done, w_stall;
    logic [31:0]    num_bytes_written;
    logic           b_valid, b_ready, b_done;
    logic           obi_wr_req, obi_rd_req;
    logic           dma_busy;
  } dma_events_t;

  axi_req_t  [NumChannels-1:0] axi_req;
  obi_req_t  [NumChannels-1:0] obi_req;
  dma_events_t [NumChannels-1:0] events;
  logic      [NumChannels-1:0] busy;
  acc_res_t  acc_res;
  logic      acc_req_ready, acc_res_valid;

  idma_inst64_top #(
    .AxiDataWidth    ( AxiDataWidth    ),
    .AxiAddrWidth    ( AxiAddrWidth    ),
    .AxiUserWidth    ( AxiUserWidth    ),
    .AxiIdWidth      ( AxiIdWidth      ),
    .NumAxInFlight   ( 32'd3           ),
    .DMAReqFifoDepth ( 32'd3           ),
    .NumChannels     ( NumChannels     ),
    .DMATracing      ( 1'b0            ),
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
    .clk_i           ( clk_i        ),
    .rst_ni          ( rst_ni       ),
    .axi_req_o       ( axi_req      ),
    .axi_res_i       ( '0           ),
    .obi_req_o       ( obi_req      ),
    .obi_res_i       ( '0           ),
    .busy_o          ( busy         ),
    .acc_req_i       ( '0           ),
    .acc_req_valid_i ( 1'b0         ),
    .acc_req_ready_o ( acc_req_ready ),
    .acc_res_o       ( acc_res      ),
    .acc_res_valid_o ( acc_res_valid ),
    .acc_res_ready_i ( 1'b0         ),
    .hart_id_i       ( 32'h0        ),
    .events_o        ( events       ),
    .addr_map_i      ( '0           )
  );

endmodule

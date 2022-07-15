`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "register_interface/typedef.svh"
`include "common_cells/registers.svh"

/// Wrapper for the 
module dma_desc_wrap #(
  parameter int  AxiAddrWidth  = 64,
  parameter int  AxiDataWidth  = 64,
  parameter int  AxiUserWidth  = -1,
  parameter int  AxiIdWidth    = -1,
  parameter int  AxiSlvIdWidth = -1,
  parameter type mst_aw_chan_t = logic, // AW Channel Type, master port
  parameter type mst_w_chan_t  = logic, //  W Channel Type, all ports
  parameter type mst_b_chan_t  = logic, //  B Channel Type, master port
  parameter type mst_ar_chan_t = logic, // AR Channel Type, master port
  parameter type mst_r_chan_t  = logic, //  R Channel Type, master port
  parameter type axi_mst_req_t = logic,
  parameter type axi_mst_rsp_t = logic,
  parameter type axi_slv_req_t = logic,
  parameter type axi_slv_rsp_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  output logic         irq_o,
  output axi_mst_req_t axi_master_req_o,
  input  axi_mst_rsp_t axi_master_rsp_i,
  input  axi_slv_req_t axi_slave_req_i,
  output axi_slv_rsp_t axi_slave_rsp_o
);
  import axi_pkg::*;

  typedef logic [AxiAddrWidth-1:0]     addr_t;
  typedef logic [AxiDataWidth-1:0]     data_t;
  typedef logic [(AxiDataWidth/8)-1:0] strb_t;
  typedef logic [AxiUserWidth-1:0]     user_t;
  // has one less bit for the mux not to error
  typedef logic [AxiIdWidth-2:0]       post_mux_id_t;

  axi_slv_req_t axi_slv_req;
  axi_slv_rsp_t axi_slv_rsp;

  `AXI_TYPEDEF_ALL(dma_axi_mst_post_mux, addr_t, post_mux_id_t, data_t, strb_t, user_t)
  dma_axi_mst_post_mux_req_t  axi_fe_mst_req;
  dma_axi_mst_post_mux_resp_t axi_fe_mst_rsp;
  dma_axi_mst_post_mux_req_t  axi_be_mst_req;
  dma_axi_mst_post_mux_resp_t axi_be_mst_rsp;

  `REG_BUS_TYPEDEF_ALL(dma_reg, addr_t, data_t, strb_t)
  dma_reg_req_t dma_reg_mst_req;
  dma_reg_rsp_t dma_reg_mst_rsp;
  dma_reg_req_t dma_reg_slv_req;
  dma_reg_rsp_t dma_reg_slv_rsp;

  typedef struct packed {
    logic [7:0]  id;
    addr_t       src;
    addr_t       dst;
    logic [31:0] num_bytes;
    cache_t      cache_src;
    cache_t      cache_dst;
    burst_t      burst_src;
    burst_t      burst_dst;
    logic        decouple_rw;
    logic        deburst;
    logic        serialize;
  } burst_req_t;

  burst_req_t dma_be_req;
  logic       dma_be_tx_complete;
  logic       dma_be_idle;
  logic       dma_be_valid;
  logic       dma_be_ready;

  idma_desc64_top #(
    .AddrWidth  (AxiAddrWidth) ,
    .burst_req_t(burst_req_t)  ,
    .reg_req_t  (dma_reg_req_t),
    .reg_rsp_t  (dma_reg_rsp_t)
  ) i_dma_desc64 (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .master_req_o        (dma_reg_mst_req),
    .master_rsp_i        (dma_reg_mst_rsp),
    .slave_req_i         (dma_reg_slv_req),
    .slave_rsp_o         (dma_reg_slv_rsp),
    .dma_be_tx_complete_i(dma_be_tx_complete),
    .dma_be_idle_i       (dma_be_idle),
    .dma_be_valid_o      (dma_be_valid),
    .dma_be_ready_i      (dma_be_ready),
    .dma_be_req_o        (dma_be_req),
    .irq_o               (irq_o)
  );

  axi_dma_backend #(
    .DataWidth     (AxiDataWidth),
    .AddrWidth     (AxiAddrWidth),
    .IdWidth       (AxiIdWidth-1),
    .AxReqFifoDepth(4),
    .TransFifoDepth(4),
    .BufferDepth   (4),
    .axi_req_t     (dma_axi_mst_post_mux_req_t),
    .axi_res_t     (dma_axi_mst_post_mux_resp_t),
    .burst_req_t   (burst_req_t),
    .DmaIdWidth    (1),
    .DmaTracing    (0)
  ) i_dma_backend (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .axi_dma_req_o   (axi_be_mst_req),
    .axi_dma_res_i   (axi_be_mst_rsp),
    .burst_req_i     (dma_be_req),
    .valid_i         (dma_be_valid),
    .ready_o         (dma_be_ready),
    .backend_idle_o  (dma_be_idle),
    .trans_complete_o(dma_be_tx_complete),
    .dma_id_i        (1'h1)
  );

  axi_mux #(
    .SlvAxiIDWidth(AxiIdWidth - 1),
    .slv_aw_chan_t(dma_axi_mst_post_mux_aw_chan_t),
    .mst_aw_chan_t(mst_aw_chan_t),
    .w_chan_t     (mst_w_chan_t), // same channel type for master+slave
    .slv_b_chan_t (dma_axi_mst_post_mux_b_chan_t),
    .mst_b_chan_t (mst_b_chan_t),
    .slv_ar_chan_t(dma_axi_mst_post_mux_ar_chan_t),
    .mst_ar_chan_t(mst_ar_chan_t),
    .slv_r_chan_t (dma_axi_mst_post_mux_r_chan_t),
    .mst_r_chan_t (mst_r_chan_t),
    .slv_req_t    (dma_axi_mst_post_mux_req_t),
    .slv_resp_t   (dma_axi_mst_post_mux_resp_t),
    .mst_req_t    (axi_mst_req_t),
    .mst_resp_t   (axi_mst_rsp_t),
    .NoSlvPorts   ('d2),
    .MaxWTrans    ('d2),
    .FallThrough  ('0),
    .SpillAw      ('b0),
    .SpillW       ('0),
    .SpillB       ('0),
    .SpillAr      ('b0),
    .SpillR       ('0)
  ) i_axi_mux (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .test_i      (1'b0),
    .slv_reqs_i  ({axi_fe_mst_req, axi_be_mst_req}),
    .slv_resps_o ({axi_fe_mst_rsp, axi_be_mst_rsp}),
    .mst_req_o   (axi_master_req_o),
    .mst_resp_i  (axi_master_rsp_i)
  );

  axi_to_reg #(
    .ADDR_WIDTH        (AxiAddrWidth),
    .DATA_WIDTH        (AxiDataWidth),
    .ID_WIDTH          (AxiSlvIdWidth),
    .USER_WIDTH        (AxiUserWidth),
    .AXI_MAX_WRITE_TXNS(32'd1),
    .AXI_MAX_READ_TXNS (32'd1),
    .DECOUPLE_W        (1'b1),
    .axi_req_t         (axi_slv_req_t),
    .axi_rsp_t         (axi_slv_rsp_t),
    .reg_req_t         (dma_reg_req_t),
    .reg_rsp_t         (dma_reg_rsp_t)
  ) i_axi_to_reg (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .testmode_i(1'b0),
    .axi_req_i (axi_slv_req),
    .axi_rsp_o (axi_slv_rsp),
    .reg_req_o (dma_reg_slv_req),
    .reg_rsp_i (dma_reg_slv_rsp)
  );

  dma_reg_to_axi #(
    .axi_req_t             (dma_axi_mst_post_mux_req_t),
    .axi_rsp_t             (dma_axi_mst_post_mux_resp_t),
    .reg_req_t             (dma_reg_req_t),
    .reg_rsp_t             (dma_reg_rsp_t),
    .ByteWidthInPowersOfTwo($clog2(AxiDataWidth / 8))
  ) i_dma_reg_to_axi (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .axi_req_o(axi_fe_mst_req),
    .axi_rsp_i(axi_fe_mst_rsp),
    .reg_req_i(dma_reg_mst_req),
    .reg_rsp_o(dma_reg_mst_rsp)
  );

  assign axi_slv_req     = axi_slave_req_i;
  assign axi_slave_rsp_o = axi_slv_rsp;

endmodule : dma_desc_wrap

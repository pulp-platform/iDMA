module dma_desc_synth #(
  parameter int  AxiAddrWidth     = dma_desc_synth_pkg::AxiAddrWidth,
  parameter int  AxiDataWidth     = dma_desc_synth_pkg::AxiDataWidth,
  parameter int  AxiUserWidth     = dma_desc_synth_pkg::AxiUserWidth,
  parameter int  AxiIdWidth       = dma_desc_synth_pkg::AxiIdWidth,
  parameter int  AxiSlvIdWidth    = dma_desc_synth_pkg::AxiSlvIdWidth,
  parameter int  NSpeculation     = dma_desc_synth_pkg::NSpeculation,
  parameter int  PendingFifoDepth = dma_desc_synth_pkg::PendingFifoDepth,
  parameter int  InputFifoDepth   = dma_desc_synth_pkg::InputFifoDepth,
  parameter type mst_aw_chan_t    = dma_desc_synth_pkg::mst_aw_chan_t,
  parameter type mst_w_chan_t     = dma_desc_synth_pkg::mst_w_chan_t,
  parameter type mst_b_chan_t     = dma_desc_synth_pkg::mst_b_chan_t,
  parameter type mst_ar_chan_t    = dma_desc_synth_pkg::mst_ar_chan_t,
  parameter type mst_r_chan_t     = dma_desc_synth_pkg::mst_r_chan_t,
  parameter type axi_mst_req_t    = dma_desc_synth_pkg::axi_mst_req_t,
  parameter type axi_mst_rsp_t    = dma_desc_synth_pkg::axi_mst_rsp_t,
  parameter type axi_slv_req_t    = dma_desc_synth_pkg::axi_slv_req_t,
  parameter type axi_slv_rsp_t    = dma_desc_synth_pkg::axi_slv_rsp_t
)(
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  output logic         irq_o,
  output axi_mst_req_t axi_master_req_o,
  input  axi_mst_rsp_t axi_master_rsp_i,
  input  axi_slv_req_t axi_slave_req_i,
  output axi_slv_rsp_t axi_slave_rsp_o
);

dma_desc_wrap #(
  .AxiAddrWidth  (AxiAddrWidth ),
  .AxiDataWidth  (AxiDataWidth ),
  .AxiUserWidth  (AxiUserWidth ),
  .AxiIdWidth    (AxiIdWidth   ),
  .AxiSlvIdWidth (AxiSlvIdWidth),
  .mst_aw_chan_t (mst_aw_chan_t),
  .mst_w_chan_t  (mst_w_chan_t ),
  .mst_b_chan_t  (mst_b_chan_t ),
  .mst_ar_chan_t (mst_ar_chan_t),
  .mst_r_chan_t  (mst_r_chan_t ),
  .axi_mst_req_t (axi_mst_req_t),
  .axi_mst_rsp_t (axi_mst_rsp_t),
  .axi_slv_req_t (axi_slv_req_t),
  .axi_slv_rsp_t (axi_slv_rsp_t)
) i_dma_desc_wrap (
  .clk_i,
  .rst_ni,
  .testmode_i,
  .irq_o,
  .axi_master_req_o,
  .axi_master_rsp_i,
  .axi_slave_req_i,
  .axi_slave_rsp_o
);

endmodule

// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Binds the AXI protocol and MX plane monitor into every AXI backend; include once per top.

`ifndef IDMA_MX_AXI_MON_BIND
`define IDMA_MX_AXI_MON_BIND(backend) \
bind backend idma_mx_axi_mon #( \
  .StrbWidth(StrbWidth), .AddrWidth(AddrWidth), .LenWidth(TFLenWidth), .IdWidth(AxiIdWidth), \
  .UserWidth(UserWidth), .EnableCompute(EnableCompute), .ComputeOps(ComputeOps) \
) i_mx_axi_mon ( \
  .clk_i, .rst_ni, .req_valid_i, .req_ready_i(req_ready_o), .req_len_i(idma_req_i.length), \
  .req_src_i(idma_req_i.src_addr), .req_dst_i(idma_req_i.dst_addr), \
  .req_scale_i(idma_req_i.scale_addr), \
  .req_src_burst_i(idma_req_i.opt.src.burst), .req_dst_burst_i(idma_req_i.opt.dst.burst), \
  .req_decouple_rw_i(idma_req_i.opt.beo.decouple_rw), .req_cmp_i(idma_req_i.opt.compute), \
  .req_beo_i(idma_req_i.opt.beo), .req_id_i(idma_req_i.opt.axi_id), \
  .req_src_opt_i(idma_req_i.opt.src), .req_dst_opt_i(idma_req_i.opt.dst), \
  .req_user_i(idma_req_i.user), .ar_id_i(axi_read_req_o.ar.id), \
  .ar_opt_i('{burst: axi_read_req_o.ar.burst, cache: axi_read_req_o.ar.cache, \
              lock: axi_read_req_o.ar.lock, prot: axi_read_req_o.ar.prot, \
              qos: axi_read_req_o.ar.qos, region: axi_read_req_o.ar.region}), \
  .ar_user_i(axi_read_req_o.ar.user), .r_id_i(axi_read_rsp_i.r.id), \
  .aw_id_i(axi_write_req_o.aw.id), \
  .aw_opt_i('{burst: axi_write_req_o.aw.burst, cache: axi_write_req_o.aw.cache, \
              lock: axi_write_req_o.aw.lock, prot: axi_write_req_o.aw.prot, \
              qos: axi_write_req_o.aw.qos, region: axi_write_req_o.aw.region}), \
  .aw_user_i(axi_write_req_o.aw.user), .aw_atop_i(axi_write_req_o.aw.atop), \
  .b_id_i(axi_write_rsp_i.b.id), \
  .ar_valid_i(axi_read_req_o.ar_valid), .ar_ready_i(axi_read_rsp_i.ar_ready), \
  .ar_addr_i(axi_read_req_o.ar.addr), .ar_len_i(axi_read_req_o.ar.len), \
  .ar_size_i(axi_read_req_o.ar.size), .ar_burst_i(axi_read_req_o.ar.burst), \
  .r_valid_i(axi_read_rsp_i.r_valid), .r_ready_i(axi_read_req_o.r_ready), \
  .r_last_i(axi_read_rsp_i.r.last), .aw_valid_i(axi_write_req_o.aw_valid), \
  .aw_ready_i(axi_write_rsp_i.aw_ready), .aw_addr_i(axi_write_req_o.aw.addr), \
  .aw_len_i(axi_write_req_o.aw.len), .aw_size_i(axi_write_req_o.aw.size), \
  .aw_burst_i(axi_write_req_o.aw.burst), .w_valid_i(axi_write_req_o.w_valid), \
  .w_ready_i(axi_write_rsp_i.w_ready), .w_data_i(axi_write_req_o.w.data), \
  .w_strb_i(axi_write_req_o.w.strb), .w_last_i(axi_write_req_o.w.last), \
  .b_valid_i(axi_write_rsp_i.b_valid), .b_ready_i(axi_write_req_o.b_ready) \
);
`endif

`IDMA_MX_AXI_MON_BIND(idma_backend_rw_axi)

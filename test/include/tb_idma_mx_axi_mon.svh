// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Connect one monitor to a specific backend instance. Explicit connections avoid
// module-wide binds and work with simulators without hierarchical bind support.

`ifndef IDMA_MX_AXI_MON
`define IDMA_MX_AXI_MON(backend, instance, enable_compute, compute_ops, strb_width=StrbWidth, addr_width=AddrWidth, len_width=TFLenWidth, id_width=AxiIdWidth, user_width=UserWidth) \
idma_mx_axi_mon #( \
  .StrbWidth(strb_width), .AddrWidth(addr_width), .LenWidth(len_width), \
  .IdWidth(id_width), .UserWidth(user_width), \
  .EnableCompute(enable_compute), .ComputeOps(compute_ops) \
) instance ( \
  .clk_i(backend.clk_i), .rst_ni(backend.rst_ni), \
  .req_valid_i(backend.req_valid_i), .req_ready_i(backend.req_ready_o), \
  .req_len_i(backend.idma_req_i.length), \
  .req_src_i(backend.idma_req_i.src_addr), .req_dst_i(backend.idma_req_i.dst_addr), \
  .req_scale_i(backend.idma_req_i.scale_addr), \
  .req_src_burst_i(backend.idma_req_i.opt.src.burst), .req_dst_burst_i(backend.idma_req_i.opt.dst.burst), \
  .req_cmp_i(backend.idma_req_i.opt.compute), \
  .req_beo_i(backend.idma_req_i.opt.beo), .req_id_i(backend.idma_req_i.opt.axi_id), \
  .req_src_opt_i(backend.idma_req_i.opt.src), .req_dst_opt_i(backend.idma_req_i.opt.dst), \
  .req_user_i(backend.idma_req_i.user), .req_src_prot_i(backend.idma_req_i.opt.src_protocol), \
  .req_dst_prot_i(backend.idma_req_i.opt.dst_protocol), .ar_id_i(backend.axi_read_req_o.ar.id), \
  .ar_opt_i('{burst: backend.axi_read_req_o.ar.burst, cache: backend.axi_read_req_o.ar.cache, \
              lock: backend.axi_read_req_o.ar.lock, prot: backend.axi_read_req_o.ar.prot, \
              qos: backend.axi_read_req_o.ar.qos, region: backend.axi_read_req_o.ar.region}), \
  .ar_user_i(backend.axi_read_req_o.ar.user), .r_id_i(backend.axi_read_rsp_i.r.id), \
  .aw_id_i(backend.axi_write_req_o.aw.id), \
  .aw_opt_i('{burst: backend.axi_write_req_o.aw.burst, cache: backend.axi_write_req_o.aw.cache, \
              lock: backend.axi_write_req_o.aw.lock, prot: backend.axi_write_req_o.aw.prot, \
              qos: backend.axi_write_req_o.aw.qos, region: backend.axi_write_req_o.aw.region}), \
  .aw_user_i(backend.axi_write_req_o.aw.user), .aw_atop_i(backend.axi_write_req_o.aw.atop), \
  .b_id_i(backend.axi_write_rsp_i.b.id), \
  .ar_valid_i(backend.axi_read_req_o.ar_valid), .ar_ready_i(backend.axi_read_rsp_i.ar_ready), \
  .ar_addr_i(backend.axi_read_req_o.ar.addr), .ar_len_i(backend.axi_read_req_o.ar.len), \
  .ar_size_i(backend.axi_read_req_o.ar.size), .ar_burst_i(backend.axi_read_req_o.ar.burst), \
  .r_valid_i(backend.axi_read_rsp_i.r_valid), .r_ready_i(backend.axi_read_req_o.r_ready), \
  .r_last_i(backend.axi_read_rsp_i.r.last), .aw_valid_i(backend.axi_write_req_o.aw_valid), \
  .aw_ready_i(backend.axi_write_rsp_i.aw_ready), .aw_addr_i(backend.axi_write_req_o.aw.addr), \
  .aw_len_i(backend.axi_write_req_o.aw.len), .aw_size_i(backend.axi_write_req_o.aw.size), \
  .aw_burst_i(backend.axi_write_req_o.aw.burst), .w_valid_i(backend.axi_write_req_o.w_valid), \
  .w_ready_i(backend.axi_write_rsp_i.w_ready), .w_data_i(backend.axi_write_req_o.w.data), \
  .w_strb_i(backend.axi_write_req_o.w.strb), .w_last_i(backend.axi_write_req_o.w.last), \
  .b_valid_i(backend.axi_write_rsp_i.b_valid), .b_ready_i(backend.axi_write_req_o.b_ready), \
  .busy_i(backend.busy_o) \
);
`endif


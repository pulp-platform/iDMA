// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Samuel Riedel <sriedel@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

module idma_distributed_midend #(
  parameter int unsigned NoMstPorts     = 1,
  parameter int unsigned DmaRegionWidth = 1, // In bytes
  parameter type         burst_req_t    = logic,
  parameter type         meta_t         = logic
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  // Slave
  input  burst_req_t                  burst_req_i,
  input  logic                        valid_i,
  output logic                        ready_o,
  output meta_t                       meta_o,
  // Master
  output burst_req_t [NoMstPorts-1:0] burst_req_o,
  output logic       [NoMstPorts-1:0] valid_o,
  input  logic       [NoMstPorts-1:0] ready_i,
  input  meta_t      [NoMstPorts-1:0] meta_i
);

  // Handle Metadata
  logic [NoMstPorts-1:0] trans_complete_d, trans_complete_q;
  logic [NoMstPorts-1:0] backend_idle_d, backend_idle_q;
  assign meta_o.trans_complete = &trans_complete_q;
  assign meta_o.backend_idle = &backend_idle_q;

  always_comb begin
    trans_complete_d = trans_complete_q;
    backend_idle_d = backend_idle_q;
    for (int unsigned i = 0; i < NoMstPorts; i++) begin
      trans_complete_d[i] = trans_complete_q[i] | meta_i[i].trans_complete;
      backend_idle_d[i] = meta_i[i].backend_idle;
    end
    if (meta_o.trans_complete) begin
      trans_complete_d = '0;
    end
  end
  `FF(trans_complete_q, trans_complete_d, '0, clk_i, rst_ni)
  `FF(backend_idle_q, backend_idle_d, '1, clk_i, rst_ni)

  // TODO Deburst

  // Fork
  stream_fork #(
    .N_OUP (NoMstPorts)
  ) i_stream_fork (
    .clk_i   (clk_i  ),
    .rst_ni  (rst_ni ),
    .valid_i (valid_i),
    .ready_o (ready_o),
    .valid_o (valid_o),
    .ready_i (ready_i)
  );

  always_comb begin
    for (int i = 0; i < NoMstPorts; i++) begin
      // Feed metadata through directly
      burst_req_o[i] = burst_req_i;
      // Modify addresses and size
      // TODO: Handle alignment
      burst_req_o[i].src = burst_req_i.src + (i * DmaRegionWidth);
      burst_req_o[i].dst = burst_req_i.dst + (i * DmaRegionWidth);
      burst_req_o[i].num_bytes = burst_req_i.num_bytes / NoMstPorts;
    end
  end

endmodule

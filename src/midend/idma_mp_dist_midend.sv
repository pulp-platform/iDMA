// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Samuel Riedel <sriedel@iis.ee.ethz.ch>
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

/// Distribute DMA requests over several backends
module idma_mp_dist_midend #(
  /// Number of back-ends
  parameter int unsigned NumBEs      = 32'd1,
  /// Size of the region that one port covers in bytes
  parameter int unsigned RegionWidth = 32'd1,
  /// Base address of the regions
  parameter int unsigned RegionStart = 32'h0000_0000,
  /// End address of the regions
  parameter int unsigned RegionEnd   = 32'h1000_0000,
  /// Address Width
  parameter int unsigned AddrWidth   = 32'd32,
  /// Print information on transfers
  parameter bit          PrintInfo   = 1'b0,
  /// DMA iDMA type
  parameter type         idma_req_t  = logic,
  /// DMA iDMA request type
  parameter type         idma_rsp_t  = logic
) (
  /// Clock
  input  logic                              clk_i,
  /// Reset
  input  logic                              rst_ni,
  /// Burst request manager
  input  idma_req_t                         idma_req_i,
  /// iDMA request valid manager
  input  logic                              idma_req_valid_i,
  /// iDMA request ready manager
  output logic                              idma_req_ready_o,
  /// iDMA response manager
  output idma_rsp_t                         idma_rsp_o,
  /// iDMA response valid manager
  output logic                              idma_rsp_valid_o,
  /// iDMA response ready manager
  input  logic                              idma_rsp_ready_i,
  /// DMA busy manager
  output idma_pkg::idma_busy_t              idma_busy_o,
  // Subordinate Port
  /// iDMA request subordinate
  output idma_req_t            [NumBEs-1:0] idma_req_o,
  /// iDMA request valid subordinate
  output logic                 [NumBEs-1:0] idma_req_valid_o,
  /// iDMA request ready subordinate
  input  logic                 [NumBEs-1:0] idma_req_ready_i,
  /// iDMA response subordinate
  input  idma_rsp_t            [NumBEs-1:0] idma_rsp_i,
  /// iDMA response valid subordinate
  input  logic                 [NumBEs-1:0] idma_rsp_valid_i,
  /// iDMA response ready subordinate
  output logic                 [NumBEs-1:0] idma_rsp_ready_o,
  /// DMA busy subordinate
  input  idma_pkg::idma_busy_t [NumBEs-1:0] idma_busy_i
);

  localparam int unsigned DmaRegionAddressBits = $clog2(RegionWidth);
  localparam int unsigned FullRegionAddressBits = $clog2(RegionWidth * NumBEs);

  typedef logic [FullRegionAddressBits:0] full_addr_t;

  // Handle Metadata
  logic                 [NumBEs-1:0] trans_complete_d, trans_complete_q;
  logic                 [NumBEs-1:0] tie_off_trans_complete_d, tie_off_trans_complete_q;
  idma_pkg::idma_busy_t [NumBEs-1:0] backend_busy_d, backend_busy_q;

  // bypass
  assign idma_rsp_valid_o = &trans_complete_q;
  assign idma_busy_o      = &backend_busy_q;
  assign idma_rsp_o       = |idma_rsp_i;
  assign idma_rsp_ready_o = idma_rsp_ready_i ? '1 : '0;

  // TODO We could have multiple outstanding requests per port, so we need multiple trans_complete_tie_offs
  always_comb begin : proc_handle_status
    trans_complete_d = trans_complete_q;
    backend_busy_d = backend_busy_q;
    for (int unsigned i = 0; i < NumBEs; i++) begin
      trans_complete_d[i] = trans_complete_q[i] | idma_rsp_valid_i[i]| tie_off_trans_complete_q[i];
      backend_busy_d[i] = idma_busy_i[i];
    end
    if (idma_rsp_valid_o) begin
      trans_complete_d = '0;
    end
  end
  `FF(trans_complete_q, trans_complete_d, '0, clk_i, rst_ni)
  `FF(tie_off_trans_complete_q, tie_off_trans_complete_d, '0, clk_i, rst_ni)
  `FF(backend_busy_q, backend_busy_d, '1, clk_i, rst_ni)

  // Fork
  logic [NumBEs-1:0] valid, ready;
  stream_fork #(
    .N_OUP (NumBEs)
  ) i_stream_fork (
    .clk_i,
    .rst_ni,
    .valid_i ( idma_req_valid_i ),
    .ready_o ( idma_req_ready_o ),
    .valid_o ( valid            ),
    .ready_i ( ready            )
  );

  full_addr_t src_addr, dst_addr, start_addr, end_addr;

  assign src_addr = idma_req_i.src_addr[FullRegionAddressBits-1:0];
  assign dst_addr = idma_req_i.dst_addr[FullRegionAddressBits-1:0];

  always_comb begin : proc_split
    if (($unsigned(idma_req_i.src_addr) >= RegionStart) &&
        ($unsigned(idma_req_i.src_addr) <  RegionEnd  )) begin
      start_addr = src_addr;
    end else begin
      start_addr = dst_addr;
    end
    end_addr = start_addr + idma_req_i.length;
    // Connect valid ready by default
    idma_req_valid_o = valid;
    ready            = idma_req_ready_i;
    // Do not interfere with metadata per default
    tie_off_trans_complete_d = '0;

    for (int i = 0; i < NumBEs; i++) begin
      // Feed metadata through directly
      idma_req_o[i]          = idma_req_i;
      // Feed through the address bits
      idma_req_o[i].src_addr = idma_req_i.src_addr;
      idma_req_o[i].dst_addr = idma_req_i.dst_addr;
      // Modify lower addresses bits and size
      if (($unsigned(start_addr) >= (i+1)*RegionWidth) ||
          ($unsigned(end_addr)   <= i*RegionWidth    )) begin
        // We are not involved in the transfer
        idma_req_o[i].src_addr = '0;
        idma_req_o[i].dst_addr = '0;
        idma_req_o[i].length   = 1;
        // Make handshake ourselves
        idma_req_valid_o[i] = 1'b0;
        ready[i]            = 1'b1;
        // Inject trans complete
        if (valid) begin
          tie_off_trans_complete_d[i] = 1'b1;
        end
      end else if (($unsigned(start_addr) >= i*RegionWidth)) begin
        // First (and potentially only) slice
        // Leave address as is
        if ($unsigned(end_addr) <= (i+1)*RegionWidth) begin
          idma_req_o[i].length = idma_req_i.length;
        end else begin
          idma_req_o[i].length = RegionWidth - start_addr[DmaRegionAddressBits-1:0];
        end
      end else begin
        // Round up the address to the next DMA boundary
        if (($unsigned(idma_req_i.src_addr) >= RegionStart) &&
            ($unsigned(idma_req_i.src_addr) <  RegionEnd  )) begin
          idma_req_o[i].src_addr[FullRegionAddressBits-1:0] = i*RegionWidth;
          idma_req_o[i].dst_addr = idma_req_i.dst_addr + i*RegionWidth -
                                   start_addr[DmaRegionAddressBits-1:0];
        end else begin
          idma_req_o[i].src_addr = idma_req_i.src_addr + i*RegionWidth -
                                   start_addr[DmaRegionAddressBits-1:0];
          idma_req_o[i].dst_addr[FullRegionAddressBits-1:0] = i*RegionWidth;
        end
        if ($unsigned(end_addr) >= (i+1)*RegionWidth) begin
          // Middle slice
          // Emit a full-sized transfer
          idma_req_o[i].length = RegionWidth;
        end else begin
          // Last slice
          idma_req_o[i].length = end_addr[DmaRegionAddressBits-1:0];
        end
      end
    end
  end

  // pragma translate_off
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (PrintInfo) begin
      if (rst_ni && idma_req_valid_i && idma_req_ready_o) begin
        $display("[idma_distributed_midend] Got request");
        $display("Request in: From: 0x%8x To: 0x%8x with size %d",
                  idma_req_i.src_addr, idma_req_i.dst_addr, idma_req_i.length);
        for (int i = 0; i < NumBEs; i++) begin
          $display("Out %6d: From: 0x%8x To: 0x%8x with size %d",
                   i, idma_req_o[i].src_addr, idma_req_o[i].dst_addr, idma_req_o[i].length);
        end
      end
    end
  end
  // pragma translate_on

endmodule

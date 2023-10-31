// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Samuel Riedel <sriedel@iis.ee.ethz.ch>
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

/// Splits DMA transactions along a given region boundaries
module idma_mp_split_midend #(
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
  input  logic       clk_i,
  /// Reset
  input  logic       rst_ni,
  /// Burst request manager
  input  idma_req_t  idma_req_i,
  /// iDMA request valid manager
  input  logic       idma_req_valid_i,
  /// iDMA request ready manager
  output logic       idma_req_ready_o,
  /// iDMA response manager
  output idma_rsp_t  idma_rsp_o,
  /// iDMA response valid manager
  output logic       idma_rsp_valid_o,
  /// iDMA response ready manager
  input  logic       idma_rsp_ready_i,
  // Subordinate Port
  /// iDMA request subordinate
  output idma_req_t  idma_req_o,
  /// iDMA request valid subordinate
  output logic       idma_req_valid_o,
  /// iDMA request ready subordinate
  input  logic       idma_req_ready_i,
  /// iDMA response subordinate
  input  idma_rsp_t  idma_rsp_i,
  /// iDMA response valid subordinate
  input  logic       idma_rsp_valid_i,
  /// iDMA response ready subordinate
  output logic       idma_rsp_ready_o
);

  /// Width of the address regions
  localparam int unsigned DmaRegionAddressBits = $clog2(RegionWidth);

  /// Address type
  typedef logic [AddrWidth-1:0] addr_t;

  /// State of the FSM
  typedef enum logic {Idle, Busy} state_t;

  addr_t start_addr, end_addr;
  logic req_valid;

  // Bypass the response port
  assign idma_rsp_o       = idma_rsp_i;
  assign idma_rsp_ready_o = idma_rsp_ready_i;

  // Handle Metadata
  // Forward idle signal and count the trans_comlete signal
  logic [31:0] num_trans_d, num_trans_q;

  always_comb begin : proc_handle_meta
    num_trans_d = num_trans_q;
    idma_rsp_valid_o = 1'b0;
    if (req_valid) begin
      num_trans_d += 1;
    end
    if (idma_rsp_valid_o & idma_rsp_ready_i) begin
      num_trans_d -= 1;
    end
    if (num_trans_q == 1 && num_trans_d == 0) begin
      idma_rsp_valid_o = 1'b1;
    end
  end
  `FF(num_trans_q, num_trans_d, '0, clk_i, rst_ni)

  // Split requests
  always_comb begin : proc_
    if (($unsigned(idma_req_i.src_addr) >= RegionStart) &&
        ($unsigned(idma_req_i.src_addr)  < RegionEnd  )) begin
      start_addr = idma_req_i.src_addr;
    end else begin
      start_addr = idma_req_i.dst_addr;
    end
    end_addr = start_addr + idma_req_i.length;
  end

  state_t state_d, state_q;
  idma_req_t req_d, req_q;

  `FFARN(state_q, state_d, Idle, clk_i, rst_ni)
  `FFARN(req_q, req_d, '0, clk_i, rst_ni)

  always_comb begin : proc_splitting
    // defaults
    state_d          = state_q;
    req_d            = req_q;
    idma_req_o       = idma_req_i;
    idma_req_valid_o = 1'b0;
    idma_req_ready_o = 1'b0;
    req_valid        = 1'b0;

    unique case (state_q)
      Idle: begin
        if (idma_req_valid_i) begin
          if (RegionWidth-start_addr[DmaRegionAddressBits-1:0] >= idma_req_i.length) begin
            // No splitting required, just forward
            idma_req_valid_o = 1'b1;
            idma_req_ready_o = idma_req_ready_i;
            req_valid        = idma_req_valid_i;
          end else begin
            // Splitting required
            // Store and acknowledge
            req_d            = idma_req_i;
            idma_req_ready_o = 1'b1;
            // Feed through the first request and modify it's size
            idma_req_o.length = RegionWidth - start_addr[DmaRegionAddressBits-1:0];
            // Forward request
            idma_req_valid_o = 1'b1;
            if (idma_req_ready_i) begin
              // Increment the address and reduce the number of outstanding splits
              req_d.length   -= RegionWidth - start_addr[DmaRegionAddressBits-1:0];
              req_d.src_addr += RegionWidth - start_addr[DmaRegionAddressBits-1:0];
              req_d.dst_addr += RegionWidth - start_addr[DmaRegionAddressBits-1:0];
              req_valid         = 1'b1;
            end
            state_d = Busy;
          end
        end
      end
      Busy: begin
        // Sent next burst from split.
        idma_req_o       = req_q;
        idma_req_valid_o = 1'b1;
        req_valid        = idma_req_ready_i;
        if (req_q.length <= RegionWidth) begin
          // Last split
          if (idma_req_ready_i) begin
            state_d = Idle;
          end
        end else begin
          // Clip size and increment address
          idma_req_o.length = RegionWidth;
          if (idma_req_ready_i) begin
            req_d.length   = req_q.length - RegionWidth;
            req_d.src_addr = req_q.src_addr + RegionWidth;
            req_d.dst_addr = req_q.dst_addr + RegionWidth;
          end
        end
      end
      default: /*do nothing*/;
    endcase
  end

  // pragma translate_off
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (PrintInfo) begin
      if (rst_ni && idma_req_valid_i && idma_req_ready_o) begin
        $display("[idma_split_midend] Got request");
        $display("Split: Request in: From: 0x%8x To: 0x%8x with size %d",
                 idma_req_i.src_addr, idma_req_i.dst_addr, idma_req_i.length);
      end
      if (rst_ni && idma_req_valid_o && idma_req_ready_i) begin
        $display("Split: Out %6d: From: 0x%8x To: 0x%8x with size %d",
                 num_trans_q, idma_req_o.src_addr, idma_req_o.dst_addr, idma_req_o.length);
      end
    end
  end
  // pragma translate_on

endmodule

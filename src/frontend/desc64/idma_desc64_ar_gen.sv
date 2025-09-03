// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

/// This module generates AR packets to fetch descriptors from memory
module idma_desc64_ar_gen #(
    /// AXI Data width
    parameter int unsigned DataWidth      = 64,
    /// Descriptor type. `$bits(descriptor_t)` must be a power of two
    parameter type         descriptor_t   = logic,
    /// AXI AR channel type
    parameter type         axi_ar_chan_t  = logic,
    /// AXI AR id type
    parameter type         axi_id_t       = logic,
    /// Type that can hold the usage information of the idma_req fifo
    parameter type         usage_t        = logic,
    /// AXI Address type
    parameter type         addr_t         = logic
)(
    /// Clock
    input  logic         clk_i,
    /// Reset
    input  logic         rst_ni,
    /// AXI AR channel
    output axi_ar_chan_t axi_ar_chan_o,
    /// AXI AR valid
    output logic         axi_ar_chan_valid_o,
    /// AXI AR ready
    input  logic         axi_ar_chan_ready_i,
    /// AXI ID to use when requesting
    input  axi_id_t      axi_ar_id_i,
    /// queued address to use when we reach the last in a chain
    input  addr_t        queued_address_i,
    /// queued address valid
    input  logic         queued_address_valid_i,
    /// queued address ready
    output logic         queued_address_ready_o,
    /// next address as read from descriptor
    input  addr_t        next_address_from_descriptor_i,
    /// next address valid
    input  logic         next_address_from_descriptor_valid_i,
    /// number of available slots in the idma request fifo
    input  usage_t       idma_req_available_slots_i,
    /// address for feedback for the next request
    output addr_t        feedback_addr_o,
    /// feedback address valid
    output logic         feedback_addr_valid_o,
    /// whether the unit is busy
    output logic         busy_o
);

`define MIN(a, b) ((a) < (b) ? a : b)

localparam int unsigned DataWidthBytes = DataWidth / 8;
localparam int unsigned DescriptorSize = $bits(descriptor_t) / 8;

localparam logic [2:0]  AxiSize   = `MIN(`MIN($clog2(DataWidthBytes),
                                         $clog2(DescriptorSize)), 3'b111);
localparam logic [7:0]  AxiLength = DescriptorSize / DataWidthBytes - 1;

logic   inflight_q, inflight_d;
logic   next_addr_from_desc_valid_q, next_addr_from_desc_valid_d;
logic   next_addr_from_desc_valid_this_cycle;
logic   take_from_queued;
logic   may_send_ar;
addr_t  next_addr_q, next_addr_d;
addr_t  ar_addr;

assign next_addr_from_desc_valid_d = next_address_from_descriptor_valid_i;
assign next_addr_from_desc_valid_this_cycle = !next_addr_from_desc_valid_q &&
                                               next_address_from_descriptor_valid_i;

assign next_addr_d = next_addr_from_desc_valid_this_cycle ?
                       next_address_from_descriptor_i :
                       next_addr_q;

assign take_from_queued = (next_addr_from_desc_valid_this_cycle ?
                           next_address_from_descriptor_i == '1 :
                           next_addr_q == '1);

assign ar_addr = take_from_queued ? queued_address_i :
                   (next_addr_from_desc_valid_this_cycle ?
                      next_address_from_descriptor_i : next_addr_q);

assign may_send_ar = idma_req_available_slots_i > 0 &&
                       (!inflight_q || next_addr_from_desc_valid_this_cycle);

always_comb begin : proc_inflight
    inflight_d = inflight_q;
    if (axi_ar_chan_ready_i && axi_ar_chan_valid_o) begin
        inflight_d = 1'b1;
    end else if (next_addr_from_desc_valid_this_cycle) begin
        inflight_d = 1'b0;
    end
end

always_comb begin : proc_ready_valid
    axi_ar_chan_valid_o    = 1'b0;
    queued_address_ready_o = 1'b0;
    if (may_send_ar) begin
        if (take_from_queued) begin
            axi_ar_chan_valid_o    = queued_address_valid_i;
            queued_address_ready_o = axi_ar_chan_ready_i;
        end else begin
            axi_ar_chan_valid_o    = 1'b1;
        end
    end
end

always_comb begin : proc_ar
    axi_ar_chan_o       = '0;
    axi_ar_chan_o.id    = axi_ar_id_i;
    axi_ar_chan_o.addr  = ar_addr;
    axi_ar_chan_o.len   = AxiLength;
    axi_ar_chan_o.size  = AxiSize;
    axi_ar_chan_o.burst = axi_pkg::BURST_INCR;
end

`FF(inflight_q, inflight_d, 1'b0)
`FF(next_addr_from_desc_valid_q, next_addr_from_desc_valid_d, 1'b0)
`FF(next_addr_q, next_addr_d, '1)

assign feedback_addr_o       = ar_addr;
assign feedback_addr_valid_o = axi_ar_chan_ready_i && axi_ar_chan_valid_o;
assign busy_o                = !take_from_queued || inflight_q;

endmodule

// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

/// This module generates AR packets to fetch descriptors from memory
module idma_desc64_ar_gen_prefetch #(
    /// AXI Data width
    parameter int unsigned DataWidth      = 64,
    /// How many descriptors may be prefetched
    parameter int unsigned NSpeculation   = 0,
    /// Descriptor type. `$bits(descriptor_t)` must be a power of two
    parameter type         descriptor_t   = logic,
    /// AXI AR channel type
    parameter type         axi_ar_chan_t  = logic,
    /// AXI AR id type
    parameter type         axi_id_t       = logic,
    /// Type that can hold the usage information of the idma_req fifo
    parameter type         usage_t        = logic,
    /// AXI Address type
    parameter type         addr_t         = logic,
    /// Type that can hold how many descriptors to flush on the R channel.
    /// Do not override.
    parameter type         flush_t        = logic [$clog2(NSpeculation + 1)-1:0]
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
    /// number of requests to flush on the R channel
    output flush_t       n_requests_to_flush_o,
    /// if asserted, flush `n_requests_to_flush_o` on the R channel
    output logic         n_requests_to_flush_valid_o,
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

// We need the descriptor to have a power of two size for easy multiplication
// when calculating the next address
// pragma translate_off
`ASSERT_INIT(DescriptorSizeIsPowerOfTwo, (32'd1 << $clog2(DescriptorSize)) == DescriptorSize)
// pragma translate_on

localparam logic [2:0]  AxiSize   = `MIN(`MIN($clog2(DataWidthBytes),
                                         $clog2(DescriptorSize)), 3'b111);
localparam logic [7:0]  AxiLength = DescriptorSize / DataWidthBytes - 1;

localparam int unsigned SpeculationWidth      = $clog2(NSpeculation + 1);
localparam int unsigned SpeculationUsageWidth = $clog2(NSpeculation);

typedef enum logic [1:0] {
    Idle,
    Submitting,
    Blocked
} gen_state_e;

typedef struct packed {
    logic  speculative;
    addr_t addr;
} addr_spec_t;

gen_state_e state_q, state_d;

addr_t      base_addr_q, base_addr_d;
addr_spec_t staging_addr;
logic       staging_addr_valid_pending, staging_addr_ready_pending;
logic       staging_addr_valid_legalization, staging_addr_ready_legalization;
logic       staging_addr_valid_speculation, staging_addr_ready_speculation;
addr_t      addr_to_retreive;

addr_spec_t next_ar;
logic       next_ar_valid, next_ar_ready;

logic                             next_addr_valid_q, next_addr_valid_d;
logic                             next_addr_valid_this_cycle;
logic [SpeculationWidth:0]        inflight_counter_q, inflight_counter_d;
logic                             flush;
logic                             commit;
logic                             speculation_correct;
logic                             legalization_usage;
logic                             idma_enough_slots;
addr_t                            speculation_addr;
logic                             speculation_ready, speculation_valid;
logic [SpeculationUsageWidth-1:0] speculation_usage_short;
logic [SpeculationWidth-1:0]      speculation_usage;

assign next_ar.speculative = inflight_counter_q > 0;
assign next_ar.addr        = base_addr_q + (inflight_counter_q << $clog2(DescriptorSize));

assign staging_addr_valid_legalization = staging_addr_valid_pending &&
                                          (staging_addr_ready_speculation ||
                                          !staging_addr.speculative) &&
                                          !flush;
assign staging_addr_ready_pending      = staging_addr_ready_legalization &&
                                          (staging_addr_ready_speculation ||
                                          !staging_addr.speculative) &&
                                          !flush;
assign staging_addr_valid_speculation  = staging_addr_valid_pending &&
                                          staging_addr_ready_legalization &&
                                          staging_addr.speculative &&
                                          !flush;

assign next_addr_valid_d = next_address_from_descriptor_valid_i;
assign next_addr_valid_this_cycle = next_address_from_descriptor_valid_i && !next_addr_valid_q;

assign speculation_correct = next_address_from_descriptor_i == '1 ?
        (queued_address_valid_i && speculation_addr == queued_address_i) :
        speculation_addr == next_address_from_descriptor_i;

assign flush  = next_addr_valid_this_cycle && (!speculation_valid || !speculation_correct);
assign commit = next_addr_valid_this_cycle && speculation_valid && speculation_correct;

assign speculation_ready = commit;

assign idma_enough_slots = idma_req_available_slots_i > inflight_counter_q &&
                             inflight_counter_q < NSpeculation;

// handle case of NSpeculation being power of 2
always_comb begin : proc_usage
    speculation_usage = speculation_usage_short;
    // we can't distinguish between max and empty if readys and valids are on
    // at the same time!
    if (speculation_usage_short == '0 && speculation_valid) begin
        speculation_usage = NSpeculation;
    end
end

always_comb begin : proc_inflight_counter
    inflight_counter_d = inflight_counter_q;
    if (flush) begin
        inflight_counter_d = '0;
    end else begin
        inflight_counter_d = inflight_counter_q + (next_ar_valid && next_ar_ready) - commit;
    end
end

always_comb begin : proc_feedback_addr
    // Normally, the next feedback address is the one we're commiting.
    feedback_addr_o       = speculation_addr;
    feedback_addr_valid_o = commit;
    // After a flush or when starting fresh however, we have a first address
    // that is known and doesn't pass through the speculation buffer. We need
    // to pass that address through in that case.
    if (!staging_addr.speculative &&
        staging_addr_valid_legalization &&
        staging_addr_ready_legalization) begin

        feedback_addr_o = staging_addr.addr;
        feedback_addr_valid_o = 1'b1;
    end
end

assign next_ar_valid          = idma_enough_slots && state_q != Idle;
assign queued_address_ready_o = (state_q == Idle && idma_enough_slots) ||
                (next_addr_valid_this_cycle && next_address_from_descriptor_i == '1);

// We never expect to flush when we are in idle, as the only
// way to get back to idle is upon flushing.
// pragma translate_off
`ASSERT_NEVER(NeverIdleWhenFlushing, (state_q == Idle) && flush)
// pragma translate_on

always_comb begin : proc_fsm
    state_d = state_q;
    base_addr_d = base_addr_q;

    if (next_address_from_descriptor_valid_i) begin
        if (next_address_from_descriptor_i == '1) begin
            if (queued_address_valid_i) begin
                base_addr_d = queued_address_i;
            end
        end else begin
            base_addr_d = next_address_from_descriptor_i;
        end
    end

    if (next_addr_valid_this_cycle && next_address_from_descriptor_i == '1 &&
        !queued_address_valid_i) begin
        state_d = Idle;
    end else begin
        unique case (state_q)
            Idle: begin
                if (idma_enough_slots && queued_address_valid_i) begin
                    state_d = Submitting;
                    base_addr_d = queued_address_i;
                end
            end
            Submitting: begin
                if (next_ar_ready) begin
                    if (idma_enough_slots && inflight_counter_q < NSpeculation) begin
                        state_d = Submitting;
                    end else begin
                        state_d = Blocked;
                    end
                end
            end
            Blocked: begin
                if (idma_enough_slots && inflight_counter_q < NSpeculation) begin
                    state_d = Submitting;
                end
            end
            default: begin
            end
        endcase
    end
end

`FF(state_q, state_d, Idle);
`FF(inflight_counter_q, inflight_counter_d, '0);
`FF(base_addr_q, base_addr_d, '0);
`FF(next_addr_valid_q, next_addr_valid_d, 1'b0);

stream_fifo #(
    .FALL_THROUGH(1'b1),
    .DEPTH       (NSpeculation),
    .T           (addr_t)
) i_speculation_fifo (
    .clk_i,
    .rst_ni,
    .flush_i   (flush),
    .testmode_i(1'b0),
    .usage_o   (speculation_usage_short),
    .data_i    (staging_addr.addr),
    .valid_i   (staging_addr_valid_speculation),
    .ready_o   (staging_addr_ready_speculation),
    .data_o    (speculation_addr),
    .valid_o   (speculation_valid),
    .ready_i   (speculation_ready)
);

stream_fifo #(
    .FALL_THROUGH(1'b1),
    .DEPTH       (NSpeculation),
    .T           (addr_spec_t)
) i_pending_ars (
    .clk_i,
    .rst_ni,
    .flush_i   (flush),
    .testmode_i(1'b0),
    .usage_o   ( /* unconnected */ ),
    .data_i    (next_ar),
    .valid_i   (next_ar_valid),
    .ready_o   (next_ar_ready),
    .data_o    (staging_addr),
    .valid_o   (staging_addr_valid_pending),
    .ready_i   (staging_addr_ready_pending)
);

stream_fifo #(
    .FALL_THROUGH(1'b1),
    .DEPTH       (1),
    .T           (addr_t)
) i_legalization_fifo (
    .clk_i,
    .rst_ni,
    .flush_i   (1'b0),
    .testmode_i(1'b0),
    .usage_o   (legalization_usage),
    .data_i    (staging_addr.addr),
    .valid_i   (staging_addr_valid_legalization),
    .ready_o   (staging_addr_ready_legalization),
    .data_o    (addr_to_retreive),
    .valid_o   (axi_ar_chan_valid_o),
    .ready_i   (axi_ar_chan_ready_i)
);

assign n_requests_to_flush_o       = speculation_usage + legalization_usage;
assign n_requests_to_flush_valid_o = flush;
assign busy_o                      = state_q != Idle || inflight_counter_q > '0;

always_comb begin : proc_ar
    axi_ar_chan_o       = '0;
    axi_ar_chan_o.id    = axi_ar_id_i;
    axi_ar_chan_o.addr  = addr_to_retreive;
    axi_ar_chan_o.len   = AxiLength;
    axi_ar_chan_o.size  = AxiSize;
    axi_ar_chan_o.burst = axi_pkg::BURST_INCR;
end

endmodule : idma_desc64_ar_gen_prefetch

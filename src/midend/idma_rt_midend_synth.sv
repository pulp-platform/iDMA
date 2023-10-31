// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

/// Synth wrapper for the RT midend for the iDMA
module idma_rt_midend_synth #(
    /// Number of parallel events
    parameter int unsigned NumEvents      = 32'd1,
    /// The width of the event counters (count multiple of clock period)
    parameter int unsigned EventCntWidth  = 32'd32,
    /// Number of outstanding DMA events
    parameter int unsigned NumOutstanding = 32'd2,
    /// Address type
    parameter type         addr_t         = idma_rt_midend_synth_pkg::axi_addr_t,
    /// ND iDMA request type
    parameter type         idma_nd_req_t  = idma_rt_midend_synth_pkg::idma_nd_req_t,
    /// iDMA response type
    parameter type         idma_rsp_t     = idma_rt_midend_synth_pkg::idma_rsp_t,
    /// *DO NOT OVERWRITE*: Derived event counter type.
    parameter type         event_cnt_t    = logic [EventCntWidth-1:0]
)(
    /// Clock
    input  logic         clk_i,
    /// Asynchronous reset, active low
    input  logic         rst_ni,
    /// The threshold an event is triggered
    input  event_cnt_t [NumEvents-1:0] event_counts_i,
    /// The source address of the event
    input  addr_t      [NumEvents-1:0] src_addr_i,
    /// The destination address of the event
    input  addr_t      [NumEvents-1:0] dst_addr_i,
    /// The length of the event
    input  addr_t      [NumEvents-1:0] length_i,
    /// The source stride of the event
    input  addr_t      [NumEvents-1:0] src_1d_stride_i,
    /// The destination stride of the event
    input  addr_t      [NumEvents-1:0] dst_1d_stride_i,
    /// The number of repetitions of the event
    input  addr_t      [NumEvents-1:0] num_1d_reps_i,
    /// The source stride of the event
    input  addr_t      [NumEvents-1:0] src_2d_stride_i,
    /// The destination stride of the event
    input  addr_t      [NumEvents-1:0] dst_2d_stride_i,
    /// The number of repetitions of the event
    input  addr_t      [NumEvents-1:0] num_2d_reps_i,
    /// Enable the given event
    input  logic       [NumEvents-1:0] event_ena_i,
    /// Current state of the counters (debugging)
    output event_cnt_t [NumEvents-1:0] event_counts_o,
    /// ND iDMA request
    output idma_nd_req_t nd_req_o,
    /// ND iDMA request valid
    output logic         nd_req_valid_o,
    /// ND iDMA request ready
    input  logic         nd_req_ready_i,
    /// iDMA 1D response
    input  idma_rsp_t    burst_rsp_i,
    /// iDMA 1D response valid
    input  logic         burst_rsp_valid_i,
    /// iDMA 1D response ready
    output logic         burst_rsp_ready_o,
    /// Bypass: ND iDMA request
    input  idma_nd_req_t nd_req_i,
    /// Bypass: ND iDMA request valid
    input  logic         nd_req_valid_i,
    /// Bypass: ND iDMA request ready
    output logic         nd_req_ready_o,
    /// Bypass: iDMA 1D response
    output idma_rsp_t    burst_rsp_o,
    /// Bypass: iDMA 1D response valid
    output logic         burst_rsp_valid_o,
    /// Bypass: iDMA 1D response ready
    input  logic         burst_rsp_ready_i
);

    idma_rt_midend #(
        .NumEvents      ( NumEvents      ),
        .EventCntWidth  ( EventCntWidth  ),
        .NumOutstanding ( NumOutstanding ),
        .addr_t         ( addr_t         ),
        .idma_nd_req_t  ( idma_nd_req_t  ),
        .idma_rsp_t     ( idma_rsp_t     )
    ) i_idma_rt_midend (
        .clk_i,
        .rst_ni,
        .event_counts_i,
        .src_addr_i,
        .dst_addr_i,
        .length_i,
        .src_1d_stride_i,
        .dst_1d_stride_i,
        .num_1d_reps_i,
        .src_2d_stride_i,
        .dst_2d_stride_i,
        .num_2d_reps_i,
        .event_ena_i,
        .event_counts_o,
        .nd_req_o,
        .nd_req_valid_o,
        .nd_req_ready_i,
        .burst_rsp_i,
        .burst_rsp_valid_i,
        .burst_rsp_ready_o,
        .nd_req_i,
        .nd_req_valid_i,
        .nd_req_ready_o,
        .burst_rsp_o,
        .burst_rsp_valid_o,
        .burst_rsp_ready_i
    );

endmodule

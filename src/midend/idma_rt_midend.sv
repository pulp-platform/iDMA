// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

/// RT midend for the iDMA
module idma_rt_midend #(
    /// Number of parallel events
    parameter int unsigned NumEvents      = 32'd1,
    /// The width of the event counters (count multiple of clock period)
    parameter int unsigned EventCntWidth  = 32'd32,
    /// Number of outstanding DMA events
    parameter int unsigned NumOutstanding = 32'd2,
    /// Address type
    parameter type         addr_t         = logic,
    /// ND iDMA request type
    parameter type         idma_nd_req_t  = logic,
    /// iDMA response type
    parameter type         idma_rsp_t     = logic,
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

    typedef struct packed {
        idma_nd_req_t req;
        logic         src;
    } ext_arb_t;

    // signals around the external arbiter
    ext_arb_t ext_req, int_req, out_req;

    // the choice signal
    logic choice, choice_head;

    // counter overflow -> event is valid
    logic [NumEvents-1:0] event_valid;

    // handshake the event
    logic [NumEvents-1:0] event_ready;

    // clear signal for the counter
    logic [NumEvents-1:0] cnt_load;

    // enable signal for the counter
    logic [NumEvents-1:0] cnt_ena;

    // each counter assembles the struct
    idma_nd_req_t [NumEvents-1:0] idma_nd_req;

    // internal request and its handshake signals
    idma_nd_req_t idma_nd_req_int;
    logic         nd_req_valid_int;
    logic         nd_req_ready_int;

    // internal response stub
    idma_rsp_t   int_rsp;
    logic        int_valid;

    // generate the counters timing the events and assemble the transfers
    for (genvar c = 0; c < NumEvents; c++) begin : gen_counters
        // counter instance
        counter #(
            .WIDTH           ( EventCntWidth ),
            .STICKY_OVERFLOW (  1'b0         )
        ) i_counter (
            .clk_i,
            .rst_ni,
            .clear_i    ( 1'b0               ),
            .en_i       ( cnt_ena        [c] ),
            .load_i     ( cnt_load       [c] ),
            .down_i     ( 1'b1               ),
            .d_i        ( event_counts_i [c] ),
            .q_o        ( event_counts_o [c] ),
            .overflow_o ( event_valid    [c] )
        );

        // n-d assignment
        assign idma_nd_req[c].d_req[0].reps        = num_1d_reps_i   [c];
        assign idma_nd_req[c].d_req[0].src_strides = src_1d_stride_i [c];
        assign idma_nd_req[c].d_req[0].dst_strides = dst_1d_stride_i [c];
        assign idma_nd_req[c].d_req[1].reps        = num_1d_reps_i   [c];
        assign idma_nd_req[c].d_req[1].src_strides = src_1d_stride_i [c];
        assign idma_nd_req[c].d_req[1].dst_strides = dst_1d_stride_i [c];

        // 1D assignment
        assign idma_nd_req[c].burst_req.length   = length_i   [c];
        assign idma_nd_req[c].burst_req.src_addr = src_addr_i [c];
        assign idma_nd_req[c].burst_req.dst_addr = dst_addr_i [c];
        assign idma_nd_req[c].burst_req.opt      = '0;

    end

    // clear on handshake
    assign cnt_load = event_ready & event_valid;

    // disable counters if they are valid
    assign cnt_ena   = event_ena_i & ~(event_valid);

    // arbitrates the events
    stream_arbiter #(
        .DATA_T  ( idma_nd_req_t ),
        .N_INP   ( NumEvents     ),
        .ARBITER ( "rr"          )
    ) i_stream_arbiter (
        .clk_i,
        .rst_ni,
        .inp_data_i  ( idma_nd_req      ),
        .inp_valid_i ( event_valid      ),
        .inp_ready_o ( event_ready      ),
        .oup_data_o  ( idma_nd_req_int  ),
        .oup_valid_o ( nd_req_valid_int ),
        .oup_ready_i ( nd_req_ready_int )
    );

    // arbitrates the events
    stream_arbiter #(
        .DATA_T  ( ext_arb_t     ),
        .N_INP   ( 32'd2         ),
        .ARBITER ( "rr"          )
    ) i_stream_arbiter_bypass (
        .clk_i,
        .rst_ni,
        .inp_data_i  ( { ext_req,        int_req          } ),
        .inp_valid_i ( { nd_req_valid_i, nd_req_valid_int } ),
        .inp_ready_o ( { nd_req_ready_o, nd_req_ready_int } ),
        .oup_data_o  ( out_req                              ),
        .oup_valid_o ( nd_req_valid_o                       ),
        .oup_ready_i ( nd_req_ready_i                       )
    );

    // assemble arbiter inputs
    assign ext_req.req = nd_req_i;
    assign ext_req.src = 1'b1;

    assign int_req.req = idma_nd_req_int;
    assign int_req.src = 1'b0;

    // arbiters outputs
    assign nd_req_o = out_req.req;
    assign choice   = out_req.src;

    // safe the choice in a fifo
    stream_fifo #(
        .FALL_THROUGH ( 1'b0           ),
        .DATA_WIDTH   ( 32'd1          ),
        .DEPTH        ( NumOutstanding )
    ) i_stream_fifo (
        .clk_i,
        .rst_ni,
        .flush_i    ( 1'b0                                  ),
        .testmode_i ( 1'b0                                  ),
        .usage_o    ( /* NC */                              ),
        .data_i     ( choice                                ),
        .valid_i    ( nd_req_valid_i & nd_req_ready_o       ),
        .ready_o    ( /* HACK: NC */                        ),
        .data_o     ( choice_head                           ),
        .valid_o    ( /* HACK: NC */                        ),
        .ready_i    ( burst_rsp_valid_o & burst_rsp_ready_i )
    );

    // arbitration of responses
    stream_demux #(
        .N_OUP       ( 32'd2 )
    ) i_stream_demux (
        .inp_valid_i ( burst_rsp_valid_i                ),
        .inp_ready_o ( burst_rsp_ready_o                ),
        .oup_sel_i   ( choice_head                      ),
        .oup_valid_o ( { burst_rsp_valid_o, int_valid } ),
        .oup_ready_i ( { burst_rsp_ready_i, 1'b1      } )
    );

    assign burst_rsp_o = burst_rsp_i;

endmodule

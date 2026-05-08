// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "common_cells/registers.svh"
`include "axi/typedef.svh"

/// Couples the `R` to the `AW` channel by keeping writes back until the corresponding
/// reads arrive at the DMA. This reduces the congestion in the memory system.
module idma_channel_coupler #(
    /// Number of transaction that can be in-flight concurrently
    parameter int unsigned NumAxInFlight = 32'd2,
    /// Address width
    parameter int unsigned AddrWidth = 32'd24,
    /// AXI user width
    parameter int unsigned UserWidth = 32'd1,
    /// AXI ID width
    parameter int unsigned AxiIdWidth = 32'd1,
    /// Print the info of the FIFO configuration
    parameter bit PrintFifoInfo = 1'b0,
    /// AXI 4 `AW` channel type
    parameter type axi_aw_chan_t = logic
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,
    /// Testmode in
    input  logic testmode_i,

    /// R response valid
    input  logic r_rsp_valid_i,
    /// R response ready
    input  logic r_rsp_ready_i,
    /// First R response
    input  logic r_rsp_first_i,
    /// Did the read originate from a decoupled request
    input  logic r_decouple_aw_i,
    /// Is the `AW` in the queue a decoupled request?
    input  logic aw_decouple_aw_i,

    /// Original meta request
    input  axi_aw_chan_t aw_req_i,
    /// Original meta request valid
    input  logic aw_valid_i,
    /// Original meta request ready
    output logic aw_ready_o,

    /// Modified meta request
    output axi_aw_chan_t aw_req_o,
    /// Modified meta request valid
    output logic aw_valid_o,
    /// Modified meta request ready
    input  logic aw_ready_i,
    /// busy signal
    output logic busy_o
);

    /// The width of the credit counter keeping track of the transfers
    localparam int unsigned CounterWidth = cf_math_pkg::idx_width(NumAxInFlight);

    /// Credit counter type
    typedef logic [CounterWidth-1:0] cnt_t;
    /// Address type
    typedef logic [AddrWidth-1:0]    addr_t;
    /// User type
    typedef logic [UserWidth-1:0]    user_t;
    /// ID type
    typedef logic [AxiIdWidth-1:0]   id_t;

    // cut signals after the fifo
    logic    aw_ready, aw_valid;
    logic    aw_decoupled_head;

    // first R arrives -> AW can be sent
    logic first;

    // aw ready i decoupled
    logic aw_ready_decoupled;

    // aw is being sent
    logic aw_sent;

    // counter to keep track of AR to send
    cnt_t aw_to_send_d, aw_to_send_q;

    // first signal -> an R has arrived that needs to free an AW
    assign first = r_rsp_valid_i & r_rsp_ready_i & r_rsp_first_i & !r_decouple_aw_i;

    // stream fifo to hold AWs back
    stream_fifo_optimal_wrap #(
        .Depth        ( NumAxInFlight ),
        .type_t       ( axi_aw_chan_t ),
        .PrintInfo    ( PrintFifoInfo )
    ) i_aw_store (
        .clk_i,
        .rst_ni,
        .testmode_i,
        .flush_i      ( 1'b0                ),
        .usage_o      ( /* NOT CONNECTED */ ),
        .data_i       ( aw_req_i            ),
        .valid_i      ( aw_valid_i          ),
        .ready_o      ( aw_ready_o          ),
        .data_o       ( aw_req_o            ),
        .valid_o      ( aw_valid            ),
        .ready_i      ( aw_ready            )
    );

    stream_fifo_optimal_wrap #(
        .Depth        ( NumAxInFlight ),
        .type_t       ( logic         ),
        .PrintInfo    ( PrintFifoInfo )
    ) i_aw_decoupled_store (
        .clk_i,
        .rst_ni,
        .testmode_i,
        .flush_i      ( 1'b0                ),
        .usage_o      ( /* NOT CONNECTED */ ),
        .data_i       ( aw_decouple_aw_i    ),
        .valid_i      ( aw_valid_i          ),
        .ready_o      ( /* NOT CONNECTED */ ),
        .data_o       ( aw_decoupled_head   ),
        .valid_o      ( /* NOT CONNECTED */ ),
        .ready_i      ( aw_ready            )
    );

    // use a credit counter to keep track of coupled AWs to send.
    //
    // The credit `aw_to_send_q` represents *coupled* AWs whose `first` R
    // beat has arrived but that have not yet been handshaken. Decoupled
    // AWs do not earn a credit. Pop a decoupled AW that happens to sit at
    // the head separately (via the default `aw_sent = aw_decoupled_head &
    // aw_valid`) so it does not consume a coupled credit reserved for a
    // coupled AW further back in the FIFO.
    always_comb begin : proc_credit_cnt

        // defaults
        aw_to_send_d = aw_to_send_q;

        // bypass: a decoupled head can always be sent
        aw_sent = aw_decoupled_head & aw_valid;

        // First arrives and the *coupled* head is ready -> send it
        // without changing the credit counter.
        if (aw_ready_decoupled & first & ~aw_decoupled_head) begin
            aw_sent = 1'b1;
        end

        // First arrives but we cannot send the corresponding coupled AW
        // *this cycle* (either downstream isn't ready, or the FIFO head is
        // currently a decoupled AW that has not yet been popped). Save the
        // first as a credit for the future coupled AW.
        else if (first) begin
            aw_to_send_d = aw_to_send_q + 1;
        end

        // No new first this cycle, downstream ready, head is coupled,
        // credit available -> drain one credit.
        else if (aw_ready_decoupled & ~aw_decoupled_head & aw_to_send_q != '0) begin
            aw_sent = 1'b1;
            aw_to_send_d = aw_to_send_q - 1;
        end
    end

    // assign outputs
    assign aw_ready = aw_valid_o & aw_ready_i;

    // fall through register to decouple the aw valid signal from the aw ready
    // now payload is required; just the decoupling of the handshaking signals
    fall_through_register #(
        .T ( logic [0:0] )
    ) i_fall_through_register_decouple_aw_valid (
        .clk_i,
        .rst_ni,
        .testmode_i,
        .clr_i       ( 1'b0                ),
        .valid_i     ( aw_sent             ),
        .ready_o     ( aw_ready_decoupled  ),
        .data_i      ( 1'b0                ),
        .valid_o     ( aw_valid_o          ),
        .ready_i     ( aw_ready_i          ),
        .data_o      ( /* NOT CONNECTED */ )
    );

    // connect busy pin
    assign busy_o = aw_valid;

    // state
    `FF(aw_to_send_q, aw_to_send_d, '0, clk_i, rst_ni)


endmodule

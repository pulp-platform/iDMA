// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

/// A byte-granular buffer holding data while it is copied.
module idma_dataflow_element #(
    /// The depth of the buffer
    parameter int unsigned BufferDepth = 32'd3,
    /// A full lane accepts a push in the cycle it is popped
    parameter bit SameCycleRW = 1'b1,
    /// Lanes with registered full/empty flags and pointers without load enables
    parameter bit RegFlags = 1'b0,
    /// The width of the buffer in bytes
    parameter int unsigned StrbWidth = 32'd1,
    /// Print the info of the FIFO configuration
    parameter bit PrintFifoInfo = 1'b0,
    /// The strobe type
    parameter type strb_t = logic,
    /// The byte type
    parameter type byte_t = logic [7:0]
)(
    input  logic clk_i,
    input  logic rst_ni,

    input  byte_t [StrbWidth-1:0] data_i,
    input  strb_t valid_i,
    output strb_t ready_o,

    output byte_t [StrbWidth-1:0] data_o,
    output strb_t valid_o,
    input  strb_t ready_i
);

    // buffer is implemented as an array of FIFOs
    for (genvar i = 0; i < StrbWidth; i++) begin : gen_fifo_buffer
        if (!RegFlags) begin : gen_stock
            cc_passthrough_stream_fifo #(
                .data_t       ( byte_t        ),
                .Depth        ( BufferDepth   ),
                .PrintInfo    ( PrintFifoInfo ),
                .SameCycleRW  ( SameCycleRW   )
            ) i_passthrough_stream_fifo (
                .clk_i,
                .rst_ni,
                .clr_i        ( 1'b0        ),
                .flush_i      ( 1'b0        ),
                .data_i       ( data_i  [i] ),
                .valid_i      ( valid_i [i] ),
                .ready_o      ( ready_o [i] ),
                .data_o       ( data_o  [i] ),
                .valid_o      ( valid_o [i] ),
                .ready_i      ( ready_i [i] )
            );
        end else begin : gen_reg_flags
            localparam int unsigned PtrW = (BufferDepth > 32'd1) ? $clog2(BufferDepth) : 32'd1;
            localparam int unsigned CntW = $clog2(BufferDepth + 32'd1);

            byte_t [BufferDepth-1:0] mem_q;
            logic  [PtrW-1:0]        wptr_q, rptr_q, wptr_inc, rptr_inc;
            logic  [CntW-1:0]        cnt_q, cnt_d;
            logic                    full_q, empty_q, push, pop;

            assign ready_o[i] = ~full_q | (SameCycleRW & pop);
            assign valid_o[i] = ~empty_q;
            assign data_o[i]  = mem_q[rptr_q];
            assign push       = valid_i[i] & ready_o[i];
            assign pop        = ready_i[i] & ~empty_q;
            assign wptr_inc   = (wptr_q == PtrW'(BufferDepth - 1)) ? '0 : wptr_q + 1'b1;
            assign rptr_inc   = (rptr_q == PtrW'(BufferDepth - 1)) ? '0 : rptr_q + 1'b1;
            assign cnt_d      = cnt_q + CntW'(push) - CntW'(pop);

            always_ff @(posedge clk_i or negedge rst_ni) begin : proc_state
                if (!rst_ni) begin
                    wptr_q  <= '0;
                    rptr_q  <= '0;
                    cnt_q   <= '0;
                    full_q  <= 1'b0;
                    empty_q <= 1'b1;
                end else begin
                    wptr_q  <= (wptr_inc & {PtrW{push}}) | (wptr_q & {PtrW{~push}});
                    rptr_q  <= (rptr_inc & {PtrW{pop}})  | (rptr_q & {PtrW{~pop}});
                    cnt_q   <= cnt_d;
                    full_q  <= cnt_d == CntW'(BufferDepth);
                    empty_q <= cnt_d == '0;
                end
            end

            // the slot at the write pointer takes the input every cycle the lane can accept
            for (genvar k = 0; k < BufferDepth; k++) begin : gen_slot
                always_ff @(posedge clk_i or negedge rst_ni) begin : proc_slot
                    if (!rst_ni)                                 mem_q[k] <= '0;
                    else if (ready_o[i] && (wptr_q == PtrW'(k))) mem_q[k] <= data_i[i];
                end
            end
        end
    end : gen_fifo_buffer

endmodule

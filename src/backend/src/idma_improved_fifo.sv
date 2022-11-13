// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz  <tbenz@ethz.ch>
// Tobias Senti <tsenti@student.ethz.ch> 

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"
`include "idma/guard.svh"

/// Optimal implementation of a stream FIFO
module idma_improved_fifo #(
    /// Depth can be arbitrary from 2 to 2**32
    parameter int unsigned Depth = 32'd8,
    /// Type of the FIFO
    parameter type type_t = logic,
    /// Print information when the simulation launches
    parameter bit PrintInfo = 1'b0,
    /// If the FIFO is full, allow reading and writing in the same cycle
    parameter bit SameCycleRW = 1'b1
) (
    input  logic                 clk_i,      // Clock
    input  logic                 rst_ni,     // Asynchronous reset active low
    input  logic                 flush_i,    // flush the fifo
    input  logic                 testmode_i, // test_mode to bypass clock gating
    // input interface
    input  type_t                data_i,     // data to push into the fifo
    input  logic                 valid_i,    // input data valid
    output logic                 ready_o,    // fifo is not full
    // output interface
    output type_t                data_o,     // output data
    output logic                 valid_o,    // fifo is not empty
    input  logic                 ready_i     // pop head from fifo
);
    // Bit Width of the read and write pointers
    // One additional bit to detect overflows
    localparam PointerWidth = $clog2(Depth) + 1;

    //--------------------------------------
    // Prevent Depth 0
    //--------------------------------------
    // Throw an error if depth is 0 and 1
    `IDMA_NONSYNTH_BLOCK(
    if (Depth < 32'd2) begin : gen_fatal
        initial begin
            $fatal(1, "FIFO of depth %d does not make any sense!", Depth);
        end
    end
    )

    // print info
    `IDMA_NONSYNTH_BLOCK(
    if (PrintInfo) begin : gen_info
        initial begin
            $info("[%m] Instantiate stream FIFO of depth %d with Pointer Width of %d", Depth, PointerWidth);
        end
    end
    )

    // Read and write pointers
    logic [PointerWidth-1:0]  read_ptr_d,  read_ptr_q;
    logic [PointerWidth-1:0] write_ptr_d, write_ptr_q;

    // Data
    type_t [Depth-1 :0] data_d, data_q;

    // Data Clock gate
    logic clock_gate;

    assign data_o = data_q[read_ptr_q[PointerWidth-2:0]];

    // Logic
    always_comb begin
        // Default
        clock_gate  = 1'b0;
        read_ptr_d  = read_ptr_q;
        write_ptr_d = write_ptr_q;
        data_d      = data_q;

        if (flush_i) begin // Flush
            read_ptr_d  = '0;
            write_ptr_d = '0;
            valid_o     = 1'b0;
            ready_o     = 1'b0;
        end else begin
            // Read
            valid_o = read_ptr_q[PointerWidth-1] == write_ptr_q[PointerWidth-1]
                ? read_ptr_q[PointerWidth-2:0] != write_ptr_q[PointerWidth-2:0] : 1'b1;  
            if (ready_i) begin
                if (read_ptr_q[PointerWidth-2:0] == (Depth-1)) begin
                    // On overflow reset pointer to zero and flip imaginary bit
                    read_ptr_d[PointerWidth-2:0] = '0;
                    read_ptr_d[PointerWidth-1]   = !read_ptr_q[PointerWidth-1];
                end else begin
                    // Increment counter
                    read_ptr_d = read_ptr_q + 'd1;
                end
            end

            // Write -> Also able to write if we read in the same cycle
            ready_o     = (read_ptr_q[PointerWidth-1] == write_ptr_q[PointerWidth-1] 
                ? 1'b1 : write_ptr_q[PointerWidth-2:0] != read_ptr_q[PointerWidth-2:0])
                || (SameCycleRW && ready_i && valid_o);

            if (valid_i) begin
                clock_gate = 1'b1;
                data_d[write_ptr_q[PointerWidth-2:0]] = data_i;
            
                if (write_ptr_q[PointerWidth-2:0] == (Depth-1)) begin
                    // On overflow reset pointer to zero and flip imaginary bit
                    write_ptr_d[PointerWidth-2:0] = '0;
                    write_ptr_d[PointerWidth-1]   = !write_ptr_q[PointerWidth-1];
                end else begin
                    // Increment pointer 
                    write_ptr_d = write_ptr_q + 'd1;
                end
            end
        end
    end

    // Flip Flops
    `FF( read_ptr_q,  read_ptr_d, '0, clk_i, rst_ni)
    `FF(write_ptr_q, write_ptr_d, '0, clk_i, rst_ni)
    
    `FFL(data_q, data_d, clock_gate || testmode_i, '0, clk_i, rst_ni)

    // no full push
    `ASSERT_NEVER(CheckFullPush, (!ready_o & valid_i), clk_i, !rst_ni)
    // empty pop
    `ASSERT_NEVER(CheckEmptyPop, (!valid_o & ready_i), clk_i, !rst_ni)
endmodule : idma_improved_fifo

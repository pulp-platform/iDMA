// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

`include "common_cells/registers.svh"

/// This module implements backpressure via ready/valid handshakes
/// for the regbus registers and exposes it to the descriptor fifo
module idma_desc64_reg_wrapper
import idma_desc64_reg_pkg::idma_desc64_reg2hw_t;
import idma_desc64_reg_pkg::idma_desc64_hw2reg_t; #(
    parameter type reg_req_t  = logic,
    parameter type reg_rsp_t  = logic
) (
    input  logic                clk_i             ,
    input  logic                rst_ni            ,
    input  reg_req_t            reg_req_i         ,
    output reg_rsp_t            reg_rsp_o         ,
    output idma_desc64_reg2hw_t reg2hw_o          ,
    input  idma_desc64_hw2reg_t hw2reg_i          ,
    input  logic                devmode_i         ,
    output logic                input_addr_valid_o,
    input  logic                input_addr_ready_i
);

    import idma_desc64_reg_pkg::IDMA_DESC64_DESC_ADDR_OFFSET;

    reg_req_t request;
    reg_rsp_t response;
    logic     input_addr_valid_q, input_addr_valid_d;

    idma_desc64_reg_top #(
        .reg_req_t (reg_req_t),
        .reg_rsp_t (reg_rsp_t)
    ) i_register_file_controller (
        .clk_i     (clk_i)    ,
        .rst_ni    (rst_ni)   ,
        .reg_req_i (request),
        .reg_rsp_o (response) ,
        .reg2hw    (reg2hw_o) ,
        .hw2reg    (hw2reg_i) ,
        .devmode_i (devmode_i)
    );

    assign request.addr    = reg_req_i.addr;
    assign request.write   = reg_req_i.write;
    assign request.wdata   = reg_req_i.wdata;
    assign request.wstrb   = reg_req_i.wstrb;
    assign reg_rsp_o.rdata = response.rdata;
    assign reg_rsp_o.error = response.error;

    always_comb begin
        if (reg_req_i.addr == IDMA_DESC64_DESC_ADDR_OFFSET) begin
            request.valid = reg_req_i.valid && input_addr_ready_i;
        end else begin
            request.valid = reg_req_i.valid;
        end
    end

    always_comb begin
        // only take into account the fifo if a write is going to it
        if (reg_req_i.addr == IDMA_DESC64_DESC_ADDR_OFFSET) begin
            reg_rsp_o.ready = response.ready && input_addr_ready_i;
            input_addr_valid_o = reg2hw_o.desc_addr.qe || input_addr_valid_q;
        end else begin
            reg_rsp_o.ready = response.ready;
            input_addr_valid_o = '0;
        end
    end

    always_comb begin
        input_addr_valid_d = input_addr_valid_q;
        if (reg2hw_o.desc_addr.qe && !input_addr_ready_i) begin
            input_addr_valid_d = 1'b1;
        end else if (input_addr_ready_i) begin
            input_addr_valid_d = '0;
        end
    end
    `FF(input_addr_valid_q, input_addr_valid_d, '0)

endmodule

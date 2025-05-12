// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

`include "common_cells/registers.svh"

/// This module implements backpressure via ready/valid handshakes
/// for the regbus registers and exposes it to the descriptor fifo
module idma_desc64_reg_wrapper
import idma_desc64_reg_pkg::idma_desc64_reg__out_t;
import idma_desc64_reg_pkg::idma_desc64_reg__in_t; #(
    parameter type apb_req_t  = logic,
    parameter type apb_rsp_t  = logic
) (
    input  logic                  clk_i             ,
    input  logic                  rst_ni            ,
    input  apb_req_t              apb_req_i         ,
    output apb_rsp_t              apb_rsp_o         ,
    output idma_desc64_reg__out_t reg2hw_o          ,
    input  idma_desc64_reg__in_t  hw2reg_i          ,
    input  logic                  devmode_i         ,
    output logic                  input_addr_valid_o,
    input  logic                  input_addr_ready_i
);

    import idma_desc64_addrmap_pkg::IDMA_DESC64_REG_DESC_ADDR_REG_OFFSET;
    import idma_desc64_addrmap_pkg::IDMA_DESC64_REG_STATUS_REG_OFFSET;

    logic     apb_psel, apb_psel_q, apb_penable, apb_pready;
    logic     input_addr_valid_q, input_addr_valid_d;

    idma_desc64_reg i_register_file_controller (
        .clk       (clk_i)    ,
        .arst_n    (rst_ni)   ,

        .s_apb_psel    (apb_psel) ,
        .s_apb_penable (apb_penable) ,
        .s_apb_pwrite  (apb_req_i.pwrite) ,
        .s_apb_pprot   (apb_req_i.pprot) ,
        .s_apb_paddr   (apb_req_i.paddr) ,
        .s_apb_pwdata  (apb_req_i.pwdata) ,
        .s_apb_pstrb   (apb_req_i.pstrb) ,
        .s_apb_pready  (apb_pready) ,
        .s_apb_prdata  (apb_rsp_o.prdata) ,
        .s_apb_pslverr (apb_rsp_o.pslverr) ,

        .reg2hw    (reg2hw_o) ,
        .hw2reg    (hw2reg_i)
    );

    assign apb_penable = apb_psel_q & apb_req_i.penable;

    always_comb begin
        if (apb_req_i.paddr == IDMA_DESC64_REG_DESC_ADDR_REG_OFFSET) begin
            apb_psel = apb_req_i.psel & input_addr_ready_i;
        end else begin
            apb_psel = apb_req_i.psel;
        end
    end

    assign input_addr_valid_o = input_addr_valid_q;

    always_comb begin
        // only take into account the fifo if a write is going to it
        if (apb_req_i.paddr == IDMA_DESC64_REG_DESC_ADDR_REG_OFFSET) begin
            apb_rsp_o.pready = apb_pready & (input_addr_ready_i | ~input_addr_valid_q);
        end else begin
            apb_rsp_o.pready = apb_pready;
        end
    end

    always_comb begin
        input_addr_valid_d = input_addr_valid_q;
        if (input_addr_ready_i) begin
            input_addr_valid_d = '0;
        end
        if (reg2hw_o.desc_addr.swmod) begin
            input_addr_valid_d = 1'b1;
        end
    end

    `FF(input_addr_valid_q, input_addr_valid_d, '0);
    `FF(apb_psel_q, apb_psel, '0);

endmodule

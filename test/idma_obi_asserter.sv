// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Tobias Senti <tsenti@student.ethz.ch>

`include "common_cells/assertions.svh"

/// Checks for compliance with the OBI spec !!!Not complete!!!
module idma_obi_asserter #(
    parameter type obi_master_req_t = logic,
    parameter type obi_master_rsp_t = logic
) (
    input logic clk_i,
    input logic rst_ni,

    input obi_master_req_t obi_master_req_i,
    input obi_master_rsp_t obi_master_rsp_i
);
    //R-2.1
    `ASSERT(OBIAReqLowDuringReset, !rst_ni |-> !obi_master_req_i.a_req, clk_i, 1'b0)
    //R-2.2
    `ASSERT(OBIRValidLowDuringReset, !rst_ni |-> !obi_master_rsp_i.r_valid, clk_i, 1'b0)

    //R-3.1 - Stable during address phase
    `ASSERT(OBIReadStableDuringAddressPhase, ((obi_master_req_i.a_req && !obi_master_req_i.a.we && !obi_master_rsp_i.a_gnt) |=> 
        $stable({obi_master_req_i.a_req, obi_master_req_i.a.we, obi_master_req_i.a.addr, obi_master_req_i.a.be})), clk_i, !rst_ni)

    `ASSERT(OBIWriteStableDuringAddressPhase, ((obi_master_req_i.a_req && obi_master_req_i.a.we && !obi_master_rsp_i.a_gnt) |=> 
        $stable({obi_master_req_i.a_req, obi_master_req_i.a})), clk_i, !rst_ni)

    //R-4.1 - Stable during response phase
    `ASSERT(OBIStableDuringResponsePhase, ((obi_master_rsp_i.r_valid && !obi_master_req_i.r_ready) |=> 
        $stable({obi_master_rsp_i.r_valid, obi_master_rsp_i.r})), clk_i, !rst_ni)

    //R-5 - Response phase should only be sent after the corresponding address phase has ended

endmodule : idma_obi_asserter

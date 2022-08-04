// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz <tbenz@ethz.ch>

`include "idma/typedef.svh"

/// The driver interface for the iDMA backend
interface IDMA_DV #(
    parameter int unsigned DataWidth = 0,
    parameter int unsigned AddrWidth = 0,
    parameter int unsigned UserWidth = 0,
    parameter int unsigned AxiIdWidth = 0,
    parameter int unsigned TFLenWidth = 0
) (
    input logic clk_i
);

    // derived parameters
    localparam int unsigned StrbWidth   = DataWidth / 8;
    localparam int unsigned OffsetWidth = $clog2(StrbWidth);

    // derived types
    typedef logic [AddrWidth-1:0]   addr_t;
    typedef logic [DataWidth-1:0]   data_t;
    typedef logic [StrbWidth-1:0]   strb_t;
    typedef logic [UserWidth-1:0]   user_t;
    typedef logic [AxiIdWidth-1:0]  id_t;
    typedef logic [OffsetWidth-1:0] offset_t;
    typedef logic [TFLenWidth-1:0]  tf_len_t;

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

    // the signals
    idma_req_t              req;
    logic                   req_valid;
    logic                   req_ready;

    idma_rsp_t              rsp;
    logic                   rsp_valid;
    logic                   rsp_ready;

    idma_pkg::idma_eh_req_t eh_req;
    logic                   eh_req_valid;
    logic                   eh_req_ready;

    // used for the driver
    modport Master (
        output req, req_valid,       input  req_ready,
        input  rsp, rsp_valid,       output rsp_ready,
        output eh_req, eh_req_valid, input  eh_req_ready
    );

    // currently not needed
    modport Slave (
        input  req, req_valid,       output req_ready,
        output rsp, rsp_valid,       input  rsp_ready,
        input  eh_req, eh_req_valid, output eh_req_ready
    );

endinterface : IDMA_DV



/// The driver interface for the iDMA with the ND-midend attached
interface IDMA_ND_DV #(
    parameter int unsigned DataWidth   = 0,
    parameter int unsigned AddrWidth   = 0,
    parameter int unsigned UserWidth   = 0,
    parameter int unsigned AxiIdWidth  = 0,
    parameter int unsigned TFLenWidth  = 0,
    parameter int unsigned NumDim      = 0,
    parameter int unsigned RepWidth    = 0,
    parameter int unsigned StrideWidth = 0
) (
    input logic clk_i
);

    // derived parameters
    localparam int unsigned StrbWidth   = DataWidth / 8;
    localparam int unsigned OffsetWidth = $clog2(StrbWidth);

    // derived types
    typedef logic [AddrWidth-1:0]   addr_t;
    typedef logic [DataWidth-1:0]   data_t;
    typedef logic [StrbWidth-1:0]   strb_t;
    typedef logic [UserWidth-1:0]   user_t;
    typedef logic [AxiIdWidth-1:0]  id_t;
    typedef logic [OffsetWidth-1:0] offset_t;
    typedef logic [TFLenWidth-1:0]  tf_len_t;
    typedef logic [RepWidth-1:0]    reps_t;
    typedef logic [StrideWidth-1:0] strides_t;

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

    // iDMA ND request
    `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)

    // the signals
    idma_nd_req_t           req;
    logic                   req_valid;
    logic                   req_ready;

    idma_rsp_t              rsp;
    logic                   rsp_valid;
    logic                   rsp_ready;

    idma_pkg::idma_eh_req_t eh_req;
    logic                   eh_req_valid;
    logic                   eh_req_ready;

    // used for the driver
    modport Master (
        output req, req_valid,       input  req_ready,
        input  rsp, rsp_valid,       output rsp_ready,
        output eh_req, eh_req_valid, input  eh_req_ready
    );

    // currently not needed
    modport Slave (
        input  req, req_valid,       output req_ready,
        output rsp, rsp_valid,       input  rsp_ready,
        input  eh_req, eh_req_valid, output eh_req_ready
    );

endinterface : IDMA_ND_DV

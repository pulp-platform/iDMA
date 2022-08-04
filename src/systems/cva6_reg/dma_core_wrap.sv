// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Thomas Benz    <tbenz@iis.ee.ethz.ch>
// Author: Andreas Kuster <kustera@ethz.ch>
//
// Description: DMA core wrapper for the CVA6 integration

`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "idma/typedef.svh"
`include "register_interface/typedef.svh"

module dma_core_wrap #(
  parameter int unsigned AXI_ADDR_WIDTH     = -1,
  parameter int unsigned AXI_DATA_WIDTH     = -1,
  parameter int unsigned AXI_USER_WIDTH     = -1,
  parameter int unsigned AXI_ID_WIDTH       = -1,
  parameter int unsigned AXI_SLV_ID_WIDTH   = -1
) (
  input  logic   clk_i,
  input  logic   rst_ni,
  input  logic   testmode_i,
  AXI_BUS.Master axi_master,
  AXI_BUS.Slave  axi_slave
);
  localparam int unsigned DmaRegisterWidth = 64;

  typedef logic [AXI_ADDR_WIDTH-1:0]     addr_t;
  typedef logic [AXI_DATA_WIDTH-1:0]     data_t;
  typedef logic [(AXI_DATA_WIDTH/8)-1:0] strb_t;
  typedef logic [AXI_USER_WIDTH-1:0]     user_t;
  typedef logic [AXI_ID_WIDTH-1:0]       axi_id_t;
  typedef logic [AXI_SLV_ID_WIDTH-1:0]   axi_slv_id_t;


  `AXI_TYPEDEF_ALL(axi_mst, addr_t, axi_id_t, data_t, strb_t, user_t)
  axi_mst_req_t axi_mst_req;
  axi_mst_resp_t axi_mst_resp;
  `AXI_ASSIGN_FROM_REQ(axi_master, axi_mst_req)
  `AXI_ASSIGN_TO_RESP(axi_mst_resp, axi_master)

  `AXI_TYPEDEF_ALL(axi_slv, addr_t, axi_slv_id_t, data_t, strb_t, user_t)
  axi_slv_req_t axi_slv_req;
  axi_slv_resp_t axi_slv_resp;
  `AXI_ASSIGN_TO_REQ(axi_slv_req, axi_slave)
  `AXI_ASSIGN_FROM_RESP(axi_slave, axi_slv_resp)

  // iDMA struct definitions
  localparam int unsigned TFLenWidth  = AXI_ADDR_WIDTH;
  typedef logic [TFLenWidth-1:0]  tf_len_t;

  // iDMA request / response types
  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_slv_id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

  `REG_BUS_TYPEDEF_ALL(dma_regs, logic[5:0], logic[63:0], logic[7:0])

  burst_req_t burst_req;
  logic be_valid, be_ready, be_trans_complete;
  idma_pkg::idma_busy_t idma_busy;

  dma_regs_req_t dma_regs_req;
  dma_regs_rsp_t dma_regs_rsp;

  axi_to_reg #(
    .ADDR_WIDTH( AXI_ADDR_WIDTH   ),
    .DATA_WIDTH( AXI_DATA_WIDTH   ),
    .ID_WIDTH  ( AXI_SLV_ID_WIDTH ),
    .USER_WIDTH( AXI_USER_WIDTH   ),
    .axi_req_t ( axi_slv_req_t    ),
    .axi_rsp_t ( axi_slv_resp_t   ),
    .reg_req_t ( dma_regs_req_t   ),
    .reg_rsp_t ( dma_regs_rsp_t   )
  ) i_axi_translate (
    .clk_i,
    .rst_ni,
    .testmode_i ( 1'b0         ),
    .axi_req_i  ( axi_slv_req  ),
    .axi_rsp_o  ( axi_slv_resp ),
    .reg_req_o  ( dma_regs_req ),
    .reg_rsp_i  ( dma_regs_rsp )
  );


  /*
   * DMA Frontend
   */
  idma_reg64_frontend #(
    .DmaAddrWidth    ( AXI_ADDR_WIDTH ),
    .dma_regs_req_t  ( dma_regs_req_t ),
    .dma_regs_rsp_t  ( dma_regs_rsp_t ),
    .burst_req_t     ( burst_req_t     )
  ) i_dma_frontend (
    .clk_i,
    .rst_ni,
    // AXI slave: control port
    .dma_ctrl_req_i   ( dma_regs_req      ),
    .dma_ctrl_rsp_o   ( dma_regs_rsp      ),
    // Backend control
    .burst_req_o      ( burst_req         ),
    .valid_o          ( be_valid          ),
    .ready_i          ( be_ready          ),
    .backend_idle_i   ( ~|idma_busy       ),
    .trans_complete_i ( be_trans_complete )
  );

  idma_backend #(
    .DataWidth           ( AXI_DATA_WIDTH              ),
    .AddrWidth           ( AXI_ADDR_WIDTH              ),
    .UserWidth           ( AXI_USER_WIDTH              ),
    .AxiIdWidth          ( AXI_ID_WIDTH                ),
    .NumAxInFlight       ( 2                           ),
    .BufferDepth         ( 3                           ),
    .TFLenWidth          ( TFLenWidth                  ),
    .RAWCouplingAvail    ( 1'b1                        ),
    .MaskInvalidData     ( 1'b1                        ),
    .HardwareLegalizer   ( 1'b1                        ),
    .RejectZeroTransfers ( 1'b1                        ),
    .MemSysDepth         ( 32'd0                       ),
    .ErrorCap            ( idma_pkg::NO_ERROR_HANDLING ),
    .idma_req_t          ( idma_req_t                  ),
    .idma_rsp_t          ( idma_rsp_t                  ),
    .idma_eh_req_t       ( idma_pkg::idma_eh_req_t     ),
    .idma_busy_t         ( idma_pkg::idma_busy_t       ),
    .axi_req_t           ( axi_slv_req_t               ),
    .axi_rsp_t           ( axi_slv_resp_t              )
  ) i_idma_backend (
    .clk_i,
    .rst_ni,
    .testmode_i    ( testmode_i        ),

    .idma_req_i    ( burst_req         ),
    .req_valid_i   ( be_valid          ),
    .req_ready_o   ( be_ready          ),

    .idma_rsp_o    ( /*NOT CONNECTED*/ ),
    .rsp_valid_o   ( be_trans_complete ),
    .rsp_ready_i   ( 1'b1              ),

    .idma_eh_req_i ( '0                ), // No error handling
    .eh_req_valid_i( 1'b1              ),
    .eh_req_ready_o( /*NOT CONNECTED*/ ),

    .axi_req_o     ( axi_mst_req       ),
    .axi_rsp_i     ( axi_mst_resp      ),
    .busy_o        ( idma_busy         )
  );

endmodule : dma_core_wrap

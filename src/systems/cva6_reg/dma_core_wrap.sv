// Copyright 2019-2022 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Thomas Benz    <tbenz@iis.ee.ethz.ch>
// Author: Andreas Kuster <kustera@ethz.ch>
//
// Description: DMA core wrapper for the CVA6 integration

`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "register_interface/typedef.svh"

module dma_core_wrap #(
  parameter AXI_ADDR_WIDTH     = -1,
  parameter AXI_DATA_WIDTH     = -1,
  parameter AXI_USER_WIDTH     = -1,
  parameter AXI_ID_WIDTH       = -1,
  parameter AXI_SLV_ID_WIDTH   = -1
) (
  input logic          clk_i,
  input logic          rst_ni,
  AXI_BUS.Master axi_master,
  AXI_BUS.Slave  axi_slave
);
  localparam DmaRegisterWidth = 64;

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

  // DMA transfer descriptor
  typedef logic [DmaRegisterWidth-1:0] num_bytes_t;

  // burst request
  typedef struct packed {
    axi_id_t            id;
    addr_t              src, dst;
    num_bytes_t         num_bytes;
    axi_pkg::cache_t    cache_src, cache_dst;
    axi_pkg::burst_t    burst_src, burst_dst;
    logic               decouple_rw;
    logic               deburst;
    logic               serialize;
  } burst_req_t;

  `REG_BUS_TYPEDEF_ALL(dma_regs, logic[5:0], logic[63:0], logic[7:0])

  burst_req_t burst_req;
  logic be_valid, be_ready, be_idle, be_trans_complete;

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
    .backend_idle_i   ( be_idle           ),
    .trans_complete_i ( be_trans_complete )
  );

  axi_dma_backend #(
    .DataWidth      ( AXI_DATA_WIDTH ),
    .AddrWidth      ( AXI_ADDR_WIDTH ),
    .IdWidth        ( AXI_ID_WIDTH   ),
    .AxReqFifoDepth ( 2              ),
    .TransFifoDepth ( 2              ),
    .BufferDepth    ( 3              ),
    .axi_req_t      ( axi_mst_req_t  ),
    .axi_res_t      ( axi_mst_resp_t ),
    .burst_req_t    ( burst_req_t    ),
    .DmaIdWidth     ( 6              ),
    .DmaTracing     ( 0              )
  ) i_dma_backend (
    .clk_i,
    .rst_ni,
    .dma_id_i         ( '0                ),
    .axi_dma_req_o    ( axi_mst_req       ),
    .axi_dma_res_i    ( axi_mst_resp      ),
    .burst_req_i      ( burst_req         ),
    .valid_i          ( be_valid          ),
    .ready_o          ( be_ready          ),
    .backend_idle_o   ( be_idle           ),
    .trans_complete_o ( be_trans_complete )
  );

endmodule : dma_core_wrap
 
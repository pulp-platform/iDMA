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

module dma_core_wrap #(
  parameter AXI_ADDR_WIDTH     = -1,
  parameter AXI_DATA_WIDTH     = -1,
  parameter AXI_USER_WIDTH     = -1,
  parameter AXI_ID_WIDTH       = -1,
  // AXI request/response
  parameter type axi_req_t     = logic,
  parameter type axi_rsp_t     = logic,
  parameter type axi_req_slv_t = logic,
  parameter type axi_rsp_slv_t = logic
) (
  input logic          clk_i,
  input logic          rst_ni,
  // slave port
  input  axi_req_slv_t slv_req_i,
  output axi_rsp_slv_t slv_rsp_o,
  // master port
  output axi_req_t     mst_req_o,
  input  axi_rsp_t     mst_rsp_i
);

  /*
   * DMA Frontend
   */
   dma_frontend #(
     .DmaAxiIdWidth   ( AXI_ID_WIDTH   ),
     .DmaDataWidth    ( AXI_DATA_WIDTH ),
     .DmaAddrWidth    ( AXI_ADDR_WIDTH ),
     .DmaAxiUserWidth ( AXI_USER_WIDTH ),
     .AxiAxReqDepth   ( 2              ),
     .TfReqFifoDepth  ( 2              ),
     .axi_req_t       ( axi_req_t      ),
     .axi_res_t       ( axi_rsp_t      ),
     .axi_req_slv_t   ( axi_req_slv_t  ),
     .axi_rsp_slv_t   ( axi_rsp_slv_t  )
   ) i_dma_frontend (
     .clk_i            ( clk_i     ),
     .rst_ni           ( rst_ni    ),
    // AXI slave: control port
    .axi_dma_ctrl_req_i( slv_req_i ),
    .axi_dma_ctrl_rsp_o( slv_rsp_o ),
    // AXI master: dma port
    .axi_dma_req_o     ( mst_req_o ),
    .axi_dma_rsp_i     ( mst_rsp_i )
   );

 endmodule : dma_core_wrap
 
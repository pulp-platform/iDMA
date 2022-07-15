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
// Description: DMA wrapper module that combines the backend with the frontend, including config and status reg handling

`include "axi/assign.svh"
`include "register_interface/assign.svh"
`include "register_interface/typedef.svh"

module dma_frontend #(
    /// register width
    parameter int  unsigned DmaRegisterWidth = 64,
    /// id width of the DMA AXI Master port
    parameter int  unsigned DmaAxiIdWidth    = -1,
    /// data width of the DMA AXI Master port
    parameter int  unsigned DmaDataWidth     = -1,
    /// address width of the DMA AXI Master port
    parameter int  unsigned DmaAddrWidth     = -1,
    /// user width of the DMA AXI Master port
    parameter int  unsigned DmaAxiUserWidth  = -1,
    /// number of AX requests in-flight
    parameter int  unsigned AxiAxReqDepth    = -1,
    /// number of 1D transfers buffered in backend
    parameter int  unsigned TfReqFifoDepth   = -1, 
    /// data request type
    parameter type          axi_req_t        = logic,
    parameter type          axi_res_t        = logic,
    parameter type          axi_req_slv_t    = logic,
    parameter type          axi_rsp_slv_t    = logic
) (
    input  logic            clk_i,
    input  logic            rst_ni,
    /// control AXI slave
    input  axi_req_slv_t    axi_dma_ctrl_req_i,
    output axi_rsp_slv_t    axi_dma_ctrl_rsp_o,
    /// transfer AXI master
    output axi_req_t        axi_dma_req_o,
    input  axi_res_t        axi_dma_rsp_i
);

    /*
     * Signal and register definitions
     */
    import dma_frontend_reg_pkg::* ;
    `REG_BUS_TYPEDEF_ALL(dma_regs, logic[5:0], logic[DmaDataWidth-1:0], logic[(DmaDataWidth/8)-1:0]) // name, addr_t, data_t, strb_t
    dma_regs_req_t dma_regs_req;
    dma_regs_rsp_t dma_regs_rsp;
    dma_frontend_reg_pkg::dma_frontend_reg2hw_t dma_reg2hw;
    dma_frontend_reg_pkg::dma_frontend_hw2reg_t dma_hw2reg;

    // DMA transfer descriptor
    typedef logic [DmaAddrWidth-1:0]     addr_t;
    typedef logic [DmaRegisterWidth-1:0] num_bytes_t;

    // burst request
    typedef logic [DmaAxiIdWidth-1:0] axi_id_t;
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

    burst_req_t burst_req;

    // transaction id
    logic [DmaAddrWidth-1:0] next_id, done_id;

    // backend signals 
    logic be_ready;
    logic be_valid;
    logic be_idle;
    logic be_trans_complete;


    /*
     * NEW AXI_TO_REG module
     */
    axi_to_reg #(
        .ADDR_WIDTH( DmaAddrWidth             ),
        .DATA_WIDTH( DmaDataWidth             ),
        .ID_WIDTH  ( ariane_soc::IdWidthSlave ),
        .USER_WIDTH( DmaAxiUserWidth          ),
        .axi_req_t ( axi_req_slv_t            ),
        .axi_rsp_t ( axi_rsp_slv_t            ),
        .reg_req_t ( dma_regs_req_t           ),
        .reg_rsp_t ( dma_regs_rsp_t           )
    ) i_axi_translate (
        .clk_i     ( clk_i              ),
        .rst_ni    ( rst_ni             ),
        .testmode_i( 1'b0               ),
        .axi_req_i ( axi_dma_ctrl_req_i ),
        .axi_rsp_o ( axi_dma_ctrl_rsp_o ),
        .reg_req_o ( dma_regs_req       ),
        .reg_rsp_i ( dma_regs_rsp       )
    );


    // /*
    //  * Legacy AXI TO REG
    //  */

    // AXI_BUS #(
    //     .AXI_ADDR_WIDTH ( DmaAddrWidth    ),
    //     .AXI_DATA_WIDTH ( DmaDataWidth    ),
    //     .AXI_ID_WIDTH   ( DmaAxiIdWidth   ),
    //     .AXI_USER_WIDTH ( DmaAxiUserWidth )
    // ) axi_in();

    // REG_BUS #(
    //     .ADDR_WIDTH( DmaAddrWidth ),
    //     .DATA_WIDTH( DmaDataWidth )
    // ) reg_out (
    //     .clk_i     ( clk_i )
    // );
        
    // // convert (axi_req_t, axi_res_t) to AXI_BUS.in
    // `AXI_ASSIGN_FROM_REQ(axi_in, axi_dma_ctrl_req_i)
    // `AXI_ASSIGN_TO_RESP(axi_dma_ctrl_res_o, axi_in)                         

    // // convert REG_BUS.out to (dma_regs_req_t, dma_regs_rsp_t)
    // `REG_BUS_ASSIGN_TO_REQ(dma_regs_req, reg_out)
    // `REG_BUS_ASSIGN_FROM_RSP(reg_out, dma_regs_rsp)

    // axi_to_reg #(
    //     .ADDR_WIDTH( DmaAddrWidth    ),
    //     .DATA_WIDTH( DmaDataWidth    )
    // ) i_axi_translate (
    //     .clk_i     ( clk_i        ),
    //     .rst_ni    ( rst_ni       ),
    //     .testmode_i( 1'b0         ),
    //     .in        ( axi_in       ),
    //     .reg_o     ( reg_out      )
    // );


    /*
     * DMA registers
     */
    dma_frontend_reg_top #(
        .reg_req_t( dma_regs_req_t ),
        .reg_rsp_t( dma_regs_rsp_t )
    ) i_dma_conf_regs (
        .clk_i    ( clk_i        ),
        .rst_ni   ( rst_ni       ),
        .reg_req_i( dma_regs_req ),
        .reg_rsp_o( dma_regs_rsp ),
        .reg2hw   ( dma_reg2hw   ),
        .hw2reg   ( dma_hw2reg   ),
        .devmode_i( 1'b0         ) // if 1, explicit error return for unmapped register access
    );

    /*
     * DMA Control Logic 
     */
    always_comb begin : proc_process_regs

        // reset state
        be_valid             = '0;
        dma_hw2reg.next_id.d = '0;
        dma_hw2reg.done.d    = '0;
        dma_hw2reg.status.d  = be_idle;

        // start transaction upon next_id read (and having a valid config)
        if (dma_reg2hw.next_id.re) begin
           if (dma_reg2hw.num_bytes.q != '0) begin
                be_valid = 1'b1;
                dma_hw2reg.next_id.d = next_id;
           end
        end

        // use full width id from generator
        dma_hw2reg.done.d = done_id;
    end : proc_process_regs


    // map hw register onto generic burst request
    always_comb begin : hw_req_conv
        burst_req             = '0;
        burst_req.src         = dma_reg2hw.src_addr.q;
        burst_req.dst         = dma_reg2hw.dst_addr.q;
        burst_req.num_bytes   = dma_reg2hw.num_bytes.q;
        burst_req.burst_src   = axi_pkg::BURST_INCR;
        burst_req.burst_dst   = axi_pkg::BURST_INCR;
        burst_req.decouple_rw = dma_reg2hw.conf.decouple.q;
        burst_req.deburst     = dma_reg2hw.conf.deburst.q;
        burst_req.serialize   = dma_reg2hw.conf.serialize.q;
    end : hw_req_conv

    /*
     * DMA Backend
     */
    logic issue;
    axi_dma_backend #(
        .DataWidth        ( DmaDataWidth      ),
        .AddrWidth        ( DmaAddrWidth      ),
        .IdWidth          ( DmaAxiIdWidth     ),
        .AxReqFifoDepth   ( AxiAxReqDepth     ),
        .TransFifoDepth   ( TfReqFifoDepth    ),
        .BufferDepth      ( 3                 ), // minimal 3 for full performance
        .axi_req_t        ( axi_req_t         ),
        .axi_res_t        ( axi_res_t         ),
        .burst_req_t      ( burst_req_t       ),
        .DmaIdWidth       ( 6                 ),
        .DmaTracing       ( 0                 )
    ) i_axi_dma_backend   (
        .clk_i            ( clk_i             ),
        .rst_ni           ( rst_ni            ),
        .dma_id_i         ( '0                ),
        .axi_dma_req_o    ( axi_dma_req_o     ),
        .axi_dma_res_i    ( axi_dma_rsp_i     ),
        .burst_req_i      ( burst_req         ),
        .valid_i          ( be_valid          ),
        .ready_o          ( be_ready          ),
        .backend_idle_o   ( be_idle           ),
        .trans_complete_o ( be_trans_complete )
    );

    // only increment issue counter if we have a valid transfer
    assign issue = be_ready & be_valid;

    // transfer id generator
    dma_transfer_id_gen #(
        .IdWidth      ( DmaRegisterWidth  )
    ) i_dma_transfer_id_gen (
        .clk_i        ( clk_i             ),
        .rst_ni       ( rst_ni            ),
        .issue_i      ( issue             ),
        .retire_i     ( be_trans_complete ),
        .next_o       ( next_id           ),
        .completed_o  ( done_id           )
    );

endmodule : dma_frontend

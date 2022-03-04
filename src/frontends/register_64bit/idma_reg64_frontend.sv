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
// Author: Michael Rogenmoser <michaero@iis.ee.ethz.ch>
//
// Description: DMA frontend module that includes 64bit config and status reg handling

module idma_reg64_frontend #(
    /// address width of the DMA AXI Master port
    parameter int  unsigned DmaAddrWidth     = -1,
    /// register_interface request type
    parameter type          dma_regs_req_t   = logic,
    /// register_interface response type
    parameter type          dma_regs_rsp_t   = logic,
    /// dma burst request type
    parameter type          burst_req_t      = logic
) (
    input  logic          clk_i,
    input  logic          rst_ni,
    /// register interface control slave
    input  dma_regs_req_t dma_ctrl_req_i,
    output dma_regs_rsp_t dma_ctrl_rsp_o,
    /// DMA backend signals
    output burst_req_t    burst_req_o,
    output logic          valid_o,
    input  logic          ready_i,
    input  logic          backend_idle_i,
    input  logic          trans_complete_i
);

    localparam DmaRegisterWidth = 64;

    /*
     * Signal and register definitions
     */
    idma_reg64_frontend_reg_pkg::idma_reg64_frontend_reg2hw_t dma_reg2hw;
    idma_reg64_frontend_reg_pkg::idma_reg64_frontend_hw2reg_t dma_hw2reg;

    // transaction id
    logic [DmaAddrWidth-1:0] next_id, done_id;
    logic issue;

    dma_regs_rsp_t dma_ctrl_rsp_tmp;

    /*
     * DMA registers
     */
    idma_reg64_frontend_reg_top #(
        .reg_req_t( dma_regs_req_t ),
        .reg_rsp_t( dma_regs_rsp_t )
    ) i_dma_conf_regs (
        .clk_i,
        .rst_ni,
        .reg_req_i ( dma_ctrl_req_i   ),
        .reg_rsp_o ( dma_ctrl_rsp_tmp ),
        .reg2hw    ( dma_reg2hw       ),
        .hw2reg    ( dma_hw2reg       ),
        .devmode_i ( 1'b0             ) // if 1, explicit error return for unmapped register access
    );

    /*
     * DMA Control Logic 
     */
    always_comb begin : proc_process_regs

        // reset state
        valid_o              = '0;
        dma_hw2reg.next_id.d = '0;
        dma_hw2reg.done.d    = '0;
        dma_hw2reg.status.d  = ~backend_idle_i;

        dma_ctrl_rsp_o = dma_ctrl_rsp_tmp;

        // start transaction upon next_id read (and having a valid config)
        if (dma_reg2hw.next_id.re) begin
           if (dma_reg2hw.num_bytes.q != '0) begin
                valid_o = 1'b1;
                dma_hw2reg.next_id.d = next_id;
                dma_ctrl_rsp_o.ready = ready_i;
           end
        end

        // use full width id from generator
        dma_hw2reg.done.d = done_id;
    end : proc_process_regs


    // map hw register onto generic burst request
    always_comb begin : hw_req_conv
        burst_req_o             = '0;
        burst_req_o.src         = dma_reg2hw.src_addr.q;
        burst_req_o.dst         = dma_reg2hw.dst_addr.q;
        burst_req_o.num_bytes   = dma_reg2hw.num_bytes.q;
        burst_req_o.burst_src   = axi_pkg::BURST_INCR;
        burst_req_o.burst_dst   = axi_pkg::BURST_INCR;
        burst_req_o.decouple_rw = dma_reg2hw.conf.decouple.q;
        burst_req_o.deburst     = dma_reg2hw.conf.deburst.q;
        burst_req_o.serialize   = dma_reg2hw.conf.serialize.q;
    end : hw_req_conv

    // only increment issue counter if we have a valid transfer
    assign issue = ready_i && valid_o;

    // transfer id generator
    dma_transfer_id_gen #(
        .IdWidth      ( DmaRegisterWidth  )
    ) i_dma_transfer_id_gen (
        .clk_i,
        .rst_ni,
        .issue_i      ( issue             ),
        .retire_i     ( trans_complete_i ),
        .next_o       ( next_id           ),
        .completed_o  ( done_id           )
    );

endmodule : idma_reg64_frontend

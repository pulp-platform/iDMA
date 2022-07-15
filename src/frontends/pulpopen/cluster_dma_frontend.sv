// Copyright (c) 2020 ETH Zurich and University of Bologna
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Thomas Benz <tbenz@iis.ee.ethz.ch>

/// replaces the mchan in the pulp cluster if the new AXI DMA should be used
/// strictly 32 bit on the TCDM side.

`include "register_interface/typedef.svh"
module cluster_dma_frontend #(
    /// number of cores in the cluster
    parameter int  unsigned NumCtrl        = -1,
    /// id width of peripherals
    parameter int  unsigned PeriphIdWidth   = -1,
    /// id width of the DMA AXI Master port
    parameter int  unsigned DmaAxiIdWidth  = -1,
    /// data width of the DMA AXI Master port
    parameter int  unsigned DmaDataWidth   = -1,
    /// address width of the DMA AXI Master port
    parameter int  unsigned DmaAddrWidth   = -1,
    /// number of AX requests in-flight
    parameter int  unsigned AxiAxReqDepth  = -1,
    /// number of 1D transfers buffered in backend
    parameter int  unsigned TfReqFifoDepth = -1,
    parameter int  unsigned NumStreams     = 1,
    /// data request type
    parameter type          axi_req_t      = logic,
    /// data response type
    parameter type          axi_res_t      = logic
) (
    input  logic                                         clk_i,
    input  logic                                         rst_ni,
    input  logic     [           5:0]                    cluster_id_i,
    /// Control Ports
    input  logic     [   NumCtrl-1:0]                    ctrl_targ_req_i,
    input  logic     [   NumCtrl-1:0]                    ctrl_targ_type_i,
    input  logic     [   NumCtrl-1:0][             3:0]  ctrl_targ_be_i,
    input  logic     [   NumCtrl-1:0][            31:0]  ctrl_targ_add_i,
    input  logic     [   NumCtrl-1:0][            31:0]  ctrl_targ_data_i,
    input  logic     [   NumCtrl-1:0][PeriphIdWidth-1:0] ctrl_targ_id_i,
    output logic     [   NumCtrl-1:0]                    ctrl_targ_gnt_o,
    output logic     [   NumCtrl-1:0]                    ctrl_targ_r_valid_o,
    output logic     [   NumCtrl-1:0][            31:0]  ctrl_targ_r_data_o,
    output logic     [   NumCtrl-1:0]                    ctrl_targ_r_opc_o,
    output logic     [   NumCtrl-1:0][PeriphIdWidth-1:0] ctrl_targ_r_id_o,
    /// wide AXI port
    output axi_req_t [NumStreams-1:0]                    axi_dma_req_o,
    input  axi_res_t [NumStreams-1:0]                    axi_dma_res_i,
    /// status signal
    output logic                                         busy_o,
    /// events and interrupts (cores)
    output logic     [  NumCtrl-1:0]                     term_event_o,
    output logic     [  NumCtrl-1:0]                     term_irq_o
);

    // number of register sets in fe
    localparam int unsigned NumRegs  = NumCtrl;

    // import cluster_dma_frontend_reg_pkg::* ;
    `REG_BUS_TYPEDEF_ALL(dma_regs, logic[9:0], logic[31:0], logic[3:0])
    dma_regs_req_t [NumRegs-1:0] dma_regs_req;
    dma_regs_rsp_t [NumRegs-1:0] dma_regs_rsp;
    cluster_dma_frontend_reg_pkg::cluster_dma_frontend_reg2hw_t [NumRegs-1:0] dma_reg2hw;
    cluster_dma_frontend_reg_pkg::cluster_dma_frontend_hw2reg_t [NumRegs-1:0] dma_hw2reg;

    logic [NumRegs-1:0] gnt_stall;
    logic [NumRegs-1:0][31:0] access_addr;

    // arbitration index width
    localparam int unsigned IdxWidth = (NumRegs + 1 > 32'd1) ? unsigned'($clog2(NumRegs + 1)) : 32'd1;

    // distributer index width
    localparam int unsigned DistrIdxWidth = (NumStreams > 32'd1) ? unsigned'($clog2(NumStreams)) : 32'd1;

    // DMA transfer descriptor
    typedef logic [DmaAddrWidth-1:0] addr_t;
    typedef logic             [31:0] num_bytes_t;
    typedef struct packed {
        num_bytes_t num_bytes;
        addr_t      dst_addr;
        addr_t      src_addr;
        logic       deburst;
        logic       decouple;
        logic       serialize;
    } transf_descr_t;

    // 1D burst request
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
    logic [NumStreams-1:0][27:0] next_id, done_id;

    // rr input
    transf_descr_t [NumRegs-1:0] transf_descr;
    logic          [NumRegs-1:0] be_ready;
    logic          [NumRegs-1:0] be_valid;
    // rr output
    transf_descr_t               transf_descr_arb;
    logic                        be_ready_arb;
    logic                        be_valid_arb;
    // zero length transfer
    // logic                        zero_length;
    // distributed outputs
    logic [NumStreams-1:0]       be_ready_stream;
    logic [NumStreams-1:0]       be_valid_stream;
    logic [NumStreams-1:0]       be_idle_stream;
    logic [NumStreams-1:0]       trans_complete_stream;
    // the index ob the chosen pe
    logic [IdxWidth-1:0]         pe_idx_arb;

    // the backend chosen
    logic [DistrIdxWidth-1:0]    be_idx_arb;


    // generate registers for cores
    for (genvar i = 0; i < NumRegs; i++) begin : gen_ctrl_regs
        
        periph_to_reg #(
            .AW   (10            ),
            .DW   (32            ),
            .BW   (8             ),
            .IW   (PeriphIdWidth ),
            .req_t(dma_regs_req_t),
            .rsp_t(dma_regs_rsp_t)
        ) i_pe_translate (
            .clk_i    (clk_i                  ),
            .rst_ni   (rst_ni                 ),
            .req_i    (ctrl_targ_req_i     [i]),
            .add_i    (access_addr         [i][9:0]),
            .wen_i    (ctrl_targ_type_i    [i]),
            .wdata_i  (ctrl_targ_data_i    [i]),
            .be_i     (ctrl_targ_be_i      [i]),
            .id_i     (ctrl_targ_id_i      [i]),
            .gnt_o    (gnt_stall           [i]),
            .r_rdata_o(ctrl_targ_r_data_o  [i]),
            .r_opc_o  (ctrl_targ_r_opc_o   [i]),
            .r_id_o   (ctrl_targ_r_id_o    [i]),
            .r_valid_o(ctrl_targ_r_valid_o [i]),
            .reg_req_o(dma_regs_req        [i]),
            .reg_rsp_i(dma_regs_rsp        [i])
        );

        cluster_dma_frontend_reg_top #(
            .reg_req_t(dma_regs_req_t),
            .reg_rsp_t(dma_regs_rsp_t)
            // .AW       (32            )
        ) i_dma_conf_regs (
            .clk_i    (clk_i           ),
            .rst_ni   (rst_ni          ),
            .reg_req_i(dma_regs_req [i]),
            .reg_rsp_o(dma_regs_rsp [i]),
            .reg2hw   (dma_reg2hw   [i]),
            .hw2reg   (dma_hw2reg   [i]),
            .devmode_i('0              )
        );

        always_comb begin : proc_process_regs
            transf_descr[i].num_bytes = dma_reg2hw[i].num_bytes.q;
            transf_descr[i].dst_addr = dma_reg2hw[i].dst_addr.q;
            transf_descr[i].src_addr = dma_reg2hw[i].src_addr.q;
            transf_descr[i].decouple = dma_reg2hw[i].conf.decouple.q;
            transf_descr[i].deburst = dma_reg2hw[i].conf.deburst.q;
            transf_descr[i].serialize = dma_reg2hw[i].conf.serialize.q;

            be_valid[i] = '0;
            dma_hw2reg[i].next_id.d = '0;
            ctrl_targ_gnt_o[i] = gnt_stall[i];
            dma_hw2reg[i].done.d = '0;
            dma_hw2reg[i].status.d = busy_o;
            access_addr[i] = ctrl_targ_add_i[i];

            if (dma_reg2hw[i].next_id.re) begin
                if (dma_reg2hw[i].num_bytes.q != '0) begin
                    be_valid[i] = 1'b1;
                    ctrl_targ_gnt_o[i] = be_ready[i]; // Stall transaction until be_ready
                    dma_hw2reg[i].next_id.d = {4'h0 + be_idx_arb, next_id[be_idx_arb]};
                end
            end

            // Directly connected done registers, at word offsets from base done register for NumStreams
            if (ctrl_targ_add_i[i][9:0] >= cluster_dma_frontend_reg_pkg::CLUSTER_DMA_FRONTEND_DONE_OFFSET) begin
                access_addr[i] = cluster_dma_frontend_reg_pkg::CLUSTER_DMA_FRONTEND_DONE_OFFSET;
            end
            if (dma_reg2hw[i].done.re) begin
                if ((ctrl_targ_add_i[i][9:0] - cluster_dma_frontend_reg_pkg::CLUSTER_DMA_FRONTEND_DONE_OFFSET) >> 2 < NumStreams) begin
                    dma_hw2reg[i].done.d = {4'h0, done_id[(ctrl_targ_add_i[i][9:0] - cluster_dma_frontend_reg_pkg::CLUSTER_DMA_FRONTEND_DONE_OFFSET) >> 2]};
                end else begin
                    dma_hw2reg[i].done.d = 32'hbadacce5;
                end
            end

        end
    end // gen_ctrl_regs

    // round robin to arbitrate
    rr_arb_tree #(
        .NumIn      ( NumRegs          ),
        .DataType   ( transf_descr_t   ),
        .ExtPrio    ( 0                ),
        .AxiVldRdy  ( 1                ),
        .LockIn     ( 1                )
    ) i_rr_arb_tree (
        .clk_i      ( clk_i              ),
        .rst_ni     ( rst_ni             ),
        .flush_i    ( 1'b0               ),
        .rr_i       ( '0                 ),
        .req_i      ( be_valid           ),
        .gnt_o      ( be_ready           ),
        .data_i     ( transf_descr       ),
        .gnt_i      ( be_ready_arb       ),
        .req_o      ( be_valid_arb       ),
        .data_o     ( transf_descr_arb   ),
        .idx_o      ( pe_idx_arb         )
    );

    // map arbitrated transfer descriptor onto generic burst request
    always_comb begin : proc_map_to_1D_burst
        burst_req             = '0;
        burst_req.src         =  transf_descr_arb.src_addr;
        burst_req.dst         =  transf_descr_arb.dst_addr;
        burst_req.num_bytes   =  transf_descr_arb.num_bytes;
        burst_req.burst_src   = axi_pkg::BURST_INCR;
        burst_req.burst_dst   = axi_pkg::BURST_INCR;
        burst_req.decouple_rw = transf_descr_arb.decouple;
        burst_req.deburst     = transf_descr_arb.deburst;
        burst_req.serialize   = transf_descr_arb.serialize;

        // assign zero length signal
        // zero_length           =  transf_descr_arb.num_bytes == 0;
    end

    rr_distributor #(
        .NumOut     ( NumStreams  )
    ) i_rr_distributor (
        .clk_i      ( clk_i           ),
        .rst_ni     ( rst_ni          ),
        .valid_i    ( be_valid_arb    ),
        .ready_o    ( be_ready_arb    ),
        .payload_i  ( '0              ),
        .valid_o    ( be_valid_stream ),
        .ready_i    ( be_ready_stream ),
        .payload_o  ( ),
        .sel_o      ( be_idx_arb      )
    );

    for (genvar i = 0; i < NumStreams; i++) begin : gen_backends

        // modify id
        burst_req_t burst_req_stream;
        always_comb begin : proc_modify_id
            burst_req_stream    = burst_req;
            burst_req_stream.id = burst_req.id + i;
        end

        logic issue;

        // instantiate backend :)
        axi_dma_backend #(
            .DataWidth       ( DmaDataWidth    ),
            .AddrWidth       ( DmaAddrWidth    ),
            .IdWidth         ( DmaAxiIdWidth   ),
            .AxReqFifoDepth  ( AxiAxReqDepth   ),
            .TransFifoDepth  ( TfReqFifoDepth  ),
            .BufferDepth     ( 3               ), // minimal 3 for giving full performance
            .axi_req_t       ( axi_req_t       ),
            .axi_res_t       ( axi_res_t       ),
            .burst_req_t     ( burst_req_t     ),
            .DmaIdWidth      ( 6               ),
            .DmaTracing      ( 0               )
        ) i_axi_dma_backend (
            .clk_i            ( clk_i                     ),
            .rst_ni           ( rst_ni                    ),
            .dma_id_i         ( cluster_id_i              ),
            .axi_dma_req_o    ( axi_dma_req_o         [i] ),
            .axi_dma_res_i    ( axi_dma_res_i         [i] ),
            .burst_req_i      ( burst_req_stream          ),
            .valid_i          ( be_valid_stream       [i] ),
            .ready_o          ( be_ready_stream       [i] ),
            .backend_idle_o   ( be_idle_stream        [i] ),
            .trans_complete_o ( trans_complete_stream [i] )
        );

        // only increment issue counter if we have a valid transfer
        assign issue = be_ready_stream[i] & be_valid_stream[i]; /*& !zero_length;*/

        // transfer id
        dma_transfer_id_gen #(
            .IdWidth      ( 28     )
        ) i_cluster_dma_transfer_id_gen (
            .clk_i        ( clk_i                     ),
            .rst_ni       ( rst_ni                    ),
            .issue_i      ( issue                     ),
            .retire_i     ( trans_complete_stream [i] ),
            .next_o       ( next_id               [i] ),
            .completed_o  ( done_id               [i] )
        );

    end

    // busy if not idle
    assign busy_o = |(~be_idle_stream);

    // interrupts and events (unconditionally)
    assign term_event_o    = |trans_complete_stream ? '1 : '0;
    assign term_irq_o      = |trans_complete_stream ? '1 : '0;
    assign term_event_pe_o = |trans_complete_stream ? '1 : '0;
    assign term_irq_pe_o   = |trans_complete_stream ? '1 : '0;

endmodule : cluster_dma_frontend

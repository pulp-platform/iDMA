// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Michael Rogenmoser <michaero@ethz.ch>
//
// Description: DMA frontend module that includes 32bit config and status reg handling for 2d transfers

module idma_reg32_2d_frontend #(
  /// Number of configuration register ports
  parameter int  unsigned NumRegs          = 1,
  /// address width of the DMA Transfer ID counter
  parameter int  unsigned IdCounterWidth   = -1,
  /// register_interface request type
  parameter type          dma_regs_req_t   = logic,
  /// register_interface response type
  parameter type          dma_regs_rsp_t   = logic,
  /// dma burst request type
  parameter type          burst_req_t      = logic
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  /// register interface control slave
  input  dma_regs_req_t [NumRegs-1:0] dma_ctrl_req_i,
  output dma_regs_rsp_t [NumRegs-1:0] dma_ctrl_rsp_o,
  /// DMA backend signals
  output burst_req_t                  burst_req_o,
  output logic                        valid_o,
  input  logic                        ready_i,
  input  logic                        backend_idle_i,
  input  logic                        trans_complete_i
);

  localparam int unsigned DmaRegisterWidth = 32;

  idma_reg32_2d_frontend_reg_pkg::idma_reg32_2d_frontend_reg2hw_t [NumRegs-1:0] dma_reg2hw;
  idma_reg32_2d_frontend_reg_pkg::idma_reg32_2d_frontend_hw2reg_t [NumRegs-1:0] dma_hw2reg;

  logic [IdCounterWidth-1:0] next_id, done_id;
  logic issue;

  dma_regs_rsp_t [NumRegs-1:0] dma_ctrl_rsp_tmp;

  logic [NumRegs-1:0] arb_valid, arb_ready;

  burst_req_t [NumRegs-1:0] arb_burst_req;

  for (genvar i = 0; i < NumRegs; i++) begin : gen_core_regs

    idma_reg32_2d_frontend_reg_top #(
      .reg_req_t ( dma_regs_req_t ),
      .reg_rsp_t ( dma_regs_rsp_t )
    ) i_dma_conf_regs (
      .clk_i,
      .rst_ni,
      .reg_req_i ( dma_ctrl_req_i   [i] ),
      .reg_rsp_o ( dma_ctrl_rsp_tmp [i] ),
      .reg2hw    ( dma_reg2hw       [i] ),
      .hw2reg    ( dma_hw2reg       [i] ),
      .devmode_i ( 1'b0                 )
    );

    /*
    * DMA Control Logic
    */
    always_comb begin: proc_process_regs
      arb_valid[i] = '0;
      dma_hw2reg[i].next_id.d = '0; // Ensure default is previous next_id...
      dma_hw2reg[i].done.d    = done_id;
      dma_hw2reg[i].status.d  = ~backend_idle_i;

      dma_ctrl_rsp_o[i] = dma_ctrl_rsp_tmp[i];

      if (dma_reg2hw[i].next_id.re) begin
        if (dma_reg2hw[i].num_bytes.q != '0 && (dma_reg2hw[i].conf.twod.q != 1'b1 ||
                                                dma_reg2hw[i].num_repetitions.q != '0)) begin
          arb_valid[i] = 1'b1;
          dma_ctrl_rsp_o[i].ready = arb_ready[i];
          dma_hw2reg[i].next_id.d = next_id;
        end
      end
    end

    always_comb begin : hw_req_conv
      arb_burst_req[i]                                  = '0;

      arb_burst_req[i].burst_req.length                 = dma_reg2hw[i].num_bytes.q;
      arb_burst_req[i].burst_req.src_addr               = dma_reg2hw[i].src_addr.q;
      arb_burst_req[i].burst_req.dst_addr               = dma_reg2hw[i].dst_addr.q;

        // Current backend only supports one ID
      arb_burst_req[i].burst_req.opt.axi_id             = '0;
        // Current backend only supports incremental burst
      arb_burst_req[i].burst_req.opt.src.burst          = axi_pkg::BURST_INCR;
        // this frontend currently does not support cache variations
      arb_burst_req[i].burst_req.opt.src.cache          = '0;
        // AXI4 does not support locked transactions, use atomics
      arb_burst_req[i].burst_req.opt.src.lock           = '0;
        // unpriviledged, secure, data access
      arb_burst_req[i].burst_req.opt.src.prot           = '0;
        // not participating in qos
      arb_burst_req[i].burst_req.opt.src.qos            = '0;
        // only one region
      arb_burst_req[i].burst_req.opt.src.region         = '0;
        // Current backend only supports incremental burst
      arb_burst_req[i].burst_req.opt.dst.burst          = axi_pkg::BURST_INCR;
        // this frontend currently does not support cache variations
      arb_burst_req[i].burst_req.opt.dst.cache          = '0;
        // AXI4 does not support locked transactions, use atomics
      arb_burst_req[i].burst_req.opt.dst.lock           = '0;
        // unpriviledged, secure, data access
      arb_burst_req[i].burst_req.opt.dst.prot           = '0;
        // not participating in qos
      arb_burst_req[i].burst_req.opt.dst.qos            = '0;
        // only one region
      arb_burst_req[i].burst_req.opt.dst.region         = '0;

        // ensure coupled AW to avoid deadlocks
      arb_burst_req[i].burst_req.opt.beo.decouple_aw    = '0;
      arb_burst_req[i].burst_req.opt.beo.decouple_rw    = dma_reg2hw[i].conf.decouple.q;
        // this frontend currently only supports completely debursting
      arb_burst_req[i].burst_req.opt.beo.src_max_llen   = '0;
        // this frontend currently only supports completely debursting
      arb_burst_req[i].burst_req.opt.beo.dst_max_llen   = '0;
      arb_burst_req[i].burst_req.opt.beo.src_reduce_len = dma_reg2hw[i].conf.deburst.q;
      arb_burst_req[i].burst_req.opt.beo.dst_reduce_len = dma_reg2hw[i].conf.deburst.q;

      if ( dma_reg2hw[i].conf.twod.q ) begin
        arb_burst_req[i].d_req[0].reps                     = dma_reg2hw[i].num_repetitions.q;
      end else begin
        arb_burst_req[i].d_req[0].reps                     = 1;
      end
      arb_burst_req[i].d_req[0].src_strides                = dma_reg2hw[i].stride_src.q;
      arb_burst_req[i].d_req[0].dst_strides                = dma_reg2hw[i].stride_dst.q;

        // serialization no longer supported
      // arb_burst_req[i].serialize       = dma_reg2hw[i].conf.serialize.q;
    end
  end

  rr_arb_tree #(
    .NumIn     ( NumRegs     ),
    .DataType  ( burst_req_t ),
    .ExtPrio   ( 0           ),
    .AxiVldRdy ( 1           ),
    .LockIn    ( 1           )
  ) i_rr_arb_tree (
    .clk_i,
    .rst_ni,
    .flush_i ( 1'b0          ),
    .rr_i    ( '0            ),
    .req_i   ( arb_valid     ),
    .gnt_o   ( arb_ready     ),
    .data_i  ( arb_burst_req ),
    .gnt_i   ( ready_i       ),
    .req_o   ( valid_o       ),
    .data_o  ( burst_req_o   ),
    .idx_o   ()
  );

  assign issue = ready_i && valid_o;

  idma_transfer_id_gen #(
    .IdWidth ( IdCounterWidth )
  ) i_transfer_id_gen (
    .clk_i,
    .rst_ni,
    .issue_i     ( issue            ),
    .retire_i    ( trans_complete_i ),
    .next_o      ( next_id          ),
    .completed_o ( done_id          )
  );

endmodule

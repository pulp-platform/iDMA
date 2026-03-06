// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Michael Rogenmoser <michaero@iis.ee.ethz.ch>
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "apb/typedef.svh"

/// Description: Register-based front-end for iDMA
module idma_reg64_2d #(
  /// Number of configuration register ports
  parameter int unsigned NumRegs        = 32'd1,
  /// Number of streams (max 16)
  parameter int unsigned NumStreams     = 32'd1,
  /// Width of the transfer id (max 32-bit)
  parameter int unsigned IdCounterWidth = 32'd32,
  /// Dependent parameter: Stream Idx
  parameter int unsigned StreamWidth    = cf_math_pkg::idx_width(NumStreams),
  /// Register_interface request type
  parameter type         reg_req_t      = logic,
  /// Register_interface response type
  parameter type         reg_rsp_t      = logic,
  /// DMA 1d or ND burst request type
  parameter type         dma_req_t      = logic,
  /// Dependent type for IdCounterWidth
  parameter type         cnt_width_t    = logic [IdCounterWidth-1:0],
  /// Dependent type for StreamWidth
  parameter type         stream_t       = logic [StreamWidth-1:0]
) (
  input  logic clk_i,
  input  logic rst_ni,
  /// Register interface control slave
  input  reg_req_t [NumRegs-1:0] dma_ctrl_req_i,
  output reg_rsp_t [NumRegs-1:0] dma_ctrl_rsp_o,
  /// Request signals
  output dma_req_t   dma_req_o,
  output logic       req_valid_o,
  input  logic       req_ready_i,
  input  cnt_width_t next_id_i,
  output stream_t    stream_idx_o,
  /// Status signals
  input  cnt_width_t           [NumStreams-1:0] done_id_i,
  input  idma_pkg::idma_busy_t [NumStreams-1:0] busy_i,
  input  logic                 [NumStreams-1:0] midend_busy_i
);

  /// Maximum number of streams is set to 16. It can be enlarged, but the register file
  /// needs to be adapted too.
  localparam int unsigned MaxNumStreams = 32'd16;

  `APB_TYPEDEF_ALL(apb, logic[31:0], logic[31:0], logic[3:0])
  apb_req_t  [NumRegs-1:0] apb_req;
  apb_resp_t [NumRegs-1:0] apb_rsp;


  // register connections
  idma_reg64_2d_reg_pkg::idma_reg__out_t dma_reg2hw [NumRegs-1:0];
  idma_reg64_2d_reg_pkg::idma_reg__in_t  dma_hw2reg [NumRegs-1:0];

  // arbitration output
  dma_req_t [NumRegs-1:0] arb_dma_req;
  logic     [NumRegs-1:0] arb_valid;
  logic     [NumRegs-1:0] arb_ready;

  // register signals
  reg_rsp_t [NumRegs-1:0] dma_ctrl_rsp;

  always_comb begin
      stream_idx_o = '0;
      for (int r = 0; r < NumRegs; r++) begin
          for (int c = 0; c < NumStreams; c++) begin
              if (dma_reg2hw[r].next_id[c].req && !dma_reg2hw[r].next_id[c].req_is_wr) begin
                  stream_idx_o = c;
              end
          end
      end
  end

  // generate the registers
  for (genvar i = 0; i < NumRegs; i++) begin : gen_core_regs


    reg_to_apb #(
      .reg_req_t  ( reg_req_t ),
      .reg_rsp_t  ( reg_rsp_t ),
      .apb_req_t  ( apb_req_t ),
      .apb_rsp_t  ( apb_resp_t )
    ) chs_regs_reg_to_apb (
      .clk_i,
      .rst_ni,
      .reg_req_i ( dma_ctrl_req_i   [i] ),
      .reg_rsp_o ( dma_ctrl_rsp     [i] ),
      .apb_req_o ( apb_req          [i] ),
      .apb_rsp_i ( apb_rsp          [i] )
    );

    idma_reg64_2d_reg_top i_idma_reg64_2d_reg_top (
      .clk    ( clk_i ),
      .arst_n ( rst_ni ),

      .s_apb_psel    (apb_req[i].psel),
      .s_apb_penable (apb_req[i].penable),
      .s_apb_pwrite  (apb_req[i].pwrite),
      .s_apb_pprot   (apb_req[i].pprot),
      .s_apb_paddr   (apb_req[i].paddr),
      .s_apb_pwdata  (apb_req[i].pwdata),
      .s_apb_pstrb   (apb_req[i].pstrb),
      .s_apb_pready  (apb_rsp[i].pready),
      .s_apb_prdata  (apb_rsp[i].prdata),
      .s_apb_pslverr (apb_rsp[i].pslverr),

      .hwif_out  ( dma_reg2hw       [i] ),
      .hwif_in   ( dma_hw2reg       [i] )
    );

    logic read_happens;
    // DMA backpressure
    always_comb begin : proc_dma_backpressure
      // ready signal
      dma_ctrl_rsp_o[i]       = dma_ctrl_rsp[i];
      dma_ctrl_rsp_o[i].ready = read_happens ? arb_ready[i] : dma_ctrl_rsp[i];
    end

    // valid signals

    always_comb begin : proc_launch
        read_happens = 1'b0;
        for (int c = 0; c < NumStreams; c++) begin
            read_happens |= dma_reg2hw[i].next_id[c].req & ~dma_reg2hw[i].next_id[c].req_is_wr;
        end
        arb_valid[i] = read_happens;
    end

    // assign request struct
    always_comb begin : proc_hw_req_conv
      // all fields are zero per default
      arb_dma_req[i] = '0;

      // address and length
      arb_dma_req[i].burst_req.length   = {dma_reg2hw[i].length[1].length.value,     dma_reg2hw[i].length[0].length.value};
      arb_dma_req[i].burst_req.src_addr = {dma_reg2hw[i].src_addr[1].src_addr.value, dma_reg2hw[i].src_addr[0].src_addr.value};
      arb_dma_req[i].burst_req.dst_addr = {dma_reg2hw[i].dst_addr[1].dst_addr.value, dma_reg2hw[i].dst_addr[0].dst_addr.value};

      // Protocols
      arb_dma_req[i].burst_req.opt.src_protocol = idma_pkg::protocol_e'(dma_reg2hw[i].conf.src_protocol.value);
      arb_dma_req[i].burst_req.opt.dst_protocol = idma_pkg::protocol_e'(dma_reg2hw[i].conf.dst_protocol.value);

      // Current backend only supports incremental burst
      arb_dma_req[i].burst_req.opt.src.burst = axi_pkg::BURST_INCR;
      arb_dma_req[i].burst_req.opt.dst.burst = axi_pkg::BURST_INCR;
        // this frontend currently does not support cache variations
      arb_dma_req[i].burst_req.opt.src.cache = axi_pkg::CACHE_MODIFIABLE;
      arb_dma_req[i].burst_req.opt.dst.cache = axi_pkg::CACHE_MODIFIABLE;

      // Backend options
      arb_dma_req[i].burst_req.opt.beo.decouple_aw    = dma_reg2hw[i].conf.decouple_aw.value;
      arb_dma_req[i].burst_req.opt.beo.decouple_rw    = dma_reg2hw[i].conf.decouple_rw.value;
      arb_dma_req[i].burst_req.opt.beo.src_max_llen   = dma_reg2hw[i].conf.src_max_llen.value;
      arb_dma_req[i].burst_req.opt.beo.dst_max_llen   = dma_reg2hw[i].conf.dst_max_llen.value;
      arb_dma_req[i].burst_req.opt.beo.src_reduce_len = dma_reg2hw[i].conf.src_reduce_len.value;
      arb_dma_req[i].burst_req.opt.beo.dst_reduce_len = dma_reg2hw[i].conf.dst_reduce_len.value;

      // ND connections
      arb_dma_req[i].d_req[0].reps = {dma_reg2hw[i].dim[0].reps[1].reps.value,
                                      dma_reg2hw[i].dim[0].reps[0].reps.value };
      arb_dma_req[i].d_req[0].src_strides = {dma_reg2hw[i].dim[0].src_stride[1].src_stride.value,
                                             dma_reg2hw[i].dim[0].src_stride[0].src_stride.value};
      arb_dma_req[i].d_req[0].dst_strides = {dma_reg2hw[i].dim[0].dst_stride[1].dst_stride.value,
                                             dma_reg2hw[i].dim[0].dst_stride[0].dst_stride.value};

      // Disable higher dimensions
      if ( dma_reg2hw[i].conf.enable_nd.value == 0) begin
        arb_dma_req[i].d_req[0].reps = 'd1;
      end
    end

    // observational registers
    for (genvar c = 0; c < NumStreams; c++) begin : gen_hw2reg_connections
        assign dma_hw2reg[i].status[c].rd_data.busy  = {midend_busy_i[c], busy_i[c]};
        assign dma_hw2reg[i].status[c].rd_ack = 1'b1;
        assign dma_hw2reg[i].next_id[c].rd_data.next_id = next_id_i;
        assign dma_hw2reg[i].next_id[c].rd_ack = 1'b1;
        assign dma_hw2reg[i].done_id[c].rd_data.done_id = done_id_i[c];
        assign dma_hw2reg[i].done_id[c].rd_ack = 1'b1;
    end

    // tie-off unused channels
    for (genvar c = NumStreams; c < MaxNumStreams; c++) begin : gen_hw2reg_unused
        assign dma_hw2reg[i].status[c].rd_data = '0;
        assign dma_hw2reg[i].status[c].rd_ack  = '0;
        assign dma_hw2reg[i].next_id[c].rd_data.next_id = '0;
        assign dma_hw2reg[i].next_id[c].rd_ack = '0;
        assign dma_hw2reg[i].done_id[c].rd_data.done_id = '0;
        assign dma_hw2reg[i].done_id[c].rd_ack = '0;
    end

  end

  // arbitration
  rr_arb_tree #(
    .NumIn     ( NumRegs   ),
    .DataType  ( dma_req_t ),
    .ExtPrio   ( 0         ),
    .AxiVldRdy ( 1         ),
    .LockIn    ( 1         )
  ) i_rr_arb_tree (
    .clk_i,
    .rst_ni,
    .flush_i ( 1'b0        ),
    .rr_i    ( '0          ),
    .req_i   ( arb_valid   ),
    .gnt_o   ( arb_ready   ),
    .data_i  ( arb_dma_req ),
    .gnt_i   ( req_ready_i ),
    .req_o   ( req_valid_o ),
    .data_o  ( dma_req_o   ),
    .idx_o   ( /* NC */    )
  );

endmodule


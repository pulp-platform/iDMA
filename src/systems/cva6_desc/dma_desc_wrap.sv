// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "idma/typedef.svh"
`include "idma/tracer.svh"
`include "register_interface/typedef.svh"
`include "common_cells/registers.svh"

/// Wrapper for the iDMA
module dma_desc_wrap #(
  parameter int  AxiAddrWidth     = 64,
  parameter int  AxiDataWidth     = 64,
  parameter int  AxiUserWidth     = -1,
  parameter int  AxiIdWidth       = -1,
  parameter int  AxiSlvIdWidth    = -1,
  parameter int  NSpeculation     = 4,
  parameter int  PendingFifoDepth = 4,
  parameter int  InputFifoDepth   = 1,
  parameter type mst_aw_chan_t    = logic, // AW Channel Type, master port
  parameter type mst_w_chan_t     = logic, //  W Channel Type, all ports
  parameter type mst_b_chan_t     = logic, //  B Channel Type, master port
  parameter type mst_ar_chan_t    = logic, // AR Channel Type, master port
  parameter type mst_r_chan_t     = logic, //  R Channel Type, master port
  parameter type axi_mst_req_t    = logic,
  parameter type axi_mst_rsp_t    = logic,
  parameter type axi_slv_req_t    = logic,
  parameter type axi_slv_rsp_t    = logic
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  output logic         irq_o,
  output axi_mst_req_t axi_master_req_o,
  input  axi_mst_rsp_t axi_master_rsp_i,
  input  axi_slv_req_t axi_slave_req_i,
  output axi_slv_rsp_t axi_slave_rsp_o
);
  import axi_pkg::*;

  typedef logic [AxiAddrWidth-1:0]     addr_t;
  typedef logic [AxiDataWidth-1:0]     data_t;
  typedef logic [(AxiDataWidth/8)-1:0] strb_t;
  typedef logic [AxiUserWidth-1:0]     user_t;
  // has one less bit for the mux not to error
  typedef logic [AxiIdWidth-2:0]       post_mux_id_t;

  localparam int unsigned NumAxInFlight = 2;
  localparam int unsigned BufferDepth   = 3;

  axi_slv_req_t axi_slv_req;
  axi_slv_rsp_t axi_slv_rsp;

  `AXI_TYPEDEF_ALL(dma_axi_mst_post_mux, addr_t, post_mux_id_t, data_t, strb_t, user_t)
  dma_axi_mst_post_mux_req_t  axi_fe_mst_req;
  dma_axi_mst_post_mux_resp_t axi_fe_mst_rsp;
  dma_axi_mst_post_mux_req_t  axi_be_mst_req;
  dma_axi_mst_post_mux_resp_t axi_be_mst_rsp;
  dma_axi_mst_post_mux_req_t  axi_be_cut_req;
  dma_axi_mst_post_mux_resp_t axi_be_cut_rsp;

  `REG_BUS_TYPEDEF_ALL(dma_reg, addr_t, data_t, strb_t)
  dma_reg_req_t dma_reg_slv_req;
  dma_reg_rsp_t dma_reg_slv_rsp;

  // iDMA struct definitions
  localparam int unsigned TFLenWidth  = 32;
  typedef logic [TFLenWidth-1:0]  tf_len_t;

  // iDMA request / response types
  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, post_mux_id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

  idma_req_t  idma_req;
  logic       idma_req_valid;
  logic       idma_req_ready;

  idma_rsp_t  idma_rsp;
  logic       idma_rsp_valid;
  logic       idma_rsp_ready;
  idma_pkg::idma_busy_t idma_busy;

  idma_desc64_top #(
    .AddrWidth        ( AxiAddrWidth                   ),
    .DataWidth        ( AxiDataWidth                   ),
    .AxiIdWidth       ( AxiIdWidth - 1                 ),
    .idma_req_t       ( idma_req_t                     ),
    .idma_rsp_t       ( idma_rsp_t                     ),
    .axi_req_t        ( dma_axi_mst_post_mux_req_t     ),
    .axi_rsp_t        ( dma_axi_mst_post_mux_resp_t    ),
    .axi_ar_chan_t    ( dma_axi_mst_post_mux_ar_chan_t ),
    .axi_r_chan_t     ( dma_axi_mst_post_mux_r_chan_t  ),
    .reg_req_t        ( dma_reg_req_t                  ),
    .reg_rsp_t        ( dma_reg_rsp_t                  ),
    .InputFifoDepth   ( InputFifoDepth                 ),
    .PendingFifoDepth ( PendingFifoDepth               ),
    .BackendDepth     ( NumAxInFlight + BufferDepth    ),
    .NSpeculation     ( NSpeculation                   )
  ) i_dma_desc64 (
    .clk_i,
    .rst_ni,
    .master_req_o     ( axi_fe_mst_req   ),
    .master_rsp_i     ( axi_fe_mst_rsp   ),
    .axi_ar_id_i      (               '1 ),
    .axi_aw_id_i      (               '1 ),
    .slave_req_i      ( dma_reg_slv_req  ),
    .slave_rsp_o      ( dma_reg_slv_rsp  ),
    .idma_req_o       ( idma_req         ),
    .idma_req_valid_o ( idma_req_valid   ),
    .idma_req_ready_i ( idma_req_ready   ),
    .idma_rsp_i       ( idma_rsp         ),
    .idma_rsp_valid_i ( idma_rsp_valid   ),
    .idma_rsp_ready_o ( idma_rsp_ready   ),
    .idma_busy_i      ( |idma_busy       ),
    .irq_o            ( irq_o            )
  );

  idma_backend #(
    .DataWidth           ( AxiDataWidth                ),
    .AddrWidth           ( AxiAddrWidth                ),
    .UserWidth           ( AxiUserWidth                ),
    .AxiIdWidth          ( AxiIdWidth-1                ),
    .NumAxInFlight       ( NumAxInFlight               ),
    .BufferDepth         ( BufferDepth                 ),
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
    .axi_req_t           ( dma_axi_mst_post_mux_req_t  ),
    .axi_rsp_t           ( dma_axi_mst_post_mux_resp_t )
  ) i_idma_backend (
    .clk_i,
    .rst_ni,
    .testmode_i    ( testmode_i        ),

    .idma_req_i    ( idma_req          ),
    .req_valid_i   ( idma_req_valid    ),
    .req_ready_o   ( idma_req_ready    ),

    .idma_rsp_o    ( idma_rsp          ),
    .rsp_valid_o   ( idma_rsp_valid    ),
    .rsp_ready_i   ( idma_rsp_ready    ),

    .idma_eh_req_i ( '0                ), // No error handling
    .eh_req_valid_i( 1'b1              ),
    .eh_req_ready_o( /*NOT CONNECTED*/ ),

    .axi_req_o     ( axi_be_cut_req    ),
    .axi_rsp_i     ( axi_be_cut_rsp    ),
    .busy_o        ( idma_busy         )
  );

  // pragma translate_off
  string trace_file;
  initial begin
    void'($value$plusargs("trace_file=%s", trace_file));
  end
  `ifndef SYNTHESYS
  `ifndef VERILATOR
  initial begin : inital_tracer
    automatic bit first_iter = 1;
    automatic integer tf;
    automatic `IDMA_TRACER_MAX_TYPE cnst [string];
    automatic `IDMA_TRACER_MAX_TYPE meta [string];
    automatic `IDMA_TRACER_MAX_TYPE busy [string];
    automatic `IDMA_TRACER_MAX_TYPE axib [string];
    automatic string trace;
    #0;
    tf = $fopen(trace_file, "w");
    $display("[Tracer] Logging iDMA backend %s to %s", "i_idma_backend", trace_file);
    forever begin
      @(posedge i_idma_backend.clk_i);
      if (i_idma_backend.rst_ni & |i_idma_backend.busy_o) begin
        break;
      end
    end
    forever begin
      @(posedge i_idma_backend.clk_i);
      /* Trace */
      trace = "{";
      /* Constants */
      cnst = '{
        "inst"                  : "i_idma_backend",
        "data_width"            : i_idma_backend.DataWidth,
        "addr_width"            : i_idma_backend.AddrWidth,
        "user_width"            : i_idma_backend.UserWidth,
        "axi_id_width"          : i_idma_backend.AxiIdWidth,
        "num_ax_in_flight"      : i_idma_backend.NumAxInFlight,
        "buffer_depth"          : i_idma_backend.BufferDepth,
        "tf_len_width"          : i_idma_backend.TFLenWidth,
        "mem_sys_depth"         : i_idma_backend.MemSysDepth,
        "rw_coupling_avail"     : i_idma_backend.RAWCouplingAvail,
        "mask_invalid_data"     : i_idma_backend.MaskInvalidData,
        "hardware_legalizer"    : i_idma_backend.HardwareLegalizer,
        "reject_zero_transfers" : i_idma_backend.RejectZeroTransfers,
        "error_cap"             : i_idma_backend.ErrorCap,
        "print_fifo_info"       : i_idma_backend.PrintFifoInfo
      };
      meta = '{
        "time" : $time()
      };
      busy = '{
        "buffer"      : i_idma_backend.busy_o.buffer_busy,
        "r_dp"        : i_idma_backend.busy_o.r_dp_busy,
        "w_dp"        : i_idma_backend.busy_o.w_dp_busy,
        "r_leg"       : i_idma_backend.busy_o.r_leg_busy,
        "w_leg"       : i_idma_backend.busy_o.w_leg_busy,
        "eh_fsm"      : i_idma_backend.busy_o.eh_fsm_busy,
        "eh_cnt"      : i_idma_backend.busy_o.eh_cnt_busy,
        "raw_coupler" : i_idma_backend.busy_o.raw_coupler_busy
      };
      axib = '{
        "w_valid" : i_idma_backend.axi_req_o.w_valid,
        "w_ready" : axi_be_cut_rsp.w_ready,
        "w_strb"  : i_idma_backend.axi_req_o.w.strb,
        "r_valid" : axi_be_cut_rsp.r_valid,
        "r_ready" : i_idma_backend.axi_req_o.r_ready
      };
      if ($isunknown(axib["w_ready"]) || $isunknown(axib["r_valid"])) begin
        $fatal("UNKNOWN AXI STATE, THIS SHOULD NEVER HAPPEN!");
      end
      /* Assembly */
      `IDMA_TRACER_STR_ASSEMBLY(cnst, first_iter);
      `IDMA_TRACER_STR_ASSEMBLY(meta, 1);
      `IDMA_TRACER_STR_ASSEMBLY(busy, 1);
      `IDMA_TRACER_STR_ASSEMBLY(axib, 1);
      `IDMA_TRACER_CLEAR_COND(first_iter);
      /* Commit */
      $fwrite(tf, $sformatf("%s}\n", trace));
    end
  end
`endif
`endif
  // pragma translate_on

  axi_cut #(
    .aw_chan_t    (dma_axi_mst_post_mux_aw_chan_t),
    .w_chan_t     (dma_axi_mst_post_mux_w_chan_t),
    .b_chan_t     (dma_axi_mst_post_mux_b_chan_t),
    .ar_chan_t    (dma_axi_mst_post_mux_ar_chan_t),
    .r_chan_t     (dma_axi_mst_post_mux_r_chan_t),
    .axi_req_t    (dma_axi_mst_post_mux_req_t),
    .axi_resp_t   (dma_axi_mst_post_mux_resp_t)
  ) i_axi_cut (
    .clk_i,
    .rst_ni,
    .slv_req_i (axi_be_cut_req),
    .slv_resp_o(axi_be_cut_rsp),
    .mst_req_o (axi_be_mst_req),
    .mst_resp_i(axi_be_mst_rsp)
  );

  axi_mux #(
    .SlvAxiIDWidth(AxiIdWidth - 1),
    .slv_aw_chan_t(dma_axi_mst_post_mux_aw_chan_t),
    .mst_aw_chan_t(mst_aw_chan_t),
    .w_chan_t     (mst_w_chan_t), // same channel type for master+slave
    .slv_b_chan_t (dma_axi_mst_post_mux_b_chan_t),
    .mst_b_chan_t (mst_b_chan_t),
    .slv_ar_chan_t(dma_axi_mst_post_mux_ar_chan_t),
    .mst_ar_chan_t(mst_ar_chan_t),
    .slv_r_chan_t (dma_axi_mst_post_mux_r_chan_t),
    .mst_r_chan_t (mst_r_chan_t),
    .slv_req_t    (dma_axi_mst_post_mux_req_t),
    .slv_resp_t   (dma_axi_mst_post_mux_resp_t),
    .mst_req_t    (axi_mst_req_t),
    .mst_resp_t   (axi_mst_rsp_t),
    .NoSlvPorts   ('d2),
    .MaxWTrans    ('d2),
    .FallThrough  ('0),
    .SpillAw      ('b0),
    .SpillW       ('0),
    .SpillB       ('0),
    .SpillAr      ('b0),
    .SpillR       ('0)
  ) i_axi_mux (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .test_i      (1'b0),
    .slv_reqs_i  ({axi_fe_mst_req, axi_be_mst_req}),
    .slv_resps_o ({axi_fe_mst_rsp, axi_be_mst_rsp}),
    .mst_req_o   (axi_master_req_o),
    .mst_resp_i  (axi_master_rsp_i)
  );

  axi_to_reg #(
    .ADDR_WIDTH        (AxiAddrWidth),
    .DATA_WIDTH        (AxiDataWidth),
    .ID_WIDTH          (AxiSlvIdWidth),
    .USER_WIDTH        (AxiUserWidth),
    .AXI_MAX_WRITE_TXNS(32'd1),
    .AXI_MAX_READ_TXNS (32'd1),
    .DECOUPLE_W        (1'b1),
    .axi_req_t         (axi_slv_req_t),
    .axi_rsp_t         (axi_slv_rsp_t),
    .reg_req_t         (dma_reg_req_t),
    .reg_rsp_t         (dma_reg_rsp_t)
  ) i_axi_to_reg (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .testmode_i(testmode_i),
    .axi_req_i (axi_slv_req),
    .axi_rsp_o (axi_slv_rsp),
    .reg_req_o (dma_reg_slv_req),
    .reg_rsp_i (dma_reg_slv_rsp)
  );

  assign axi_slv_req     = axi_slave_req_i;
  assign axi_slave_rsp_o = axi_slv_rsp;

endmodule : dma_desc_wrap

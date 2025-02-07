// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/*
 * dmac_wrap.sv
 * Thomas Benz <tbenz@iis.ee.ethz.ch>
 * Michael Rogenmoser <michaero@iis.ee.ethz.ch>
 * Alessandro Ottaviano <aottaviano@iis.ee.ethz.ch>
 */

// DMA Core wrapper

`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "idma/typedef.svh"
`include "register_interface/typedef.svh"
`include "register_interface/assign.svh"

module dmac_wrap_fc_idma #(
  parameter int unsigned NB_CORES            = 4,
  parameter int unsigned AXI_ADDR_WIDTH      = 32,
  parameter int unsigned AXI_DATA_WIDTH      = 64,
  parameter int unsigned AXI_USER_WIDTH      = 6,
  parameter int unsigned AXI_ID_WIDTH_MST_1  = 4,
  parameter int unsigned AXI_ID_WIDTH_MST_2  = 4,
  parameter int unsigned PE_ID_WIDTH         = 1,
  parameter int unsigned NB_PE_PORTS         = 1,
  parameter int unsigned DATA_WIDTH          = 32,
  parameter int unsigned ADDR_WIDTH          = 32,
  parameter int unsigned BE_WIDTH            = DATA_WIDTH/8,
  parameter int unsigned NUM_STREAMS         = 1, // Only 1 for now
  parameter int unsigned L2_SIZE           = 0,
  parameter int unsigned TwoDMidend          = 1, // Leave this on for now
  parameter int unsigned NB_OUTSND_BURSTS    = 8,
  parameter int unsigned GLOBAL_QUEUE_DEPTH  = 16,
  parameter int unsigned BACKEND_QUEUE_DEPTH = 16,
  parameter int unsigned RtMidend            = 0
) (
  input logic                      clk_i,
  input logic                      rst_ni,
  input logic                      test_mode_i,
  APB_BUS.Slave                    apb_sdma_cfg_bus, // core->sdma control interface
  AXI_BUS.Master                   axi_tcdm_master,
  AXI_BUS.Master                   axi_ext_master,
  output logic                     term_event_o,
  output logic                     term_irq_o,
  output logic                     busy_o
);

  localparam int unsigned MstIdxWidth = AXI_ID_WIDTH_MST_1;
  localparam int unsigned SlvIdxWidth = AXI_ID_WIDTH_MST_1 - $clog2(NUM_STREAMS);

  localparam int unsigned NumRegs = 1;
  localparam int unsigned NumEvents = 5;

  // AXI4+ATOP types
  typedef logic [AXI_ADDR_WIDTH-1:0]   addr_t;
  typedef logic [ADDR_WIDTH-1:0]       mem_addr_t;
  typedef logic [AXI_DATA_WIDTH-1:0]   data_t;
  typedef logic [SlvIdxWidth-1:0]      slv_id_t;
  typedef logic [MstIdxWidth-1:0]      mst_id_t;
  typedef logic [AXI_DATA_WIDTH/8-1:0] strb_t;
  typedef logic [AXI_USER_WIDTH-1:0]   user_t;
  // AXI4+ATOP channels typedefs
  `AXI_TYPEDEF_AW_CHAN_T(slv_aw_chan_t, addr_t, slv_id_t, user_t)
  `AXI_TYPEDEF_AW_CHAN_T(mst_aw_chan_t, addr_t, mst_id_t, user_t)
  `AXI_TYPEDEF_AW_CHAN_T(mem_aw_chan_t, mem_addr_t, mst_id_t, user_t)
  `AXI_TYPEDEF_W_CHAN_T(w_chan_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_B_CHAN_T(slv_b_chan_t, slv_id_t, user_t)
  `AXI_TYPEDEF_B_CHAN_T(mst_b_chan_t, mst_id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(slv_ar_chan_t, addr_t, slv_id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(mst_ar_chan_t, addr_t, mst_id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(mem_ar_chan_t, mem_addr_t, mst_id_t, user_t)
  `AXI_TYPEDEF_R_CHAN_T(slv_r_chan_t, data_t, slv_id_t, user_t)
  `AXI_TYPEDEF_R_CHAN_T(mst_r_chan_t, data_t, mst_id_t, user_t)
  `AXI_TYPEDEF_REQ_T(slv_req_t, slv_aw_chan_t, w_chan_t, slv_ar_chan_t)
  `AXI_TYPEDEF_REQ_T(mst_req_t, mst_aw_chan_t, w_chan_t, mst_ar_chan_t)
  `AXI_TYPEDEF_REQ_T(mem_req_t, mem_aw_chan_t, w_chan_t, mem_ar_chan_t)
  `AXI_TYPEDEF_RESP_T(slv_resp_t, slv_b_chan_t, slv_r_chan_t)
  `AXI_TYPEDEF_RESP_T(mst_resp_t, mst_b_chan_t, mst_r_chan_t)
  // BUS definitions
  mst_req_t  tcdm_req, ext_req;
  mst_resp_t ext_rsp;
  mst_resp_t tcdm_rsp;
  slv_req_t  [NUM_STREAMS-1:0] dma_req;
  slv_resp_t [NUM_STREAMS-1:0] dma_rsp;

  // mst1
  `AXI_ASSIGN_FROM_REQ(axi_ext_master, ext_req)
  `AXI_ASSIGN_TO_RESP(ext_rsp, axi_ext_master)

  // mst2
  `AXI_ASSIGN_FROM_REQ(axi_tcdm_master, tcdm_req_iwc)
  `AXI_ASSIGN_TO_RESP(tcdm_rsp_iwc, axi_tcdm_master)
  
  // Register BUS definitions
  `REG_BUS_TYPEDEF_ALL(dma_regs, logic[9:0], logic[31:0], logic[3:0])
  dma_regs_req_t dma_regs_req;
  dma_regs_rsp_t dma_regs_rsp;

  // iDMA struct definitions
  localparam int unsigned TFLenWidth  = AXI_ADDR_WIDTH;
  localparam int unsigned NumDim      = 2; // Support 2D midend for 2D transfers
  localparam int unsigned RepWidth    = 32;
  localparam int unsigned StrideWidth = 32;
  typedef logic [TFLenWidth-1:0]  tf_len_t;
  typedef logic [RepWidth-1:0]    reps_t;
  typedef logic [StrideWidth-1:0] strides_t;

  // iDMA request / response types
  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, slv_id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

  // iDMA ND request
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)

  idma_nd_req_t twod_req, twod_req_queue;
  idma_req_t burst_req;
  idma_rsp_t idma_rsp;

  logic fe_valid, twod_queue_valid, be_valid, be_rsp_valid;
  logic fe_ready, twod_queue_ready, be_ready, be_rsp_ready;
  logic trans_complete, midend_busy;
  idma_pkg::idma_busy_t idma_busy;

  // ------------------------------------------------------
  // FRONTEND
  // ------------------------------------------------------

  // SDMA control from core

  // regbus interface
  REG_BUS #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) regbus_sdma_cfg(clk_i);
  // apb to reg conversion
  apb_to_reg i_apb_to_regbus_sdma (
    .clk_i,
    .rst_ni,
    .penable_i ( apb_sdma_cfg_bus.penable  ),
    .pwrite_i  ( apb_sdma_cfg_bus.pwrite   ),
    .paddr_i   ( apb_sdma_cfg_bus.paddr    ),
    .psel_i    ( apb_sdma_cfg_bus.psel     ),
    .pwdata_i  ( apb_sdma_cfg_bus.pwdata   ),
    .prdata_o  ( apb_sdma_cfg_bus.prdata   ),
    .pready_o  ( apb_sdma_cfg_bus.pready   ),
    .pslverr_o ( apb_sdma_cfg_bus.pslverr  ),
    .reg_o     ( regbus_sdma_cfg )
  );

  // regbus to req/rsp
  `REG_BUS_ASSIGN_TO_REQ(dma_regs_req, regbus_sdma_cfg)
  `REG_BUS_ASSIGN_FROM_RSP(regbus_sdma_cfg, dma_regs_rsp)

  if (RtMidend) begin : gen_regs_rt_midend
    idma_reg32_rt_frontend #(
      .NumRegs        ( NumRegs        ),
      .IdCounterWidth ( 28             ),
      .dma_regs_req_t ( dma_regs_req_t ),
      .dma_regs_rsp_t ( dma_regs_rsp_t ),
      .burst_req_t    ( idma_nd_req_t  )
    ) i_idma_reg32_2d_frontend (
      .clk_i,
      .rst_ni,
      .dma_ctrl_req_i   ( dma_regs_req   ),
      .dma_ctrl_rsp_o   ( dma_regs_rsp   ),
      .burst_req_o      ( twod_req       ),
      .valid_o          ( fe_valid       ),
      .ready_i          ( fe_ready       ),
      .backend_idle_i   ( ~busy_o        ),
      .trans_complete_i ( trans_complete )
    );
  end else begin : gen_regs_no_rt_midend
    idma_reg32_2d_frontend #(
      .NumRegs        ( NumRegs        ),
      .IdCounterWidth ( 28             ),
      .dma_regs_req_t ( dma_regs_req_t ),
      .dma_regs_rsp_t ( dma_regs_rsp_t ),
      .burst_req_t    ( idma_nd_req_t  )
    ) i_idma_reg32_2d_frontend (
      .clk_i,
      .rst_ni,
      .dma_ctrl_req_i   ( dma_regs_req   ),
      .dma_ctrl_rsp_o   ( dma_regs_rsp   ),
      .burst_req_o      ( twod_req       ),
      .valid_o          ( fe_valid       ),
      .ready_i          ( fe_ready       ),
      .backend_idle_i   ( ~busy_o        ),
      .trans_complete_i ( trans_complete )
    );
  end

  // interrupts and events (currently broadcast tx_cplt event only)
  assign term_event_o    = |trans_complete ? '1 : '0;
  assign term_irq_o      = '0;

  assign busy_o = midend_busy | |idma_busy;

  // ------------------------------------------------------
  // MIDEND
  // ------------------------------------------------------

  // global (2D) request FIFO
  stream_fifo #(
    .DEPTH       ( GLOBAL_QUEUE_DEPTH ),
    .T           (idma_nd_req_t       )
  ) i_2D_request_fifo (
    .clk_i,
    .rst_ni,
    .flush_i    ( 1'b0            ),
    .testmode_i ( test_mode_i     ),
    .usage_o    (/*NOT CONNECTED*/),

    .data_i    ( twod_req         ),
    .valid_i   ( fe_valid         ),
    .ready_o   ( fe_ready         ),

    .data_o    ( twod_req_queue   ),
    .valid_o   ( twod_queue_valid ),
    .ready_i   ( twod_queue_ready )
  );

  localparam logic [1:0][31:0] RepWidths = '{default: 32'd32};

  if (RtMidend) begin : gen_rt_midend
     idma_rd_midend #(
      .NumEvents    ( NumEvents     ),
      .NumOutstanding ( NB_OUTSND_BURSTS ),              
      .addr_t       ( addr_t        ),
      .idma_rsp_t   ( idma_rsp_t    ),
      .idma_nd_req_t( idma_nd_req_t )
    ) i_idma_rt_midend (
      .clk_i,
      .rst_ni,

      .event_counts_i   ( rt_event_counts ),
      // linear bursts               
      .src_addr_i       ( rt_src_addr ),
      .dst_addr_i       ( rt_dst_addr ),
      .length_i         ( rt_length   ),
      // 1d bursts               
      .src_1d_stride_i  ( rt_src_1d_stride ),
      .dst_1d_stride_i  ( rt_dst_1d_stride ),
      .num_1d_reps_i    ( ),
      // 2d bursts (currently not supported)
      .src_2d_stride_i  ( '0 ),
      .dst_2d_stride_i  ( '0 ),
      .num_2d_reps_i    ( '0 ),

      // enable               
      .event_ena_i      ( rt_event_enable ),
      .event_counts_o   ( rt_event_count  ),      
          
      .nd_req_i         ( twod_req_queue   ),
      .nd_req_valid_i   ( twod_queue_valid ),
      .nd_req_ready_o   ( twod_queue_ready ),
    
      .nd_req_o         ( burst_req ),
      .nd_req_valid_o   ( be_valid  ),
      .nd_req_ready_i   ( be_ready  ),
    
      .burst_rsp_o      ( /*NOT CONNECTED*/ ),
      .burst_rsp_valid_o( trans_complete    ),
      .burst_rsp_ready_i( 1'b1              ),
    
      .burst_rsp_i      ( idma_rsp     ),
      .burst_rsp_valid_i( be_rsp_valid ),
      .burst_rsp_ready_o( be_rsp_ready ),
    
      .busy_o           ( midend_busy )
    );
  end else begin : gen_no_rt_midend  
    idma_nd_midend #(
      .NumDim       ( NumDim        ),
      .addr_t       ( addr_t        ),
      .idma_req_t   ( idma_req_t    ),
      .idma_rsp_t   ( idma_rsp_t    ),
      .idma_nd_req_t( idma_nd_req_t ),
      .RepWidths    ( RepWidths     )
    ) i_idma_2D_midend (
      .clk_i,
      .rst_ni,
    
      .nd_req_i         ( twod_req_queue   ),
      .nd_req_valid_i   ( twod_queue_valid ),
      .nd_req_ready_o   ( twod_queue_ready ),
    
      .nd_rsp_o         (/*NOT CONNECTED*/ ),
      .nd_rsp_valid_o   ( trans_complete   ),
      .nd_rsp_ready_i   ( 1'b1             ), // Always ready to accept completed transfers
    
      .burst_req_o      ( burst_req        ),
      .burst_req_valid_o( be_valid         ),
      .burst_req_ready_i( be_ready         ),
    
      .burst_rsp_i      ( idma_rsp         ),
      .burst_rsp_valid_i( be_rsp_valid     ),
      .burst_rsp_ready_o( be_rsp_ready     ),
    
      .busy_o           ( midend_busy      )
    );
  end

  // ------------------------------------------------------
  // BACKEND
  // ------------------------------------------------------

  idma_backend #(
    .Protocol            ( idma_pkg::AXI               ),
    .DataWidth           ( AXI_DATA_WIDTH              ),
    .AddrWidth           ( AXI_ADDR_WIDTH              ),
    .UserWidth           ( AXI_USER_WIDTH              ),
    .AxiIdWidth          ( AXI_ID_WIDTH_MST_1          ),
    .NumAxInFlight       ( NB_OUTSND_BURSTS            ),
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
    .protocol_req_t      ( slv_req_t                   ),
    .protocol_rsp_t      ( slv_resp_t                  ),
    .aw_chan_t           ( slv_aw_chan_t               ),
    .ar_chan_t           ( slv_ar_chan_t               )
  ) i_idma_backend (
    .clk_i,
    .rst_ni,
    .testmode_i    ( test_mode_i     ),

    .idma_req_i    ( burst_req       ),
    .req_valid_i   ( be_valid        ),
    .req_ready_o   ( be_ready        ),

    .idma_rsp_o    ( idma_rsp        ),
    .rsp_valid_o   ( be_rsp_valid    ),
    .rsp_ready_i   ( be_rsp_ready    ),

    .idma_eh_req_i ( '0              ), // No error handling
    .eh_req_valid_i( 1'b1            ),
    .eh_req_ready_o(/*NOT CONNECTED*/),

    .protocol_req_o ( dma_req         ),
    .protocol_rsp_i ( dma_rsp         ),
    .busy_o         ( idma_busy       )
  );

  // ------------------------------------------------------
  // AXI connection to EXT/TCDM
  // ------------------------------------------------------

  // xbar
  localparam int unsigned NumRules = 3;
  typedef struct packed {
    int unsigned idx;
    logic [AXI_ADDR_WIDTH-1:0] start_addr;
    logic [AXI_ADDR_WIDTH-1:0] end_addr;
  } xbar_rule_t;
  xbar_rule_t [NumRules-1:0] addr_map;
  logic [AXI_ADDR_WIDTH-1:0] tcdm_base_addr;
  assign tcdm_base_addr = 32'h1C00_0000; //`SOC_MEM_MAP_PRIVATE_BANK0_START_ADDR
  assign addr_map = '{
    '{ // SoC low
      start_addr: '0,
      end_addr:   tcdm_base_addr,
      idx:        0
    },
    '{ // TCDM
      start_addr: tcdm_base_addr,
      end_addr:   tcdm_base_addr + L2_SIZE,
      idx:        1
    },
    '{ // SoC high
      start_addr: tcdm_base_addr + L2_SIZE,
      end_addr:   '1,
      idx:        0
    }
  };
  localparam int unsigned NumMstPorts = 2;
  localparam int unsigned NumSlvPorts = NUM_STREAMS;

  /* verilator lint_off WIDTHCONCAT */
  localparam axi_pkg::xbar_cfg_t XbarCfg = '{
    NoSlvPorts:                    NumSlvPorts,
    NoMstPorts:                    NumMstPorts,
    MaxMstTrans:              NB_OUTSND_BURSTS,
    MaxSlvTrans:              NB_OUTSND_BURSTS,
    FallThrough:                          1'b0,
    LatencyMode:        axi_pkg::CUT_ALL_PORTS,
    PipelineStages:                          0,
    AxiIdWidthSlvPorts:            SlvIdxWidth,
    AxiIdUsedSlvPorts:             SlvIdxWidth,
    UniqueIds:                            1'b0,
    AxiAddrWidth:               AXI_ADDR_WIDTH,
    AxiDataWidth:               AXI_DATA_WIDTH,
    NoAddrRules:                      NumRules
  };
  /* verilator lint_on WIDTHCONCAT */

  axi_xbar #(
    .Cfg          ( XbarCfg       ),
    .slv_aw_chan_t( slv_aw_chan_t ),
    .mst_aw_chan_t( mst_aw_chan_t ),
    .w_chan_t     ( w_chan_t      ),
    .slv_b_chan_t ( slv_b_chan_t  ),
    .mst_b_chan_t ( mst_b_chan_t  ),
    .slv_ar_chan_t( slv_ar_chan_t ),
    .mst_ar_chan_t( mst_ar_chan_t ),
    .slv_r_chan_t ( slv_r_chan_t  ),
    .mst_r_chan_t ( mst_r_chan_t  ),
    .slv_req_t    ( slv_req_t     ),
    .slv_resp_t   ( slv_resp_t    ),
    .mst_req_t    ( mst_req_t     ),
    .mst_resp_t   ( mst_resp_t    ),
    .rule_t       ( xbar_rule_t   )
  ) i_dma_axi_xbar (
    .clk_i                  ( clk_i                 ),
    .rst_ni                 ( rst_ni                ),
    .test_i                 ( test_mode_i           ),
    .slv_ports_req_i        ( dma_req               ),
    .slv_ports_resp_o       ( dma_rsp               ),
    .mst_ports_req_o        ( { tcdm_req, ext_req } ),
    .mst_ports_resp_i       ( { tcdm_rsp, ext_rsp } ),
    .addr_map_i             ( addr_map              ),
    .en_default_mst_port_i  ( '0                    ),
    .default_mst_port_i     ( '0                    )
  );

  // AXI ID oup width conversion
  typedef logic [AXI_ID_WIDTH_MST_2-1:0] mst_id_iwc_t;

  `AXI_TYPEDEF_AW_CHAN_T(mst_aw_chan_iwc_t, addr_t, mst_id_iwc_t, user_t);
  `AXI_TYPEDEF_B_CHAN_T(mst_b_chan_iwc_t, mst_id_iwc_t, user_t);
  `AXI_TYPEDEF_AR_CHAN_T(mst_ar_chan_iwc_t, addr_t, mst_id_iwc_t, user_t);
  `AXI_TYPEDEF_R_CHAN_T(mst_r_chan_iwc_t, data_t, mst_id_iwc_t, user_t);

  `AXI_TYPEDEF_REQ_T(mst_req_iwc_t, mst_aw_chan_iwc_t, w_chan_t, mst_ar_chan_iwc_t);
  `AXI_TYPEDEF_RESP_T(mst_resp_iwc_t, mst_b_chan_iwc_t, mst_r_chan_iwc_t);

  mst_req_iwc_t      tcdm_req_iwc;
  mst_resp_iwc_t     tcdm_rsp_iwc;

  // Convert AXI req/rsp widths as necessary
  // One AXI has all the widths already correct (

  // ID width converter
  axi_iw_converter #(
    .AxiSlvPortIdWidth      ( AXI_ID_WIDTH_MST_1     ),
    .AxiMstPortIdWidth      ( AXI_ID_WIDTH_MST_2     ),
    .AxiSlvPortMaxUniqIds   ( 16                     ),
    .AxiSlvPortMaxTxnsPerId ( 13                     ),
    .AxiSlvPortMaxTxns      (                        ),
    .AxiMstPortMaxUniqIds   (                        ),
    .AxiMstPortMaxTxnsPerId (                        ),
    .AxiAddrWidth           ( AXI_ADDR_WIDTH         ),
    .AxiDataWidth           ( AXI_DATA_WIDTH         ),
    .AxiUserWidth           ( AXI_USER_WIDTH         ),
    .slv_req_t              ( mst_req_t              ),
    .slv_resp_t             ( mst_resp_t             ),
    .mst_req_t              ( mst_req_iwc_t          ),
    .mst_resp_t             ( mst_resp_iwc_t         )
  ) i_axi_iwc_fc_idma (
    .clk_i,
    .rst_ni,
    .slv_req_i  ( tcdm_req      ),
    .slv_resp_o ( tcdm_rsp      ),
    .mst_req_o  ( tcdm_req_iwc  ),
    .mst_resp_i ( tcdm_rsp_iwc  )
  );

endmodule : dmac_wrap_fc_idma

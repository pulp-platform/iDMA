// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/*
 * dmac_wrap.sv
 * Thomas Benz <tbenz@iis.ee.ethz.ch>
 * Michael Rogenmoser <michaero@iis.ee.ethz.ch>
 */

// DMA Core wrapper

`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "idma/typedef.svh"
`include "register_interface/typedef.svh"

module dmac_wrap #(
  parameter int unsigned NB_CORES            = 4,
  parameter int unsigned AXI_ADDR_WIDTH      = 32,
  parameter int unsigned AXI_DATA_WIDTH      = 64,
  parameter int unsigned AXI_USER_WIDTH      = 6,
  parameter int unsigned AXI_ID_WIDTH        = 4,
  parameter int unsigned PE_ID_WIDTH         = 1,
  parameter int unsigned NB_PE_PORTS         = 1,
  parameter int unsigned DATA_WIDTH          = 32,
  parameter int unsigned ADDR_WIDTH          = 32,
  parameter int unsigned BE_WIDTH            = DATA_WIDTH/8,
  parameter int unsigned NUM_STREAMS         = 1, // Only 1 for now
  parameter int unsigned TCDM_SIZE           = 0,
  parameter int unsigned TwoDMidend          = 1, // Leave this on for now
  parameter int unsigned NB_OUTSND_BURSTS    = 8,
  parameter int unsigned GLOBAL_QUEUE_DEPTH  = 16,
  parameter int unsigned BACKEND_QUEUE_DEPTH = 16
) (
  input logic                      clk_i,
  input logic                      rst_ni,
  input logic                      test_mode_i,
  XBAR_PERIPH_BUS.Slave            pe_ctrl_slave[NB_PE_PORTS-1:0],
  XBAR_TCDM_BUS.Slave              ctrl_slave[NB_CORES-1:0],
  hci_core_intf.master             tcdm_master[3:0],
  AXI_BUS.Master                   ext_master,
  output logic [NB_CORES-1:0]      term_event_o,
  output logic [NB_CORES-1:0]      term_irq_o,
  output logic [NB_PE_PORTS-1:0]   term_event_pe_o,
  output logic [NB_PE_PORTS-1:0]   term_irq_pe_o,
  output logic                     busy_o
);

  localparam int unsigned NumRegs = NB_CORES+NB_PE_PORTS;
  localparam int unsigned MstIdxWidth = AXI_ID_WIDTH;
  localparam int unsigned SlvIdxWidth = AXI_ID_WIDTH - $clog2(NUM_STREAMS);

  // CORE --> MCHAN CTRL INTERFACE BUS SIGNALS
  logic [NumRegs-1:0][DATA_WIDTH-1:0]  config_wdata;
  logic [NumRegs-1:0][ADDR_WIDTH-1:0]  config_add;
  logic [NumRegs-1:0]                  config_req;
  logic [NumRegs-1:0]                  config_wen;
  logic [NumRegs-1:0][BE_WIDTH-1:0]    config_be;
  logic [NumRegs-1:0][PE_ID_WIDTH-1:0] config_id;
  logic [NumRegs-1:0]                  config_gnt;
  logic [NumRegs-1:0][DATA_WIDTH-1:0]  config_r_rdata;
  logic [NumRegs-1:0]                  config_r_valid;
  logic [NumRegs-1:0]                  config_r_opc;
  logic [NumRegs-1:0][PE_ID_WIDTH-1:0] config_r_id;

  // tie-off pe control ports
  for (genvar i = 0; i < NB_CORES; i++) begin : gen_ctrl_registers
    assign config_add[i]         = ctrl_slave[i].add;
    assign config_req[i]         = ctrl_slave[i].req;
    assign config_wdata[i]       = ctrl_slave[i].wdata;
    assign config_wen[i]         = ctrl_slave[i].wen;
    assign config_be[i]          = ctrl_slave[i].be;
    assign config_id[i]          = '0;
    assign ctrl_slave[i].gnt     = config_gnt[i];
    assign ctrl_slave[i].r_opc   = config_r_opc[i];
    assign ctrl_slave[i].r_valid = config_r_valid[i];
    assign ctrl_slave[i].r_rdata = config_r_rdata[i];
  end

  for (genvar i = 0; i < NB_PE_PORTS; i++) begin : gen_pe_ctrl_registers
    assign config_add[NB_CORES+i]         = pe_ctrl_slave[i].add;
    assign config_req[NB_CORES+i]         = pe_ctrl_slave[i].req;
    assign config_wdata[NB_CORES+i]       = pe_ctrl_slave[i].wdata;
    assign config_wen[NB_CORES+i]         = pe_ctrl_slave[i].wen;
    assign config_be[NB_CORES+i]          = pe_ctrl_slave[i].be;
    assign config_id[NB_CORES+i]          = pe_ctrl_slave[i].id;
    assign pe_ctrl_slave[i].gnt     = config_gnt[NB_CORES+i];
    assign pe_ctrl_slave[i].r_opc   = config_r_opc[NB_CORES+i];
    assign pe_ctrl_slave[i].r_valid = config_r_valid[NB_CORES+i];
    assign pe_ctrl_slave[i].r_rdata = config_r_rdata[NB_CORES+i];
    assign pe_ctrl_slave[i].r_id    = config_r_id[NB_CORES+i];
  end

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
  mst_req_t  tcdm_req, soc_req;
  mem_req_t  tcdm_read_req, tcdm_write_req;
  mst_resp_t soc_rsp, tcdm_read_rsp, tcdm_write_rsp;
  mst_resp_t tcdm_rsp;
  slv_req_t  [NUM_STREAMS-1:0] dma_req;
  slv_resp_t [NUM_STREAMS-1:0] dma_rsp;
  // interface to structs
  `AXI_ASSIGN_FROM_REQ(ext_master, soc_req)
  `AXI_ASSIGN_TO_RESP(soc_rsp, ext_master)

  // Register BUS definitions
  `REG_BUS_TYPEDEF_ALL(dma_regs, logic[9:0], logic[31:0], logic[3:0])
  dma_regs_req_t [NumRegs-1:0] dma_regs_req;
  dma_regs_rsp_t [NumRegs-1:0] dma_regs_rsp;

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

  for (genvar i = 0; i < NumRegs; i++) begin : gen_core_regs
    periph_to_reg #(
      .AW    ( 10             ),
      .DW    ( 32             ),
      .BW    ( 8              ),
      .IW    ( PE_ID_WIDTH    ),
      .req_t ( dma_regs_req_t ),
      .rsp_t ( dma_regs_rsp_t )
    ) i_pe_translate (
      .clk_i,
      .rst_ni,
      .req_i     ( config_req     [i] ),
      .add_i     ( config_add     [i][9:0] ),
      .wen_i     ( config_wen     [i] ),
      .wdata_i   ( config_wdata   [i] ),
      .be_i      ( config_be      [i] ),
      .id_i      ( config_id      [i] ),
      .gnt_o     ( config_gnt     [i] ),
      .r_rdata_o ( config_r_rdata [i] ),
      .r_opc_o   ( config_r_opc   [i] ),
      .r_id_o    ( config_r_id    [i] ),
      .r_valid_o ( config_r_valid [i] ),
      .reg_req_o ( dma_regs_req   [i] ),
      .reg_rsp_i ( dma_regs_rsp   [i] )
    );
  end

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

  // interrupts and events (currently broadcast tx_cplt event only)
  assign term_event_pe_o = |trans_complete ? '1 : '0;
  assign term_irq_pe_o   = '0;
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

  idma_nd_midend #(
    .NumDim       ( 32'd2         ),
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

  // ------------------------------------------------------
  // BACKEND
  // ------------------------------------------------------

  idma_backend #(
    .DataWidth           ( AXI_DATA_WIDTH              ),
    .AddrWidth           ( AXI_ADDR_WIDTH              ),
    .UserWidth           ( AXI_USER_WIDTH              ),
    .AxiIdWidth          ( AXI_ID_WIDTH                ),
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
    .axi_req_t           ( slv_req_t                   ),
    .axi_rsp_t           ( slv_resp_t                  )
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

    .axi_req_o     ( dma_req         ),
    .axi_rsp_i     ( dma_rsp         ),
    .busy_o        ( idma_busy       )
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
  logic [AXI_ADDR_WIDTH-1:0] cluster_base_addr;
  assign cluster_base_addr = 32'h1000_0000; /* + (cluster_id_i << 22);*/
  assign addr_map = '{
    '{ // SoC low
      start_addr: '0,
      end_addr:   cluster_base_addr,
      idx:        0
    },
    '{ // TCDM
      start_addr: cluster_base_addr,
      end_addr:   cluster_base_addr + TCDM_SIZE,
      idx:        1
    },
    '{ // SoC high
      start_addr: cluster_base_addr + TCDM_SIZE,
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
    .slv_ports_req_i        ( dma_req          ),
    .slv_ports_resp_o       ( dma_rsp          ),
    .mst_ports_req_o        ( { tcdm_req, soc_req } ),
    .mst_ports_resp_i       ( { tcdm_rsp, soc_rsp } ),
    .addr_map_i             ( addr_map              ),
    .en_default_mst_port_i  ( '0                    ),
    .default_mst_port_i     ( '0                    )
  );

  // split AXI bus in read and write
  always_comb begin : proc_tcdm_axi_rw_split
    `AXI_SET_R_STRUCT(tcdm_rsp.r, tcdm_read_rsp.r)
    tcdm_rsp.r_valid        = tcdm_read_rsp.r_valid;
    tcdm_rsp.ar_ready       = tcdm_read_rsp.ar_ready;
    `AXI_SET_B_STRUCT(tcdm_rsp.b, tcdm_write_rsp.b)
    tcdm_rsp.b_valid        = tcdm_write_rsp.b_valid;
    tcdm_rsp.w_ready        = tcdm_write_rsp.w_ready;
    tcdm_rsp.aw_ready       = tcdm_write_rsp.aw_ready;

    tcdm_write_req          = '0;
    `AXI_SET_AW_STRUCT(tcdm_write_req.aw, tcdm_req.aw)
    tcdm_write_req.aw.addr  = tcdm_req.aw.addr[ADDR_WIDTH-1:0];
    tcdm_write_req.aw_valid = tcdm_req.aw_valid;
    `AXI_SET_W_STRUCT(tcdm_write_req.w, tcdm_req.w)
    tcdm_write_req.w_valid  = tcdm_req.w_valid;
    tcdm_write_req.b_ready  = tcdm_req.b_ready;

    tcdm_read_req           = '0;
    `AXI_SET_AR_STRUCT(tcdm_read_req.ar, tcdm_req.ar)
    tcdm_read_req.ar.addr   = tcdm_req.ar.addr[ADDR_WIDTH-1:0];
    tcdm_read_req.ar_valid  = tcdm_req.ar_valid;
    tcdm_read_req.r_ready   = tcdm_req.r_ready;
  end

  logic tcdm_master_we_0, tcdm_master_we_1, tcdm_master_we_2, tcdm_master_we_3;

  localparam int unsigned TcdmFifoDepth = 1;

  idma_axi_to_mem #(
    .axi_req_t   ( mem_req_t           ),
    .axi_resp_t  ( mst_resp_t          ),
    .AddrWidth   ( ADDR_WIDTH          ),
    .DataWidth   ( AXI_DATA_WIDTH      ),
    .IdWidth     ( MstIdxWidth         ),
    .NumBanks    ( 2                   ),
    .BufDepth    ( TcdmFifoDepth       )
  ) i_axi_to_mem_read (
    .clk_i        ( clk_i         ),
    .rst_ni       ( rst_ni        ),
    .busy_o       ( ),
    .axi_req_i    ( tcdm_read_req ),
    .axi_resp_o   ( tcdm_read_rsp ),
    .mem_req_o    ( { tcdm_master[0].req,     tcdm_master[1].req     } ),
    .mem_gnt_i    ( { tcdm_master[0].gnt,     tcdm_master[1].gnt     } ),
    .mem_addr_o   ( { tcdm_master[0].add,     tcdm_master[1].add     } ),
    .mem_wdata_o  ( { tcdm_master[0].data,    tcdm_master[1].data    } ),
    .mem_strb_o   ( { tcdm_master[0].be,      tcdm_master[1].be      } ),
    // .mem_atop_o   ( ),
    .mem_we_o     ( { tcdm_master_we_0,       tcdm_master_we_1       } ),
    .mem_rvalid_i ( { tcdm_master[0].r_valid, tcdm_master[1].r_valid } ),
    .mem_rdata_i  ( { tcdm_master[0].r_data,  tcdm_master[1].r_data  } )
  );

  idma_axi_to_mem #(
    .axi_req_t   ( mem_req_t           ),
    .axi_resp_t  ( mst_resp_t          ),
    .AddrWidth   ( ADDR_WIDTH          ),
    .DataWidth   ( AXI_DATA_WIDTH      ),
    .IdWidth     ( MstIdxWidth         ),
    .NumBanks    ( 2                   ),
    .BufDepth    ( TcdmFifoDepth       )
  ) i_axi_to_mem_write (
    .clk_i        ( clk_i          ),
    .rst_ni       ( rst_ni         ),
    .busy_o       ( ),
    .axi_req_i    ( tcdm_write_req ),
    .axi_resp_o   ( tcdm_write_rsp ),
    .mem_req_o    ( { tcdm_master[2].req,     tcdm_master[3].req     } ),
    .mem_gnt_i    ( { tcdm_master[2].gnt,     tcdm_master[3].gnt     } ),
    .mem_addr_o   ( { tcdm_master[2].add,     tcdm_master[3].add     } ),
    .mem_wdata_o  ( { tcdm_master[2].data,    tcdm_master[3].data    } ),
    .mem_strb_o   ( { tcdm_master[2].be,      tcdm_master[3].be      } ),
    // .mem_atop_o   ( ),
    .mem_we_o     ( { tcdm_master_we_2,       tcdm_master_we_3       } ),
    .mem_rvalid_i ( { tcdm_master[2].r_valid, tcdm_master[3].r_valid } ),
    .mem_rdata_i  ( { tcdm_master[2].r_data,  tcdm_master[3].r_data  } )
  );

  // tie-off TCDM master port
  // for (genvar i = 0; i < 4; i++) begin : gen_tie_off_unused_tcdm_master
  //     assign tcdm_master[i].r_opc   = '0;
  // end

  // flip we polarity
  assign tcdm_master[0].wen = !tcdm_master_we_0;
  assign tcdm_master[1].wen = !tcdm_master_we_1;
  assign tcdm_master[2].wen = !tcdm_master_we_2;
  assign tcdm_master[3].wen = !tcdm_master_we_3;

  assign tcdm_master[0].boffs = '0;
  assign tcdm_master[1].boffs = '0;
  assign tcdm_master[2].boffs = '0;
  assign tcdm_master[3].boffs = '0;

  assign tcdm_master[0].lrdy  = '1;
  assign tcdm_master[1].lrdy  = '1;
  assign tcdm_master[2].lrdy  = '1;
  assign tcdm_master[3].lrdy  = '1;

  assign tcdm_master[0].user  = '0;
  assign tcdm_master[1].user  = '0;
  assign tcdm_master[2].user  = '0;
  assign tcdm_master[3].user  = '0;

endmodule : dmac_wrap

// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Michael Rogenmoser <michaero@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@student.ethz.ch>

`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "idma/typedef.svh"
`include "register_interface/typedef.svh"

/// DMA Core wrapper
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
  parameter int unsigned TCDM_SIZE           = 0,
  parameter int unsigned TwoDMidend          = 1, // Leave this on for now
  parameter int unsigned NB_OUTSND_BURSTS    = 8,
  parameter int unsigned GLOBAL_QUEUE_DEPTH  = 16,
  parameter int unsigned BACKEND_QUEUE_DEPTH = 16,
  parameter int unsigned NUM_STREAMS         = 1,
  parameter int unsigned DUAL_BACKEND        = 0
  // 0 -> Single AXI-OBI Backend
  // 1 -> One AXI to OBI and one OBI to AXI Backend
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

  localparam int unsigned NumRegs = NB_CORES + NB_PE_PORTS;
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
  typedef logic [AXI_DATA_WIDTH-1:0]   data_t;
  typedef logic [MstIdxWidth-1:0]      mst_id_t;
  typedef logic [AXI_DATA_WIDTH/8-1:0] strb_t;
  typedef logic [AXI_USER_WIDTH-1:0]   user_t;
  // AXI4+ATOP channels typedefs
  `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, mst_id_t, user_t)
  `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, mst_id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, mst_id_t, user_t)
  `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, mst_id_t, user_t)
  `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
  `AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)
  // OBI channels typedefs
  `IDMA_OBI_TYPEDEF_A_CHAN_T(obi_a_chan_t, addr_t, data_t, strb_t)
  `IDMA_OBI_TYPEDEF_R_CHAN_T(obi_r_chan_t, data_t)

  `IDMA_OBI_TYPEDEF_REQ_T(obi_req_t, obi_a_chan_t)
  `IDMA_OBI_TYPEDEF_RESP_T(obi_rsp_t, obi_r_chan_t)

  // Calculate padding (keep it static for now!)
  localparam int unsigned ObiAChanWidth  = AXI_ADDR_WIDTH + AXI_DATA_WIDTH + AXI_DATA_WIDTH/8 + 32'd1;
  localparam int unsigned AxiAwChanWidth = axi_pkg::aw_width(AXI_ADDR_WIDTH, MstIdxWidth, AXI_USER_WIDTH);
  localparam int unsigned AxiArChanWidth = axi_pkg::ar_width(AXI_ADDR_WIDTH, MstIdxWidth, AXI_USER_WIDTH);
  localparam int unsigned ArMetaPadWidth = ObiAChanWidth - AxiArChanWidth;
  localparam int unsigned AwMetaPadWidth = ObiAChanWidth - AxiAwChanWidth;


  // DMA Meta Channels
  typedef struct packed {
      axi_ar_chan_t              ar_chan;
      logic [ArMetaPadWidth-1:0] padding;
  } axi_read_ar_chan_padded_t;

  typedef struct packed {
      obi_a_chan_t a_chan;
  } obi_read_a_chan_padded_t;

  typedef union packed {
      axi_read_ar_chan_padded_t axi;
      obi_read_a_chan_padded_t  obi;
  } read_meta_channel_t;

  typedef struct packed {
      axi_aw_chan_t              aw_chan;
      logic [AwMetaPadWidth-1:0] padding;
  } axi_write_aw_chan_padded_t;

  typedef struct packed {
      obi_a_chan_t a_chan;
  } obi_write_a_chan_padded_t;

  typedef union packed {
      axi_write_aw_chan_padded_t axi;
      obi_write_a_chan_padded_t  obi;
  } write_meta_channel_t;

  // BUS definitions
  axi_req_t axi_read_req, axi_write_req, soc_req;
  axi_rsp_t axi_read_rsp, axi_write_rsp, soc_rsp;

  obi_req_t obi_read_req, obi_write_req;
  obi_rsp_t obi_read_rsp, obi_write_rsp;

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
  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, mst_id_t, addr_t, tf_len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

  // iDMA ND request
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)

  idma_nd_req_t twod_req, twod_req_queue;

  logic fe_valid, twod_queue_valid;
  logic fe_ready, twod_queue_ready;
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
  assign term_event_pe_o = |(trans_complete) ? '1 : '0;
  assign term_irq_pe_o   = '0;
  assign term_event_o    = |(trans_complete) ? '1 : '0;
  assign term_irq_o      = '0;

  assign busy_o = midend_busy | (|idma_busy);

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

  if (DUAL_BACKEND) begin : gen_split_axi_to_from_obi_backend
    logic [1:0] twod_queue_valid_demux;
    logic [1:0] twod_queue_ready_demux;

    stream_demux #(
      .N_OUP ( 2 )
    ) i_stream_demux (
      .inp_valid_i ( twod_queue_valid ),
      .inp_ready_o ( twod_queue_ready ),
      //0 -> AXI to OBI
      //1 -> OBI to AXI
      .oup_sel_i   ( twod_req_queue.burst_req.opt.src_protocol == idma_pkg::OBI ),

      .oup_valid_o ( twod_queue_valid_demux ),
      .oup_ready_i ( twod_queue_ready_demux )
    );

    logic [1:0] trans_complete_demux;
    idma_req_t [1:0] burst_req_demux;
    logic [1:0] be_valid_demux;
    logic [1:0] be_ready_demux;

    idma_rsp_t [1:0] idma_rsp_demux;
    logic [1:0] be_rsp_valid_demux;
    logic [1:0] be_rsp_ready_demux;

    logic [1:0] midend_busy_demux;

    idma_pkg::idma_busy_t [1:0] idma_busy_demux;

    assign trans_complete = |trans_complete_demux;
    assign midend_busy    = |midend_busy_demux;
    assign idma_busy      = idma_busy_demux[0] | idma_busy_demux[1];

    idma_nd_midend #(
      .NumDim       ( NumDim        ),
      .addr_t       ( addr_t        ),
      .idma_req_t   ( idma_req_t    ),
      .idma_rsp_t   ( idma_rsp_t    ),
      .idma_nd_req_t( idma_nd_req_t ),
      .RepWidths    ( RepWidths     )
    ) i_idma_2D_midend_axi_to_obi (
      .clk_i,
      .rst_ni,

      .nd_req_i         ( twod_req_queue            ),
      .nd_req_valid_i   ( twod_queue_valid_demux[0] ),
      .nd_req_ready_o   ( twod_queue_ready_demux[0] ),

      .nd_rsp_o         (/*NOT CONNECTED*/        ),
      .nd_rsp_valid_o   ( trans_complete_demux[0] ),
      .nd_rsp_ready_i   ( 1'b1                    ), // Always ready to accept completed transfers

      .burst_req_o      ( burst_req_demux[0] ),
      .burst_req_valid_o( be_valid_demux[0]  ),
      .burst_req_ready_i( be_ready_demux[0]  ),

      .burst_rsp_i      ( idma_rsp_demux[0]     ),
      .burst_rsp_valid_i( be_rsp_valid_demux[0] ),
      .burst_rsp_ready_o( be_rsp_ready_demux[0] ),

      .busy_o           ( midend_busy_demux[0]  )
    );

    idma_nd_midend #(
      .NumDim       ( NumDim        ),
      .addr_t       ( addr_t        ),
      .idma_req_t   ( idma_req_t    ),
      .idma_rsp_t   ( idma_rsp_t    ),
      .idma_nd_req_t( idma_nd_req_t ),
      .RepWidths    ( RepWidths     )
    ) i_idma_2D_midend_obi_to_axi (
      .clk_i,
      .rst_ni,

      .nd_req_i         ( twod_req_queue            ),
      .nd_req_valid_i   ( twod_queue_valid_demux[1] ),
      .nd_req_ready_o   ( twod_queue_ready_demux[1] ),

      .nd_rsp_o         (/*NOT CONNECTED*/        ),
      .nd_rsp_valid_o   ( trans_complete_demux[1] ),
      .nd_rsp_ready_i   ( 1'b1                    ), // Always ready to accept completed transfers

      .burst_req_o      ( burst_req_demux[1] ),
      .burst_req_valid_o( be_valid_demux[1]  ),
      .burst_req_ready_i( be_ready_demux[1]  ),

      .burst_rsp_i      ( idma_rsp_demux[1]     ),
      .burst_rsp_valid_i( be_rsp_valid_demux[1] ),
      .burst_rsp_ready_o( be_rsp_ready_demux[1] ),

      .busy_o           ( midend_busy_demux[1]  )
    );

    // ------------------------------------------------------
    // BACKEND
    // ------------------------------------------------------

    idma_backend_r_axi_w_obi #(
        .DataWidth            ( AXI_DATA_WIDTH              ),
        .AddrWidth            ( AXI_ADDR_WIDTH              ),
        .AxiIdWidth           ( AXI_ID_WIDTH                ),
        .UserWidth            ( AXI_USER_WIDTH              ),
        .TFLenWidth           ( TFLenWidth                  ),
        .MaskInvalidData      ( 1'b1                        ),
        .BufferDepth          ( 3                           ),
        .RAWCouplingAvail     ( 1'b0                        ),
        .HardwareLegalizer    ( 1'b1                        ),
        .RejectZeroTransfers  ( 1'b1                        ),
        .ErrorCap             ( idma_pkg::NO_ERROR_HANDLING ),
        .PrintFifoInfo        ( 1'b0                        ),
        .NumAxInFlight        ( NB_OUTSND_BURSTS            ),
        .MemSysDepth          ( 32'd0                       ),
        .idma_req_t           ( idma_req_t                  ),
        .idma_rsp_t           ( idma_rsp_t                  ),
        .idma_eh_req_t        ( idma_pkg::idma_eh_req_t     ),
        .idma_busy_t          ( idma_pkg::idma_busy_t       ),
        .axi_req_t            ( axi_req_t                   ),
        .axi_rsp_t            ( axi_rsp_t                   ),
        .obi_req_t            ( obi_req_t                   ),
        .obi_rsp_t            ( obi_rsp_t                   ),
        .write_meta_channel_t ( write_meta_channel_t        ),
        .read_meta_channel_t  ( read_meta_channel_t         )
    ) i_idma_backend_axi_to_obi (
        .clk_i                ( clk_i                 ),
        .rst_ni               ( rst_ni                ),
        .testmode_i           ( test_mode_i           ),

        .idma_req_i           ( burst_req_demux[0]    ),
        .req_valid_i          ( be_valid_demux[0]     ),
        .req_ready_o          ( be_ready_demux[0]     ),

        .idma_rsp_o           ( idma_rsp_demux[0]     ),
        .rsp_valid_o          ( be_rsp_valid_demux[0] ),
        .rsp_ready_i          ( be_rsp_ready_demux[0] ),

        .idma_eh_req_i        ( '0                    ),
        .eh_req_valid_i       ( 1'b1                  ),
        .eh_req_ready_o       ( /* NOT CONNECTED */   ),

        .axi_read_req_o       ( axi_read_req          ),
        .axi_read_rsp_i       ( axi_read_rsp          ),

        .obi_write_req_o      ( obi_write_req         ),
        .obi_write_rsp_i      ( obi_write_rsp         ),

        .busy_o               ( idma_busy_demux[0]    )
    );

    idma_backend_w_axi_r_obi #(
        .DataWidth            ( AXI_DATA_WIDTH              ),
        .AddrWidth            ( AXI_ADDR_WIDTH              ),
        .AxiIdWidth           ( AXI_ID_WIDTH                ),
        .UserWidth            ( AXI_USER_WIDTH              ),
        .TFLenWidth           ( TFLenWidth                  ),
        .MaskInvalidData      ( 1'b1                        ),
        .BufferDepth          ( 3                           ),
        .RAWCouplingAvail     ( 1'b0                        ),
        .HardwareLegalizer    ( 1'b1                        ),
        .RejectZeroTransfers  ( 1'b1                        ),
        .ErrorCap             ( idma_pkg::NO_ERROR_HANDLING ),
        .PrintFifoInfo        ( 1'b0                        ),
        .NumAxInFlight        ( NB_OUTSND_BURSTS            ),
        .MemSysDepth          ( 32'd0                       ),
        .idma_req_t           ( idma_req_t                  ),
        .idma_rsp_t           ( idma_rsp_t                  ),
        .idma_eh_req_t        ( idma_pkg::idma_eh_req_t     ),
        .idma_busy_t          ( idma_pkg::idma_busy_t       ),
        .axi_req_t            ( axi_req_t                   ),
        .axi_rsp_t            ( axi_rsp_t                   ),
        .obi_req_t            ( obi_req_t                   ),
        .obi_rsp_t            ( obi_rsp_t                   ),
        .write_meta_channel_t ( write_meta_channel_t        ),
        .read_meta_channel_t  ( read_meta_channel_t         )
    ) i_idma_backend_obi_to_axi (
        .clk_i                ( clk_i                 ),
        .rst_ni               ( rst_ni                ),
        .testmode_i           ( test_mode_i           ),

        .idma_req_i           ( burst_req_demux[1]    ),
        .req_valid_i          ( be_valid_demux[1]     ),
        .req_ready_o          ( be_ready_demux[1]     ),

        .idma_rsp_o           ( idma_rsp_demux[1]     ),
        .rsp_valid_o          ( be_rsp_valid_demux[1] ),
        .rsp_ready_i          ( be_rsp_ready_demux[1] ),

        .idma_eh_req_i        ( '0                    ),
        .eh_req_valid_i       ( 1'b1                  ),
        .eh_req_ready_o       ( /* NOT CONNECTED */   ),

        .axi_write_req_o      ( axi_write_req         ),
        .axi_write_rsp_i      ( axi_write_rsp         ),

        .obi_read_req_o       ( obi_read_req          ),
        .obi_read_rsp_i       ( obi_read_rsp          ),

        .busy_o               ( idma_busy_demux[1]    )
    );
  end else begin : gen_single_axi_obi_backend
    idma_req_t burst_req;
    idma_rsp_t idma_rsp;
    logic be_valid, be_rsp_valid;
    logic be_ready, be_rsp_ready;

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

    // ------------------------------------------------------
    // BACKEND
    // ------------------------------------------------------

    idma_backend_rw_axi_rw_obi #(
        .DataWidth            ( AXI_DATA_WIDTH              ),
        .AddrWidth            ( AXI_ADDR_WIDTH              ),
        .AxiIdWidth           ( AXI_ID_WIDTH                ),
        .UserWidth            ( AXI_USER_WIDTH              ),
        .TFLenWidth           ( TFLenWidth                  ),
        .MaskInvalidData      ( 1'b1                        ),
        .BufferDepth          ( 3                           ),
        .RAWCouplingAvail     ( 1'b0                        ),
        .HardwareLegalizer    ( 1'b1                        ),
        .RejectZeroTransfers  ( 1'b1                        ),
        .ErrorCap             ( idma_pkg::NO_ERROR_HANDLING ),
        .PrintFifoInfo        ( 1'b0                        ),
        .NumAxInFlight        ( NB_OUTSND_BURSTS            ),
        .MemSysDepth          ( 32'd0                       ),
        .idma_req_t           ( idma_req_t                  ),
        .idma_rsp_t           ( idma_rsp_t                  ),
        .idma_eh_req_t        ( idma_pkg::idma_eh_req_t     ),
        .idma_busy_t          ( idma_pkg::idma_busy_t       ),
        .axi_req_t            ( axi_req_t                   ),
        .axi_rsp_t            ( axi_rsp_t                   ),
        .obi_req_t            ( obi_req_t                   ),
        .obi_rsp_t            ( obi_rsp_t                   ),
        .write_meta_channel_t ( write_meta_channel_t        ),
        .read_meta_channel_t  ( read_meta_channel_t         )
    ) i_idma_backend  (
        .clk_i                ( clk_i               ),
        .rst_ni               ( rst_ni              ),
        .testmode_i           ( test_mode_i         ),

        .idma_req_i           ( burst_req           ),
        .req_valid_i          ( be_valid            ),
        .req_ready_o          ( be_ready            ),

        .idma_rsp_o           ( idma_rsp            ),
        .rsp_valid_o          ( be_rsp_valid        ),
        .rsp_ready_i          ( be_rsp_ready        ),

        .idma_eh_req_i        ( '0                  ),
        .eh_req_valid_i       ( 1'b1                ),
        .eh_req_ready_o       ( /* NOT CONNECTED */ ),

        .axi_read_req_o       ( axi_read_req        ),
        .axi_read_rsp_i       ( axi_read_rsp        ),

        .obi_read_req_o       ( obi_read_req        ),
        .obi_read_rsp_i       ( obi_read_rsp        ),

        .axi_write_req_o      ( axi_write_req       ),
        .axi_write_rsp_i      ( axi_write_rsp       ),

        .obi_write_req_o      ( obi_write_req       ),
        .obi_write_rsp_i      ( obi_write_rsp       ),

        .busy_o               ( idma_busy           )
    );
  end

  // ------------------------------------------------------
  // AXI RW Join
  // ------------------------------------------------------

  axi_rw_join #(
      .axi_req_t        ( axi_req_t ),
      .axi_resp_t       ( axi_rsp_t )
  ) i_axi_soc_rw_join (
      .clk_i            ( clk_i         ),
      .rst_ni           ( rst_ni        ),
      .slv_read_req_i   ( axi_read_req  ),
      .slv_read_resp_o  ( axi_read_rsp  ),
      .slv_write_req_i  ( axi_write_req ),
      .slv_write_resp_o ( axi_write_rsp ),
      .mst_req_o        ( soc_req       ),
      .mst_resp_i       ( soc_rsp       )
  );

  // ------------------------------------------------------
  // TCDM Bank Split
  // ------------------------------------------------------

  logic tcdm_master_we_0;
  logic tcdm_master_we_1;
  logic tcdm_master_we_2;
  logic tcdm_master_we_3;

  mem_to_banks #(
    .AddrWidth( AXI_ADDR_WIDTH ),
    .DataWidth( AXI_DATA_WIDTH ),
    .NumBanks ( 2              ),
    .HideStrb ( 1'b1           ),
    .MaxTrans ( 32'd1          )
  ) i_mem_to_banks_write (
    .clk_i         ( clk_i  ),
    .rst_ni        ( rst_ni ),

    .req_i         ( obi_write_req.a_req       ),
    .addr_i        ( obi_write_req.a.addr      ),
    .wdata_i       ( obi_write_req.a.wdata     ),
    .strb_i        ( obi_write_req.a.be        ),
    .atop_i        ( '0                        ), // We need to use the RISC-V atomics
    .we_i          ( !obi_write_req.a.we       ),

    .gnt_o         ( obi_write_rsp.a_gnt       ),
    .rvalid_o      ( obi_write_rsp.r_valid     ),
    .rdata_o       ( obi_write_rsp.r.rdata     ),

    .bank_req_o    ( { tcdm_master[0].req,     tcdm_master[1].req     } ),
    .bank_gnt_i    ( { tcdm_master[0].gnt,     tcdm_master[1].gnt     } ),
    .bank_addr_o   ( { tcdm_master[0].add,     tcdm_master[1].add     } ),
    .bank_wdata_o  ( { tcdm_master[0].data,    tcdm_master[1].data    } ),
    .bank_strb_o   ( { tcdm_master[0].be,      tcdm_master[1].be      } ),
    .bank_atop_o   ( /* NOT CONNECTED */                                ),
    .bank_we_o     ( { tcdm_master_we_0,       tcdm_master_we_1       } ),
    .bank_rvalid_i ( { tcdm_master[0].r_valid, tcdm_master[1].r_valid } ),
    .bank_rdata_i  ( { tcdm_master[0].r_data,  tcdm_master[1].r_data  } )
  );

  mem_to_banks #(
    .AddrWidth( AXI_ADDR_WIDTH ),
    .DataWidth( AXI_DATA_WIDTH ),
    .NumBanks ( 2              ),
    .HideStrb ( 1'b1           ),
    .MaxTrans ( 32'd1          )
  ) i_mem_to_banks_read (
    .clk_i         ( clk_i  ),
    .rst_ni        ( rst_ni ),

    .req_i         ( obi_read_req.a_req        ),
    .addr_i        ( obi_read_req.a.addr       ),
    .wdata_i       ( obi_read_req.a.wdata      ),
    .strb_i        ( obi_read_req.a.be         ),
    .atop_i        ( '0                        ), // We need to use the RISC-V atomics
    .we_i          ( !obi_read_req.a.we        ),

    .gnt_o         ( obi_read_rsp.a_gnt        ),
    .rvalid_o      ( obi_read_rsp.r_valid      ),
    .rdata_o       ( obi_read_rsp.r.rdata      ),

    .bank_req_o    ( { tcdm_master[2].req,     tcdm_master[3].req     } ),
    .bank_gnt_i    ( { tcdm_master[2].gnt,     tcdm_master[3].gnt     } ),
    .bank_addr_o   ( { tcdm_master[2].add,     tcdm_master[3].add     } ),
    .bank_wdata_o  ( { tcdm_master[2].data,    tcdm_master[3].data    } ),
    .bank_strb_o   ( { tcdm_master[2].be,      tcdm_master[3].be      } ),
    .bank_atop_o   ( /* NOT CONNECTED */                                ),
    .bank_we_o     ( { tcdm_master_we_2,       tcdm_master_we_3       } ),
    .bank_rvalid_i ( { tcdm_master[2].r_valid, tcdm_master[3].r_valid } ),
    .bank_rdata_i  ( { tcdm_master[2].r_data,  tcdm_master[3].r_data  } )
  );

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

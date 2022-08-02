// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

/*
 * dmac_wrap.sv
 * Thomas Benz <tbenz@iis.ee.ethz.ch>
 * Michael Rogenmoser <michaero@iis.ee.ethz.ch>
 */

// DMA Core wrapper

`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "register_interface/typedef.svh"

module dmac_wrap #(
  parameter NB_CORES            = 4,
  parameter AXI_ADDR_WIDTH      = 32,
  parameter AXI_DATA_WIDTH      = 64,
  parameter AXI_USER_WIDTH      = 6,
  parameter AXI_ID_WIDTH        = 4,
  parameter PE_ID_WIDTH         = 1,
  parameter NB_PE_PORTS         = 1,
  parameter DATA_WIDTH          = 32,
  parameter ADDR_WIDTH          = 32,
  parameter BE_WIDTH            = DATA_WIDTH/8,
  parameter NUM_STREAMS         = 1, // Only 1 for now
  parameter TCDM_SIZE           = 0,
  parameter TwoDMidend          = 1, // Leave this on for now
  parameter NB_OUTSND_BURSTS    = 8,
  parameter GLOBAL_QUEUE_DEPTH  = 16,
  parameter BACKEND_QUEUE_DEPTH = 16
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
  localparam int unsigned NumDims = 1; 
  
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

  // DMA burst definitions
  // 1D burst request
  typedef logic [AXI_ID_WIDTH-1:0] axi_id_t;
  typedef logic             [31:0] num_bytes_t;
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
  // 2D burst request
  typedef struct packed {
      axi_id_t            id;
      addr_t              src, dst;
      num_bytes_t         num_bytes;
      logic               is_twod;
      num_bytes_t         stride_src, stride_dst, num_repetitions;
      axi_pkg::cache_t    cache_src, cache_dst;
      axi_pkg::burst_t    burst_src, burst_dst;
      logic               decouple_rw;
      logic               deburst;
      logic               serialize; 
  } twod_req_t;
   
   // ND burst request
   import idma_nd_midend_pkg::nd_req_t;
   
   nd_req_t nd_req;    
  twod_req_t twod_req;
  burst_req_t burst_req;
   

  logic fe_valid, fe_ready, be_valid, be_ready;
  logic backend_idle, trans_complete, oned_trans_complete, twod_req_last, twod_req_last_realigned;

  // ------------------------------------------------------
  // FRONTEND
  // ------------------------------------------------------

  for (genvar i = 0; i < NumRegs; i++) begin
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
    .burst_req_t    ( twod_req_t     )
  ) i_idma_reg32_2d_frontend (
    .clk_i,
    .rst_ni,
    .dma_ctrl_req_i   ( dma_regs_req   ),
    .dma_ctrl_rsp_o   ( dma_regs_rsp   ),
    .burst_req_o      ( twod_req       ),
    .valid_o          ( fe_valid       ),
    .ready_i          ( fe_ready       ),
    .backend_idle_i   ( backend_idle   ),
    .trans_complete_i ( trans_complete )
  );

  // interrupts and events (currently broadcast tx_cplt event only)
  assign term_event_pe_o = |trans_complete ? '1 : '0;
  assign term_irq_pe_o   = '0;
  assign term_event_o    = |trans_complete ? '1 : '0;
  assign term_irq_o      = '0;

  assign busy_o = ~backend_idle;

// TODO: possibly implement distributor for NumStreams > 1?
//       -> Will be a challenge to keep transfers in order...


  // ------------------------------------------------------
  // MIDEND
  // ------------------------------------------------------

 /* idma_2D_midend #(
    .ADDR_WIDTH     ( AXI_ADDR_WIDTH     ),
    .REQ_FIFO_DEPTH ( GLOBAL_QUEUE_DEPTH ),
    .burst_req_t    ( burst_req_t        ),
    .twod_req_t     ( twod_req_t         )
  ) i_idma_2D_midend (
    .clk_i,
    .rst_ni,
    .twod_req_i        ( twod_req      ),
    .twod_req_valid_i  ( fe_valid      ),
    .twod_req_ready_o  ( fe_ready      ),
    .burst_req_o       ( burst_req     ),
    .burst_req_valid_o ( be_valid      ),
    .burst_req_ready_i ( be_ready      ),
    .twod_req_last_o   ( twod_req_last )
  );*/

   idma_nd_midend  #(
    .NumDims( NumDims ),
    .addr_t( addr_t ),
    .nd_req_t( nd_req_t )
  ) i_idma_nd_midend (
    .clk_i,
    .rst_ni,
    .nd_req_i( nd_req ),
    .nd_valid_i( fe_valid ),
    .nd_ready_o( fe_ready ),
    .burst_req_o( burst_req ),
    .burst_valid_o( be_valid ),
    .burst_ready_i( be_ready )
  );
                        
                        
  // transfer complete alignment, should be integrated into twod module
 /* localparam TwodBufferDepth = 2 * BACKEND_QUEUE_DEPTH + NB_OUTSND_BURSTS + 3 + 1;
  fifo_v3 #(
    .DATA_WIDTH ( 1               ),
    .DEPTH      ( TwodBufferDepth )
  ) i_fifo_v3_last_twod_buffer (
    .clk_i,
    .rst_ni,
    .flush_i    ( 1'b0                    ),
    .testmode_i ( 1'b0                    ),
    .full_o     (),
    .empty_o    (),
    .usage_o    (),
    .data_i     ( twod_req_last           ),
    .push_i     ( be_ready && be_valid    ),
    .data_o     ( twod_req_last_realigned ),
    .pop_i      ( oned_trans_complete     )
  );*/

//  assign trans_complete = oned_trans_complete && twod_req_last_realigned;
   assign trans_complete = oned_trans_complete;

  // ------------------------------------------------------
  // BACKEND
  // ------------------------------------------------------

  axi_dma_backend #(
    .DataWidth      ( AXI_DATA_WIDTH      ),
    .AddrWidth      ( AXI_ADDR_WIDTH      ),
    .IdWidth        ( AXI_ID_WIDTH        ),
    .AxReqFifoDepth ( NB_OUTSND_BURSTS    ),
    .TransFifoDepth ( BACKEND_QUEUE_DEPTH ),
    .BufferDepth    ( 3                   ),
    .axi_req_t      ( slv_req_t           ),
    .axi_res_t      ( slv_resp_t          ),
    .burst_req_t    ( burst_req_t         ),
    .DmaIdWidth     ( 6                   ),
    .DmaTracing     ( 0                   )
  ) i_axi_dma_backend (
    .clk_i,
    .rst_ni,
    .dma_id_i         ( '0                  ),
    .axi_dma_req_o    ( dma_req             ),
    .axi_dma_res_i    ( dma_rsp             ),
    .burst_req_i      ( burst_req           ),
    .valid_i          ( be_valid            ),
    .ready_o          ( be_ready            ),
    .backend_idle_o   ( backend_idle        ),
    .trans_complete_o ( oned_trans_complete )
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
  localparam NumMstPorts = 2;
  localparam NumSlvPorts = NUM_STREAMS;

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

  localparam TcdmFifoDepth = 1;

  axi_to_mem #(
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

  axi_to_mem #(
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

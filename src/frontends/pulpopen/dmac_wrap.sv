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
 */

// DMA Core wrapper

`include "axi/assign.svh"
`include "axi/typedef.svh"

module dmac_wrap
#(
  parameter NB_CORES           = 4,
  parameter AXI_ADDR_WIDTH     = 32,
  parameter AXI_DATA_WIDTH     = 64,
  parameter AXI_USER_WIDTH     = 6,
  parameter AXI_ID_WIDTH       = 4,
  parameter PE_ID_WIDTH        = 1,
  parameter DATA_WIDTH         = 32,
  parameter ADDR_WIDTH         = 32,
  parameter BE_WIDTH           = DATA_WIDTH/8,
  parameter NUM_STREAMS        = 4
) (
  input logic                      clk_i,
  input logic                      rst_ni,
  input logic                      test_mode_i,
  XBAR_PERIPH_BUS.Slave            pe_ctrl_slave,
  XBAR_TCDM_BUS.Slave              ctrl_slave[NB_CORES-1:0],
  XBAR_TCDM_BUS.Master             tcdm_master[3:0],
  AXI_BUS.Master                   ext_master,
  output logic [NB_CORES-1:0]      term_event_o,
  output logic [NB_CORES-1:0]      term_irq_o,
  output logic                     term_event_pe_o,
  output logic                     term_irq_pe_o,
  output logic                     busy_o
);

  localparam int unsigned MstIdxWidth = AXI_ID_WIDTH;
  localparam int unsigned SlvIdxWidth = AXI_ID_WIDTH - $clog2(NUM_STREAMS);

  // CORE --> MCHAN CTRL INTERFACE BUS SIGNALS
  logic [NB_CORES-1:0][DATA_WIDTH-1:0] config_wdata;
  logic [NB_CORES-1:0][ADDR_WIDTH-1:0] config_add;
  logic [NB_CORES-1:0]                 config_req;
  logic [NB_CORES-1:0]                 config_wen;
  logic [NB_CORES-1:0][BE_WIDTH-1:0]   config_be;
  logic [NB_CORES-1:0]                 config_gnt;
  logic [NB_CORES-1:0][DATA_WIDTH-1:0] config_r_rdata;
  logic [NB_CORES-1:0]                 config_r_valid;

  // tie-off pe control ports
  for (genvar i = 0; i < NB_CORES; i++) begin : gen_ctrl_registers
    assign config_add[i]         = ctrl_slave[i].add;
    assign config_req[i]         = ctrl_slave[i].req;
    assign config_wdata[i]       = ctrl_slave[i].wdata;
    assign config_wen[i]         = ctrl_slave[i].wen;
    assign config_be[i]          = ctrl_slave[i].be;
    assign ctrl_slave[i].gnt     = config_gnt[i];
    assign ctrl_slave[i].r_opc   = '0;
    assign ctrl_slave[i].r_valid = config_r_valid[i];
    assign ctrl_slave[i].r_rdata = config_r_rdata[i];
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
  mst_resp_t tcdm_rsp, soc_rsp, tcdm_read_rsp, tcdm_write_rsp;
  slv_req_t  [NUM_STREAMS-1:0] dma_req;
  slv_resp_t [NUM_STREAMS-1:0] dma_rsp;
  // interface to structs
  `AXI_ASSIGN_FROM_REQ(ext_master, soc_req)
  `AXI_ASSIGN_TO_RESP(soc_rsp, ext_master)

  cluster_dma_frontend #(
    .NumCores          ( NB_CORES        ),
    .PerifIdWidth      ( PE_ID_WIDTH     ),
    .DmaAxiIdWidth     ( AXI_ID_WIDTH    ),
    .DmaDataWidth      ( AXI_DATA_WIDTH  ),
    .DmaAddrWidth      ( AXI_ADDR_WIDTH  ),
    .AxiAxReqDepth     ( 2               ),
    .TfReqFifoDepth    ( 2               ),
    .NumStreams        ( NUM_STREAMS     ),
    .axi_req_t         ( slv_req_t       ),
    .axi_res_t         ( slv_resp_t      )
  ) i_cluster_dma_frontend (
    .clk_i                   ( clk_i                   ),
    .rst_ni                  ( rst_ni                  ),
    .cluster_id_i            ( '0                      ),
    .ctrl_pe_targ_req_i      ( pe_ctrl_slave.req       ),
    .ctrl_pe_targ_type_i     ( pe_ctrl_slave.wen       ),
    .ctrl_pe_targ_be_i       ( pe_ctrl_slave.be        ),
    .ctrl_pe_targ_add_i      ( pe_ctrl_slave.add       ),
    .ctrl_pe_targ_data_i     ( pe_ctrl_slave.wdata     ),
    .ctrl_pe_targ_id_i       ( pe_ctrl_slave.id        ),
    .ctrl_pe_targ_gnt_o      ( pe_ctrl_slave.gnt       ),
    .ctrl_pe_targ_r_valid_o  ( pe_ctrl_slave.r_valid   ),
    .ctrl_pe_targ_r_data_o   ( pe_ctrl_slave.r_rdata   ),
    .ctrl_pe_targ_r_opc_o    ( pe_ctrl_slave.r_opc     ),
    .ctrl_pe_targ_r_id_o     ( pe_ctrl_slave.r_id      ),
    .ctrl_targ_req_i         ( config_req              ),
    .ctrl_targ_type_i        ( config_wen              ),
    .ctrl_targ_be_i          ( config_be               ),
    .ctrl_targ_add_i         ( config_add              ),
    .ctrl_targ_data_i        ( config_wdata            ),
    .ctrl_targ_gnt_o         ( config_gnt              ),
    .ctrl_targ_r_valid_o     ( config_r_valid          ),
    .ctrl_targ_r_data_o      ( config_r_rdata          ),
    .axi_dma_req_o           ( dma_req                 ),
    .axi_dma_res_i           ( dma_rsp                 ),
    .busy_o                  ( busy_o                  ),
    .term_event_o            ( term_event_o            ),
    .term_irq_o              ( term_irq_o              ),
    .term_event_pe_o         ( term_event_pe_o         ),
    .term_irq_pe_o           ( term_irq_pe_o           )
  );

  // xbar
  localparam int unsigned NumRules = 3;
  if (AXI_ADDR_WIDTH != 64) begin : gen_non_64bit_addr_error
    $error("Non-64-bit AXI addresses require changes to code.");
  end
  typedef axi_pkg::xbar_rule_64_t xbar_rule_t; // change this to different width if required
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
      end_addr:   cluster_base_addr + 24'h10_0000,
      idx:        1
    },
    '{ // SoC high
      start_addr: cluster_base_addr + 24'h10_0000,
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
    MaxMstTrans:                             3,
    MaxSlvTrans:                             3,
    FallThrough:                          1'b0,
    LatencyMode:        axi_pkg::CUT_ALL_PORTS,
    AxiIdWidthSlvPorts:            SlvIdxWidth,
    AxiIdUsedSlvPorts:             SlvIdxWidth,
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
    `AXI_SET_B_STRUCT(tcdm_rsp.b, tcdm_read_rsp.b)
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

  axi2mem #(
    .axi_req_t   ( mem_req_t           ),
    .axi_resp_t  ( mst_resp_t          ),
    .AddrWidth   ( ADDR_WIDTH          ),
    .DataWidth   ( AXI_DATA_WIDTH      ),
    .IdWidth     ( MstIdxWidth         ),
    .NumBanks    ( 2                   ),
    .BufDepth    ( 1                   )
  ) i_axi_to_mem_read (
    .clk_i        ( clk_i         ),
    .rst_ni       ( rst_ni        ),
    .busy_o       ( ),
    .axi_req_i    ( tcdm_read_req ),
    .axi_resp_o   ( tcdm_read_rsp ),
    .mem_req_o    ( { tcdm_master[0].req,     tcdm_master[1].req     } ),
    .mem_gnt_i    ( { tcdm_master[0].gnt,     tcdm_master[1].gnt     } ),
    .mem_addr_o   ( { tcdm_master[0].add,     tcdm_master[1].add     } ),
    .mem_wdata_o  ( { tcdm_master[0].wdata,   tcdm_master[1].wdata   } ),
    .mem_strb_o   ( { tcdm_master[0].be,      tcdm_master[1].be      } ),
    .mem_atop_o   ( ),
    .mem_we_o     ( { tcdm_master_we_0,       tcdm_master_we_1       } ),
    .mem_rvalid_i ( { tcdm_master[0].r_valid, tcdm_master[1].r_valid } ),
    .mem_rdata_i  ( { tcdm_master[0].r_rdata, tcdm_master[1].r_rdata } )
  );

  axi2mem #(
    .axi_req_t   ( mem_req_t           ),
    .axi_resp_t  ( mst_resp_t          ),
    .AddrWidth   ( ADDR_WIDTH          ),
    .DataWidth   ( AXI_DATA_WIDTH      ),
    .IdWidth     ( MstIdxWidth         ),
    .NumBanks    ( 2                   ),
    .BufDepth    ( 1                   )
  ) i_axi_to_mem_write (
    .clk_i        ( clk_i          ),
    .rst_ni       ( rst_ni         ),
    .busy_o       ( ),
    .axi_req_i    ( tcdm_write_req ),
    .axi_resp_o   ( tcdm_write_rsp ),
    .mem_req_o    ( { tcdm_master[2].req,     tcdm_master[3].req     } ),
    .mem_gnt_i    ( { tcdm_master[2].gnt,     tcdm_master[3].gnt     } ),
    .mem_addr_o   ( { tcdm_master[2].add,     tcdm_master[3].add     } ),
    .mem_wdata_o  ( { tcdm_master[2].wdata,   tcdm_master[3].wdata   } ),
    .mem_strb_o   ( { tcdm_master[2].be,      tcdm_master[3].be      } ),
    .mem_atop_o   ( ),
    .mem_we_o     ( { tcdm_master_we_2,       tcdm_master_we_3       } ),
    .mem_rvalid_i ( { tcdm_master[2].r_valid, tcdm_master[3].r_valid } ),
    .mem_rdata_i  ( { tcdm_master[2].r_rdata, tcdm_master[3].r_rdata } )
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

endmodule : dmac_wrap

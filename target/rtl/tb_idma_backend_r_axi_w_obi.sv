// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz  <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`timescale 1ns/1ns
`include "axi/typedef.svh"
`include "axi_stream/typedef.svh"
`include "idma/tracer.svh"
`include "idma/typedef.svh"
`include "obi/typedef.svh"
`include "tilelink/typedef.svh"

// Protocol testbench defines
`define PROT_AXI4
`define PROT_OBI

module tb_idma_backend_r_axi_w_obi import idma_pkg::*; #(
    parameter int unsigned BufferDepth           = 3,
    parameter int unsigned NumAxInFlight         = 3,
    parameter int unsigned DataWidth             = 32,
    parameter int unsigned AddrWidth             = 32,
    parameter int unsigned UserWidth             = 1,
    // ID is currently used to differentiate transfers in testbench. We need to fix this
    // eventually.
    parameter int unsigned AxiIdWidth            = 12,
    parameter int unsigned TFLenWidth            = 32,
    parameter int unsigned MemSysDepth           = 0,
    parameter bit          AXI_IdealMemory       = 1,
    parameter int unsigned AXI_MemNumReqOutst    = 1,
    parameter int unsigned AXI_MemLatency        = 0,
    parameter bit          OBI_IdealMemory       = 1,
    parameter int unsigned OBI_MemNumReqOutst    = 1,
    parameter int unsigned OBI_MemLatency        = 0,
    parameter bit          CombinedShifter       = 1'b0,
    parameter int unsigned WatchDogNumCycles     = 100,
    parameter bit          MaskInvalidData       = 1,
    parameter bit          RAWCouplingAvail      = 0,
    parameter bit          HardwareLegalizer     = 1,
    parameter bit          RejectZeroTransfers   = 1,
    parameter bit          ErrorHandling         = 0,
    parameter bit          DmaTracing            = 1
);

    // timing parameters
    localparam time TA  =  1ns;
    localparam time TT  =  9ns;
    localparam time TCK = 10ns;

    // debug
    localparam bit Debug         = 1'b0;
    localparam bit ModelOutput   = 1'b0;
    localparam bit PrintFifoInfo = 1'b1;

    // TB parameters
    // dependent parameters
    localparam int unsigned StrbWidth       = DataWidth / 8;
    localparam int unsigned OffsetWidth     = $clog2(StrbWidth);

    // parse error handling caps
    localparam idma_pkg::error_cap_e ErrorCap = ErrorHandling ? idma_pkg::ERROR_HANDLING :
                                                                idma_pkg::NO_ERROR_HANDLING;

    // static types
    typedef logic [7:0] byte_t;

    // dependent typed
    typedef logic [AddrWidth-1:0]   addr_t;
    typedef logic [DataWidth-1:0]   data_t;
    typedef logic [StrbWidth-1:0]   strb_t;
    typedef logic [UserWidth-1:0]   user_t;
    typedef logic [AxiIdWidth-1:0]  id_t;
    typedef logic [OffsetWidth-1:0] offset_t;
    typedef logic [TFLenWidth-1:0]  tf_len_t;

    // AXI4+ATOP typedefs
`AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
`AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
`AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)

`AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
`AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)

`AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
`AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)

    // OBI typedefs
`OBI_TYPEDEF_MINIMAL_A_OPTIONAL(a_optional_t)
`OBI_TYPEDEF_MINIMAL_R_OPTIONAL(r_optional_t)

`OBI_TYPEDEF_TYPE_A_CHAN_T(obi_a_chan_t, addr_t, data_t, strb_t, id_t, a_optional_t)
`OBI_TYPEDEF_TYPE_R_CHAN_T(obi_r_chan_t, data_t, id_t, r_optional_t)

`OBI_TYPEDEF_REQ_T(obi_req_t, obi_a_chan_t)
`OBI_TYPEDEF_RSP_T(obi_rsp_t, obi_r_chan_t)

    // Meta Channel Widths
    localparam int unsigned axi_ar_chan_width = axi_pkg::ar_width(AddrWidth, AxiIdWidth, UserWidth);
    localparam int unsigned obi_a_chan_width = $bits(obi_a_chan_t);

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)


    typedef struct packed {
        axi_ar_chan_t ar_chan;
    } axi_read_meta_channel_t;

    typedef struct packed {
        axi_read_meta_channel_t axi;
    } read_meta_channel_t;

    typedef struct packed {
        obi_a_chan_t a_chan;
    } obi_write_meta_channel_t;

    typedef struct packed {
        obi_write_meta_channel_t obi;
    } write_meta_channel_t;

    //--------------------------------------
    // Physical Signals to the DUT
    //--------------------------------------
    // clock reset signals
    logic clk;
    logic rst_n;

    // dma request
    idma_req_t idma_req;
    logic req_valid;
    logic req_ready;

    // dma response
    idma_rsp_t idma_rsp;
    logic rsp_valid;
    logic rsp_ready;

    // error handler
    idma_eh_req_t idma_eh_req;
    logic eh_req_valid;
    logic eh_req_ready;

    // AXI4+ATOP request and response
    axi_req_t axi_read_req, axi_req, axi_req_mem;
    axi_rsp_t axi_read_rsp, axi_rsp, axi_rsp_mem;

    // OBI request and response

    obi_req_t obi_write_req;
    obi_rsp_t obi_write_rsp;

    axi_req_t obi_axi_write_req, obi_axi_req, obi_axi_req_mem;
    axi_rsp_t obi_axi_write_rsp, obi_axi_rsp, obi_axi_rsp_mem;

    // busy signal
    idma_busy_t busy;


    //--------------------------------------
    // DMA Driver
    //--------------------------------------
    // virtual interface definition
    IDMA_DV #(
        .DataWidth  ( DataWidth   ),
        .AddrWidth  ( AddrWidth   ),
        .UserWidth  ( UserWidth   ),
        .AxiIdWidth ( AxiIdWidth  ),
        .TFLenWidth ( TFLenWidth  )
    ) idma_dv (clk);

    // DMA driver type
    typedef idma_test::idma_driver #(
        .DataWidth  ( DataWidth   ),
        .AddrWidth  ( AddrWidth   ),
        .UserWidth  ( UserWidth   ),
        .AxiIdWidth ( AxiIdWidth  ),
        .TFLenWidth ( TFLenWidth  ),
        .TA         ( TA          ),
        .TT         ( TT          )
    ) drv_t;

    // instantiation of the driver
    drv_t drv = new(idma_dv);


    //--------------------------------------
    // DMA Job Queue
    //--------------------------------------
    // job type definition
    typedef idma_test::idma_job #(
        .AddrWidth   ( AddrWidth  ),
        .IdWidth     ( AxiIdWidth )
    ) tb_dma_job_t;

    // request and response queues
    tb_dma_job_t req_jobs [$];
    tb_dma_job_t rsp_jobs [$];
    tb_dma_job_t trf_jobs [$];

    //--------------------------------------
    // DMA Model
    //--------------------------------------
    // model type definition
    typedef idma_test::idma_model #(
        .AddrWidth   ( AddrWidth   ),
        .DataWidth   ( DataWidth   ),
        .ModelOutput ( ModelOutput )
    ) model_t;

    // instantiation of the model
    model_t model = new();


    //--------------------------------------
    // Misc TB Signals
    //--------------------------------------
    logic match;


    //--------------------------------------
    // TB Modules
    //--------------------------------------
    // clocking block
    clk_rst_gen #(
        .ClkPeriod    ( TCK  ),
        .RstClkCycles ( 1    )
    ) i_clk_rst_gen (
        .clk_o        ( clk     ),
        .rst_no       ( rst_n   )
    );
    // AXI4+ATOP sim memory
    axi_sim_mem #(
        .AddrWidth         ( AddrWidth    ),
        .DataWidth         ( DataWidth    ),
        .IdWidth           ( AxiIdWidth   ),
        .UserWidth         ( UserWidth    ),
        .axi_req_t         ( axi_req_t    ),
        .axi_rsp_t         ( axi_rsp_t    ),
        .WarnUninitialized ( 1'b0         ),
        .ClearErrOnAccess  ( 1'b1         ),
        .ApplDelay         ( TA           ),
        .AcqDelay          ( TT           )
    ) i_axi_sim_mem (
        .clk_i              ( clk                 ),
        .rst_ni             ( rst_n               ),
        .axi_req_i          ( axi_req_mem         ),
        .axi_rsp_o          ( axi_rsp_mem         ),
        .mon_r_last_o       ( /* NOT CONNECTED */ ),
        .mon_r_beat_count_o ( /* NOT CONNECTED */ ),
        .mon_r_user_o       ( /* NOT CONNECTED */ ),
        .mon_r_id_o         ( /* NOT CONNECTED */ ),
        .mon_r_data_o       ( /* NOT CONNECTED */ ),
        .mon_r_addr_o       ( /* NOT CONNECTED */ ),
        .mon_r_valid_o      ( /* NOT CONNECTED */ ),
        .mon_w_last_o       ( /* NOT CONNECTED */ ),
        .mon_w_beat_count_o ( /* NOT CONNECTED */ ),
        .mon_w_user_o       ( /* NOT CONNECTED */ ),
        .mon_w_id_o         ( /* NOT CONNECTED */ ),
        .mon_w_data_o       ( /* NOT CONNECTED */ ),
        .mon_w_addr_o       ( /* NOT CONNECTED */ ),
        .mon_w_valid_o      ( /* NOT CONNECTED */ )
    );
    // OBI sim memory
    axi_sim_mem #(
        .AddrWidth         ( AddrWidth    ),
        .DataWidth         ( DataWidth    ),
        .IdWidth           ( AxiIdWidth   ),
        .UserWidth         ( UserWidth    ),
        .axi_req_t         ( axi_req_t    ),
        .axi_rsp_t         ( axi_rsp_t    ),
        .WarnUninitialized ( 1'b0         ),
        .ClearErrOnAccess  ( 1'b1         ),
        .ApplDelay         ( TA           ),
        .AcqDelay          ( TT           )
    ) i_obi_axi_sim_mem (
        .clk_i              ( clk                 ),
        .rst_ni             ( rst_n               ),
        .axi_req_i          ( obi_axi_req_mem ),
        .axi_rsp_o          ( obi_axi_rsp_mem ),
        .mon_r_last_o       ( /* NOT CONNECTED */ ),
        .mon_r_beat_count_o ( /* NOT CONNECTED */ ),
        .mon_r_user_o       ( /* NOT CONNECTED */ ),
        .mon_r_id_o         ( /* NOT CONNECTED */ ),
        .mon_r_data_o       ( /* NOT CONNECTED */ ),
        .mon_r_addr_o       ( /* NOT CONNECTED */ ),
        .mon_r_valid_o      ( /* NOT CONNECTED */ ),
        .mon_w_last_o       ( /* NOT CONNECTED */ ),
        .mon_w_beat_count_o ( /* NOT CONNECTED */ ),
        .mon_w_user_o       ( /* NOT CONNECTED */ ),
        .mon_w_id_o         ( /* NOT CONNECTED */ ),
        .mon_w_data_o       ( /* NOT CONNECTED */ ),
        .mon_w_addr_o       ( /* NOT CONNECTED */ ),
        .mon_w_valid_o      ( /* NOT CONNECTED */ )
    );

    // Dummy memory
    typedef struct {
        logic [7:0]     mem[addr_t];
        axi_pkg::resp_t rerr[addr_t];
        axi_pkg::resp_t werr[addr_t];
    } dummy_mem_t;

    dummy_mem_t i_init_axi_sim_mem;
    dummy_mem_t i_axil_axi_sim_mem;
    dummy_mem_t i_axis_axi_sim_mem;
    dummy_mem_t i_tilelink_axi_sim_mem;

    //--------------------------------------
    // TB Monitors
    //--------------------------------------
    // AXI4+ATOP Signal Highlighters
    signal_highlighter #(.T(axi_aw_chan_t)) i_aw_hl (.ready_i(axi_rsp.aw_ready), .valid_i(axi_req.aw_valid), .data_i(axi_req.aw));
    signal_highlighter #(.T(axi_ar_chan_t)) i_ar_hl (.ready_i(axi_rsp.ar_ready), .valid_i(axi_req.ar_valid), .data_i(axi_req.ar));
    signal_highlighter #(.T(axi_w_chan_t))  i_w_hl  (.ready_i(axi_rsp.w_ready),  .valid_i(axi_req.w_valid),  .data_i(axi_req.w));
    signal_highlighter #(.T(axi_r_chan_t))  i_r_hl  (.ready_i(axi_req.r_ready),  .valid_i(axi_rsp.r_valid),  .data_i(axi_rsp.r));
    signal_highlighter #(.T(axi_b_chan_t))  i_b_hl  (.ready_i(axi_req.b_ready),  .valid_i(axi_rsp.b_valid),  .data_i(axi_rsp.b));

    // OBI-AXI Signal Highlighters
    signal_highlighter #(.T(axi_aw_chan_t)) i_obi_aw_hl (.ready_i(obi_axi_rsp.aw_ready), .valid_i(obi_axi_req.aw_valid), .data_i(obi_axi_req.aw));
    signal_highlighter #(.T(axi_ar_chan_t)) i_obi_ar_hl (.ready_i(obi_axi_rsp.ar_ready), .valid_i(obi_axi_req.ar_valid), .data_i(obi_axi_req.ar));
    signal_highlighter #(.T(axi_w_chan_t))  i_obi_w_hl  (.ready_i(obi_axi_rsp.w_ready),  .valid_i(obi_axi_req.w_valid),  .data_i(obi_axi_req.w));
    signal_highlighter #(.T(axi_r_chan_t))  i_obi_r_hl  (.ready_i(obi_axi_req.r_ready),  .valid_i(obi_axi_rsp.r_valid),  .data_i(obi_axi_rsp.r));
    signal_highlighter #(.T(axi_b_chan_t))  i_obi_b_hl  (.ready_i(obi_axi_req.b_ready),  .valid_i(obi_axi_rsp.b_valid),  .data_i(obi_axi_rsp.b));

    // DMA types
    signal_highlighter #(.T(idma_req_t))    i_req_hl (.ready_i(req_ready),    .valid_i(req_valid),    .data_i(idma_req));
    signal_highlighter #(.T(idma_rsp_t))    i_rsp_hl (.ready_i(rsp_ready),    .valid_i(rsp_valid),    .data_i(idma_rsp));
    signal_highlighter #(.T(idma_eh_req_t)) i_eh_hl  (.ready_i(eh_req_ready), .valid_i(eh_req_valid), .data_i(idma_eh_req));

    // Watchdogs
    stream_watchdog #(.NumCycles(WatchDogNumCycles)) i_axi_r_watchdog (.clk_i(clk), .rst_ni(rst_n),
        .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));

    stream_watchdog #(.NumCycles(WatchDogNumCycles)) i_obi_w_watchdog (.clk_i(clk), .rst_ni(rst_n),
        .valid_i(obi_axi_req.w_valid), .ready_i(obi_axi_rsp.w_ready));

    //--------------------------------------
    // DUT
    //--------------------------------------

    idma_backend_r_axi_w_obi #(
        .CombinedShifter      ( CombinedShifter      ),
        .DataWidth            ( DataWidth            ),
        .AddrWidth            ( AddrWidth            ),
        .AxiIdWidth           ( AxiIdWidth           ),
        .UserWidth            ( UserWidth            ),
        .TFLenWidth           ( TFLenWidth           ),
        .MaskInvalidData      ( MaskInvalidData      ),
        .BufferDepth          ( BufferDepth          ),
        .RAWCouplingAvail     ( RAWCouplingAvail     ),
        .HardwareLegalizer    ( HardwareLegalizer    ),
        .RejectZeroTransfers  ( RejectZeroTransfers  ),
        .ErrorCap             ( ErrorCap             ),
        .PrintFifoInfo        ( PrintFifoInfo        ),
        .NumAxInFlight        ( NumAxInFlight        ),
        .MemSysDepth          ( MemSysDepth          ),
        .idma_req_t           ( idma_req_t           ),
        .idma_rsp_t           ( idma_rsp_t           ),
        .idma_eh_req_t        ( idma_eh_req_t        ),
        .idma_busy_t          ( idma_busy_t          ),
        .axi_req_t ( axi_req_t ),
        .axi_rsp_t ( axi_rsp_t ),
        .obi_req_t ( obi_req_t ),
        .obi_rsp_t ( obi_rsp_t ),
        .write_meta_channel_t ( write_meta_channel_t ),
        .read_meta_channel_t  ( read_meta_channel_t  )
    ) i_idma_backend  (
        .clk_i                ( clk             ),
        .rst_ni               ( rst_n           ),
        .testmode_i           ( 1'b0            ),
        .idma_req_i           ( idma_req        ),
        .req_valid_i          ( req_valid       ),
        .req_ready_o          ( req_ready       ),
        .idma_rsp_o           ( idma_rsp        ),
        .rsp_valid_o          ( rsp_valid       ),
        .rsp_ready_i          ( rsp_ready       ),
        .idma_eh_req_i        ( idma_eh_req     ),
        .eh_req_valid_i       ( eh_req_valid    ),
        .eh_req_ready_o       ( eh_req_ready    ),
        .axi_read_req_o       ( axi_read_req    ),
        .axi_read_rsp_i       ( axi_read_rsp    ),
        .obi_write_req_o      ( obi_write_req   ),
        .obi_write_rsp_i      ( obi_write_rsp   ),
        .busy_o               ( busy            )
    );


    //--------------------------------------
    // DMA Tracer
    //--------------------------------------
    // only activate tracer if requested
    if (DmaTracing) begin
        // fetch the name of the trace file from CMD line
        string trace_file;
        initial begin
            void'($value$plusargs("trace_file=%s", trace_file));
        end
        // attach the tracer
        `IDMA_TRACER_R_AXI_W_OBI(i_idma_backend, trace_file);
    end


    //--------------------------------------
    // TB connections
    //--------------------------------------


    idma_obi2axi_bridge #(
        .DataWidth ( DataWidth    ),
        .AddrWidth ( AddrWidth    ),
        .UserWidth ( UserWidth    ),
        .IdWidth   ( AxiIdWidth   ),
        .obi_req_t ( obi_req_t    ),
        .obi_rsp_t ( obi_rsp_t    ),
        .axi_req_t ( axi_req_t    ),
        .axi_rsp_t ( axi_rsp_t    )
    ) i_obi2axi_bridge_write (
        .clk_i     ( clk ),
        .rst_ni    ( rst_n ),
        .obi_req_i ( obi_write_req ),
        .obi_rsp_o ( obi_write_rsp ),
        .axi_req_o ( obi_axi_write_req ),
        .axi_rsp_i ( obi_axi_write_rsp )
    );
    

    // Read Write Join
    assign axi_req      = axi_read_req;
    assign axi_read_rsp = axi_rsp;

    assign obi_axi_req = obi_axi_write_req;
    assign obi_axi_write_rsp = obi_axi_rsp;


    // connect virtual driver interface to structs
    assign idma_req              = idma_dv.req;
    assign req_valid             = idma_dv.req_valid;
    assign rsp_ready             = idma_dv.rsp_ready;
    assign idma_eh_req           = idma_dv.eh_req;
    assign eh_req_valid          = idma_dv.eh_req_valid;
    // connect struct to virtual driver interface
    assign idma_dv.req_ready     = req_ready;
    assign idma_dv.rsp           = idma_rsp;
    assign idma_dv.rsp_valid     = rsp_valid;
    assign idma_dv.eh_req_ready  = eh_req_ready;

    // throttle theAXI4+ATOP- AXI bus
    if (AXI_IdealMemory) begin : gen_axi_ideal_mem_connect

        // if the memory is ideal: 0 cycle latency here
        assign axi_req_mem = axi_req;
        assign axi_rsp = axi_rsp_mem;

    end else begin : gen_axi_delayed_mem_connect
        // the throttled AXI buses
        axi_req_t axi_req_throttled;
        axi_rsp_t axi_rsp_throttled;

        // axi throttle: limit the amount of concurrent requests in the memory system
        axi_throttle #(
            .MaxNumAwPending ( 2**32 - 1  ),
            .MaxNumArPending ( 2**32 - 1  ),
            .axi_req_t       ( axi_req_t  ),
            .axi_rsp_t       ( axi_rsp_t  )
        ) i_axi_throttle (
            .clk_i       ( clk               ),
            .rst_ni      ( rst_n             ),
            .req_i       ( axi_req           ),
            .rsp_o       ( axi_rsp           ),
            .req_o       ( axi_req_throttled ),
            .rsp_i       ( axi_rsp_throttled ),
            .w_credit_i  ( AXI_MemNumReqOutst ),
            .r_credit_i  ( AXI_MemNumReqOutst )
        );

        // delay the signals using AXI4 multicuts
        axi_multicut #(
            .NoCuts     ( AXI_MemLatency ),
            .aw_chan_t  ( axi_aw_chan_t ),
            .w_chan_t   ( axi_w_chan_t  ),
            .b_chan_t   ( axi_b_chan_t  ),
            .ar_chan_t  ( axi_ar_chan_t ),
            .r_chan_t   ( axi_r_chan_t  ),
            .axi_req_t  ( axi_req_t     ),
            .axi_resp_t ( axi_rsp_t     )
        ) i_axi_multicut (
            .clk_i       ( clk               ),
            .rst_ni      ( rst_n             ),
            .slv_req_i   ( axi_req_throttled ),
            .slv_resp_o  ( axi_rsp_throttled ),
            .mst_req_o   ( axi_req_mem       ),
            .mst_resp_i  ( axi_rsp_mem       )
        );
    end
    // throttle theOBI- AXI bus
    if (OBI_IdealMemory) begin : gen_obi_ideal_mem_connect

        // if the memory is ideal: 0 cycle latency here
        assign obi_axi_req_mem = obi_axi_req;
        assign obi_axi_rsp = obi_axi_rsp_mem;

    end else begin : gen_obi_delayed_mem_connect
        // the throttled AXI buses
        axi_req_t obi_axi_req_throttled;
        axi_rsp_t obi_axi_rsp_throttled;

        // axi throttle: limit the amount of concurrent requests in the memory system
        axi_throttle #(
            .MaxNumAwPending ( 2**32 - 1  ),
            .MaxNumArPending ( 2**32 - 1  ),
            .axi_req_t       ( axi_req_t  ),
            .axi_rsp_t       ( axi_rsp_t  )
        ) i_obi_axi_throttle (
            .clk_i       ( clk               ),
            .rst_ni      ( rst_n             ),
            .req_i       ( obi_axi_req           ),
            .rsp_o       ( obi_axi_rsp           ),
            .req_o       ( obi_axi_req_throttled ),
            .rsp_i       ( obi_axi_rsp_throttled ),
            .w_credit_i  ( OBI_MemNumReqOutst ),
            .r_credit_i  ( OBI_MemNumReqOutst )
        );

        // delay the signals using AXI4 multicuts
        axi_multicut #(
            .NoCuts     ( OBI_MemLatency ),
            .aw_chan_t  ( axi_aw_chan_t ),
            .w_chan_t   ( axi_w_chan_t  ),
            .b_chan_t   ( axi_b_chan_t  ),
            .ar_chan_t  ( axi_ar_chan_t ),
            .r_chan_t   ( axi_r_chan_t  ),
            .axi_req_t  ( axi_req_t     ),
            .axi_resp_t ( axi_rsp_t     )
        ) i_obi_axi_multicut (
            .clk_i       ( clk               ),
            .rst_ni      ( rst_n             ),
            .slv_req_i   ( obi_axi_req_throttled ),
            .slv_resp_o  ( obi_axi_rsp_throttled ),
            .mst_req_o   ( obi_axi_req_mem       ),
            .mst_resp_i  ( obi_axi_rsp_mem       )
        );
    end


    //--------------------------------------
    // Various TB Tasks
    //--------------------------------------
    `include "include/tb_tasks.svh"


    // --------------------- Begin TB --------------------------


    //--------------------------------------
    // Read Job queue from File
    //--------------------------------------
    initial begin
        string job_file;
        void'($value$plusargs("job_file=%s", job_file));
        $display("Reading from %s", job_file);
        read_jobs(job_file, req_jobs);
        read_jobs(job_file, rsp_jobs);
        read_jobs(job_file, trf_jobs);
    end


    //--------------------------------------
    // Launch Transfers
    //--------------------------------------
    initial begin
        tb_dma_job_t previous;
        bit overlap;
        previous = null;

        // reset driver
        drv.reset_driver();
        // wait until reset has completed
        wait (rst_n);
        // print a job summary
        print_summary(req_jobs);
        // wait some additional time
        #100ns;

        // run all requests in queue
        while (req_jobs.size() != 0) begin
            // pop front to get a job
            automatic tb_dma_job_t now = req_jobs.pop_front();
            if (!(now.src_protocol inside { idma_pkg::AXI })) begin
                now.src_protocol = idma_pkg::AXI;
            end
            if (!(now.dst_protocol inside { idma_pkg::OBI })) begin
                now.dst_protocol = idma_pkg::OBI;
            end
            if (previous != null) begin
                overlap = 1'b0;

                // Check if previous destination and this jobs source overlap -> New job's src init could override dst of previous job 
                overlap = overlap || ((now.src_protocol == previous.dst_protocol) && ( (now.src_addr inside {[previous.dst_addr:previous.dst_addr+previous.length]})
                || ((now.src_addr + now.length) inside {[previous.dst_addr:previous.dst_addr+previous.length]}) ));

                // Check if previous destination and this jobs destination overlap -> New job's dst could override dst of previous job
                overlap = overlap || ((now.dst_protocol == previous.dst_protocol) && ( (now.dst_addr inside {[previous.dst_addr:previous.dst_addr+previous.length]})
                || ((now.dst_addr + now.length) inside {[previous.dst_addr:previous.dst_addr+previous.length]}) ));

                if (overlap) begin
                    $display("Overlap!");
                    // Wait until previous job is no longer in response queue -> Got checked
                    while (overlap) begin
                        overlap = 1'b0;
                        foreach (rsp_jobs[index]) begin
                            if ((rsp_jobs[index].src_addr == previous.src_addr)
                             && (rsp_jobs[index].dst_addr == previous.dst_addr))
                                overlap = 1'b1;
                        end
                        if(overlap) begin
                            @(posedge clk);
                        end
                    end
                    $display("Resolved!");
                end
            end
            // print job to terminal
            $display("%s", now.pprint());
            // init mem (model and sim-memory)
            init_mem({ idma_pkg::AXI, idma_pkg::OBI }, now);
            // launch DUT
            drv.launch_tf(
                          now.length,
                          now.src_addr,
                          now.dst_addr,
                          now.src_protocol,
                          now.dst_protocol,
                          now.aw_decoupled,
                          now.rw_decoupled,
                          $clog2(now.max_src_len),
                          $clog2(now.max_dst_len),
                          now.max_src_len != 'd256,
                          now.max_dst_len != 'd256,
                          now.id
                         );
            previous = now;
        end
        // once done: launched all transfers
        $display("Launched all Transfers.");
    end

    // Keep track of writes still outstanding
    int unsigned writes_in_flight [idma_pkg::protocol_e][id_t];

    initial begin
        id_t id;
        idma_pkg::protocol_e proto;
        forever begin
            @(posedge clk);
            proto = idma_pkg::OBI;
            if ( obi_axi_req_mem.aw_valid && obi_axi_rsp_mem.aw_ready ) begin
                id = obi_axi_req_mem.aw.id;
                if ( writes_in_flight.exists(proto) && writes_in_flight[proto].exists(id) )
                    writes_in_flight[proto][id]++;
                else
                    writes_in_flight[proto][id] = 1;

                //if (writes_in_flight[proto][id] == 1)
                    //$display("Started transfer %d id @%d ns", id, $time);
            end
            if ( obi_axi_rsp_mem.b_valid && obi_axi_req_mem.b_ready ) begin
                id = obi_axi_rsp_mem.b.id;
                if ( !writes_in_flight.exists(proto) )
                    $fatal(1, "B response protocol not in scoreboard!");
                if ( !writes_in_flight[proto].exists(id) )
                    $fatal(1, "B response id not in scoreboard!");
                if ( writes_in_flight[proto][id] == 0 )
                    $fatal(1, "Tried to decrement 0");
                writes_in_flight[proto][id]--;
                //if (writes_in_flight[proto][id] == 0)
                    //$display("Stopped transfer %d id @%d ns", id, $time);
            end
        end
    end

    //--------------------------------------
    // Ack Transfers and Compare Memories
    //--------------------------------------
    initial begin
        id_t id;
        // wait until reset has completed
        wait (rst_n);
        // wait some additional time
        #100ns;
        // receive
        while (rsp_jobs.size() != 0) begin
            // peek front to get a job
            automatic tb_dma_job_t now = rsp_jobs[0];
            if (!(now.src_protocol inside { idma_pkg::AXI })) begin
                $fatal(1, "Requested Source Protocol (%d) Not Supported", now.src_protocol);
            end
            if (!(now.dst_protocol inside { idma_pkg::OBI })) begin
                $fatal(1, "Requested Destination Protocol (%d) Not Supported", now.dst_protocol);
            end
            // wait for DMA to complete
            ack_tf_handle_err(now);
            // Check if corresponding writes went through
            case(now.dst_protocol)
        idma_pkg::OBI:
                id = now.id;
            endcase
            if (now.err_addr.size() == 0) begin
                while (writes_in_flight[now.dst_protocol][id] > 0) begin
                    $display("Waiting for write to finish!");
                    @(posedge clk);
                end
            end
            // finished job
            // $display("vvv Finished: vvv%s\n^^^ Finished: ^^^", now.pprint());
            // launch model
            model.transfer(
                           now.length,
                           now.src_addr,
                           now.dst_addr,
                           now.src_protocol,
                           now.dst_protocol,
                           now.max_src_len,
                           now.max_dst_len,
                           now.rw_decoupled,
                           now.err_addr,
                           now.err_is_read,
                           now.err_action
                          );
            // check memory
            compare_mem(now.length, now.dst_addr, now.dst_protocol, match);
            // fail if there is a mismatch
            if (!match)
                $fatal(1, "Mismatch!");
            // pop front
            rsp_jobs.pop_front();
        end
        // wait some additional time
        #100ns;
        // we are done!
        $finish();
    end


    //--------------------------------------
    // Show first non-acked Transfer
    //--------------------------------------
    initial begin
        wait (rst_n);
        forever begin
            if(rsp_jobs.size() > 0) begin
                automatic tb_dma_job_t now = rsp_jobs[0];
                if (!(now.src_protocol inside { idma_pkg::AXI })) begin
                    now.src_protocol = idma_pkg::AXI;
                end
                if (!(now.dst_protocol inside { idma_pkg::OBI })) begin
                    now.dst_protocol = idma_pkg::OBI;
                end
                // at least one watch dog triggers
                if (
                    (now.src_protocol == idma_pkg::AXI && i_axi_r_watchdog.cnt == 0) |
                    (now.dst_protocol == idma_pkg::OBI && i_obi_w_watchdog.cnt == 0)) 
                begin
                    $error("First non-acked transfer:%s\n\n", now.pprint());
                end
            end
            @(posedge clk);
        end
    end

endmodule


// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz  <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`timescale 1ns/1ns
`include "axi/typedef.svh"
`include "idma/tracer.svh"
`include "idma/typedef.svh"

// Protocol testbench defines
`define PROT_AXI4

module tb_idma_nd_midend import idma_pkg::*; #(
    parameter int unsigned BufferDepth         = 3,
    parameter int unsigned NumAxInFlight       = 3,
    parameter int unsigned DataWidth           = 32,
    parameter int unsigned AddrWidth           = 32,
    parameter int unsigned UserWidth           = 1,
    parameter int unsigned AxiIdWidth          = 1,
    parameter int unsigned TFLenWidth          = 32,
    parameter int unsigned MemSysDepth         = 0,
    parameter int unsigned NumDim              = 4,
    parameter int unsigned RepWidth            = 32,
    parameter int unsigned StrideWidth         = 32,
    parameter int unsigned MemNumReqOutst      = 1,
    parameter int unsigned MemLatency          = 0,
    parameter int unsigned WatchDogNumCycles   = 100,
    parameter bit          CombinedShifter     = 1'b0,
    parameter bit          MaskInvalidData     = 1,
    parameter bit          RAWCouplingAvail    = 1,
    parameter bit          HardwareLegalizer   = 1,
    parameter bit          RejectZeroTransfers = 1,
    parameter bit          ErrorHandling       = 1,
    parameter bit          IdealMemory         = 1,
    parameter bit          DmaTracing          = 1
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
    typedef logic [RepWidth-1:0]    reps_t;
    typedef logic [StrideWidth-1:0] strides_t;

    // AXI typedef
    `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
    `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)

    `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)

    `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
    `AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

    // iDMA ND request
    `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)

    // Meta channels
    typedef struct packed {
        axi_ar_chan_t ar_chan;
    } axi_read_meta_channel_t;

    typedef struct packed {
        axi_read_meta_channel_t axi;
    } read_meta_channel_t;

    typedef struct packed {
        axi_aw_chan_t aw_chan;
    } axi_write_meta_channel_t;

    typedef struct packed {
        axi_write_meta_channel_t axi;
    } write_meta_channel_t;


    //--------------------------------------
    // Physical Signals to the DUT
    //--------------------------------------
    // clock reset signals
    logic clk;
    logic rst_n;

    // nd request
    idma_nd_req_t nd_req;
    logic nd_req_valid;
    logic nd_req_ready;

    // nd response
    idma_rsp_t nd_rsp;
    logic nd_rsp_valid;
    logic nd_rsp_ready;

    // dma request
    idma_req_t burst_req;
    logic burst_req_valid;
    logic burst_req_ready;

    // dma response
    idma_rsp_t burst_rsp;
    logic burst_rsp_valid;
    logic burst_rsp_ready;

    // error handler
    idma_eh_req_t idma_eh_req;
    logic eh_req_valid;
    logic eh_req_ready;

    // AXI4 master
    axi_req_t axi_req, axi_read_req, axi_write_req, axi_req_mem, axi_req_mem_delayed;
    axi_rsp_t axi_rsp, axi_read_rsp, axi_write_rsp, axi_rsp_mem;

    // busy signal
    idma_busy_t busy;


    //--------------------------------------
    // DMA Driver
    //--------------------------------------
    // virtual interface definition
    IDMA_ND_DV #(
        .DataWidth   ( DataWidth   ),
        .AddrWidth   ( AddrWidth   ),
        .UserWidth   ( UserWidth   ),
        .AxiIdWidth  ( AxiIdWidth  ),
        .TFLenWidth  ( TFLenWidth  ),
        .NumDim      ( NumDim      ),
        .RepWidth    ( RepWidth    ),
        .StrideWidth ( StrideWidth )
    ) idma_nd_dv (clk);

    // DMA driver type
    typedef idma_test::idma_nd_driver #(
        .DataWidth   ( DataWidth   ),
        .AddrWidth   ( AddrWidth   ),
        .UserWidth   ( UserWidth   ),
        .AxiIdWidth  ( AxiIdWidth  ),
        .TFLenWidth  ( TFLenWidth  ),
        .NumDim      ( NumDim      ),
        .RepWidth    ( RepWidth    ),
        .StrideWidth ( StrideWidth ),
        .TA          ( TA          ),
        .TT          ( TT          )
    ) nd_drv_t;

    // instantiation of the driver
    nd_drv_t drv = new(idma_nd_dv);


    //--------------------------------------
    // DMA Job Queue
    //--------------------------------------
    // job type definition
    typedef idma_test::idma_job #(
        .AddrWidth   ( AddrWidth ),
        .NumDim      ( NumDim    ),
        .IsND        ( 1'b1      )
    ) tb_dma_job_t;

    // request and response queues
    tb_dma_job_t req_jobs [$];
    tb_dma_job_t req_jobs_flat [$];
    tb_dma_job_t rsp_jobs [$];
    tb_dma_job_t rsp_jobs_flat [$];


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
    // ND Midend Model
    //--------------------------------------
    // nd midend model type definition
    typedef idma_test::idma_nd_midend_model #(
        .AddrWidth   ( AddrWidth   ),
        .NumDim      ( NumDim      ),
        .ModelOutput ( ModelOutput )
    ) nd_midend_model_t;

    // instantiate the nd midend model
    nd_midend_model_t nd_midend_model = new();


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

    // sim memory
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

    axi_cut #(
        .Bypass     ( 1'b0                ),
        .aw_chan_t  ( axi_aw_chan_t       ),
        .w_chan_t   ( axi_w_chan_t        ),
        .b_chan_t   ( axi_b_chan_t        ),
        .ar_chan_t  ( axi_ar_chan_t       ),
        .r_chan_t   ( axi_r_chan_t        ),
        .axi_req_t  ( axi_req_t           ),
        .axi_resp_t ( axi_rsp_t           )
    ) i_axi_cut (
        .clk_i      ( clk                 ),
        .rst_ni     ( rst_n               ),

        .slv_req_i  ( axi_req_mem         ),
        .slv_resp_o (                     ),
        .mst_req_o  ( axi_req_mem_delayed ),
        .mst_resp_i ( axi_rsp_mem         )
    );

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
    ) i_axi_sim_mem_delayed (
        .clk_i              ( clk                 ),
        .rst_ni             ( rst_n               ),
        .axi_req_i          ( axi_req_mem_delayed ),
        .axi_rsp_o          (                     ),
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

    //--------------------------------------
    // TB Monitors
    //--------------------------------------
    // AXI
    signal_highlighter #(.T(axi_aw_chan_t)) i_aw_hl (.ready_i(axi_rsp.aw_ready), .valid_i(axi_req.aw_valid), .data_i(axi_req.aw));
    signal_highlighter #(.T(axi_ar_chan_t)) i_ar_hl (.ready_i(axi_rsp.ar_ready), .valid_i(axi_req.ar_valid), .data_i(axi_req.ar));
    signal_highlighter #(.T(axi_w_chan_t))  i_w_hl  (.ready_i(axi_rsp.w_ready),  .valid_i(axi_req.w_valid),  .data_i(axi_req.w));
    signal_highlighter #(.T(axi_r_chan_t))  i_r_hl  (.ready_i(axi_req.r_ready),  .valid_i(axi_rsp.r_valid),  .data_i(axi_rsp.r));
    signal_highlighter #(.T(axi_b_chan_t))  i_b_hl  (.ready_i(axi_req.b_ready),  .valid_i(axi_rsp.b_valid),  .data_i(axi_rsp.b));

    // DMA backend types
    signal_highlighter #(.T(idma_nd_req_t)) i_nd_req_hl (.ready_i(nd_req_ready),    .valid_i(nd_req_valid),     .data_i(nd_req));
    signal_highlighter #(.T(idma_rsp_t))    i_nd_rsp_hl (.ready_i(nd_rsp_ready),    .valid_i(nd_rsp_valid),     .data_i(nd_rsp));
    signal_highlighter #(.T(idma_req_t))    i_req_hl    (.ready_i(burst_req_ready), .valid_i(burst_req_valid),  .data_i(burst_req));
    signal_highlighter #(.T(idma_rsp_t))    i_rsp_hl    (.ready_i(burst_rsp_ready), .valid_i(burst_rsp_valid),  .data_i(burst_rsp));
    signal_highlighter #(.T(idma_eh_req_t)) i_eh_hl     (.ready_i(eh_req_ready),    .valid_i(eh_req_valid),     .data_i(idma_eh_req));

    // Watchdogs
    stream_watchdog #(.NumCycles(WatchDogNumCycles)) i_axi_w_watchdog (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));
    stream_watchdog #(.NumCycles(WatchDogNumCycles)) i_axi_r_watchdog (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));


    //--------------------------------------
    // DUT
    //--------------------------------------
    // nd midend
    idma_nd_midend #(
        .NumDim        ( NumDim               ),
        .addr_t        ( addr_t               ),
        .idma_req_t    ( idma_req_t           ),
        .idma_rsp_t    ( idma_rsp_t           ),
        .idma_nd_req_t ( idma_nd_req_t        ),
        .RepWidths     ( '{default: RepWidth} )
    ) i_idma_nd_midend (
        .clk_i             ( clk             ),
        .rst_ni            ( rst_n           ),
        .nd_req_i          ( nd_req          ),
        .nd_req_valid_i    ( nd_req_valid    ),
        .nd_req_ready_o    ( nd_req_ready    ),
        .nd_rsp_o          ( nd_rsp          ),
        .nd_rsp_valid_o    ( nd_rsp_valid    ),
        .nd_rsp_ready_i    ( nd_rsp_ready    ),
        .burst_req_o       ( burst_req       ),
        .burst_req_valid_o ( burst_req_valid ),
        .burst_req_ready_i ( burst_req_ready ),
        .burst_rsp_i       ( burst_rsp       ),
        .burst_rsp_valid_i ( burst_rsp_valid ),
        .burst_rsp_ready_o ( burst_rsp_ready ),
        .busy_o            ( )
    );

    // the backend
    idma_backend_rw_axi #(
        .DataWidth            ( DataWidth            ),
        .AddrWidth            ( AddrWidth            ),
        .AxiIdWidth           ( AxiIdWidth           ),
        .UserWidth            ( UserWidth            ),
        .TFLenWidth           ( TFLenWidth           ),
        .MaskInvalidData      ( MaskInvalidData      ),
        .BufferDepth          ( BufferDepth          ),
        .CombinedShifter      ( CombinedShifter      ),
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
        .axi_req_t            ( axi_req_t            ),
        .axi_rsp_t            ( axi_rsp_t            ),
        .read_meta_channel_t  ( read_meta_channel_t  ),
        .write_meta_channel_t ( write_meta_channel_t )
    ) i_idma_backend  (
        .clk_i           ( clk             ),
        .rst_ni          ( rst_n           ),
        .testmode_i      ( 1'b0            ),
        .idma_req_i      ( burst_req       ),
        .req_valid_i     ( burst_req_valid ),
        .req_ready_o     ( burst_req_ready ),
        .idma_rsp_o      ( burst_rsp       ),
        .rsp_valid_o     ( burst_rsp_valid ),
        .rsp_ready_i     ( burst_rsp_ready ),
        .idma_eh_req_i   ( idma_eh_req     ),
        .eh_req_valid_i  ( eh_req_valid    ),
        .eh_req_ready_o  ( eh_req_ready    ),
        .axi_read_req_o  ( axi_read_req    ),
        .axi_read_rsp_i  ( axi_read_rsp    ),
        .axi_write_req_o ( axi_write_req   ),
        .axi_write_rsp_i ( axi_write_rsp   ),
        .busy_o          ( busy            )
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
        `IDMA_TRACER_RW_AXI(i_idma_backend, trace_file);
    end


    //--------------------------------------
    // TB connections
    //--------------------------------------

    // Read Write Join
    axi_rw_join #(
        .axi_req_t        ( axi_req_t ),
        .axi_resp_t       ( axi_rsp_t )
    ) i_axi_rw_join (
        .clk_i            ( clk           ),
        .rst_ni           ( rst_n         ),
        .slv_read_req_i   ( axi_read_req  ),
        .slv_read_resp_o  ( axi_read_rsp  ),
        .slv_write_req_i  ( axi_write_req ),
        .slv_write_resp_o ( axi_write_rsp ),
        .mst_req_o        ( axi_req       ),
        .mst_resp_i       ( axi_rsp       )
    );

    // connect virtual driver interface to structs
    assign nd_req                   = idma_nd_dv.req;
    assign nd_req_valid             = idma_nd_dv.req_valid;
    assign nd_rsp_ready             = idma_nd_dv.rsp_ready;
    assign idma_eh_req              = idma_nd_dv.eh_req;
    assign eh_req_valid             = idma_nd_dv.eh_req_valid;
    // connect struct to virtual driver interface
    assign idma_nd_dv.req_ready     = nd_req_ready;
    assign idma_nd_dv.rsp           = nd_rsp;
    assign idma_nd_dv.rsp_valid     = nd_rsp_valid;
    assign idma_nd_dv.eh_req_ready  = eh_req_ready;

    // throttle the AXI bus
    if (IdealMemory) begin : gen_ideal_mem_connect

        // if the memory is ideal: 0 cycle latency here
        assign axi_req_mem = axi_req;
        assign axi_rsp = axi_rsp_mem;

    end else begin : gen_delayed_mem_connect

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
            .w_credit_i  ( MemNumReqOutst    ),
            .r_credit_i  ( MemNumReqOutst    )
        );

        // delay the signals using AXI4 multicuts
        axi_multicut #(
            .NoCuts     ( MemLatency    ),
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
    end


    //--------------------------------------
    // Launch Transfers
    //--------------------------------------
    initial begin
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
            automatic tb_dma_job_t now_nd = req_jobs.pop_front();
            // print job to terminal
            $display("%s", now_nd.pprint());
            // decompose the job
            nd_midend_model.decompose(now_nd, req_jobs_flat);
            // iterate over flat jobs
            while (req_jobs_flat.size() != 0) begin
                // pop queue
                automatic tb_dma_job_t now = req_jobs_flat.pop_front();
                // init mem (model and AXI)
                init_mem({idma_pkg::AXI}, now);
            end
            // launch DUT
            drv.launch_nd_tf(
                          now_nd.length,
                          now_nd.src_addr,
                          now_nd.dst_addr,
                          idma_pkg::AXI,
                          idma_pkg::AXI,
                          now_nd.aw_decoupled,
                          now_nd.rw_decoupled,
                          $clog2(now_nd.max_src_len),
                          $clog2(now_nd.max_dst_len),
                          now_nd.max_src_len != 'd256,
                          now_nd.max_dst_len != 'd256,
                          now_nd.n_dims
                         );
        end
        // once done: launched all transfers
        $display("Launched all Transfers.");
    end


    //--------------------------------------
    // Ack Transfers and Compare Memories
    //--------------------------------------
    initial begin
        // wait until reset has completed
        wait (rst_n);
        // wait some additional time
        #100ns;
        // receive
        while (rsp_jobs.size() != 0) begin
            // peek front to get a job
            automatic tb_dma_job_t now_nd = rsp_jobs[0];
            // wait for DMA to complete
            ack_tf_handle_err(now_nd);
            // decompose the job
            nd_midend_model.decompose(now_nd, rsp_jobs_flat);
            // iterate over flat jobs
            while (rsp_jobs_flat.size() != 0) begin
                // pop queue
                automatic tb_dma_job_t now = rsp_jobs_flat[0];
                // launch model
                model.transfer(
                            now.length,
                            now.src_addr,
                            now.dst_addr,
                            idma_pkg::AXI,
                            idma_pkg::AXI,
                            now.max_src_len,
                            now.max_dst_len,
                            now.rw_decoupled,
                            now.err_addr,
                            now.err_is_read,
                            now.err_action
                           );
                // check memory
                compare_mem(now.length, now.dst_addr, idma_pkg::AXI, match);
                // fail if there is a mismatch
                if (!match)
                    $fatal(1, "Mismatch!");
                // pop front
                rsp_jobs_flat.pop_front();
            end
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
            // at least one watch dog triggers
            if (i_axi_r_watchdog.cnt == 0 | i_axi_w_watchdog.cnt == 0) begin
                automatic tb_dma_job_t now = rsp_jobs[0];
                $error("First non-acked transfer:%s\n\n", now.pprint());
            end
            @(posedge clk);
        end
    end

endmodule

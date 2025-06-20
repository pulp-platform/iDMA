// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz  <tbenz@ethz.ch>
// Tobias Senti <tsenti@student.ethz.ch>

`timescale 1ns/1ns
`include "axi/typedef.svh"
`include "idma/typedef.svh"

module tb_idma_lite_backend import idma_pkg::*; #(
    parameter int unsigned BufferDepth         = 3,
    parameter int unsigned NumAxInFlight       = 3,
    parameter int unsigned DataWidth           = 32,
    parameter int unsigned AddrWidth           = 32,
    parameter int unsigned UserWidth           = 1,
    parameter int unsigned AxiIdWidth          = 1,
    parameter int unsigned TFLenWidth          = 32,
    parameter int unsigned MemSysDepth         = 0,
    parameter int unsigned MemNumReqOutst      = 1,
    parameter int unsigned MemLatency          = 0,
    parameter int unsigned WatchDogNumCycles   = 100,
    parameter bit          MaskInvalidData     = 1,
    parameter bit          RAWCouplingAvail    = 1,
    parameter bit          HardwareLegalizer   = 1,
    parameter bit          RejectZeroTransfers = 1,
    parameter bit          ErrorHandling       = 1,
    parameter bit          IdealMemory         = 1,
    parameter bit          AxiDumper           = 0
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

    // AXI typedef
    `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
    `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)

    `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)

    `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
    `AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)

    // AXI-Lite typedef
    `AXI_LITE_TYPEDEF_AW_CHAN_T(axi_lite_aw_chan_t, addr_t)
    `AXI_LITE_TYPEDEF_W_CHAN_T(axi_lite_w_chan_t, data_t, strb_t)
    `AXI_LITE_TYPEDEF_B_CHAN_T(axi_lite_b_chan_t)

    `AXI_LITE_TYPEDEF_AR_CHAN_T(axi_lite_ar_chan_t, addr_t)
    `AXI_LITE_TYPEDEF_R_CHAN_T(axi_lite_r_chan_t, data_t)

    `AXI_LITE_TYPEDEF_REQ_T(axi_lite_req_t, axi_lite_aw_chan_t, axi_lite_w_chan_t, axi_lite_ar_chan_t)
    `AXI_LITE_TYPEDEF_RESP_T(axi_lite_rsp_t, axi_lite_b_chan_t, axi_lite_r_chan_t)

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)


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

    // AXI4 master
    axi_req_t axi_req, axi_req_mem, axi_req_mem_delayed;
    axi_rsp_t axi_rsp, axi_rsp_mem;

    axi_req_t dut_axi_req;
    axi_rsp_t dut_axi_rsp;

    axi_lite_req_t dut_axi_lite_req;
    axi_lite_rsp_t dut_axi_lite_rsp;

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
        .AddrWidth   ( AddrWidth )
    ) tb_dma_job_t;

    // request and response queues
    tb_dma_job_t req_jobs [$];
    tb_dma_job_t rsp_jobs [$];


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

    // DMA types
    signal_highlighter #(.T(idma_req_t))    i_req_hl (.ready_i(req_ready),    .valid_i(req_valid),    .data_i(idma_req));
    signal_highlighter #(.T(idma_rsp_t))    i_rsp_hl (.ready_i(rsp_ready),    .valid_i(rsp_valid),    .data_i(idma_rsp));
    signal_highlighter #(.T(idma_eh_req_t)) i_eh_hl  (.ready_i(eh_req_ready), .valid_i(eh_req_valid), .data_i(idma_eh_req));

    // Watchdogs
    stream_watchdog #(.NumCycles(WatchDogNumCycles)) i_axi_w_watchdog (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));
    stream_watchdog #(.NumCycles(WatchDogNumCycles)) i_axi_r_watchdog (.clk_i(clk), .rst_ni(rst_n), .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));


    //--------------------------------------
    // DUT
    //--------------------------------------
    // the backend
    idma_backend #(
        .Protocol            ( idma_pkg::AXILITE  ),
        .DataWidth           ( DataWidth           ),
        .AddrWidth           ( AddrWidth           ),
        .AxiIdWidth          ( AxiIdWidth          ),
        .UserWidth           ( UserWidth           ),
        .TFLenWidth          ( TFLenWidth          ),
        .MaskInvalidData     ( MaskInvalidData     ),
        .BufferDepth         ( BufferDepth         ),
        .RAWCouplingAvail    ( RAWCouplingAvail    ),
        .HardwareLegalizer   ( HardwareLegalizer   ),
        .RejectZeroTransfers ( RejectZeroTransfers ),
        .ErrorCap            ( ErrorCap            ),
        .PrintFifoInfo       ( PrintFifoInfo       ),
        .NumAxInFlight       ( NumAxInFlight       ),
        .MemSysDepth         ( MemSysDepth         ),
        .idma_req_t          ( idma_req_t          ),
        .idma_rsp_t          ( idma_rsp_t          ),
        .idma_eh_req_t       ( idma_eh_req_t       ),
        .idma_busy_t         ( idma_busy_t         ),
        .protocol_req_t      ( axi_lite_req_t      ),
        .protocol_rsp_t      ( axi_lite_rsp_t      ),
        .aw_chan_t           ( axi_lite_aw_chan_t  ),
        .ar_chan_t           ( axi_lite_ar_chan_t  )
    ) i_idma_backend (
        .clk_i          ( clk              ),
        .rst_ni         ( rst_n            ),
        .testmode_i     ( 1'b0             ),
        .idma_req_i     ( idma_req         ),
        .req_valid_i    ( req_valid        ),
        .req_ready_o    ( req_ready        ),
        .idma_rsp_o     ( idma_rsp         ),
        .rsp_valid_o    ( rsp_valid        ),
        .rsp_ready_i    ( rsp_ready        ),
        .idma_eh_req_i  ( idma_eh_req      ),
        .eh_req_valid_i ( eh_req_valid     ),
        .eh_req_ready_o ( eh_req_ready     ),
        .protocol_req_o ( dut_axi_lite_req ),
        .protocol_rsp_i ( dut_axi_lite_rsp ),
        .busy_o         ( busy             )
    );


    //--------------------------------------
    // TB connections
    //--------------------------------------

    // AXI-Lite to AXI Bridge

    axi_lite_to_axi #(
        .AxiDataWidth ( DataWidth      ),
        .req_lite_t   ( axi_lite_req_t ),
        .resp_lite_t  ( axi_lite_rsp_t ),
        .axi_req_t    ( axi_req_t      ),
        .axi_resp_t   ( axi_rsp_t      )
    ) i_axi_lite_to_axi (
        .slv_req_lite_i  ( dut_axi_lite_req          ),
        .slv_resp_lite_o ( dut_axi_lite_rsp          ),
        .slv_aw_cache_i  ( axi_pkg::CACHE_MODIFIABLE ),
        .slv_ar_cache_i  ( axi_pkg::CACHE_MODIFIABLE ),
        .mst_req_o       ( axi_req                   ),
        .mst_resp_i      ( axi_rsp                   )
    );

    // Channel Logger
    if (AxiDumper) begin : gen_axi_dumper
        axi_dumper #(
            .LogAW      ( 1'b1      ),
            .LogAR      ( 1'b1      ),
            .LogW       ( 1'b1      ),
            .LogB       ( 1'b1      ),
            .LogR       ( 1'b1      ),
            .axi_req_t  ( axi_req_t ),
            .axi_resp_t ( axi_rsp_t )
        ) i_axi_dumper (
            .clk_i      ( clk     ),
            .rst_ni     ( rst_n   ),

            .axi_req_i  ( axi_req ),
            .axi_resp_i ( axi_rsp )
        );
    end

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
            automatic tb_dma_job_t now = req_jobs.pop_front();
            // print job to terminal
            $display("%s", now.pprint());
            // init mem (model and AXI)
            init_mem(now);
            // launch DUT
            drv.launch_tf(
                          now.length,
                          now.src_addr,
                          now.dst_addr,
                          now.aw_decoupled,
                          now.rw_decoupled,
                          $clog2(now.max_src_len),
                          $clog2(now.max_dst_len),
                          now.max_src_len != 'd256,
                          now.max_dst_len != 'd256
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
            automatic tb_dma_job_t now = rsp_jobs[0];
            // wait for DMA to complete
            ack_tf_handle_err(now);
            // finished job
            // $display("vvv Finished: vvv%s\n^^^ Finished: ^^^", now.pprint());
            // launch model
            model.transfer(
                           now.length,
                           now.src_addr,
                           now.dst_addr,
                           now.max_src_len,
                           now.max_dst_len,
                           now.rw_decoupled,
                           now.err_addr,
                           now.err_is_read,
                           now.err_action
                          );
            // check memory
            compare_mem(now.length, now.dst_addr, match);
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
            // at least one watch dog triggers
            if (i_axi_r_watchdog.cnt == 0 | i_axi_w_watchdog.cnt == 0) begin
                automatic tb_dma_job_t now = rsp_jobs[0];
                $error("First non-acked transfer:%s\n\n", now.pprint());
            end
            @(posedge clk);
        end
    end

endmodule : tb_idma_lite_backend

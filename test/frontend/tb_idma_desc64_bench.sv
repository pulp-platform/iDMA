// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

`include "apb/typedef.svh"
`include "apb/assign.svh"
`include "idma/tracer.svh"
`include "idma/typedef.svh"
`include "axi/typedef.svh"
`include "axi/assign.svh"



/// Benchmarking TB for the descriptor-based frontend
module tb_idma_desc64_bench
    import idma_desc64_addrmap_pkg::IDMA_DESC64_REG_DESC_ADDR_REG_OFFSET;
    import idma_desc64_addrmap_pkg::IDMA_DESC64_REG_STATUS_REG_OFFSET;
    import rand_verif_pkg::rand_wait;
    import axi_pkg::*;
    import apb_test::apb_driver; #(
    parameter integer NumberOfTests           = 100,
    parameter integer SimulationTimeoutCycles = 1000000,
    parameter integer ChainedDescriptors      = 10,
    parameter integer TransferLength          = 1024,
    parameter integer AlignmentMask           = 'h0f,
    parameter integer NumContiguous           = 200000,
    parameter integer MaxAxInFlight           = 64,
    parameter bit     DoIRQ                   = 1,
    parameter integer TransfersToSkip         = 4,
    // from frontend
    parameter int unsigned InputFifoDepth     = 8,
    parameter int unsigned PendingFifoDepth   = 8,
    parameter int unsigned NSpeculation       = 4,
    // from backend tb
    parameter int unsigned BufferDepth         = 3,
    parameter int unsigned NumAxInFlight       = NSpeculation > 3 ? NSpeculation : 3,
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
    parameter bit          DmaTracing          = 1,
    parameter int unsigned Seed                = 1337
) ();
    localparam time PERIOD     = 10ns;
    localparam time APPL_DELAY = PERIOD / 4;
    localparam time ACQ_DELAY  = PERIOD * 3 / 4;

    localparam integer RESET_CYCLES              = 10;

    localparam integer DataWidth  = 64;
    localparam integer AddrWidth  = 64;
    localparam integer UserWidth  = 1;
    localparam integer AxiIdWidth = 3;

    typedef logic [63:0] addr_t;
    typedef logic [ 2:0] axi_id_t;
    typedef logic [ 3:0] mem_axi_id_t;
    typedef axi_test::axi_ax_beat #(.AW(64), .IW(3), .UW(1)) ax_beat_t;
    typedef axi_test::axi_r_beat  #(.DW(64), .IW(3), .UW(1)) r_beat_t;
    typedef axi_test::axi_w_beat  #(.DW(64), .UW(1))         w_beat_t;
    typedef axi_test::axi_b_beat  #(.IW(3),  .UW(1))         b_beat_t;

    `APB_TYPEDEF_ALL(apb, /* addr */ addr_t, /* data */ logic [63:0], /* strobe */ logic [7:0])
    `AXI_TYPEDEF_ALL(axi, /* addr */ addr_t, /* id */ axi_id_t, /* data */ logic [63:0], /* strb */ logic [7:0], /* user */ logic [0:0])
    `AXI_TYPEDEF_ALL(mem_axi, /* addr */ addr_t, /* id */ mem_axi_id_t, /* data */ logic [63:0], /* strb */ logic [7:0], /* user */ logic [0:0])

    // iDMA struct definitions
    typedef logic [TFLenWidth-1:0]  tf_len_t;

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

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

    // set seed
    initial begin
        automatic int drop = $urandom(Seed);
    end

    class stimulus_t;
        rand addr_t base;
        rand idma_req_t burst;
        rand logic do_irq;
        addr_t next = 64'hffff_ffff_ffff_ffff;

        // an entire descriptor of 4 words must fit before the end of memory
        constraint descriptor_fits_in_memory { (64'hffff_ffff_ffff_ffff - base) > 64'd32; }
        constraint descriptor_is_in_descriptor_area { base > 64'h0000_ffff_ffff_ffff; }
        constraint descriptor_is_aligned { (base & 64'hf) == 0; }
        constraint no_empty_transfers { burst.length > '0; }
        constraint src_fits_in_memory { 64'hffff_ffff_ffff_ffff - burst.src_addr > burst.length; }
        constraint dst_fits_in_memory { 64'hffff_ffff_ffff_ffff - burst.dst_addr > burst.length; }
        constraint src_is_not_in_descriptor_area { 64'h0000_ffff_ffff_ffff > (burst.src_addr + burst.length); }
        constraint dst_is_not_in_descriptor_area { 64'h0000_ffff_ffff_ffff > (burst.dst_addr + burst.length); }
        constraint src_aligned { (burst.src_addr & AlignmentMask) == 64'b0; }
        constraint dst_aligned { (burst.dst_addr & AlignmentMask) == 64'b0; }
        constraint src_burst_valid { burst.opt.src.burst inside { BURST_INCR }; }
        constraint dst_burst_valid { burst.opt.dst.burst inside { BURST_INCR }; }
        constraint reduce_len_equal { burst.opt.beo.src_reduce_len == burst.opt.beo.dst_reduce_len; }
        constraint reduce_len_zero { burst.opt.beo.src_reduce_len == 1'b0; }
        constraint beo_zero { burst.opt.beo.decouple_aw == '0 && burst.opt.beo.src_max_llen == '0 && burst.opt.beo.dst_max_llen == '0 && burst.opt.last == '0 && burst.opt.beo.decouple_rw == '0; }
        constraint axi_params_zero_src { burst.opt.src.lock == '0 && burst.opt.src.prot == '0 && burst.opt.src.qos == '0 && burst.opt.src.region == '0; }
        constraint axi_params_zero_dst { burst.opt.dst.lock == '0 && burst.opt.dst.prot == '0 && burst.opt.dst.qos == '0 && burst.opt.dst.region == '0; }
        constraint axi_src_cache_zero { burst.opt.src.cache == '0; }
        constraint axi_dst_cache_zero { burst.opt.dst.cache == '0; }
        constraint transfer_length { burst.length == TransferLength; }
        constraint irq { do_irq == DoIRQ; }
    endclass

    typedef struct {
        idma_req_t   burst;
        addr_t       read_address;
        logic  [7:0] read_length;
        logic  [2:0] read_size;
        addr_t       write_address;
        logic  [7:0] write_length;
        logic  [2:0] write_size;
        logic [63:0] write_data;
        logic        did_irq;
    } result_t;
    result_t golden_queue[$];

    // clocks
    logic clk;
    logic rst_n;

    clk_rst_gen #(
        .ClkPeriod(PERIOD),
        .RstClkCycles(RESET_CYCLES)
    ) i_clock_reset_generator (
        .clk_o (clk)  ,
        .rst_no(rst_n)
    );

    // dut signals and module
    APB_DV #(
        .ADDR_WIDTH(64),
        .DATA_WIDTH(64)
    ) i_apb_iface_bus (clk);

    apb_driver #(
        .ADDR_WIDTH(64),
        .DATA_WIDTH(64),
        .TA(APPL_DELAY),
        .TT(ACQ_DELAY)
    ) i_apb_driver = new (i_apb_iface_bus);

    axi_resp_t dma_fe_master_response;
    axi_req_t  dma_fe_master_request;
    axi_resp_t dma_be_cut_resp;
    axi_req_t  dma_be_cut_req;
    axi_resp_t dma_be_master_response, axi_read_rsp, axi_write_rsp;
    axi_req_t  dma_be_master_request,  axi_read_req, axi_write_req;
    mem_axi_resp_t axi_mem_response;
    mem_axi_req_t  axi_mem_request;
    mem_axi_resp_t axi_throttle_rsp;
    mem_axi_req_t  axi_throttle_req;
    mem_axi_resp_t axi_multicut_rsp;
    mem_axi_req_t  axi_multicut_req;

    AXI_BUS_DV #(
        .AXI_ADDR_WIDTH(64),
        .AXI_DATA_WIDTH(64),
        .AXI_ID_WIDTH(3),
        .AXI_USER_WIDTH(1)
    ) i_axi_be_bus (clk);

    AXI_BUS_DV #(
        .AXI_ADDR_WIDTH(64),
        .AXI_DATA_WIDTH(64),
        .AXI_ID_WIDTH(3),
        .AXI_USER_WIDTH(1)
    ) i_axi_iface_bus (clk);

    axi_test::axi_driver #(
        .AW(64),
        .DW(64),
        .IW(3),
        .UW(1),
        .TA(APPL_DELAY),
        .TT(ACQ_DELAY)
    ) i_axi_iface_driver = new (i_axi_iface_bus);

    apb_resp_t dma_slave_response;
    apb_req_t dma_slave_request;

    idma_pkg::idma_busy_t busy;
    idma_req_t dma_be_req;
    idma_rsp_t dma_be_rsp;

    logic dma_be_req_valid;
    logic dma_be_req_ready;
    logic dma_be_rsp_valid;
    logic dma_be_rsp_ready;
    logic irq;

    idma_desc64_top #(
        .AddrWidth       (64),
        .DataWidth       (64),
        .AxiIdWidth      (3),
        .idma_req_t      (idma_req_t),
        .idma_rsp_t      (idma_rsp_t),
        .axi_rsp_t       (axi_resp_t),
        .axi_req_t       (axi_req_t),
        .axi_ar_chan_t   (axi_ar_chan_t),
        .axi_r_chan_t    (axi_r_chan_t),
        .apb_rsp_t       (apb_resp_t),
        .apb_req_t       (apb_req_t),
        .InputFifoDepth  (InputFifoDepth),
        .PendingFifoDepth(PendingFifoDepth),
        .BackendDepth    (NumAxInFlight + BufferDepth),
        .NSpeculation    (NSpeculation)
    ) i_dut (
        .clk_i           (clk),
        .rst_ni          (rst_n),
        .master_req_o    (dma_fe_master_request),
        .master_rsp_i    (dma_fe_master_response),
        .axi_ar_id_i     (3'b111),
        .axi_aw_id_i     (3'b111),
        .slave_req_i     (dma_slave_request),
        .slave_rsp_o     (dma_slave_response),
        .idma_req_o      (dma_be_req),
        .idma_req_valid_o(dma_be_req_valid),
        .idma_req_ready_i(dma_be_req_ready),
        .idma_rsp_i      ('0),
        .idma_rsp_valid_i(dma_be_rsp_valid),
        .idma_rsp_ready_o(dma_be_rsp_ready),
        .idma_busy_i     (|busy),
        .irq_o           (irq)
    );

    idma_backend_rw_axi #(
        .DataWidth            ( DataWidth                   ),
        .AddrWidth            ( AddrWidth                   ),
        .AxiIdWidth           ( AxiIdWidth                  ),
        .UserWidth            ( UserWidth                   ),
        .TFLenWidth           ( TFLenWidth                  ),
        .MaskInvalidData      ( MaskInvalidData             ),
        .BufferDepth          ( BufferDepth                 ),
        .RAWCouplingAvail     ( RAWCouplingAvail            ),
        .HardwareLegalizer    ( HardwareLegalizer           ),
        .RejectZeroTransfers  ( RejectZeroTransfers         ),
        .ErrorCap             ( idma_pkg::NO_ERROR_HANDLING ),
        .CombinedShifter      ( 1'b0                        ),
        .PrintFifoInfo        ( 1'b0                        ),
        .NumAxInFlight        ( NumAxInFlight               ),
        .MemSysDepth          ( 32'd0                       ),
        .idma_req_t           ( idma_req_t                  ),
        .idma_rsp_t           ( idma_rsp_t                  ),
        .idma_eh_req_t        ( idma_pkg::idma_eh_req_t     ),
        .idma_busy_t          ( idma_pkg::idma_busy_t       ),
        .axi_req_t            ( axi_req_t                   ),
        .axi_rsp_t            ( axi_resp_t                  ),
        .write_meta_channel_t ( write_meta_channel_t        ),
        .read_meta_channel_t  ( read_meta_channel_t         )
    ) i_idma_backend  (
        .clk_i                ( clk               ),
        .rst_ni               ( rst_n             ),
        .testmode_i           ( 1'b0              ),
        .idma_req_i           ( dma_be_req        ),
        .req_valid_i          ( dma_be_req_valid  ),
        .req_ready_o          ( dma_be_req_ready  ),
        .idma_rsp_o           ( dma_be_rsp        ),
        .rsp_valid_o          ( dma_be_rsp_valid  ),
        .rsp_ready_i          ( dma_be_rsp_ready  ),
        .idma_eh_req_i        ( '0                ),
        .eh_req_valid_i       ( '1                ),
        .eh_req_ready_o       ( /* unconnected */ ),
        .axi_read_req_o       ( axi_read_req      ),
        .axi_read_rsp_i       ( axi_read_rsp      ),
        .axi_write_req_o      ( axi_write_req     ),
        .axi_write_rsp_i      ( axi_write_rsp     ),
        .busy_o               ( busy              )
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
        .axi_req_t        ( axi_req_t  ),
        .axi_resp_t       ( axi_resp_t )
    ) i_axi_rw_join (
        .clk_i            ( clk                    ),
        .rst_ni           ( rst_n                  ),
        .slv_read_req_i   ( axi_read_req           ),
        .slv_read_resp_o  ( axi_read_rsp           ),
        .slv_write_req_i  ( axi_write_req          ),
        .slv_write_resp_o ( axi_write_rsp          ),
        .mst_req_o        ( dma_be_master_request  ),
        .mst_resp_i       ( dma_be_master_response )
    );

    // AXI mux
    axi_mux #(
        .SlvAxiIDWidth (3),
        .slv_aw_chan_t (axi_aw_chan_t),
        .mst_aw_chan_t (mem_axi_aw_chan_t),
        .w_chan_t      (axi_w_chan_t),
        .slv_b_chan_t  (axi_b_chan_t),
        .mst_b_chan_t  (mem_axi_b_chan_t),
        .slv_ar_chan_t (axi_ar_chan_t),
        .mst_ar_chan_t (mem_axi_ar_chan_t),
        .slv_r_chan_t  (axi_r_chan_t),
        .mst_r_chan_t  (mem_axi_r_chan_t),
        .slv_req_t     (axi_req_t),
        .slv_resp_t    (axi_resp_t),
        .mst_req_t     (mem_axi_req_t),
        .mst_resp_t    (mem_axi_resp_t),
        .NoSlvPorts    (2),
        .MaxWTrans     (MaxAxInFlight),
        .FallThrough   (1'b0),
        .SpillAw       (1'b0),
        .SpillW        (1'b0),
        .SpillB        (1'b0),
        .SpillAr       (1'b0),
        .SpillR        (1'b0)
    ) i_mux (
        .clk_i      (clk),
        .rst_ni     (rst_n),
        .test_i     (1'b0),
        .slv_reqs_i ({dma_be_master_request, dma_fe_master_request}),
        .slv_resps_o({dma_be_master_response, dma_fe_master_response}),
        .mst_req_o  (axi_throttle_req),
        .mst_resp_i (axi_throttle_rsp)
    );

    // sim memory
    axi_sim_mem #(
        .AddrWidth         ( AddrWidth    ),
        .DataWidth         ( DataWidth    ),
        .IdWidth           (AxiIdWidth + 1),
        .UserWidth         ( UserWidth    ),
        .axi_req_t         (mem_axi_req_t ),
        .axi_rsp_t         (mem_axi_resp_t),
        .WarnUninitialized ( 1'b0         ),
        .ClearErrOnAccess  ( 1'b1         ),
        .ApplDelay         ( APPL_DELAY   ),
        .AcqDelay          ( ACQ_DELAY    )
    ) i_axi_sim_mem (
        .clk_i      ( clk          ),
        .rst_ni     ( rst_n        ),
        .axi_req_i  ( axi_mem_request  ),
        .axi_rsp_o  ( axi_mem_response  ),
        .mon_w_valid_o (),
        .mon_w_addr_o (),
        .mon_w_data_o (),
        .mon_w_id_o (),
        .mon_w_user_o (),
        .mon_w_beat_count_o (),
        .mon_w_last_o (),
        .mon_r_valid_o (),
        .mon_r_addr_o (),
        .mon_r_data_o (),
        .mon_r_id_o (),
        .mon_r_user_o (),
        .mon_r_beat_count_o (),
        .mon_r_last_o ()
    );

    // allow 1 AR, 1 AW in-flight
    axi_throttle #(
        .MaxNumAwPending(MaxAxInFlight),
        .MaxNumArPending(MaxAxInFlight),
        .axi_req_t(mem_axi_req_t),
        .axi_rsp_t(mem_axi_resp_t)
    ) i_axi_throttle (
        .clk_i (clk),
        .rst_ni(rst_n),
        .req_i(axi_throttle_req),
        .rsp_o(axi_throttle_rsp),
        .req_o(axi_multicut_req),
        .rsp_i(axi_multicut_rsp),
        .w_credit_i (MaxAxInFlight),
        .r_credit_i (MaxAxInFlight)
    );

    // delay the signals using AXI4 multicuts
    axi_multicut #(
        .NoCuts     ( MemLatency    ),
        .aw_chan_t  ( mem_axi_aw_chan_t ),
        .w_chan_t   ( mem_axi_w_chan_t  ),
        .b_chan_t   ( mem_axi_b_chan_t  ),
        .ar_chan_t  ( mem_axi_ar_chan_t ),
        .r_chan_t   ( mem_axi_r_chan_t  ),
        .axi_req_t  ( mem_axi_req_t     ),
        .axi_resp_t ( mem_axi_resp_t    )
    ) i_axi_multicut (
        .clk_i       ( clk                    ),
        .rst_ni      ( rst_n                  ),
        .slv_req_i   ( axi_multicut_req       ),
        .slv_resp_o  ( axi_multicut_rsp       ),
        .mst_req_o   ( axi_mem_request        ),
        .mst_resp_i  ( axi_mem_response       )
    );

    assign dma_slave_request.paddr   = i_apb_iface_bus.paddr;
    assign dma_slave_request.pprot   = i_apb_iface_bus.pprot;
    assign dma_slave_request.psel    = i_apb_iface_bus.psel;
    assign dma_slave_request.penable = i_apb_iface_bus.penable;
    assign dma_slave_request.pwrite  = i_apb_iface_bus.pwrite;
    assign dma_slave_request.pwdata  = i_apb_iface_bus.pwdata;
    assign dma_slave_request.pstrb   = i_apb_iface_bus.pstrb;
    assign i_apb_iface_bus.pready          = dma_slave_response.pready;
    assign i_apb_iface_bus.prdata          = dma_slave_response.prdata;
    assign i_apb_iface_bus.pslverr         = dma_slave_response.pslverr;

    `AXI_ASSIGN_FROM_REQ(i_axi_iface_bus, dma_fe_master_request);
    `AXI_ASSIGN_FROM_RESP(i_axi_iface_bus, dma_fe_master_response);

    `AXI_ASSIGN_FROM_REQ(i_axi_be_bus, dma_be_master_request);
    `AXI_ASSIGN_FROM_RESP(i_axi_be_bus, dma_be_master_response);

    initial begin
        i_axi_iface_driver.reset_slave();
    end

    // queues for communication and data transfer
    stimulus_t   generated_stimuli[$][$];
    result_t     ar_seen_result[$];
    result_t     inflight_results_after_reads[$];
    result_t     inflight_results_submitted_to_be[$];
    result_t     aw_seen_result[$];
    result_t     w_seen_result[$];
    result_t     result_queue[$];

    function automatic void generate_stimuli();
        automatic addr_t base_current = 64'h0001_0000_0000_0000;
        automatic int    contiguous   = 0;
        repeat (NumberOfTests) begin
            automatic stimulus_t current_stimulus;
            automatic stimulus_t current_stimuli_group[$];
            automatic int        number_of_descriptors_in_test;

            number_of_descriptors_in_test = ChainedDescriptors;

            current_stimulus = new();
            if (!current_stimulus.randomize()) begin
                $error("Couldn't randomize stimulus");
            end else begin

                // overwrite protocols
                current_stimulus.burst.opt.src_protocol = idma_pkg::AXI;
                current_stimulus.burst.opt.dst_protocol = idma_pkg::AXI;

                current_stimulus.base = base_current;
                current_stimuli_group.push_back(current_stimulus);
                contiguous += 1;
                golden_queue.push_back('{
                    burst:        current_stimulus.burst,

                    read_address: current_stimulus.base,
                    // axi length 3 is 4 transfers (+1)
                    read_length:  'd3,
                    // 2^3 = 8 bytes in a transfer
                    read_size:    'b011,

                    write_address: current_stimulus.base,
                    // axi length 0 is 1 transfer (+1)
                    write_length:  8'b0,
                    // 2^3 = 8 bytes in a transfer
                    write_size:    3'b011,
                    write_data:    64'hffff_ffff_ffff_ffff,

                    did_irq:       current_stimulus.do_irq
                });
                if (contiguous != NumContiguous) begin
                    base_current += 'd32;
                end else begin
                    // make sure all invalid prefetches grab Xs from memory
                    base_current += 'h1000;
                    contiguous    = '0;
                end
            end

            repeat (number_of_descriptors_in_test - 1) begin
                current_stimulus = new();
                if (!current_stimulus.randomize()) begin
                    $error("Couldn't randomize stimulus");
                end else begin

                    // overwrite protocols
                    current_stimulus.burst.opt.src_protocol = idma_pkg::AXI;
                    current_stimulus.burst.opt.dst_protocol = idma_pkg::AXI;

                    current_stimulus.base = base_current;
                    contiguous += 1;

                    // chain descriptor
                    current_stimuli_group[$].next = current_stimulus.base;

                    current_stimuli_group.push_back(current_stimulus);

                    golden_queue.push_back('{
                        burst:        current_stimulus.burst,

                        read_address: current_stimulus.base,
                        // axi length 3 is 4 transfers (+1)
                        read_length:  'd3,
                        // 2^3 = 8 bytes in a transfer
                        read_size:    'b011,

                        write_address: current_stimulus.base,
                        // axi length 0 is 1 transfer (+1)
                        write_length:  8'b0,
                        // 2^3 = 8 bytes in a transfer
                        write_size:    3'b011,
                        write_data:    64'hffff_ffff_ffff_ffff,

                        did_irq:       current_stimulus.do_irq
                    });
                end
                if (contiguous != NumContiguous) begin
                    base_current += 'd32;
                end else begin
                    // make sure all invalid prefetches grab Xs from memory
                    base_current += 'h1000;
                    contiguous    = '0;
                end
            end
            generated_stimuli.push_back(current_stimuli_group);
        end
        // make the last stimulus generate an irq to simplify the IRQ
        // acquisition
        // NOTE: with few requests this might impact statitics of the no-IRQ
        // case
        generated_stimuli[$][$].do_irq = 1'b1;
        golden_queue[$].did_irq = 1'b1;
    endfunction : generate_stimuli

    function automatic void write_mem_64(addr_t base, logic[63:0] data);
        i_axi_sim_mem.mem[base]     = data[ 7: 0];
        i_axi_sim_mem.mem[base + 1] = data[15: 8];
        i_axi_sim_mem.mem[base + 2] = data[23:16];
        i_axi_sim_mem.mem[base + 3] = data[31:24];
        i_axi_sim_mem.mem[base + 4] = data[39:32];
        i_axi_sim_mem.mem[base + 5] = data[47:40];
        i_axi_sim_mem.mem[base + 6] = data[55:48];
        i_axi_sim_mem.mem[base + 7] = data[63:56];
    endfunction : write_mem_64

    function automatic void load_descriptors_into_memory();
        $display("Loading descriptors");
        foreach (generated_stimuli[i]) begin
            foreach (generated_stimuli[i][j]) begin
                automatic addr_t base       = generated_stimuli[i][j].base;
                write_mem_64(base, stimulus_to_flag_bits(generated_stimuli[i][j]));
                if (j == (generated_stimuli[i].size() - 1)) begin
                    write_mem_64(base + 64'h8, 64'hffff_ffff_ffff_ffff);
                end else begin
                    write_mem_64(base + 64'h8, generated_stimuli[i][j+1].base);
                end
                write_mem_64(base + 64'h10, generated_stimuli[i][j].burst.src_addr);
                write_mem_64(base + 64'h18, generated_stimuli[i][j].burst.dst_addr);
            end
        end
    endfunction : load_descriptors_into_memory

    task apply_stimuli();
        fork
            regbus_slave_interaction();
        join
    endtask

    task collect_responses();
        fork
            axi_master_acquire_ars();
            axi_master_acquire_rs();
            axi_master_acquire_aw();
            axi_master_acquire_w();
            axi_master_acquire_irqs();
            acquire_bursts();
        join
    endtask

    // regbus slave interaction (we're acting as master)
    task regbus_slave_interaction();
        automatic stimulus_t current_stimulus_group[$];
        i_apb_driver.reset_master();
        @(posedge rst_n);

        forever begin
            automatic logic [63:0] status;
            automatic addr_t       start_addr;
            automatic logic        error;

            wait (generated_stimuli.size() > '0);
            current_stimulus_group = generated_stimuli.pop_front();

            i_apb_driver.write(
                .addr(IDMA_DESC64_REG_DESC_ADDR_REG_OFFSET) ,
                .data(current_stimulus_group[0].base),
                .strb(8'hff)                         ,
                .err (error)
            );
        end
    endtask

    function automatic logic [63:0] stimulus_to_flag_bits(stimulus_t stim);
        // Copied from frontend:
        // bit  0         set to trigger an irq on completion, unset to not be notified
        // bits 2:1       burst type for source, fixed: 00, incr: 01, wrap: 10
        // bits 4:3       burst type for destination, fixed: 00, incr: 01, wrap: 10
        //                for a description of these modes, check AXI-Pulp documentation
        // bit  5         set to decouple reads and writes in the backend
        // bit  6         set to serialize requests. Not setting might violate AXI spec
        // bit  7         set to deburst (each burst is split into own transfer)
        //                for a more thorough description, refer to the iDMA backend documentation
        // bits 11:8      Bitfield for AXI cache attributes for the source
        // bits 15:12     Bitfield for AXI cache attributes for the destination
        //                bits of the bitfield (refer to AXI-Pulp for a description):
        //                bit 0: cache bufferable
        //                bit 1: cache modifiable
        //                bit 2: cache read alloc
        //                bit 3: cache write alloc
        // bits 23:16     AXI ID used for the transfer
        // bits 31:26     unused/reserved
        automatic logic [63:0] result = '0;
        automatic logic [31:0] flags  = '0;

        flags[0]     = stim.do_irq;
        flags[2:1]   = stim.burst.opt.src.burst;
        flags[4:3]   = stim.burst.opt.dst.burst;
        flags[5]     = stim.burst.opt.beo.decouple_rw;
        flags[6]     = 1'b0;
        // flags[6]     = stim.burst.opt.beo.serialize;
        flags[7]     = stim.burst.opt.beo.src_reduce_len;
        flags[11:8]  = stim.burst.opt.src.cache;
        flags[15:12] = stim.burst.opt.dst.cache;
        flags[23:16] = stim.burst.opt.axi_id;
        flags[31:26] = '0;

        result[31:0]  = stim.burst.length;
        result[63:32] = flags;
        return result;
    endfunction

    task axi_master_acquire_ars();
        @(posedge rst_n);
        forever begin
            automatic ax_beat_t ar_beat;
            automatic result_t current_result;
            // monitor ar
            i_axi_iface_driver.mon_ar(ar_beat);
            // and record contents
            current_result.read_address = ar_beat.ax_addr;
            current_result.read_length  = ar_beat.ax_len;
            current_result.read_size    = ar_beat.ax_size;
            ar_seen_result.push_back(current_result);
        end
    endtask : axi_master_acquire_ars

    task axi_master_acquire_rs();
        @(posedge rst_n);
        forever begin
            automatic r_beat_t r_beat;
            automatic result_t current_result;
            wait (ar_seen_result.size() > 0);
            current_result = ar_seen_result.pop_front();
            i_axi_iface_driver.mon_r(r_beat);
            if ($isunknown(r_beat.r_data)) begin
                // drop current result
                // as it is a prefetched one
            end else begin
                inflight_results_after_reads.push_back(current_result);
            end
            // four reads per descriptor in the 64-bit case
            i_axi_iface_driver.mon_r(r_beat);
            i_axi_iface_driver.mon_r(r_beat);
            i_axi_iface_driver.mon_r(r_beat);
            if (!r_beat.r_last) begin
                $error("R acquisition has come out-of-sync.");
            end
        end
    endtask : axi_master_acquire_rs

    task axi_master_acquire_aw();
        // set to one to skip first submission of what would be an invalid result
        automatic result_t current_result;
        @(posedge rst_n);
        forever begin
            automatic ax_beat_t aw_beat;
            i_axi_iface_driver.mon_aw(aw_beat);

            wait (inflight_results_submitted_to_be.size() > 0);
            current_result = inflight_results_submitted_to_be.pop_front();
            current_result.write_address = aw_beat.ax_addr;
            current_result.write_length  = aw_beat.ax_len;
            current_result.write_size    = aw_beat.ax_size;
            aw_seen_result.push_back(current_result);
        end
    endtask

    task axi_master_acquire_w();
        automatic result_t current_result;
        @(posedge rst_n);
        forever begin
            automatic w_beat_t  w_beat;
            i_axi_iface_driver.mon_w(w_beat);
            wait (aw_seen_result.size() > 0);
            current_result = aw_seen_result.pop_front();
            current_result.write_data = w_beat.w_data;
            w_seen_result.push_back(current_result);
        end
    endtask : axi_master_acquire_w

    task axi_master_acquire_irqs();
        automatic result_t current_result;
        @(posedge rst_n);
        forever begin
            automatic b_beat_t  b_beat;
            automatic result_t  current_result;

            // HACK: I'm taking advantage of the knowledge that the irq and
            // B happen in the same cycle
            i_axi_iface_driver.mon_b(b_beat);
            wait(w_seen_result.size() > 0);
            current_result = w_seen_result.pop_front();
            current_result.did_irq = irq;
            result_queue.push_back(current_result);
        end
    endtask : axi_master_acquire_irqs

    task acquire_bursts();
        automatic result_t current_result;
        automatic idma_req_t current_burst;
        @(posedge rst_n);
        forever begin
            forever begin
                @(posedge clk);
                #(ACQ_DELAY);
                if (dma_be_req_valid && dma_be_req_ready) break;
            end
            current_burst = dma_be_req;
            wait (inflight_results_after_reads.size() > 0);
            current_result = inflight_results_after_reads.pop_front();
            current_result.burst = current_burst;
            inflight_results_submitted_to_be.push_back(current_result);
        end
    endtask

    // score the results
    initial begin : proc_scoring
        static logic finished_simulation = 1'b0;

        static int number_of_descriptors = 0;
        static int read_addr_errors      = 0;
        static int read_length_errors    = 0;
        static int read_size_errors      = 0;
        static int write_addr_errors     = 0;
        static int write_length_errors   = 0;
        static int write_data_errors     = 0;
        static int write_size_errors     = 0;
        static int burst_errors          = 0;
        static int irq_errors            = 0;

        generate_stimuli();
        load_descriptors_into_memory();

        fork
            apply_stimuli();
            collect_responses();
            begin : watchdog
                @(posedge rst_n);
                repeat (SimulationTimeoutCycles) begin
                    @(posedge clk);
                end
            end : watchdog
            begin : scorer
                @(posedge rst_n);

                while (golden_queue.size() > '0) begin
                    automatic result_t golden;
                    automatic result_t actual;
                    wait (result_queue.size() > 0);
                    golden = golden_queue.pop_front();
                    actual = result_queue.pop_front();
                    if (golden.burst !== actual.burst) begin
                        $error("Burst mismatch @ %d:\ngolden: %p\nactual: %p",
                            number_of_descriptors, golden.burst, actual.burst);
                        ++burst_errors;
                    end
                    if (golden.read_address !== actual.read_address) begin
                        $error("Read address mismatch @ %d:\ngolden: %x\nactual: %x",
                            number_of_descriptors, golden.read_address, actual.read_address);
                        ++read_addr_errors;
                    end
                    if (golden.read_length !== actual.read_length) begin
                        $error("Read length mismatch @ %d:\ngolden: %x\nactual: %x",
                            number_of_descriptors, golden.read_length, actual.read_length);
                        ++read_length_errors;
                    end
                    if (golden.read_size !== actual.read_size) begin
                        $error("Read size mismatch @ %d:\ngolden: %x\nactual: %x",
                            number_of_descriptors, golden.read_size, actual.read_size);
                        ++read_size_errors;
                    end
                    if (golden.write_address !== actual.write_address) begin
                        $error("Write address mismatch @ %d:\ngolden: %x\nactual: %x",
                            number_of_descriptors, golden.write_address, actual.write_address);
                        ++write_addr_errors;
                    end
                    if (golden.write_length !== actual.write_length) begin
                        $error("Write length mismatch @ %d:\ngolden: %x\nactual: %x",
                            number_of_descriptors, golden.write_length, actual.write_length);
                        ++write_length_errors;
                    end
                    if (golden.write_size !== actual.write_size) begin
                        $error("Write size mismatch @ %d:\ngolden: %x\nactual: %x",
                            number_of_descriptors, golden.write_size, actual.write_size);
                        ++write_size_errors;
                    end
                    if (golden.write_data !== actual.write_data) begin
                        $error("Write data mismatch @ %d:\ngolden: %x\nactual: %x",
                            number_of_descriptors, golden.write_data, actual.write_data);
                        ++write_data_errors;
                    end
                    if (golden.did_irq !== actual.did_irq) begin
                        $error("IRQ mismatch @ %d:\ngolden: %x\nactual: %x",
                            number_of_descriptors, golden.did_irq, actual.did_irq);
                        ++irq_errors;
                    end
                    ++number_of_descriptors;
                end
                // wait for frontend to signal no longer busy
                forever begin
                    automatic logic [63:0] status;
                    automatic logic error;
                    i_apb_driver.read(
                        .addr(IDMA_DESC64_REG_STATUS_REG_OFFSET),
                        .data(status),
                        .err (error)
                    );
                    if (status[0] != 1'b1) break;
                end
                finished_simulation = 1'b1;
            end : scorer
        join_any
        disable fork;
        if (!finished_simulation) begin
            $error("Simulation timed out.");
        end else begin
            $display("Simulation finished in a timely manner.");
        end
        $display("Saw %d descriptors."     , number_of_descriptors);
        $display("Read  address errors: %d", read_addr_errors);
        $display("Read  length  errors: %d", read_length_errors);
        $display("Read  size    errors: %d", read_size_errors);
        $display("Write address errors: %d", write_addr_errors);
        $display("Write length  errors: %d", write_length_errors);
        $display("Write size    errors: %d", write_size_errors);
        $display("Write data    errors: %d", write_data_errors);
        $display("Burst         errors: %d", burst_errors);
        $display("IRQ           errors: %d", irq_errors);
        $finish();
    end : proc_scoring
endmodule : tb_idma_desc64_bench

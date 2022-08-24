// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

`include "register_interface/typedef.svh"
`include "register_interface/assign.svh"
`include "idma/tracer.svh"
`include "idma/typedef.svh"
`include "axi/typedef.svh"
`include "axi/assign.svh"

import idma_desc64_reg_pkg::IDMA_DESC64_DESC_ADDR_OFFSET;
import idma_desc64_reg_pkg::IDMA_DESC64_STATUS_OFFSET;
import rand_verif_pkg::rand_wait;
import axi_pkg::*;
import reg_test::reg_driver;

module tb_idma_desc64_bench #(
    parameter integer NumberOfTests           = 100,
    parameter integer SimulationTimeoutCycles = 100000,
    parameter integer ChainedDescriptors      = 10,
    parameter integer TransferLength          = 1024,
    parameter integer AlignmentMask           = 0'h0f,
    parameter bit     DoIRQ                   = 0,
    // from backend tb
    parameter int unsigned BufferDepth         = 3,
    parameter int unsigned NumAxInFlight       = 3,
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
    parameter bit          IdealMemory         = 1
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
    typedef axi_test::axi_ax_beat #(.AW(64), .IW(3), .UW(1)) ax_beat_t;
    typedef axi_test::axi_r_beat  #(.DW(64), .IW(3), .UW(1)) r_beat_t;
    typedef axi_test::axi_w_beat  #(.DW(64), .UW(1))         w_beat_t;
    typedef axi_test::axi_b_beat  #(.IW(3),  .UW(1))         b_beat_t;

    `REG_BUS_TYPEDEF_ALL(reg, /* addr */ addr_t, /* data */ logic [63:0], /* strobe */ logic [7:0])
    `AXI_TYPEDEF_ALL(axi, /* addr */ addr_t, /* id */ axi_id_t, /* data */ logic [63:0], /* strb */ logic [7:0], /* user */ logic [0:0])

    // iDMA struct definitions
    typedef logic [TFLenWidth-1:0]  tf_len_t;

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

    class stimulus_t;
        rand addr_t base;
        rand idma_req_t burst;
        rand logic do_irq;
        addr_t next = 64'hffff_ffff_ffff_ffff;

        // an entire descriptor of 4 words must fit before the end of memory
        constraint descriptor_fits_in_memory { (64'hffff_ffff_ffff_ffff - base) > 64'd32; }
        constraint no_empty_transfers { burst.length > '0; }
        constraint src_fits_in_memory { 64'hffff_ffff_ffff_ffff - burst.src_addr > burst.length; }
        constraint dst_fits_in_memory { 64'hffff_ffff_ffff_ffff - burst.dst_addr > burst.length; }
        constraint src_aligned { (burst.src_addr & AlignmentMask) == 64'b0; }
        constraint dst_aligned { (burst.dst_addr & AlignmentMask) == 64'b0; }
        constraint src_burst_valid { burst.opt.src.burst inside { BURST_INCR, BURST_WRAP, BURST_FIXED }; }
        constraint dst_burst_valid { burst.opt.dst.burst inside { BURST_INCR, BURST_WRAP, BURST_FIXED }; }
        constraint reduce_len_equal { burst.opt.beo.src_reduce_len == burst.opt.beo.dst_reduce_len; }
        constraint beo_zero { burst.opt.beo.decouple_aw == '0 && burst.opt.beo.src_max_llen == '0 && burst.opt.beo.dst_max_llen == '0 && burst.opt.last == '0; }
        constraint axi_params_zero_src { burst.opt.src.lock == '0 && burst.opt.src.prot == '0 && burst.opt.src.qos == '0 && burst.opt.src.region == '0; }
        constraint axi_params_zero_dst { burst.opt.dst.lock == '0 && burst.opt.dst.prot == '0 && burst.opt.dst.qos == '0 && burst.opt.dst.region == '0; }
        constraint transfer_length { burst.length == TransferLength; }
        constraint irq { do_irq == DoIRQ; }
    endclass

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
    REG_BUS #(
        .ADDR_WIDTH(64),
        .DATA_WIDTH(64)
    ) i_reg_iface_bus (clk);

    reg_driver #(
        .AW(64),
        .DW(64),
        .TA(APPL_DELAY),
        .TT(ACQ_DELAY)
    ) i_reg_iface_driver = new (i_reg_iface_bus);

    axi_resp_t dma_fe_master_response;
    axi_req_t  dma_fe_master_request;
    axi_resp_t dma_be_master_response;
    axi_req_t  dma_be_master_request;
    axi_resp_t axi_mem_response;
    axi_req_t  axi_mem_request;

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

    reg_rsp_t dma_slave_response;
    reg_req_t dma_slave_request;

    idma_busy_t busy;
    idma_req_t dma_be_req;
    idma_rsp dma_be_rsp;

    logic dma_be_idle;
    logic dma_be_req_valid;
    logic dma_be_req_ready;
    logic dma_be_rsp_valid;
    logic dma_be_rsp_ready;
    logic irq;

    idma_desc64_top #(
        .AddrWidth  (64),
        .DataWidth  (64),
        .AxiIdWidth (3),
        .idma_req_t (idma_req_t),
        .idma_rsp_t (idma_rsp_t),
        .axi_rsp_t  (axi_resp_t),
        .axi_req_t  (axi_req_t),
        .reg_rsp_t  (reg_rsp_t),
        .reg_req_t  (reg_req_t)
    ) i_idma_frontend (
        .clk_i               (clk),
        .rst_ni              (rst_n),
        .master_req_o        (dma_master_request),
        .master_rsp_i        (dma_master_response),
        .axi_r_id_i          (3'b111),
        .axi_w_id_i          (3'b111),
        .slave_req_i         (dma_slave_request),
        .slave_rsp_o         (dma_slave_response),
        .dma_be_req_o        (dma_be_req),
        .dma_be_req_valid_o  (dma_be_req_valid),
        .dma_be_req_ready_i  (dma_be_req_ready),
        .dma_be_rsp_i        ('0),
        .dma_be_rsp_valid_i  (dma_be_rsp_valid),
        .dma_be_rsp_ready_o  (dma_be_rsp_ready),
        .dma_be_idle_i       (~|busy),
        .irq_o               (irq)
    );

    idma_backend #(
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
        .axi_req_t           ( axi_req_t           ),
        .axi_rsp_t           ( axi_rsp_t           )
    ) i_idma_backend  (
        .clk_i          ( clk              ),
        .rst_ni         ( rst_n            ),
        .testmode_i     ( 1'b0             ),
        .idma_req_i     ( dma_be_req       ),
        .req_valid_i    ( dma_be_req_valid ),
        .req_ready_o    ( dma_be_req_ready ),
        .idma_rsp_o     ( dma_be_rsp       ),
        .rsp_valid_o    ( dma_be_rsp_valid ),
        .rsp_ready_i    ( dma_be_rsp_ready ),
        .idma_eh_req_i  ( '0               ),
        .eh_req_valid_i ( '1               ),
        .eh_req_ready_o ( /* unconnected */),
        .axi_req_o      ( be_axi_req       ),
        .axi_rsp_i      ( be_axi_rsp       ),
        .busy_o         ( busy             )
    );

    string trace_file;
    initial begin
        void'($value$plusargs("trace_file=%s", trace_file));
    end
    `IDMA_TRACER(i_idma_backend, trace_file);

    // sim memory
    idma_sim_mem #(
        .AddrWidth         ( AddrWidth    ),
        .DataWidth         ( DataWidth    ),
        .IdWidth           ( AxiIdWidth   ),
        .UserWidth         ( UserWidth    ),
        .req_t             ( axi_req_t    ),
        .rsp_t             ( axi_rsp_t    ),
        .WarnUninitialized ( 1'b0         ),
        .ClearErrOnAccess  ( 1'b1         ),
        .ApplDelay         ( APPL_DELAY   ),
        .AcqDelay          ( ACQ_DELAY    )
    ) i_idma_sim_mem (
        .clk_i      ( clk          ),
        .rst_ni     ( rst_n        ),
        .axi_req_i  ( axi_req_mem  ),
        .axi_rsp_o  ( axi_rsp_mem  )
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
        .clk_i       ( clk                    ),
        .rst_ni      ( rst_n                  ),
        .slv_req_i   ( dma_be_master_request  ),
        .slv_resp_o  ( dma_be_master_response ),
        .mst_req_o   ( axi_req_mem            ),
        .mst_resp_i  ( axi_rsp_mem            )
    );

    `REG_BUS_ASSIGN_TO_REQ(dma_slave_request, i_reg_iface_bus);
    `REG_BUS_ASSIGN_FROM_RSP(i_reg_iface_bus, dma_slave_response);

    `AXI_ASSIGN_FROM_REQ(i_axi_iface_bus, dma_master_request);
    `AXI_ASSIGN_TO_RESP(dma_master_response, i_axi_iface_bus);

    initial begin
        i_axi_iface_driver.reset_slave();
        dma_be_rsp_valid = 1'b0;
        dma_be_req_ready = 1'b0;
    end

    // queues for communication and data transfer
    stimulus_t   generated_stimuli[$][$];
    stimulus_t   inflight_stimuli[$][$];

    function automatic void generate_stimuli();
        repeat (NumberOfTests) begin
            automatic stimulus_t current_stimulus;
            automatic stimulus_t current_stimuli_group[$];
            automatic int        number_of_descriptors_in_test;

            void'(std::randomize(number_of_descriptors_in_test) with {
                number_of_descriptors_in_test == ChainedDescriptors;
            });

            current_stimulus = new();
            if (!current_stimulus.randomize()) begin
                $error("Couldn't randomize stimulus");
            end else begin
                current_stimuli_group.push_back(current_stimulus);
            end

            repeat (number_of_descriptors_in_test - 1) begin
                current_stimulus = new();
                if (!current_stimulus.randomize()) begin
                    $error("Couldn't randomize stimulus");
                end else begin
                    // chain descriptor
                    current_stimuli_group[$].next = current_stimulus.base;
                    current_stimuli_group.push_back(current_stimulus);
                end
            end
            generated_stimuli.push_back(current_stimuli_group);
        end
        // make the last stimulus generate an irq to simplify the IRQ
        // acquisition
        // NOTE: with few requests this might impact statitics of the no-IRQ
        // case
        generated_stimuli[$][$].do_irq = 1'b1;
    endfunction : generate_stimuli

    task apply_stimuli();
        fork
            regbus_slave_interaction();
            axi_master_apply_read_channel();
            axi_master_apply_write_channel();
        join
    endtask

    task collect_responses();
        fork
            axi_master_acquire_aw_w_and_irqs();
        join
    endtask

    // regbus slave interaction (we're acting as master)
    task regbus_slave_interaction();
        automatic stimulus_t current_stimulus_group[$];
        i_reg_iface_driver.reset_master();
        @(posedge rst_n);

        forever begin
            automatic logic [63:0] status;
            automatic addr_t       start_addr;
            automatic logic        error;

            wait (generated_stimuli.size() > '0);
            current_stimulus_group = generated_stimuli.pop_front();

            i_reg_iface_driver.send_write(
                .addr (IDMA_DESC64_DESC_ADDR_OFFSET)  ,
                .data (current_stimulus_group[0].base),
                .strb (8'hff)                         ,
                .error(error)
            );
            inflight_stimuli.push_back(current_stimulus_group);
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

    task axi_master_apply_write_channel();
        @(posedge rst_n);
        forever begin
            automatic ax_beat_t aw_beat;
            automatic w_beat_t  w_beat;
            automatic b_beat_t  b_beat;
            // receive and acknowledge all writes
            @(posedge clk);
            fork
                i_axi_iface_driver.recv_aw(aw_beat);
                i_axi_iface_driver.recv_w(w_beat);
            join
            @(posedge clk);
            // all writes succeed
            b_beat = new;
            b_beat.b_id = aw_beat.ax_id;
            @(posedge clk);
            i_axi_iface_driver.send_b(b_beat);
        end
    endtask

    // regbus master interaction read and write application (we're acting as slave)
    task axi_master_apply_read_channel();
        automatic stimulus_t current_stimulus_group[$];
        automatic stimulus_t current_stimulus;

        @(posedge rst_n);

        wait (inflight_stimuli.size() > 0);
        current_stimulus_group = inflight_stimuli.pop_front();
        current_stimulus       = current_stimulus_group.pop_front();

        forever begin
            automatic ax_beat_t ar_beat;
            automatic r_beat_t  r_beat;
            @(posedge clk);
            i_axi_iface_driver.recv_ar(ar_beat);

            // send the descriptor
            r_beat = new;
            r_beat.r_id = ar_beat.ax_id;
            r_beat.r_data = stimulus_to_flag_bits(current_stimulus);
            i_axi_iface_driver.send_r(r_beat);

            if (current_stimulus_group.size() == '0) begin
                r_beat.r_data = 64'hffff_ffff_ffff_ffff;
            end else begin
                r_beat.r_data = current_stimulus_group[0].base;
            end
            i_axi_iface_driver.send_r(r_beat);

            r_beat.r_data = current_stimulus.burst.src_addr;
            i_axi_iface_driver.send_r(r_beat);

            r_beat.r_data = current_stimulus.burst.dst_addr;
            r_beat.r_last = 'b1;
            i_axi_iface_driver.send_r(r_beat);

            // get the next transfer group if we are done with the current group
            if (current_stimulus_group.size() == '0) begin
                wait (inflight_stimuli.size() > '0);
                current_stimulus_group = inflight_stimuli.pop_front();
            end

            current_stimulus = current_stimulus_group.pop_front();
        end
    endtask

    // score the results
    initial begin : proc_scoring
        static logic finished_simulation = 1'b0;

        generate_stimuli();

        fork
            apply_stimuli();
            begin : watchdog
                @(posedge rst_n);
                repeat (SimulationTimeoutCycles) begin
                    @(posedge clk);
                end
            end : watchdog
            begin : scorer
                @(posedge rst_n);

                wait (inflight_stimuli.size() == 0 && generate_stimuli.size() == 0);
                wait (busy == '0);
                wait (irq);
                finished_simulation = 1'b1;
            end : scorer
        join_any
        disable fork;
        if (!finished_simulation) begin
            $error("Simulation timed out.");
        end else begin
            $display("Simulation finished in a timely manner.");
        end
        $stop();
        $finish();
    end : proc_scoring
endmodule : tb_idma_desc64_bench

// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

`include "register_interface/typedef.svh"
`include "register_interface/assign.svh"
`include "idma/typedef.svh"
`include "axi/typedef.svh"
`include "axi/assign.svh"

import idma_desc64_reg_pkg::IDMA_DESC64_DESC_ADDR_OFFSET;
import idma_desc64_reg_pkg::IDMA_DESC64_STATUS_OFFSET;
import rand_verif_pkg::rand_wait;
import axi_pkg::*;
import reg_test::reg_driver;

module tb_idma_desc64_top #(
    parameter int unsigned NumberOfTests           = 100,
    parameter int unsigned SimulationTimeoutCycles = 100000,
    parameter int   signed ChainedDescriptors      = -1,
    parameter int unsigned MaxChainedDescriptors   = 10,
    parameter int unsigned MinChainedDescriptors   = 1,
    parameter int unsigned InputFifoDepth          = 8,
    parameter int unsigned PendingFifoDepth        = 8,
    parameter int unsigned BackendDepth            = 5,
    parameter int unsigned MaxAWWPending           = 8
) ();
    localparam time PERIOD     = 10ns;
    localparam time APPL_DELAY = PERIOD / 4;
    localparam time ACQ_DELAY  = PERIOD * 3 / 4;

    localparam integer RESET_CYCLES              = 10;

    typedef logic [63:0] addr_t;
    typedef logic [ 2:0] axi_id_t;
    typedef axi_test::axi_ax_beat #(.AW(64), .IW(3), .UW(1)) ax_beat_t;
    typedef axi_test::axi_r_beat  #(.DW(64), .IW(3), .UW(1)) r_beat_t;
    typedef axi_test::axi_w_beat  #(.DW(64), .UW(1))         w_beat_t;
    typedef axi_test::axi_b_beat  #(.IW(3),  .UW(1))         b_beat_t;

    `REG_BUS_TYPEDEF_ALL(reg, /* addr */ addr_t, /* data */ logic [63:0], /* strobe */ logic [7:0])
    `AXI_TYPEDEF_ALL(axi, /* addr */ addr_t, /* id */ axi_id_t, /* data */ logic [63:0], /* strb */ logic [7:0], /* user */ logic [0:0])

    // iDMA struct definitions
    localparam int unsigned TFLenWidth  = 32;
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
        constraint src_burst_valid { burst.opt.src.burst inside { BURST_INCR, BURST_WRAP, BURST_FIXED }; }
        constraint dst_burst_valid { burst.opt.dst.burst inside { BURST_INCR, BURST_WRAP, BURST_FIXED }; }
        constraint reduce_len_equal { burst.opt.beo.src_reduce_len == burst.opt.beo.dst_reduce_len; }
        constraint reduce_len_zero { burst.opt.beo.src_reduce_len == 1'b0; }
        constraint beo_zero { burst.opt.beo.decouple_aw == '0 && burst.opt.beo.src_max_llen == '0 && burst.opt.beo.dst_max_llen == '0 && burst.opt.last == '0; }
        constraint axi_params_zero_src { burst.opt.src.lock == '0 && burst.opt.src.prot == '0 && burst.opt.src.qos == '0 && burst.opt.src.region == '0; }
        constraint axi_params_zero_dst { burst.opt.dst.lock == '0 && burst.opt.dst.prot == '0 && burst.opt.dst.qos == '0 && burst.opt.dst.region == '0; }
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

    axi_resp_t dma_master_response;
    axi_req_t dma_master_request;

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

    idma_req_t dma_be_req;

    logic backend_busy;
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
        .reg_rsp_t       (reg_rsp_t),
        .reg_req_t       (reg_req_t),
        .InputFifoDepth  (InputFifoDepth),
        .PendingFifoDepth(PendingFifoDepth),
        .BackendDepth    (BackendDepth),
        .MaxAWWPending   (MaxAWWPending)
    ) i_dut (
        .clk_i           (clk),
        .rst_ni          (rst_n),
        .master_req_o    (dma_master_request),
        .master_rsp_i    (dma_master_response),
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
        .idma_busy_i     (backend_busy),
        .irq_o           (irq)
    );

    assign dma_slave_request.addr  = i_reg_iface_bus.addr;
    assign dma_slave_request.write = i_reg_iface_bus.write;
    assign dma_slave_request.wdata = i_reg_iface_bus.wdata;
    assign dma_slave_request.wstrb = i_reg_iface_bus.wstrb;
    assign dma_slave_request.valid = i_reg_iface_bus.valid;
    assign i_reg_iface_bus.rdata   = dma_slave_response.rdata;
    assign i_reg_iface_bus.ready   = dma_slave_response.ready;
    assign i_reg_iface_bus.error   = dma_slave_response.error;

    `AXI_ASSIGN_FROM_REQ(i_axi_iface_bus, dma_master_request);
    `AXI_ASSIGN_TO_RESP(dma_master_response, i_axi_iface_bus);

    initial begin
        i_axi_iface_driver.reset_slave();
        dma_be_rsp_valid = 1'b0;
        dma_be_req_ready = 1'b0;
        backend_busy = 1'b0;
    end

    // queues for communication and data transfer
    stimulus_t   generated_stimuli[$][$];
    stimulus_t   inflight_stimuli[$][$];
    result_t     inflight_results_after_reads[$];
    result_t     inflight_results_submitted_to_be[$];
    result_t     result_queue[$];

    function automatic void generate_stimuli();
        repeat (NumberOfTests) begin
            automatic stimulus_t current_stimulus;
            automatic stimulus_t current_stimuli_group[$];
            automatic int        number_of_descriptors_in_test;

            if (ChainedDescriptors < 0) begin
                void'(std::randomize(number_of_descriptors_in_test) with {
                    number_of_descriptors_in_test >= MinChainedDescriptors;
                    number_of_descriptors_in_test <= MaxChainedDescriptors;
                });
            end else begin
                number_of_descriptors_in_test = ChainedDescriptors;
            end

            current_stimulus = new();
            if (!current_stimulus.randomize()) begin
                $error("Couldn't randomize stimulus");
            end else begin

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

            repeat (number_of_descriptors_in_test - 1) begin
                current_stimulus = new();
                if (!current_stimulus.randomize()) begin
                    $error("Couldn't randomize stimulus");
                end else begin
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
            end
            generated_stimuli.push_back(current_stimuli_group);
        end
        // make the last stimulus generate an irq to simplify the IRQ
        // acquisition
        generated_stimuli[$][$].do_irq = 1'b1;
        golden_queue[$].did_irq = 1'b1;
    endfunction : generate_stimuli

    task apply_stimuli();
        fork
            regbus_slave_interaction();
            axi_master_apply_read_channel();
            axi_master_apply_write_channel();
            backend_tx_done_notifier();
            backend_acceptor();
        join
    endtask

    task collect_responses();
        fork
            axi_master_aquire_ars();
            axi_master_acquire_aw_w_and_irqs();
            acquire_bursts();
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
                .addr (IDMA_DESC64_DESC_ADDR_OFFSET) ,
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
            i_axi_iface_driver.recv_aw(aw_beat);
            @(posedge clk);
            i_axi_iface_driver.recv_w(w_beat);
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

    task axi_master_aquire_ars();
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
            inflight_results_after_reads.push_back(current_result);
        end
    endtask

    task axi_master_acquire_aw_w_and_irqs();
        // set to one to skip first submission of what would be an invalid result
        automatic bit      captured_irq = '1;
        automatic result_t current_result;
        @(posedge rst_n);
        wait (inflight_results_submitted_to_be.size() > 0);
        current_result = inflight_results_submitted_to_be.pop_front();
        forever begin
            automatic ax_beat_t aw_beat;
            automatic w_beat_t  w_beat;
            @(posedge clk);
            // wait for either an irq or an aw_beat
            fork
                forever begin
                    #(ACQ_DELAY);
                    if (irq) begin
                        break;
                    end
                    @(posedge clk);
                end
                i_axi_iface_driver.mon_aw(aw_beat);
            join_any
            disable fork;

            if (irq) begin
                if (captured_irq) begin
                    $error("Got a duplicate IRQ!");
                end else begin
                    current_result.did_irq = irq;
                    captured_irq = 1'b1;
                    result_queue.push_back(current_result);
                    wait (inflight_results_submitted_to_be.size() > 0);
                    current_result = inflight_results_submitted_to_be.pop_front();
                end
            end else begin
                // if we haven't captured an irq, we are still with the last
                // result, which we now need to submit and get the next one
                if (!captured_irq) begin
                    current_result.did_irq = 0;
                    result_queue.push_back(current_result);
                    wait (inflight_results_submitted_to_be.size() > 0);
                    current_result = inflight_results_submitted_to_be.pop_front();
                end
                current_result.write_address = aw_beat.ax_addr;
                current_result.write_length  = aw_beat.ax_len;
                current_result.write_size    = aw_beat.ax_size;
                captured_irq                 = 1'b0;
                i_axi_iface_driver.mon_w(w_beat);
                current_result.write_data    = w_beat.w_data;
            end
        end
    endtask

    task backend_tx_done_notifier();
        @(posedge rst_n);
        forever begin
            wait (backend_busy);

            rand_wait(5, 20, clk);

            #(APPL_DELAY);
            dma_be_rsp_valid = 1'b1;
            wait (dma_be_rsp_ready);

            @(posedge clk);
            #(APPL_DELAY);
            dma_be_rsp_valid = 1'b0;
            backend_busy = 1'b0;
        end
    endtask

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

    task backend_acceptor();
        @(posedge rst_n);
        forever begin
            wait (!backend_busy);
            @(posedge clk);
            #(APPL_DELAY)
            dma_be_req_ready = 1'b1;
            #(ACQ_DELAY - APPL_DELAY);
            forever begin
                if (dma_be_req_valid) begin
                    break;
                end
                @(posedge clk);
                #(ACQ_DELAY);
            end
            @(posedge clk);
            #(APPL_DELAY)
            dma_be_req_ready = 1'b0;
            backend_busy = 1'b1;
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
                    i_reg_iface_driver.send_read(
                        .addr(IDMA_DESC64_STATUS_OFFSET),
                        .data(status),
                        .error(error)
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
        $stop();
        $finish();
    end : proc_scoring
endmodule : tb_idma_desc64_top

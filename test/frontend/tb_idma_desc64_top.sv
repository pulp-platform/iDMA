// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

`include "apb/typedef.svh"
`include "apb/assign.svh"
`include "idma/typedef.svh"
`include "axi/typedef.svh"
`include "axi/assign.svh"



/// VIP for the descriptor-based frontend
module tb_idma_desc64_top
    import idma_desc64_addrmap_pkg::IDMA_DESC64_REG_DESC_ADDR_REG_OFFSET;
    import idma_desc64_addrmap_pkg::IDMA_DESC64_REG_STATUS_REG_OFFSET;
    import rand_verif_pkg::rand_wait;
    import axi_pkg::*;
    import apb_test::apb_driver; #(
    parameter integer NumberOfTests              = 100,
    parameter integer SimulationTimeoutCycles    = 100000,
    parameter integer ChainedDescriptors         = -1,
    parameter int unsigned MaxChainedDescriptors = 10,
    parameter int unsigned MinChainedDescriptors = 1,
    parameter integer TransferLength             = 1024,
    parameter integer AlignmentMask              = 'h0f,
    parameter integer NumContiguous              = 200000,
    parameter integer MaxAxInFlight              = 64,
    parameter bit     DoIRQ                      = 1,
    parameter integer TransfersToSkip            = 4,
    // from frontend
    parameter int unsigned InputFifoDepth        = 8,
    parameter int unsigned PendingFifoDepth      = 8,
    parameter int unsigned NSpeculation          = 4,
    parameter int unsigned BackendDepth          = 5,
    parameter int unsigned MaxAWWPending         = 8,
    parameter int unsigned Seed                  = 1337
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

    `APB_TYPEDEF_ALL(apb, /* addr */ addr_t, /* data */ logic [63:0], /* strobe */ logic [7:0])
    `AXI_TYPEDEF_ALL(axi, /* addr */ addr_t, /* id */ axi_id_t, /* data */ logic [63:0], /* strb */ logic [7:0], /* user */ logic [0:0])

    // iDMA struct definitions
    localparam int unsigned TFLenWidth  = 32;
    typedef logic [TFLenWidth-1:0]  tf_len_t;

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

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
        constraint src_burst_valid { burst.opt.src.burst inside { BURST_INCR, BURST_WRAP, BURST_FIXED }; }
        constraint dst_burst_valid { burst.opt.dst.burst inside { BURST_INCR, BURST_WRAP, BURST_FIXED }; }
        constraint src_is_not_in_descriptor_area { 64'h0000_ffff_ffff_ffff > (burst.src_addr + burst.length); }
        constraint dst_is_not_in_descriptor_area { 64'h0000_ffff_ffff_ffff > (burst.dst_addr + burst.length); }
        constraint src_aligned { (burst.src_addr & AlignmentMask) == 64'b0; }
        constraint dst_aligned { (burst.dst_addr & AlignmentMask) == 64'b0; }
        constraint reduce_len_equal { burst.opt.beo.src_reduce_len == burst.opt.beo.dst_reduce_len; }
        constraint reduce_len_zero { burst.opt.beo.src_reduce_len == 1'b0; }
        constraint beo_zero { burst.opt.beo.decouple_aw == '0 && burst.opt.beo.src_max_llen == '0 && burst.opt.beo.dst_max_llen == '0 && burst.opt.last == '0 && burst.opt.beo.decouple_rw == '0; }
        constraint axi_params_zero_src { burst.opt.src.lock == '0 && burst.opt.src.prot == '0 && burst.opt.src.qos == '0 && burst.opt.src.region == '0; }
        constraint axi_params_zero_dst { burst.opt.dst.lock == '0 && burst.opt.dst.prot == '0 && burst.opt.dst.qos == '0 && burst.opt.dst.region == '0; }
        constraint axi_src_cache_zero { burst.opt.src.cache == '0; }
        constraint axi_dst_cache_zero { burst.opt.dst.cache == '0; }
        constraint transfer_length { burst.length == TransferLength; }
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

    apb_resp_t dma_slave_response;
    apb_req_t dma_slave_request;

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
        .apb_rsp_t       (apb_resp_t),
        .apb_req_t       (apb_req_t),
        .InputFifoDepth  (InputFifoDepth),
        .PendingFifoDepth(PendingFifoDepth),
        .BackendDepth    (BackendDepth),
        .NSpeculation    (NSpeculation)
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

    // sim memory
    axi_sim_mem #(
        .AddrWidth         ( 64       ),
        .DataWidth         ( 64       ),
        .IdWidth           (3         ),
        .UserWidth         (1         ),
        .axi_req_t         (axi_req_t ),
        .axi_rsp_t         (axi_resp_t),
        .WarnUninitialized (1'b0      ),
        .ClearErrOnAccess  (1'b1      ),
        .ApplDelay         (APPL_DELAY),
        .AcqDelay          (ACQ_DELAY )
    ) i_axi_sim_mem (
        .clk_i      ( clk          ),
        .rst_ni     ( rst_n        ),
        .axi_req_i  ( dma_master_request  ),
        .axi_rsp_o  ( dma_master_response  ),
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

    `AXI_ASSIGN_FROM_REQ(i_axi_iface_bus, dma_master_request);
    `AXI_ASSIGN_FROM_RESP(i_axi_iface_bus, dma_master_response);

    initial begin
        dma_be_rsp_valid = 1'b0;
        dma_be_req_ready = 1'b0;
        backend_busy = 1'b0;
    end

    // queues for communication and data transfer
    stimulus_t   generated_stimuli[$][$];
    stimulus_t   inflight_stimuli[$][$];
    result_t     ar_seen_result[$];
    result_t     inflight_results_after_reads[$];
    result_t     inflight_results_submitted_to_be[$];
    result_t     aw_seen_result[$];
    result_t     w_seen_result[$];
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

                // overwrite protocols
                current_stimulus.burst.opt.src_protocol = idma_pkg::AXI;
                current_stimulus.burst.opt.dst_protocol = idma_pkg::AXI;

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

                    // overwrite protocols
                    current_stimulus.burst.opt.src_protocol = idma_pkg::AXI;
                    current_stimulus.burst.opt.dst_protocol = idma_pkg::AXI;

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
            apb_slave_interaction();
            backend_tx_done_notifier();
            backend_acceptor();
        join
    endtask

    task collect_responses();
        fork
            axi_master_acquire_ars();
            axi_master_acquire_rs();
            axi_master_acquire_aw_w_and_irqs();
            acquire_bursts();
        join
    endtask

    // apb slave interaction (we're acting as master)
    task apb_slave_interaction();
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
                .addr (IDMA_DESC64_REG_DESC_ADDR_REG_OFFSET),
                .data (current_stimulus_group[0].base),
                .strb (8'hff)                         ,
                .err  (error)
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

    task axi_master_acquire_aw_w_and_irqs();
        fork
            axi_master_acquire_aw();
            axi_master_acquire_w();
            axi_master_acquire_irqs();
        join
    endtask : axi_master_acquire_aw_w_and_irqs

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

    task backend_tx_done_notifier();
        automatic int unsigned rand_success, cycles;
        @(posedge rst_n);
        forever begin
            wait (backend_busy);

            /* EXPAND RAND_WAIT FROM COMMON_VERIF_PKG */
            rand_success = randomize(cycles) with {
                cycles >= 5;
                cycles <= 10;
            };
            assert (rand_success) else $error("Failed to randomize wait cycles!");
            repeat (cycles) @(posedge clk);
            /* END EXPAND RAND_WAIT FROM COMMON_VERIF_PKG */

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
                        .addr(idma_desc64_addrmap_pkg::IDMA_DESC64_REG_STATUS_REG_OFFSET),
                        .data(status),
                        .err(error)
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

endmodule : tb_idma_desc64_top

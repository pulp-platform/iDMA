// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

/// This module serves as a descriptor-based frontend for the iDMA in the CVA6-core
module idma_desc64_top #(
    /// Width of the addresses
    parameter int unsigned AddrWidth              = 64   ,
    /// Width of a data item on the AXI bus
    parameter int unsigned DataWidth              = 64   ,
    /// Width an AXI ID
    parameter int unsigned AxiIdWidth             = 3    ,
    /// burst request type. See the documentation of the idma backend for details
    parameter type         idma_req_t            = logic,
    /// burst response type. See the documentation of the idma backend for details
    parameter type         idma_rsp_t            = logic,
    /// regbus interface types. Use the REG_BUS_TYPEDEF macros to define the types
    /// or see the idma backend documentation for more details
    parameter type         reg_rsp_t              = logic,
    parameter type         reg_req_t              = logic,
    /// AXI interface types used for fetching descriptors.
    /// Use the AXI_TYPEDEF_ALL macros to define the types
    parameter type         axi_rsp_t              = logic,
    parameter type         axi_req_t              = logic,
    /// Specifies the depth of the fifo behind the descriptor address register
    parameter int unsigned InputFifoDepth         =     8,
    /// Specifies the buffer size of the fifo that tracks requests submitted to the backend
    parameter int unsigned PendingFifoDepth       =     8
)(
    /// clock
    input  logic                  clk_i             ,
    /// reset
    input  logic                  rst_ni            ,

    /// axi interface
    /// master pair
    /// master request
    output axi_req_t              master_req_o      ,
    /// master response
    input  axi_rsp_t              master_rsp_i      ,
    /// ID to be used by the read channel
    input  logic [AxiIdWidth-1:0] axi_r_id_i        ,
    /// ID to be used by the write channel
    input  logic [AxiIdWidth-1:0] axi_w_id_i        ,
    /// regbus interface
    /// slave pair
    /// The slave interface exposes two registers: One address register to
    /// write a descriptor address to process and a status register that
    /// exposes whether the DMA is busy on bit 0 and whether FIFOs are full
    /// on bit 1.
    /// master request
    input  reg_req_t              slave_req_i       ,
    /// master response
    output reg_rsp_t              slave_rsp_o       ,

    /// backend interface
    /// burst request submission
    /// burst request data. See iDMA backend documentation for fields
    output idma_req_t             dma_be_req_o      ,
    /// valid signal for the backend data submission
    output logic                  dma_be_req_valid_o,
    /// ready signal for the backend data submission
    input  logic                  dma_be_req_ready_i,
    /// status information from the backend
    input  idma_rsp_t             dma_be_rsp_i      ,
    /// valid signal for the backend response
    input  logic                  dma_be_rsp_valid_i,
    /// ready signal for the backend response
    output logic                  dma_be_rsp_ready_o,
    /// whether the backend is currently idle
    input  logic                  dma_be_idle_i     ,

    /// Event: irq
    output logic                  irq_o
);

    import idma_desc64_reg_pkg::*;

    // {{{ typedefs and parameters
    typedef logic [AddrWidth-1:0] addr_t;

    // pragma translate_off
    `ASSERT_INIT(AddrWidthIsSupported, AddrWidth == 64)
    `ASSERT_INIT(DataWidthIsSupported, DataWidth >= 64 && DataWidth <= 256)
    // pragma translate_on

    /// Descriptor layout
    typedef struct packed {
        /// Flags for this request. Currently, the following are defined:
        /// bit  0         set to trigger an irq on completion, unset to not be notified
        /// bits 2:1       burst type for source, fixed: 00, incr: 01, wrap: 10
        /// bits 4:3       burst type for destination, fixed: 00, incr: 01, wrap: 10
        ///                for a description of these modes, check AXI-Pulp documentation
        /// bit  5         set to decouple reads and writes in the backend
        /// bit  6         set to serialize requests. Not setting might violate AXI spec
        /// bit  7         set to deburst (each burst is split into own transfer)
        ///                for a more thorough description, refer to the iDMA backend documentation
        /// bits 11:8      Bitfield for AXI cache attributes for the source
        /// bits 15:12     Bitfield for AXI cache attributes for the destination
        ///                bits of the bitfield (refer to AXI-Pulp for a description):
        ///                bit 0: cache bufferable
        ///                bit 1: cache modifiable
        ///                bit 2: cache read alloc
        ///                bit 3: cache write alloc
        /// bits 23:16     AXI ID used for the transfer
        /// bits 31:24     unused/reserved
        logic [31:0] flags;
        /// length of request in bytes
        logic [31:0] length;
        /// address of next descriptor, 0xFFFF_FFFF_FFFF_FFFF for last descriptor in chain
        addr_t       next;
        /// source address to copy from
        addr_t       src_addr;
        /// destination address to copy to
        addr_t       dest_addr;
    } descriptor_t;

    localparam int          dw_in_bytes             = DataWidth / 8;
    localparam int          axi_size_as_int         = $clog2(dw_in_bytes) > 3 ? 3 : $clog2(dw_in_bytes); //$max(3, (dw_in_bytes));
    localparam logic [2:0]  axi_size_for_data_width = 3'(axi_size_as_int);
    localparam int unsigned words_per_descriptor    = 32 / dw_in_bytes < 1 ? 1 : 32 / dw_in_bytes;
    localparam int unsigned counter_width           = words_per_descriptor == 1 ? 0 : words_per_descriptor - 1;

    typedef struct packed {
        logic  do_irq;
        addr_t descriptor_addr;
    } addr_irq_t;

    localparam addr_t AddressSentinel = ~'0;

    typedef enum logic [1:0] {
        SubmitterIdle,
        SubmitterSendAR,
        SubmitterWaitForData,
        SubmitterSendToBE
    } submitter_e;

    typedef enum logic [1:0] {
        FeedbackIdle,
        FeedbackWaitingOnBackend,
        FeedbackSendAW,
        FeedbackSendData
    } feedback_fsm_e;

    // }}} typedefs and parameters

    // {{{ signal declarations

    axi_req_t master_req;

    // {{{ descriptor addr input to fifo
    idma_desc64_reg2hw_t register_file_to_hw;
    idma_desc64_hw2reg_t register_file_to_reg;

    addr_t                desc_addr_to_input_fifo_data;
    logic                 desc_addr_to_input_fifo_valid;
    logic                 desc_addr_to_input_fifo_ready;

    addr_t                desc_addr_from_input_fifo_data;
    logic                 desc_addr_from_input_fifo_valid;
    logic                 desc_addr_from_input_fifo_ready;

    logic [$clog2(InputFifoDepth)-1:0]           desc_addr_fifo_usage;
    // }}} descriptor addr input to fifo

    // {{{ pending descriptor FIFO
    addr_irq_t pending_descriptor_to_fifo_data;
    logic      pending_descriptor_to_fifo_valid;
    logic      pending_descriptor_to_fifo_ready;

    addr_irq_t pending_descriptor_from_fifo_data;
    logic      pending_descriptor_from_fifo_valid;
    logic      pending_descriptor_from_fifo_ready;
    // }}} pending descriptor FIFO

    // {{{ submitter FSM
    // state
    submitter_e  submitter_q,                    submitter_d;
    logic [counter_width:0] submitter_fetch_counter_q, submitter_fetch_counter_d;
    // data
    addr_t       submitter_current_addr_q,       submitter_current_addr_d;
    descriptor_t submitter_current_descriptor_q, submitter_current_descriptor_d;
    idma_req_t   submitter_burst_req;
    // ready-valid signals
    logic        submitter_input_fifo_ready;
    logic        submitter_input_fifo_valid;
    logic        submitter_burst_valid_q,        submitter_burst_valid_d;
    logic        submitter_pending_fifo_valid_q, submitter_pending_fifo_valid_d;
    // }}} submitter FSM

    // {{{ instantiated modules
    logic completion_counter_decrement;
    // }}} instantiated modules

    // {{{ feedback FSM
    // state
    feedback_fsm_e feedback_fsm_q,                      feedback_fsm_d;
    // data
    addr_irq_t     feedback_addr_irq_q,                 feedback_addr_irq_d;
    logic          feedback_irq_q,                      feedback_irq_d;
    logic          dma_be_rsp_ready;
    // }}} feedback FSM

    // }}} signal declarations

    // {{{ combinatorial processes

    // {{{ descriptor addr input to fifo
    assign desc_addr_to_input_fifo_data = register_file_to_hw.desc_addr.q;
    // }}} descriptor addr input to fifo

    // {{{ submitter FSM
    assign desc_addr_from_input_fifo_ready                 = submitter_q == SubmitterIdle;
    assign submitter_input_fifo_valid                      = desc_addr_from_input_fifo_valid;
    assign pending_descriptor_to_fifo_valid                = submitter_pending_fifo_valid_q;

    // TODO: make sure that a burst does not cross a 4-KB boundary
    always_comb begin : proc_submitter_axi_ar
        master_req.ar                                      = '0;
        master_req.ar.id                                   = axi_r_id_i;
        master_req.ar.addr                                 = submitter_current_addr_q;
        master_req.ar.len                                  = 8'(words_per_descriptor - 1);
        master_req.ar.size                                 = axi_size_for_data_width;
        master_req.ar.burst                                = axi_pkg::BURST_INCR;
    end
    assign master_req.ar_valid                             = submitter_q == SubmitterSendAR;
    assign master_req.r_ready                              = submitter_q == SubmitterWaitForData;

    assign pending_descriptor_to_fifo_data.do_irq          = submitter_current_descriptor_q.flags[0];
    assign pending_descriptor_to_fifo_data.descriptor_addr = submitter_current_addr_q;

    always_comb begin : proc_submitter_burst_req
        submitter_burst_req                        = '0;

        submitter_burst_req.length                 = submitter_current_descriptor_q.length;
        submitter_burst_req.src_addr               = submitter_current_descriptor_q.src_addr;
        submitter_burst_req.dst_addr               = submitter_current_descriptor_q.dest_addr;

            // Current backend only supports one ID
        submitter_burst_req.opt.axi_id             = submitter_current_descriptor_q.flags[23:16];
        submitter_burst_req.opt.src.burst          = submitter_current_descriptor_q.flags[2:1];
        submitter_burst_req.opt.src.cache          = submitter_current_descriptor_q.flags[11:8];
            // AXI4 does not support locked transactions, use atomics
        submitter_burst_req.opt.src.lock           = '0;
            // unpriviledged, secure, data access
        submitter_burst_req.opt.src.prot           = '0;
            // not participating in qos
        submitter_burst_req.opt.src.qos            = '0;
            // only one region
        submitter_burst_req.opt.src.region         = '0;
        submitter_burst_req.opt.dst.burst          = submitter_current_descriptor_q.flags[4:3];
        submitter_burst_req.opt.dst.cache          = submitter_current_descriptor_q.flags[15:12];
            // AXI4 does not support locked transactions, use atomics
        submitter_burst_req.opt.dst.lock           = '0;
            // unpriviledged, secure, data access
        submitter_burst_req.opt.dst.prot           = '0;
            // not participating in qos
        submitter_burst_req.opt.dst.qos            = '0;
            // only one region in system
        submitter_burst_req.opt.dst.region         = '0;
            // ensure coupled AW to avoid deadlocks
        submitter_burst_req.opt.beo.decouple_aw    = '0;
        submitter_burst_req.opt.beo.decouple_rw    = submitter_current_descriptor_q.flags[5];
            // this frontend currently only supports completely debursting
        submitter_burst_req.opt.beo.src_max_llen   = '0;
            // this frontend currently only supports completely debursting
        submitter_burst_req.opt.beo.dst_max_llen   = '0;
        submitter_burst_req.opt.beo.src_reduce_len = submitter_current_descriptor_q.flags[7];
        submitter_burst_req.opt.beo.dst_reduce_len = submitter_current_descriptor_q.flags[7];
            // serialization no longer supported
        // submitter_burst_req.serialize   = submitter_current_descriptor_q.flags[6];
    end

    always_comb begin : submitter_fsm
        submitter_d                    = submitter_q;
        submitter_current_addr_d       = submitter_current_addr_q;
        submitter_current_descriptor_d = submitter_current_descriptor_q;
        submitter_burst_valid_d        = submitter_burst_valid_q;
        submitter_pending_fifo_valid_d = submitter_pending_fifo_valid_q;
        submitter_fetch_counter_d      = submitter_fetch_counter_q;

        unique case (submitter_q)
            SubmitterIdle: begin
                if (submitter_input_fifo_valid) begin
                    submitter_current_addr_d  = desc_addr_from_input_fifo_data;

                    submitter_d               = SubmitterSendAR;
                    submitter_fetch_counter_d = '0;
                end
            end
            SubmitterSendAR: begin
                if (master_rsp_i.ar_ready) begin
                    submitter_d = SubmitterWaitForData;
                end
            end
            SubmitterWaitForData: begin
                if (master_rsp_i.r_valid) begin
                    if (DataWidth == 64) begin : gen_wait_for_data_64
                        submitter_fetch_counter_d = submitter_fetch_counter_q + 2'b01;
                        unique case (submitter_fetch_counter_q)
                            2'b00: begin
                                submitter_current_descriptor_d.length    = master_rsp_i.r.data[31:0];
                                submitter_current_descriptor_d.flags     = master_rsp_i.r.data[63:32];
                            end
                            2'b01: begin
                                submitter_current_descriptor_d.next      = master_rsp_i.r.data;
                            end
                            2'b10: begin
                                submitter_current_descriptor_d.src_addr  = master_rsp_i.r.data;
                            end
                            2'b11: begin
                                submitter_current_descriptor_d.dest_addr = master_rsp_i.r.data;
                                submitter_fetch_counter_d                = 2'b00;
                                submitter_d                              = SubmitterSendToBE;
                                submitter_burst_valid_d                  = 1'b1;
                                submitter_pending_fifo_valid_d           = 1'b1;
                            end
                            default: begin
                                submitter_d                    = submitter_e'('X);
                                submitter_current_addr_d       = 'X;
                                submitter_current_descriptor_d = 'X;
                                submitter_burst_valid_d        = 'X;
                                submitter_pending_fifo_valid_d = 'X;
                                submitter_fetch_counter_d      = 'X;
                            end
                        endcase
                    end else if (DataWidth == 128) begin : gen_wait_for_data_128
                        submitter_fetch_counter_d = 1'b1;
                        unique case (submitter_fetch_counter_q)
                            1'b0: begin
                                submitter_current_descriptor_d.length    = master_rsp_i.r.data[31:0];
                                submitter_current_descriptor_d.flags     = master_rsp_i.r.data[63:32];
                                submitter_current_descriptor_d.next      = master_rsp_i.r.data[127:64];
                            end
                            1'b1: begin
                                submitter_current_descriptor_d.src_addr  = master_rsp_i.r.data[63:0];
                                submitter_current_descriptor_d.dest_addr = master_rsp_i.r.data[127:64];
                                submitter_fetch_counter_d                = 1'b0;
                                submitter_d                              = SubmitterSendToBE;
                                submitter_burst_valid_d                  = 1'b1;
                                submitter_pending_fifo_valid_d           = 1'b1;
                            end
                            default: begin
                                submitter_d                    = submitter_e'('X);
                                submitter_current_addr_d       = 'X;
                                submitter_current_descriptor_d = 'X;
                                submitter_burst_valid_d        = 'X;
                                submitter_pending_fifo_valid_d = 'X;
                                submitter_fetch_counter_d      = 'X;
                            end
                        endcase
                    end else if (DataWidth == 256) begin : gen_wait_for_data_256
                        submitter_current_descriptor_d.length    = master_rsp_i.r.data[31:0];
                        submitter_current_descriptor_d.flags     = master_rsp_i.r.data[63:32];
                        submitter_current_descriptor_d.next      = master_rsp_i.r.data[127:64];
                        submitter_current_descriptor_d.src_addr  = master_rsp_i.r.data[191:128];
                        submitter_current_descriptor_d.dest_addr = master_rsp_i.r.data[255:192];
                        submitter_d                              = SubmitterSendToBE;
                        submitter_burst_valid_d                  = 1'b1;
                        submitter_pending_fifo_valid_d           = 1'b1;
                    end
                end
            end
            SubmitterSendToBE: begin
                // Unset valid once the ready signal came. We can't use !ready,
                // as we might be waiting on the other signal, while the
                // first ready goes low again, marking our signal erroniously as valid.
                if (pending_descriptor_to_fifo_ready) submitter_pending_fifo_valid_d = 1'b0;
                if (dma_be_req_ready_i)               submitter_burst_valid_d        = 1'b0;

                if ((submitter_burst_valid_q        == 1'b0 || dma_be_req_ready_i               == 1'b1) &&
                    (submitter_pending_fifo_valid_q == 1'b0 || pending_descriptor_to_fifo_ready == 1'b1)) begin

                    submitter_current_descriptor_d = '0;

                    if (submitter_current_descriptor_q.next == AddressSentinel) begin
                        submitter_d               = SubmitterIdle;
                    end else begin
                        submitter_d               = SubmitterSendAR;
                        submitter_current_addr_d  = submitter_current_descriptor_q.next;
                    end
                end
            end
            default: begin
                submitter_d                    = submitter_e'('X);
                submitter_current_addr_d       = 'X;
                submitter_current_descriptor_d = 'X;
                submitter_burst_valid_d        = 'X;
                submitter_pending_fifo_valid_d = 'X;
                submitter_fetch_counter_d      = 'X;
            end
        endcase
    end : submitter_fsm

    // When we get the last data item of the descriptor, it must be the last in the burst
    // pragma translate_off
    if (DataWidth == 64) begin : gen_assert_last_64
        assert property (@(posedge clk_i) submitter_q == SubmitterWaitForData
            && submitter_fetch_counter_q == 2'b11
            && master_rsp_i.r_valid |-> master_rsp_i.r.last);
    end else if (DataWidth == 128) begin : gen_assert_last_128
        assert property (@(posedge clk_i) submitter_q == SubmitterWaitForData
            && submitter_fetch_counter_q == 1'b1
            && master_rsp_i.r_valid |-> master_rsp_i.r.last);
    end else if (DataWidth == 256) begin : gen_assert_last_256
        assert property (@(posedge clk_i) submitter_q == SubmitterWaitForData
            && master_rsp_i.r_valid |-> master_rsp_i.r.last);
    end
    // pragma translate_on
    // }}} submitter FSM

    // {{{ feedback FSM
    assign pending_descriptor_from_fifo_ready = feedback_fsm_q == FeedbackIdle;
    assign dma_be_rsp_ready                   = feedback_fsm_q == FeedbackWaitingOnBackend;
    assign master_req.aw_valid                = feedback_fsm_q == FeedbackSendAW;
    assign master_req.w_valid                 = feedback_fsm_q == FeedbackSendData;
    // ignore the b channel, we have no error reporting atm
    assign master_req.b_ready                 = 1'b1;

    always_comb begin : proc_feedback_axi_aw
        master_req.aw                         = '0;
        master_req.aw.id                      = axi_w_id_i;
        master_req.aw.addr                    = feedback_addr_irq_q;
        master_req.aw.size                    = 3'b011;
    end

    always_comb begin : proc_feedback_axi_w
        master_req.w                          = '0;
        master_req.w.data                     = 'X;
        master_req.w.data[63:0]               = 64'hffff_ffff_ffff_ffff;
        master_req.w.strb                     = 'hff;
        master_req.w.last                     = 1'b1;
    end

    always_comb begin : feedback_fsm
        feedback_fsm_d                      = feedback_fsm_q;
        feedback_addr_irq_d                 = feedback_addr_irq_q;
        feedback_irq_d                      = 1'b0;

        unique case (feedback_fsm_q)
            FeedbackIdle: begin
                if (pending_descriptor_from_fifo_valid) begin
                    feedback_addr_irq_d = pending_descriptor_from_fifo_data;
                    feedback_fsm_d      = FeedbackWaitingOnBackend;
                end
            end
            FeedbackWaitingOnBackend: begin
                if (dma_be_rsp_valid_i) begin
                    feedback_fsm_d = FeedbackSendAW;
                end
            end
            FeedbackSendAW: begin
                if (master_rsp_i.aw_ready == 1'b1) begin
                    feedback_fsm_d = FeedbackSendData;
                end
            end
            FeedbackSendData: begin
                if (master_rsp_i.w_ready == 1'b1) begin
                    feedback_fsm_d = FeedbackIdle;
                    feedback_irq_d = feedback_addr_irq_q.do_irq;
                end
            end
            default: begin
                feedback_fsm_d                      = feedback_fsm_e'('X);
                feedback_addr_irq_d                 = 'X;
                feedback_irq_d                      = 'X;
            end
        endcase
    end : feedback_fsm
    // }}} feedback FSM

    // {{{ status update
    assign register_file_to_reg.status.busy.d  = (submitter_q    != SubmitterIdle ||
                                                  feedback_fsm_q != FeedbackIdle  ||
                                                  !dma_be_idle_i);
    assign register_file_to_reg.status.busy.de = 1'b1;

    // leave a bit of wiggle room for the previous registers to catch up
    assign register_file_to_reg.status.fifo_full.d  = desc_addr_fifo_usage > (InputFifoDepth - 1);
    assign register_file_to_reg.status.fifo_full.de = 1'b1;
    // }}} status update

    // }}} combinatorial processes

    // {{{ instantiated modules

    // {{{ descriptor addr input to fifo
    stream_fifo #(
        .DATA_WIDTH (64)            ,
        .DEPTH      (InputFifoDepth)
    ) i_descriptor_input_fifo (
        .clk_i,
        .rst_ni,
        .flush_i    (1'b0)                           ,
        .testmode_i (1'b0)                           ,
        .usage_o    (desc_addr_fifo_usage)           ,
        // input port
        .data_i     (desc_addr_to_input_fifo_data)   ,
        .valid_i    (desc_addr_to_input_fifo_valid)  ,
        .ready_o    (desc_addr_to_input_fifo_ready)  ,
        // output port
        .data_o     (desc_addr_from_input_fifo_data) ,
        .valid_o    (desc_addr_from_input_fifo_valid),
        .ready_i    (desc_addr_from_input_fifo_ready)
    );
    idma_desc64_reg_wrapper #(
        .reg_req_t (reg_req_t),
        .reg_rsp_t (reg_rsp_t)
    ) i_register_file_controller (
        .clk_i     (clk_i)                                     ,
        .rst_ni    (rst_ni)                                    ,
        .reg_req_i (slave_req_i)                               ,
        .reg_rsp_o (slave_rsp_o)                               ,
        .reg2hw_o  (register_file_to_hw)                       ,
        .hw2reg_i  (register_file_to_reg)                      ,
        .devmode_i (1'b1)                                      ,
        .descriptor_fifo_ready_i(desc_addr_to_input_fifo_ready),
        .descriptor_fifo_valid_o(desc_addr_to_input_fifo_valid)
    );
    // }}} descriptor addr input to fifo

    // {{{ pending descriptor FIFO
    stream_fifo #(
        .T          (addr_irq_t)      ,
        .DEPTH      (PendingFifoDepth)
    ) i_pending_descriptor_fifo (
        .clk_i,
        .rst_ni,
        .flush_i    (1'b0)                              ,
        .testmode_i (1'b0)                              ,
        .usage_o    (/* don't care for now */)          ,
        .data_i     (pending_descriptor_to_fifo_data)   ,
        .valid_i    (pending_descriptor_to_fifo_valid)  ,
        .ready_o    (pending_descriptor_to_fifo_ready)  ,
        .data_o     (pending_descriptor_from_fifo_data) ,
        .valid_o    (pending_descriptor_from_fifo_valid),
        .ready_i    (pending_descriptor_from_fifo_ready)
    );
    // }}} pending descriptor FIFO

    // }}} instantiated modules

    // {{{ state-holding processes

    // {{{ submitter FSM
    // state
    `FF(submitter_q,                    submitter_d,                    SubmitterIdle);
    if (words_per_descriptor > 1) begin: gen_counter_ff_if_needed
        `FF(submitter_fetch_counter_q,  submitter_fetch_counter_d,      '0);
    end

    // data
    `FF(submitter_current_addr_q,       submitter_current_addr_d,       '0);
    `FF(submitter_current_descriptor_q, submitter_current_descriptor_d, '{default: '0});

    // ready-valid signals
    `FF(submitter_burst_valid_q,        submitter_burst_valid_d,        1'b0);
    `FF(submitter_pending_fifo_valid_q, submitter_pending_fifo_valid_d, 1'b0);
    // }}} submitter FSM

    // {{{ feedback FSM
    `FF(feedback_fsm_q,                      feedback_fsm_d,            FeedbackIdle);

    // data
    `FF(feedback_addr_irq_q,                 feedback_addr_irq_d,       '0);
    `FF(feedback_irq_q,                      feedback_irq_d,            '0);

    // }}} feedback FSM

    // }}} state-holding processes

    // {{{ output assignments
    assign dma_be_req_o       = submitter_burst_req;
    assign dma_be_req_valid_o = submitter_burst_valid_q;
    assign irq_o              = feedback_irq_q;
    assign master_req_o       = master_req;
    assign dma_be_rsp_ready_o = dma_be_rsp_ready;
    // }}} output assignments

endmodule : idma_desc64_top

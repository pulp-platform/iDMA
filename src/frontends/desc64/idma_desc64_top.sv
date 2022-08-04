// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Axel Vanoni <axvanoni@student.ethz.ch>

`include "common_cells/registers.svh"

/// This module serves as a descriptor-based frontend for the iDMA in the CVA6-core
module idma_desc64_top #(
    /// Width of the addresses
    parameter int unsigned AddrWidth              = 64   ,
    /// burst request type. See the documentation of the idma backend for details
    parameter type         burst_req_t            = logic,
    /// regbus interface types. Use the REG_BUS_TYPEDEF macros to define the types
    /// or see the idma backend documentation for more details
    parameter type         reg_rsp_t              = logic,
    parameter type         reg_req_t              = logic,
    /// Specifies the depth of the fifo behind the descriptor address register
    parameter int unsigned InputFifoDepth       = 8,
    /// Specifies the buffer size of the fifo that tracks requests submitted to the backend
    parameter int unsigned PendingFifoDepth     = 8,
    /// Specifies the counter width of the buffer that tracks completions delivered by the backend
    parameter int unsigned TxDoneBufferWidth   = 5
)(
    /// clock
    input  logic       clk_i               ,
    /// reset
    input  logic       rst_ni              ,

    /// regbus interface
    /// master pair
    /// master request
    output reg_req_t   master_req_o        ,
    /// master response
    input  reg_rsp_t   master_rsp_i        ,
    /// slave pair
    /// The slave interface exposes two registers: One address register to
    /// write a descriptor address to process and a status register that
    /// exposes whether the DMA is busy on bit 0 and whether FIFOs are full
    /// on bit 1.
    /// master request
    input  reg_req_t   slave_req_i         ,
    /// master response
    output reg_rsp_t   slave_rsp_o         ,

    /// backend interface
    /// burst request submission
    /// burst request data. See iDMA backend documentation for fields
    output burst_req_t dma_be_req_o        ,
    /// valid signal for the backend data submission
    output logic       dma_be_valid_o      ,
    /// ready signal for the backend data submission
    input  logic       dma_be_ready_i      ,
    /// status information from the backend
    /// event: when a transfer has completed
    input  logic       dma_be_tx_complete_i,
    /// whether the backend is currently idle
    input  logic       dma_be_idle_i       ,

    /// Event: irq
    output logic       irq_o
);

    import idma_desc64_reg_pkg::*;
    import axi_pkg::BURST_INCR;

    // {{{ typedefs and parameters
    typedef logic [AddrWidth-1:0] addr_t;

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

    typedef struct packed {
        logic  do_irq;
        addr_t descriptor_addr;
    } addr_irq_t;

    localparam addr_t AddressSentinel = ~'0;

    typedef enum logic [1:0] {
        SubmitterIdle = '0,
        SubmitterFetchDescriptor,
        SubmitterSendToBE
    } submitter_e;

    typedef enum logic [1:0] {
        FeedbackIdle,
        FeedbackWaitingOnBackend,
        FeedbackUpdateMemory,
        FeedbackRaiseIRQ
    } feedback_fsm_e;

    // }}} typedefs and parameters

    // {{{ signal declarations

    // {{{ descriptor addr input to fifo
    idma_desc64_reg2hw_t register_file_to_hw;
    idma_desc64_hw2reg_t register_file_to_reg;

    addr_t                desc_addr_to_input_fifo_data;
    logic                 desc_addr_to_input_fifo_valid;
    logic                 desc_addr_to_input_fifo_ready;

    addr_t                desc_addr_from_input_fifo_data;
    logic                 desc_addr_from_input_fifo_valid;
    logic                 desc_addr_from_input_fifo_ready;

    logic [2:0]           desc_addr_fifo_usage;
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
    logic [1:0]  submitter_fetch_counter_q,      submitter_fetch_counter_d;
    // data
    addr_t       submitter_current_addr_q,       submitter_current_addr_d;
    descriptor_t submitter_current_descriptor_q, submitter_current_descriptor_d;
    burst_req_t  submitter_burst_req;
    // register_interface master
    reg_req_t    submitter_master_req;
    reg_rsp_t    submitter_master_rsp;
    // ready-valid signals
    logic        submitter_input_fifo_ready;
    logic        submitter_input_fifo_valid;
    logic        submitter_burst_valid_q,        submitter_burst_valid_d;
    logic        submitter_pending_fifo_valid_q, submitter_pending_fifo_valid_d;
    // }}} submitter FSM

    // {{{ instantiated modules
    logic completion_counter_decrement;
    logic completion_counter_has_items;
    // }}} instantiated modules

    // {{{ feedback FSM
    // state
    feedback_fsm_e feedback_fsm_q,                      feedback_fsm_d;
    // data
    addr_irq_t     feedback_addr_irq_q,                 feedback_addr_irq_d;
    logic          feedback_irq_q,                      feedback_irq_d;
    // register_interface master
    reg_req_t      feedback_master_req_q,               feedback_master_req_d;
    reg_rsp_t      feedback_master_rsp;
    // ready-valid signals
    logic          feedback_pending_descriptor_ready_q, feedback_pending_descriptor_ready_d;
    logic          feedback_counter_ready_q,            feedback_counter_ready_d;
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
    assign submitter_master_req.addr                       = submitter_current_addr_q + (submitter_fetch_counter_q << 3);
    assign submitter_master_req.write                      = '0;
    assign submitter_master_req.wdata                      = '0;
    assign submitter_master_req.wstrb                      = '0;
    assign submitter_master_req.valid                      = submitter_q == SubmitterFetchDescriptor;

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

                    submitter_d               = SubmitterFetchDescriptor;
                    submitter_fetch_counter_d = '0;
                end
            end
            SubmitterFetchDescriptor: begin
                if (submitter_master_rsp.ready) begin
                    submitter_fetch_counter_d = submitter_fetch_counter_q + 1;
                    unique case (submitter_fetch_counter_q)
                        2'b00: begin
                            submitter_current_descriptor_d.flags     = submitter_master_rsp.rdata[63:32];
                            submitter_current_descriptor_d.length    = submitter_master_rsp.rdata[31:0];
                        end
                        2'b01: begin
                            submitter_current_descriptor_d.next      = submitter_master_rsp.rdata;
                        end
                        2'b10: begin
                            submitter_current_descriptor_d.src_addr  = submitter_master_rsp.rdata;
                        end
                        2'b11: begin
                            submitter_current_descriptor_d.dest_addr = submitter_master_rsp.rdata;
                            submitter_fetch_counter_d                = '0;
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
                end
            end
            SubmitterSendToBE: begin
                // Unset valid once the ready signal came. We can't use !ready,
                // as we might be waiting on the other signal, while the
                // first ready goes low again, marking our signal erroniously as valid.
                if (pending_descriptor_to_fifo_ready) submitter_pending_fifo_valid_d = 1'b0;
                if (dma_be_ready_i)                   submitter_burst_valid_d        = 1'b0;

                if ((submitter_burst_valid_q        == 1'b0 || dma_be_ready_i                   == 1'b1) &&
                    (submitter_pending_fifo_valid_q == 1'b0 || pending_descriptor_to_fifo_ready == 1'b1)) begin

                    submitter_current_descriptor_d = '0;

                    if (submitter_current_descriptor_q.next == AddressSentinel) begin
                        submitter_d               = SubmitterIdle;
                    end else begin
                        submitter_d               = SubmitterFetchDescriptor;
                        submitter_current_addr_d  = submitter_current_descriptor_q.next;
                        submitter_fetch_counter_d = '0;
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
    // }}} submitter FSM

    // {{{ feedback FSM
    assign pending_descriptor_from_fifo_ready = feedback_pending_descriptor_ready_q;
    assign completion_counter_decrement       = feedback_counter_ready_q;

    always_comb begin : feedback_fsm
        feedback_fsm_d                      = feedback_fsm_q;
        feedback_addr_irq_d                 = feedback_addr_irq_q;
        feedback_master_req_d               = feedback_master_req_q;
        feedback_irq_d                      = '0;
        feedback_pending_descriptor_ready_d = '0;
        feedback_counter_ready_d            = '0;

        unique case (feedback_fsm_q)
            FeedbackIdle: begin
                feedback_pending_descriptor_ready_d = 1'b1;
                if (pending_descriptor_from_fifo_valid) begin
                    feedback_addr_irq_d = pending_descriptor_from_fifo_data;

                    feedback_fsm_d = FeedbackWaitingOnBackend;
                end
            end
            FeedbackWaitingOnBackend: begin
                if (completion_counter_has_items) begin
                    feedback_counter_ready_d = 1'b1;
                    feedback_fsm_d = FeedbackUpdateMemory;
                end
            end
            FeedbackUpdateMemory: begin
                if (feedback_master_req_q.valid == '0) begin
                    // overwrite the flags and length fields with all 1s
                    // to mark it as completed
                    feedback_master_req_d.addr  = feedback_addr_irq_q.descriptor_addr;
                    feedback_master_req_d.write = 1'b1;
                    feedback_master_req_d.wdata = ~'0;
                    feedback_master_req_d.wstrb = ~'0;
                    feedback_master_req_d.valid = 1'b1;
                end else if (feedback_master_rsp.ready == 1'b1) begin
                    feedback_master_req_d.write = '0;
                    feedback_master_req_d.valid = '0;
                    if (feedback_addr_irq_q.do_irq) begin
                        feedback_fsm_d = FeedbackRaiseIRQ;
                    end else begin
                        feedback_fsm_d = FeedbackIdle;
                    end
                end
            end
            FeedbackRaiseIRQ: begin
                feedback_irq_d = 1'b1;
                feedback_fsm_d = FeedbackIdle;
            end
            default: begin
                feedback_fsm_d                      = feedback_fsm_e'('X);
                feedback_addr_irq_d                 = 'X;
                feedback_master_req_d               = 'X;
                feedback_irq_d                      = 'X;
                feedback_pending_descriptor_ready_d = 'X;
                feedback_counter_ready_d            = 'X;
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
    assign register_file_to_reg.status.fifo_full.d  = desc_addr_fifo_usage > 6;
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

    // {{{ counter module
    idma_desc64_shared_counter #(
        .CounterWidth(TxDoneBufferWidth)
    ) i_completion_counter (
        .clk_i              (clk_i)                       ,
        .rst_ni             (rst_ni)                      ,
        .increment_i        (dma_be_tx_complete_i)        ,
        .decrement_i        (completion_counter_decrement),
        .greater_than_zero_o(completion_counter_has_items)
    );
    // }}} counter module

    // {{{ regbus master arbitration
    reg_mux #(
        .NoPorts  (2)        ,
        .AW       (AddrWidth),
        .DW       (AddrWidth),
        .req_t    (reg_req_t),
        .rsp_t    (reg_rsp_t)
    ) i_master_arbitration (
        .clk_i    (clk_i)                                        ,
        .rst_ni   (rst_ni)                                       ,
        .in_req_i ({submitter_master_req, feedback_master_req_q}),
        .in_rsp_o ({submitter_master_rsp, feedback_master_rsp})  ,
        .out_req_o(master_req_o)                                 ,
        .out_rsp_i(master_rsp_i)
    );
    // }}} regbus master arbitration

    // }}} instantiated modules

    // {{{ state-holding processes

    // {{{ submitter FSM
    // state
    `FF(submitter_q,                    submitter_d,                    SubmitterIdle);
    `FF(submitter_fetch_counter_q,      submitter_fetch_counter_d,      '0);

    // data
    `FF(submitter_current_addr_q,       submitter_current_addr_d,       '0);
    `FF(submitter_current_descriptor_q, submitter_current_descriptor_d, '{default: '0});

    // ready-valid signals
    `FF(submitter_burst_valid_q,        submitter_burst_valid_d,        '0);
    `FF(submitter_pending_fifo_valid_q, submitter_pending_fifo_valid_d, '0);
    // }}} submitter FSM

    // {{{ feedback FSM
    `FF(feedback_fsm_q,                      feedback_fsm_d,                      FeedbackIdle);

    // data
    `FF(feedback_addr_irq_q,                 feedback_addr_irq_d,                 '0);
    `FF(feedback_irq_q,                      feedback_irq_d,                      '0);

    // register_interface master request
    `FF(feedback_master_req_q,               feedback_master_req_d,               '{default: '0});

    // ready-valid signals
    `FF(feedback_pending_descriptor_ready_q, feedback_pending_descriptor_ready_d, '0);
    `FF(feedback_counter_ready_q,            feedback_counter_ready_d,            '0);
    // }}} feedback FSM

    // }}} state-holding processes

    // {{{ output assignments
    assign dma_be_req_o   = submitter_burst_req;
    assign dma_be_valid_o = submitter_burst_valid_q;
    assign irq_o          = feedback_irq_q;
    // }}} output assignments

endmodule : idma_desc64_top

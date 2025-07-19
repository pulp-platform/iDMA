// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Axel Vanoni <axvanoni@ethz.ch>

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
    /// regbus interface types. Use the APB_TYPEDEF macros to define the types
    /// or see the idma backend documentation for more details
    parameter type         apb_rsp_t              = logic,
    parameter type         apb_req_t              = logic,
    /// AXI interface types used for fetching descriptors.
    /// Use the AXI_TYPEDEF_ALL macros to define the types
    parameter type         axi_rsp_t              = logic,
    parameter type         axi_req_t              = logic,
    parameter type         axi_ar_chan_t          = logic,
    parameter type         axi_r_chan_t           = logic,
    /// Specifies the depth of the fifo behind the descriptor address register
    parameter int unsigned InputFifoDepth         =     8,
    /// Specifies the buffer size of the fifo that tracks requests submitted to the backend
    parameter int unsigned PendingFifoDepth       =     8,
    /// How many requests the backend might have at the same time in its buffers.
    /// Usually, `NumAxInFlight + BufferDepth`
    parameter int unsigned BackendDepth           =     0,
    /// Specifies how many descriptors may be fetched speculatively
    parameter int unsigned NSpeculation           =     4
)(
    /// clock
    input  logic                  clk_i             ,
    /// reset
    input  logic                  rst_ni            ,

    /// axi interface used for fetching descriptors
    /// master pair
    /// master request
    output axi_req_t              master_req_o      ,
    /// master response
    input  axi_rsp_t              master_rsp_i      ,
    /// ID to be used by the read channel
    input  logic [AxiIdWidth-1:0] axi_ar_id_i        ,
    /// ID to be used by the write channel
    input  logic [AxiIdWidth-1:0] axi_aw_id_i        ,
    /// regbus interface
    /// slave pair
    /// The slave interface exposes two registers: One address register to
    /// write a descriptor address to process and a status register that
    /// exposes whether the DMA is busy on bit 0 and whether FIFOs are full
    /// on bit 1.
    /// master request
    input  apb_req_t              slave_req_i       ,
    /// master response
    output apb_rsp_t              slave_rsp_o       ,

    /// backend interface
    /// burst request submission
    /// burst request data. See iDMA backend documentation for fields
    output idma_req_t             idma_req_o      ,
    /// valid signal for the backend data submission
    output logic                  idma_req_valid_o,
    /// ready signal for the backend data submission
    input  logic                  idma_req_ready_i,
    /// status information from the backend
    input  idma_rsp_t             idma_rsp_i      ,
    /// valid signal for the backend response
    input  logic                  idma_rsp_valid_i,
    /// ready signal for the backend response
    output logic                  idma_rsp_ready_o,
    /// whether the backend is currently busy
    input  logic                  idma_busy_i     ,

    /// Event: irq
    output logic                  irq_o
);

/// Specifies how many unsent AWs/Ws are allowed
localparam int unsigned MaxAWWPending = BackendDepth;

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

idma_req_t idma_req;
logic      idma_req_valid;
logic      idma_req_ready;
logic      idma_req_inflight;
logic      gated_r_valid, gated_r_ready;

logic do_irq;
logic do_irq_valid;
logic do_irq_ready;

addr_t      queued_addr;
logic       queued_addr_valid;
logic       queued_addr_ready;
addr_t      next_addr_from_desc;
logic       next_addr_from_desc_valid;
logic       ar_busy;
addr_t      feedback_addr;
logic       feedback_addr_valid;
logic       feedback_addr_ready;
addr_t      next_wb_addr;
logic       next_wb_addr_valid;
logic       next_wb_addr_ready;

`define MAX(a, b) (a) > (b) ? a : b

localparam int unsigned PendingFifoDepthBits = `MAX($clog2(PendingFifoDepth), 1);

logic [PendingFifoDepthBits-1:0] idma_req_used;
logic [PendingFifoDepthBits:0]   idma_req_available;

logic [1:0]                        ws_per_writeback;
// one bit extra for the 32 bit case
logic [$clog2(MaxAWWPending):0] w_counter_q, w_counter_d;
logic                           aw_tx;
logic                           w_tx;

addr_t input_addr;
logic  input_addr_valid, input_addr_ready;

logic do_irq_out;

idma_desc64_reg_pkg::idma_desc64_reg__out_t reg2hw;
idma_desc64_reg_pkg::idma_desc64_reg__in_t  hw2reg;

addr_t aw_addr;

always_comb begin : proc_available
    idma_req_available = PendingFifoDepth - idma_req_used - idma_req_inflight;
    if (idma_req_used == '0) begin
        if (idma_req_ready) begin
            idma_req_available = PendingFifoDepth - idma_req_inflight;
        end else begin
            idma_req_available = '0;
        end
    end else if (idma_req_used == PendingFifoDepth && idma_req_inflight) begin
        idma_req_available = '0;
    end
end

always_comb begin : proc_aw
    master_req_o.aw      = '0;
    master_req_o.aw.id   = axi_aw_id_i;
    master_req_o.aw.addr = aw_addr;
    master_req_o.aw.size = (DataWidth == 32) ? 3'b010 : 3'b011;
    master_req_o.aw.len  = (DataWidth == 32) ? 'b1 : 'b0;
end

assign master_req_o.w_valid = w_counter_q > 0;
assign aw_tx = master_req_o.aw_valid && master_rsp_i.aw_ready;
assign w_tx = master_req_o.w_valid && master_rsp_i.w_ready;

always_comb begin : proc_w_counter
    w_counter_d = w_counter_q;
    if (aw_tx && w_tx) begin
        w_counter_d = w_counter_q + ws_per_writeback - 'b1;
    end else if (aw_tx) begin
        w_counter_d = w_counter_q + ws_per_writeback;
    end else if (w_tx) begin
        w_counter_d = w_counter_q - 'b1;
    end
end

if (DataWidth == 32) begin : gen_aw_w_chan_32
    logic w_is_last_q, w_is_last_d;
    assign ws_per_writeback = 2'd2;
    // writeback is 64 bits, so toggle last after sending one word
    always_comb begin : proc_is_last
        w_is_last_d = w_is_last_q;
        if (master_req_o.w_valid && master_rsp_i.w_ready) begin
            w_is_last_d = !w_is_last_q;
        end
    end

    always_comb begin : proc_w
        master_req_o.w       = '0;
        master_req_o.w.data  = '1;
        master_req_o.w.strb  = 4'hf;
        master_req_o.w.last  = w_is_last_q;
    end
    `FF(w_is_last_q, w_is_last_d, 1'b0)
end else begin : gen_aw_w_chan
    assign ws_per_writeback = 2'd1;
    always_comb begin : proc_w
        master_req_o.w            = '0;
        master_req_o.w.data       = '0;
        master_req_o.w.data[63:0] = 64'hffff_ffff_ffff_ffff;
        master_req_o.w.strb       = 'hff;
        master_req_o.w.last       = 1'b1;
    end
end

assign hw2reg.status.busy.next      = queued_addr_valid     ||
                                      next_wb_addr_valid    ||
                                      idma_req_valid_o      ||
                                      master_req_o.b_ready  ||
                                      master_req_o.aw_valid ||
                                      w_counter_q > 0       ||
                                      idma_busy_i           ||
                                      ar_busy;

assign hw2reg.status.fifo_full.next = !input_addr_ready;

assign input_addr = reg2hw.desc_addr.desc_addr.value;

idma_desc64_reg_wrapper #(
    .apb_req_t(apb_req_t),
    .apb_rsp_t(apb_rsp_t)
) i_reg_wrapper (
    .clk_i,
    .rst_ni,
    .apb_req_i          (slave_req_i),
    .apb_rsp_o          (slave_rsp_o),
    .reg2hw_o           (reg2hw),
    .hw2reg_i           (hw2reg),
    .devmode_i          (1'b0),
    .input_addr_valid_o (input_addr_valid),
    .input_addr_ready_i (input_addr_ready)
);

if (NSpeculation == 0) begin : gen_no_spec

assign master_req_o.r_ready = gated_r_ready;
assign gated_r_valid = master_rsp_i.r_valid;
idma_desc64_ar_gen #(
    .DataWidth    (DataWidth),
    .descriptor_t (descriptor_t),
    .axi_ar_chan_t(axi_ar_chan_t),
    .axi_id_t     (logic [AxiIdWidth-1:0]),
    .usage_t      (logic [$bits(idma_req_available)-1:0]),
    .addr_t       (addr_t)
) i_ar_gen (
    .clk_i,
    .rst_ni,
    .axi_ar_chan_o                       (master_req_o.ar),
    .axi_ar_chan_valid_o                 (master_req_o.ar_valid),
    .axi_ar_chan_ready_i                 (master_rsp_i.ar_ready),
    .axi_ar_id_i,
    .queued_address_i                    (queued_addr),
    .queued_address_valid_i              (queued_addr_valid),
    .queued_address_ready_o              (queued_addr_ready),
    .next_address_from_descriptor_i      (next_addr_from_desc),
    .next_address_from_descriptor_valid_i(next_addr_from_desc_valid),
    .idma_req_available_slots_i          (idma_req_available),
    .feedback_addr_o                     (feedback_addr),
    .feedback_addr_valid_o               (feedback_addr_valid),
    .busy_o                              (ar_busy)
);
end else begin : gen_spec

typedef logic [$clog2(NSpeculation + 1)-1:0] flush_t;

flush_t n_requests_to_flush;
logic   n_requests_to_flush_valid;


idma_desc64_ar_gen_prefetch #(
    .DataWidth    (DataWidth),
    .NSpeculation (NSpeculation),
    .descriptor_t (descriptor_t),
    .axi_ar_chan_t(axi_ar_chan_t),
    .axi_id_t     (logic [AxiIdWidth-1:0]),
    .usage_t      (logic [$bits(idma_req_available)-1:0]),
    .addr_t       (addr_t),
    .flush_t      (flush_t)
) i_ar_gen (
    .clk_i,
    .rst_ni,
    .axi_ar_chan_o                       (master_req_o.ar),
    .axi_ar_chan_valid_o                 (master_req_o.ar_valid),
    .axi_ar_chan_ready_i                 (master_rsp_i.ar_ready),
    .axi_ar_id_i,
    .queued_address_i                    (queued_addr),
    .queued_address_valid_i              (queued_addr_valid),
    .queued_address_ready_o              (queued_addr_ready),
    .next_address_from_descriptor_i      (next_addr_from_desc),
    .next_address_from_descriptor_valid_i(next_addr_from_desc_valid),
    .idma_req_available_slots_i          (idma_req_available),
    .n_requests_to_flush_o               (n_requests_to_flush),
    .n_requests_to_flush_valid_o         (n_requests_to_flush_valid),
    .feedback_addr_o                     (feedback_addr),
    .feedback_addr_valid_o               (feedback_addr_valid),
    .busy_o                              (ar_busy)
);

idma_desc64_reader_gater #(
    .flush_t(flush_t)
) i_reader_gater (
    .clk_i,
    .rst_ni,
    .n_to_flush_i      (n_requests_to_flush),
    .n_to_flush_valid_i(n_requests_to_flush_valid),
    .r_valid_i         (master_rsp_i.r_valid),
    .r_ready_o         (master_req_o.r_ready),
    .r_valid_o         (gated_r_valid),
    .r_ready_i         (gated_r_ready),
    .r_last_i          (master_rsp_i.r.last)
);


end

idma_desc64_reader #(
    .AddrWidth   (AddrWidth),
    .DataWidth   (DataWidth),
    .idma_req_t  (idma_req_t),
    .descriptor_t(descriptor_t),
    .axi_r_chan_t(axi_r_chan_t)
) i_reader (
    .clk_i,
    .rst_ni,
    .r_chan_i                    (master_rsp_i.r),
    .r_chan_valid_i              (gated_r_valid),
    .r_chan_ready_o              (gated_r_ready),
    .idma_req_o                  (idma_req),
    .idma_req_valid_o            (idma_req_valid),
    .idma_req_ready_i            (idma_req_ready),
    .next_descriptor_addr_o      (next_addr_from_desc),
    .next_descriptor_addr_valid_o(next_addr_from_desc_valid),
    .do_irq_o                    (do_irq),
    .do_irq_valid_o              (do_irq_valid),
    .idma_req_inflight_o         (idma_req_inflight)
);

stream_fifo #(
    .FALL_THROUGH (1'b1),
    .DEPTH        (InputFifoDepth),
    .T            (addr_t)
) i_input_addr_fifo (
    .clk_i,
    .rst_ni,
    .flush_i   (1'b0),
    .testmode_i(1'b0),
    .usage_o   (/* unconnected */),
    .data_i    (input_addr),
    .valid_i   (input_addr_valid),
    .ready_o   (input_addr_ready),
    .data_o    (queued_addr),
    .valid_o   (queued_addr_valid),
    .ready_i   (queued_addr_ready)
);

stream_fifo #(
    .FALL_THROUGH (1'b1),
    .DEPTH        (PendingFifoDepth + BackendDepth),
    .T            (addr_t)
) i_pending_addr_fifo (
    .clk_i,
    .rst_ni,
    .flush_i   (1'b0),
    .testmode_i(1'b0),
    .usage_o   (/* unconnected */),
    .data_i    (feedback_addr),
    .valid_i   (feedback_addr_valid),
    .ready_o   (feedback_addr_ready),
    .data_o    (next_wb_addr),
    .valid_o   (next_wb_addr_valid),
    .ready_i   (next_wb_addr_ready && idma_rsp_valid_i)
);

stream_fifo #(
    .FALL_THROUGH (1'b0),
    .DEPTH        (PendingFifoDepth),
    .T            (idma_req_t)
) i_idma_request_fifo (
    .clk_i,
    .rst_ni,
    .flush_i   (1'b0),
    .testmode_i(1'b0),
    .usage_o   (idma_req_used),
    .data_i    (idma_req),
    .valid_i   (idma_req_valid),
    .ready_o   (idma_req_ready),
    .data_o    (idma_req_o),
    .valid_o   (idma_req_valid_o),
    .ready_i   (idma_req_ready_i)
);

stream_fifo #(
    .FALL_THROUGH (1'b0),
    .DEPTH        (PendingFifoDepth + MaxAWWPending + BackendDepth),
    .T            (logic)
) i_irq_fifo (
    .clk_i,
    .rst_ni,
    .flush_i   (1'b0),
    .testmode_i(1'b0),
    .usage_o   (/* unconnected */),
    .data_i    (do_irq),
    .valid_i   (do_irq_valid),
    .ready_o   (do_irq_ready),
    .data_o    (do_irq_out),
    .valid_o   (master_req_o.b_ready),
    .ready_i   (master_rsp_i.b_valid)
);

stream_fifo #(
    .FALL_THROUGH (1'b0),
    .DEPTH        (MaxAWWPending),
    .T            (addr_t)
) i_aw_addrs (
    .clk_i,
    .rst_ni,
    .flush_i   (1'b0),
    .testmode_i(1'b0),
    .usage_o   (/* unconnected */),
    .data_i    (next_wb_addr),
    .valid_i   (next_wb_addr_valid && idma_rsp_valid_i),
    .ready_o   (next_wb_addr_ready),
    .data_o    (aw_addr),
    .valid_o   (master_req_o.aw_valid),
    .ready_i   (master_rsp_i.aw_ready)
);

`FF(w_counter_q, w_counter_d, '0);


assign idma_rsp_ready_o = next_wb_addr_ready && next_wb_addr_valid;
assign irq_o            = do_irq_out && master_req_o.b_ready && master_rsp_i.b_valid;

// The three fifos for idma_req, irqs and feedback addresses must fill
// and empty in lockstep. Capacity is tested at the idma_req fifo, the
// other two ready signals are ignored.
// pragma translate_off
`ASSERT_IF(NoIrqDropped, do_irq_ready, do_irq_valid);
`ASSERT_IF(NoAddrDropped, feedback_addr_ready, feedback_addr_valid);
// pragma translate_on

endmodule

// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Michael Rogenmoser <michaero@ethz.ch>

`include "idma/typedef.svh"

/// This is a wrapper for the new backend to emulate the old one
module axi_dma_backend #(
    /// Data width of the AXI bus
    parameter int unsigned DataWidth = -1,
    /// Address width of the AXI bus
    parameter int unsigned AddrWidth = -1,
    /// ID width of the AXI bus
    parameter int unsigned IdWidth = -1,
    /// User width of the AXI bus
    parameter int unsigned UserWidth = -1,
    /// Number of AX beats that can be in-flight
    parameter int unsigned AxReqFifoDepth = -1,
    /// Number of generic 1D requests that can be buffered
    parameter int unsigned TransFifoDepth = -1,
    /// Number of elements the realignment buffer can hold. To achieve
    /// full performance a depth of 3 is minimally required.
    parameter int unsigned BufferDepth = -1,
    /// AXI4+ATOP request struct definition.
    parameter type         axi_req_t = logic,
    /// AXI4+ATOP response struct definition.
    parameter type         axi_res_t = logic,
    /// Arbitrary 1D burst request definition:
    /// - `id`: the AXI id used - this id should be constant, as the DMA does not support reordering
    /// - `src`, `dst`: source and destination address, same width as the AXI 4 channels
    /// - `num_bytes`: the length of the contiguous 1D transfer requested, can be up to 32/64 bit long
    ///              num_bytes will be interpreted as an unsigned number
    ///              A value of 0 will cause the backend to discard the transfer prematurely
    /// - `cache_src`, `cache_dst`: the configuration of the cache fields in the AX beats
    /// - `burst_src`, `burst_dst`: currently only incremental bursts are supported (`2'b01`)
    /// - `decouple_rw`: if set to true, there is no longer exactly one AXI write_request issued for
    ///              every read request. This mode can improve performance of unaligned transfers when
    ///              crossing the AXI page boundaries.
    /// - `deburst`: if set, the DMA will split all bursts in single transfers
    /// - `serialize`: if set, the DMA will only send AX belonging to a given Arbitrary 1D burst request
    ///              at a time. This is default behavior to prevent deadlocks. Setting `serialize` to
    ///              zero violates the AXI4+ATOP specification.
    parameter type         burst_req_t = logic,
    /// Give each DMA backend a unique id
    parameter int unsigned DmaIdWidth = -1,
    /// Enable or disable tracing, not functional here
    parameter bit          DmaTracing = 0
) (
    /// Clock
    input  logic                    clk_i,
    /// Asynchronous reset, active low
    input  logic                    rst_ni,
    /// AXI4+ATOP master request
    output axi_req_t                axi_dma_req_o,
    /// AXI4+ATOP master response
    input  axi_res_t                axi_dma_res_i,
    /// Arbitrary 1D burst request
    input  burst_req_t              burst_req_i,
    /// Handshake: 1D burst request is valid
    input  logic                    valid_i,
    /// Handshake: 1D burst can be accepted
    output logic                    ready_o,
    /// High if the backend is idle
    output logic                    backend_idle_o,
    /// Event: a 1D burst request has completed
    output logic                    trans_complete_o,
    /// unique DMA id
    input  logic [DmaIdWidth-1:0]   dma_id_i
);

    // This wrapper emulates the old (v.0.1.0) backend which is deprecated. Throw a warning here
    // to inform the user in simulation
    // pragma translate_off
    `ifndef VERILATOR
    initial begin : proc_deprecated_warning
        $warning("You are using the deprecated interface of the backend. Please update ASAP!");
    end
    `endif
    // pragma translate_on

    // Parameters unavailable to old backend
    localparam int unsigned TFLenWidth  = AddrWidth;
    localparam int unsigned MemSysDepth = 0;

    // typedefs
    typedef logic [ AddrWidth-1:0] addr_t;
    typedef logic [TFLenWidth-1:0] tf_len_t;
    typedef logic [   IdWidth-1:0] id_t;

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

    // local signals
    idma_req_t              idma_req;
    logic                   idma_rsp_valid;
    idma_pkg::idma_busy_t   idma_busy;

    // busy if at least one of the sub-units is busy
    assign backend_idle_o = ~|idma_busy;

    // assemble the new request from the old
    always_comb begin : proc_idma_req
        idma_req = '0;

        idma_req.length                 = burst_req_i.num_bytes;
        idma_req.src_addr               = burst_req_i.src;
        idma_req.dst_addr               = burst_req_i.dst;

        idma_req.opt.axi_id             = burst_req_i.id;
            // DMA only supports incremental burst
        idma_req.opt.src.burst          = axi_pkg::BURST_INCR; // burst_req_i.burst_src;
        idma_req.opt.src.cache          = burst_req_i.cache_src;
            // AXI4 does not support locked transactions, use atomics
        idma_req.opt.src.lock           = '0;
            // unpriviledged, secure, data access
        idma_req.opt.src.prot           = '0;
            // not participating in qos
        idma_req.opt.src.qos            = '0;
            // only one region
        idma_req.opt.src.region         = '0;
            // DMA only supports incremental burst
        idma_req.opt.dst.burst          = axi_pkg::BURST_INCR; // burst_req_i.burst_dst;
        idma_req.opt.dst.cache          = burst_req_i.cache_dst;
            // AXI4 does not support locked transactions, use atomics
        idma_req.opt.dst.lock           = '0;
            // unpriviledged, secure, data access
        idma_req.opt.dst.prot           = '0;
            // not participating in qos
        idma_req.opt.dst.qos            = '0;
            // only one region in system
        idma_req.opt.dst.region         = '0;
            // ensure coupled AW to avoid deadlocks
        idma_req.opt.beo.decouple_aw    = '0;
        idma_req.opt.beo.decouple_rw    = burst_req_i.decouple_rw;
            // this compatibility layer only supports completely debursting
        idma_req.opt.beo.src_max_llen   = '0;
            // this compatibility layer only supports completely debursting
        idma_req.opt.beo.dst_max_llen   = '0;
        idma_req.opt.beo.src_reduce_len = burst_req_i.deburst;
        idma_req.opt.beo.dst_reduce_len = burst_req_i.deburst;
    end

    idma_backend #(
        .DataWidth           ( DataWidth                   ),
        .AddrWidth           ( AddrWidth                   ),
        .UserWidth           ( UserWidth                   ),
        .AxiIdWidth          ( IdWidth                     ),
        .NumAxInFlight       ( AxReqFifoDepth              ),
        .BufferDepth         ( BufferDepth                 ),
        .TFLenWidth          ( TFLenWidth                  ),
        .RAWCouplingAvail    ( 1                           ),
        .MaskInvalidData     ( 1                           ),
        .HardwareLegalizer   ( 1                           ),
        .RejectZeroTransfers ( 1                           ),
        .MemSysDepth         ( MemSysDepth                 ),
        .ErrorCap            ( idma_pkg::NO_ERROR_HANDLING ),
        .idma_req_t          ( idma_req_t                  ),
        .idma_rsp_t          ( idma_rsp_t                  ),
        .idma_eh_req_t       ( idma_pkg::idma_eh_req_t     ),
        .idma_busy_t         ( idma_pkg::idma_busy_t       ),
        .axi_req_t           ( axi_req_t                   ),
        .axi_rsp_t           ( axi_res_t                   )
    ) i_idma_backend (
        .clk_i,
        .rst_ni,
        .testmode_i     ( 1'b0                ),

        .idma_req_i     ( idma_req            ),
        .req_valid_i    ( valid_i             ),
        .req_ready_o    ( ready_o             ),

        .idma_rsp_o     ( /* NOT CONNECTED */ ),
        .rsp_valid_o    ( idma_rsp_valid      ), // valid_o signals a completed transfer
        .rsp_ready_i    ( 1'b1                ), // always ready for complete transfers

        .idma_eh_req_i  ( '0                  ), // No error handling hardware is present
        .eh_req_valid_i ( 1'b1                ),
        .eh_req_ready_o ( /* NOT CONNECTED */ ),

        .axi_req_o      ( axi_dma_req_o       ),
        .axi_rsp_i      ( axi_dma_res_i       ),
        .busy_o         ( idma_busy           )
    );

    // transfer is completed if response is valid (there is no error handling)
    assign trans_complete_o = idma_rsp_valid;

endmodule : axi_dma_backend

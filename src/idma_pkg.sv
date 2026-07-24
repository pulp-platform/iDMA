// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz  <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

/// iDMA Package
/// Contains all static type definitions
package idma_pkg;

    /// Error Handling Capabilities
    /// - `NO_ERROR_HANDLING`: No error handling hardware is present
    /// - `ERROR_HANDLING`: Error handling hardware is present
    typedef enum logic [0:0] {
        NO_ERROR_HANDLING,
        ERROR_HANDLING
    } error_cap_e;

    /// Error Handling Type
    typedef logic [0:0] idma_eh_req_t;

    /// Error Handling Action
    /// - `CONTINUE`: The current 1D transfer will just be continued
    /// - `ABORT`: The current 1D transfer will be aborted
    typedef enum logic [0:0] {
        CONTINUE,
        ABORT
    } eh_action_e;

    /// Error Type type
    typedef logic [1:0] err_type_t;

    /// Error Type
    /// - `BUS_READ`: Error happened during a manager bus read
    /// - `BUS_WRITE`: Error happened during a manager bus write
    /// - `BACKEND`: Internal error to the backend; currently only transfer length == 0
    /// - `ND_MIDEND`: Internal error to the nd-midend; currently all number of repetitions are
    ///                zero
    typedef enum logic [1:0] {
        BUS_READ,
        BUS_WRITE,
        BACKEND,
        ND_MIDEND
    } err_type_e;

    /// iDMA busy type: contains the busy fields of the various sub units
    typedef struct packed {
        logic buffer_busy;
        logic r_dp_busy;
        logic w_dp_busy;
        logic r_leg_busy;
        logic w_leg_busy;
        logic eh_fsm_busy;
        logic eh_cnt_busy;
        logic raw_coupler_busy;
    } idma_busy_t;

    /// AXI4 option type: contains the AXI4 options fields
    typedef struct packed {
        axi_pkg::burst_t  burst;
        axi_pkg::cache_t  cache;
        logic             lock;
        axi_pkg::prot_t   prot;
        axi_pkg::qos_t    qos;
        axi_pkg::region_t region;
    } axi_options_t;

    /// Backend option type:
    /// - `decouple_aw`: `AWs` will only be sent after the first corresponding `R` is received
    /// - `decouple_rw`: decouples the `R` and `W` channels completely: can cause deadlocks
    /// - `*_max_llen`: the maximum log length of a burst
    /// - `*_reduce_len`: should bursts be reduced in length?
    typedef struct packed {
        logic       decouple_aw;
        logic       decouple_rw;
        logic [2:0] src_max_llen;
        logic [2:0] dst_max_llen;
        logic       src_reduce_len;
        logic       dst_reduce_len;
    } backend_options_t;

    /// Compute operation selector
    typedef enum logic [3:0] {
        COMPUTE_NONE      = 4'd0,
        COMPUTE_TRANSPOSE = 4'd1
    } compute_op_e;

    /// Transpose tensor dimension width (elements)
    localparam int unsigned TransposeDimWidth = 32'd12;

    /// Transpose options.
    ///
    /// `E` denotes the width of one matrix element in bytes. The encoded
    /// element width is `E = 1 << mode`, selecting 1, 2, 4, or 8 byte
    /// elements. A transpose tile therefore contains `StrbWidth / E`
    /// elements along each side, where `StrbWidth` is the datapath width in
    /// bytes.
    typedef struct packed {
        /// Store output rows without tile padding.
        logic                         compact;
        /// Base-2 logarithm of the element width in bytes (`E = 1 << mode`).
        logic [1:0]                   mode;
        /// Number of rows in the source matrix, measured in elements.
        logic [TransposeDimWidth-1:0] tensor_m;
        /// Number of columns in the source matrix, measured in elements.
        logic [TransposeDimWidth-1:0] tensor_n;
    } transpose_options_t;

    /// Per-op compute parameter union (members must be equal width)
    typedef union packed {
        transpose_options_t transpose;
    } compute_params_t;

    /// Compute option type: per-transfer on-the-fly compute selection
    typedef struct packed {
        logic            enable;
        compute_op_e     op;
        compute_params_t params;
    } compute_options_t;

    /// Compile-time per-op compute feature enables
    typedef struct packed {
        logic transpose;
    } compute_enable_t;

    /// Supported Protocols
    /// - `AXI`: Full AXI
    /// - `AXILITE`: AXI Lite
    /// - `OBI`: OBI
    /// - `TILELINK`: TileLink-UH
    /// - `INIT`: Init protocol
    /// - `AXI_STREAM`: AXI Stream
    typedef enum logic[2:0] {
        AXI        = 'd0,
        OBI        = 'd1,
        AXILITE    = 'd2,
        TILELINK   = 'd3,
        INIT       = 'd4,
        AXI_STREAM = 'd5
    } protocol_e;

    /// Multihead channel selection type
    typedef logic[7:0] multihead_t;

    /// Supported Protocols type
    typedef logic[1:0] protocol_t;

    typedef enum logic {
        TCDMDMA   = 0,
        ToSoC     = 1
    } dma_addr_map_e;

endpackage

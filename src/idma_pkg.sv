// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz  <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

/// iDMA Package
/// Contains all static type definitions
package idma_pkg;

    `include "idma/compute.svh"

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

    /// MX block geometry (OCP MX): 32 elements per block, width-independent
    localparam int unsigned MxBlockElems     = 32'd32;
    localparam int unsigned MxFp32BlockBytes = 32'd4 * MxBlockElems;
    localparam int unsigned MxFp16BlockBytes = 32'd2 * MxBlockElems;
    /// Data-plane bytes of a block (one E5M2 or E4M3 byte per element)
    localparam int unsigned MxDataBlockBytes = MxBlockElems;
    /// Scale plane unit and alignment: one 64 B line holds the E8M0 scales of up to 64 blocks
    localparam int unsigned MxScaleSlotBytes = 32'd64;

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

    /// MX element format (OCP MX v1.0); E2M1 is reserved, not elaborated
    typedef enum logic [1:0] { MX_E5M2, MX_E4M3, MX_E2M1 } mx_elem_e;

    /// Unused low bits of `mx_options_t`; the scale plane address is `idma_req_t.scale_addr`
    localparam int unsigned MxOptResvWidth = $bits(transpose_options_t) - 32'd2 -
                                             $bits(mx_elem_e) - $bits(mx_group_e);

    /// MX options
    typedef struct packed {
        logic                         poison_dis;
        logic                         rceil;
        mx_elem_e                     elem_fmt;
        logic [$bits(mx_group_e)-1:0] group;
        logic [MxOptResvWidth-1:0]    resv;
    } mx_options_t;

    /// MX element formats implemented in this release (E2M1 and 3 are reserved)
    function automatic logic mx_elem_legal(mx_elem_e f);
        return f inside {MX_E5M2, MX_E4M3};
    endfunction

    /// Per-op compute parameter union (members must be equal width)
    typedef union packed {
        transpose_options_t transpose;
        mx_options_t        mx;
    } compute_params_t;

    /// Compute option type: per-transfer on-the-fly compute selection
    typedef struct packed {
        logic            enable;
        compute_op_e     op;
        compute_params_t params;
    } compute_options_t;

    /// Compile-time per-op compute feature enables; `mxfp16` gates the FP16
    /// source/destination format paths of the MX ops (area opt-out)
    typedef struct packed {
        logic transpose;
        logic mxquant;
        logic mxdequant;
        logic mxfp16;
    } compute_enable_t;

    /// Implementation tuning knobs for the compute engines
    typedef struct packed {
        /// Transpose engine duplex (1: two banks full rate, 0: one bank half area)
        logic transpose_full_duplex;
    } compute_tuning_t;

    /// Opt-in timing cuts of the backend; '0 is the stock datapath
    typedef struct packed {
        /// MX beats enter their engine on the read beat, past the byte-lane masks (whole beats)
        logic mx_beat_push;
        /// Dataflow element ready from flops; a lane's extra entry fills only on a pending W pop
        logic dfe_ready_ahead;
        /// MX beats enter their engine through a one-beat register stage, which takes one input entry
        logic mx_in_reg;
        /// Dataflow element ready from flops, no same-cycle refill of a full lane; one more entry
        logic dfe_ready_cut;
        /// Dataflow element lanes with registered full/empty flags, pointers without enables
        logic dfe_reg_flags;
        /// Spill register on the head of the write datapath request FIFO
        logic wdp_head_spill;
        /// The outstanding-transfer counter takes accepted requests one cycle late
        logic outst_cnt_reg;
    } timing_cuts_t;

    /// MX element transfer format (FP32 is the architectural base format)
    typedef enum logic [0:0] { MX_FMT_FP32, MX_FMT_FP16 } mx_fmt_e;

    /// Single source of truth: element transfer format of an MX op
    function automatic mx_fmt_e compute_op_fmt(compute_op_e op);
        return (op inside {COMPUTE_MXQUANT_FP16, COMPUTE_MXDEQUANT_FP16})
               ? MX_FMT_FP16 : MX_FMT_FP32;
    endfunction

    /// Single source of truth: is `op` an MX op (its params are `mx_options_t`)?
    function automatic logic compute_op_is_mx(compute_op_e op);
        return op inside {COMPUTE_MXQUANT, COMPUTE_MXQUANT_FP16,
                          COMPUTE_MXDEQUANT, COMPUTE_MXDEQUANT_FP16};
    endfunction

    /// Per-op bytes per block of the request length and of the written data plane
    function automatic int unsigned compute_in_bytes(compute_op_e op);
        unique case (op)
            COMPUTE_MXQUANT:        return MxFp32BlockBytes;
            COMPUTE_MXQUANT_FP16:   return MxFp16BlockBytes;
            COMPUTE_MXDEQUANT,
            COMPUTE_MXDEQUANT_FP16: return MxDataBlockBytes;
            default:                return 32'd1;
        endcase
    endfunction

    function automatic int unsigned compute_out_bytes(compute_op_e op);
        unique case (op)
            COMPUTE_MXQUANT,
            COMPUTE_MXQUANT_FP16:   return MxDataBlockBytes;
            COMPUTE_MXDEQUANT:      return MxFp32BlockBytes;
            COMPUTE_MXDEQUANT_FP16: return MxFp16BlockBytes;
            default:                return 32'd1;
        endcase
    endfunction

    /// Does the written length of `len` input bytes fit a `w`-bit length field?
    function automatic logic compute_out_len_fits(compute_op_e op, logic [63:0] len,
                                                  int unsigned w);
        unique case (op)
            COMPUTE_MXDEQUANT:
                return (len >> (w - $clog2(MxFp32BlockBytes / MxDataBlockBytes))) == '0;
            COMPUTE_MXDEQUANT_FP16:
                return (len >> (w - $clog2(MxFp16BlockBytes / MxDataBlockBytes))) == '0;
            default: return 1'b1;
        endcase
    endfunction

    /// Blocks per scale group
    function automatic int unsigned compute_mx_group_blocks(compute_options_t c);
        return (c.params.mx.group == MX_GROUP_G32) ? 32'd32 : 32'd64;
    endfunction

    /// Single source of truth: is `op` elaborated under this feature mask?
    function automatic logic compute_op_supported(compute_enable_t ena, compute_op_e op);
        unique case (op)
            COMPUTE_TRANSPOSE:      return ena.transpose;
            COMPUTE_MXQUANT:        return ena.mxquant;
            COMPUTE_MXQUANT_FP16:   return ena.mxquant   & ena.mxfp16;
            COMPUTE_MXDEQUANT:      return ena.mxdequant;
            COMPUTE_MXDEQUANT_FP16: return ena.mxdequant & ena.mxfp16;
            default:                return 1'b0;
        endcase
    endfunction

    /// Per-beat MX sideband; `last`: last burst or beat of the transfer, `half`: one 32 B block
    typedef struct packed {
        logic                         mx;
        logic                         dequant;
        mx_fmt_e                      fmt;
        mx_elem_e                     elem_fmt;
        logic                         rceil;
        logic                         poison_dis;
        logic [$bits(mx_group_e)-1:0] group;
        logic                         is_scale;
        logic                         half;
        logic                         last;
    } mx_tag_t;

    /// MX sideband of a transfer; zero unless it is an elaborated MX op
    function automatic mx_tag_t mx_tag(compute_enable_t ena, compute_options_t c, logic is_scale,
                                       logic half, logic last);
        mx_tag_t t;
        t            = '0;
        t.mx         = c.enable & compute_op_is_mx(c.op) & compute_op_supported(ena, c.op);
        t.dequant    = t.mx & (c.op inside {COMPUTE_MXDEQUANT, COMPUTE_MXDEQUANT_FP16});
        t.fmt        = t.mx ? compute_op_fmt(c.op) : MX_FMT_FP32;
        t.elem_fmt   = t.mx ? c.params.mx.elem_fmt : MX_E5M2;
        t.rceil      = t.mx & ~t.dequant & c.params.mx.rceil;
        t.poison_dis = t.mx & ~t.dequant & c.params.mx.poison_dis;
        t.group      = t.mx ? c.params.mx.group : MX_GROUP_G64;
        t.is_scale   = t.mx & is_scale;
        t.half       = t.mx & half;
        t.last       = t.mx & last;
        return t;
    endfunction

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

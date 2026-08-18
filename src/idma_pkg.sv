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
    /// Compressed block: 1B E8M0 scale + 32B E5M2
    localparam int unsigned MxBlockBytes     = MxBlockElems + 32'd1;
    localparam int unsigned MxFp32BlockBytes = 32'd4 * MxBlockElems;
    localparam int unsigned MxFp16BlockBytes = 32'd2 * MxBlockElems;


    /// Per-op source:dest byte ratio; the legalizer sizes the write length from it.
    function automatic int unsigned compute_in_bytes(compute_op_e op);
        unique case (op)
            COMPUTE_MXQUANT:        return MxFp32BlockBytes;
            COMPUTE_MXQUANT_FP16:   return MxFp16BlockBytes;
            COMPUTE_MXDEQUANT:      return MxBlockBytes;
            COMPUTE_MXDEQUANT_FP16: return MxBlockBytes;
            default:                return 32'd1;
        endcase
    endfunction

    function automatic int unsigned compute_out_bytes(compute_op_e op);
        unique case (op)
            COMPUTE_MXQUANT:        return MxBlockBytes;
            COMPUTE_MXQUANT_FP16:   return MxBlockBytes;
            COMPUTE_MXDEQUANT:      return MxFp32BlockBytes;
            COMPUTE_MXDEQUANT_FP16: return MxFp16BlockBytes;
            default:                return 32'd1;
        endcase
    endfunction

    /// Transpose tensor dimension width (elements)
    localparam int unsigned TransposeDimWidth = 32'd12;

    /// Transpose options (E = 1<<mode: 1/2/4 B)
    typedef struct packed {
        logic [1:0]                   mode;
        logic [TransposeDimWidth-1:0] tensor_m;
        logic [TransposeDimWidth-1:0] tensor_n;
    } transpose_options_t;

    /// Width of the per-op compute parameter union (set by the widest member)
    localparam int unsigned ComputeParamsWidth = $bits(transpose_options_t);

    /// ALU immediate width (one byte lane)
    localparam int unsigned AluImmWidth = 32'd8;

    /// ALU options: function and byte immediate, padded to the union width
    typedef struct packed {
        logic [ComputeParamsWidth-$bits(alu_func_e)-AluImmWidth-1:0] reserved;
        alu_func_e                                                    func;
        logic [AluImmWidth-1:0]                                       imm;
    } alu_options_t;

    /// Per-op compute parameter union (members must be equal width)
    typedef union packed {
        transpose_options_t transpose;
        alu_options_t       alu;
    } compute_params_t;

    /// Compute option type: per-transfer on-the-fly compute selection
    typedef struct packed {
        logic            enable;
        compute_op_e     op;
        compute_params_t params;
    } compute_options_t;

    /// Compile-time per-op compute feature enables; `mxfp16` and `alu_mul` are area opt-outs
    typedef struct packed {
        logic transpose;
        logic mxquant;
        logic mxdequant;
        logic mxfp16;
        logic alu;
        logic alu_mul;
    } compute_enable_t;

    /// Implementation tuning knobs for the compute engines
    typedef struct packed {
        /// Transpose engine duplex (1: two banks full rate, 0: one bank half area)
        logic transpose_full_duplex;
    } compute_tuning_t;

    /// MX element transfer format (FP32 is the architectural base format)
    typedef enum logic [0:0] { MX_FMT_FP32, MX_FMT_FP16 } mx_fmt_e;

    /// Single source of truth: element transfer format of an MX op
    function automatic mx_fmt_e compute_op_fmt(compute_op_e op);
        return (op inside {COMPUTE_MXQUANT_FP16, COMPUTE_MXDEQUANT_FP16})
               ? MX_FMT_FP16 : MX_FMT_FP32;
    endfunction

    /// Single source of truth: does the ALU function use the multiplier?
    function automatic logic alu_func_uses_mul(alu_func_e func);
        return func inside {ALU_MULI};
    endfunction

    /// Single source of truth: is the ALU function defined?
    function automatic logic alu_func_defined(alu_func_e func);
        return func inside {ALU_NOT, ALU_ADDI, ALU_SUBI, ALU_MULI, ALU_ANDI, ALU_ORI, ALU_XORI};
    endfunction

    /// Single source of truth: is the requested op elaborated under this feature mask?
    function automatic logic compute_op_supported(compute_enable_t ena, compute_options_t cmp);
        unique case (cmp.op)
            COMPUTE_TRANSPOSE:      return ena.transpose;
            COMPUTE_MXQUANT:        return ena.mxquant;
            COMPUTE_MXQUANT_FP16:   return ena.mxquant   & ena.mxfp16;
            COMPUTE_MXDEQUANT:      return ena.mxdequant;
            COMPUTE_MXDEQUANT_FP16: return ena.mxdequant & ena.mxfp16;
            COMPUTE_ALU:            return ena.alu & alu_func_defined(cmp.params.alu.func) &
                                           (~alu_func_uses_mul(cmp.params.alu.func) | ena.alu_mul);
            default:                return 1'b0;
        endcase
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

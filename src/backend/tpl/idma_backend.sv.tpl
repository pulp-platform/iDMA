// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "axi/typedef.svh"
`include "idma/guard.svh"

/// The iDMA backend implements an arbitrary 1D copy engine
module idma_backend_${name_uniqueifier} #(
    /// Data width
    parameter int unsigned DataWidth        = 32'd16,
    /// Address width
    parameter int unsigned AddrWidth        = 32'd24,
    /// AXI user width
    parameter int unsigned UserWidth        = 32'd1,
    /// AXI ID width
    parameter int unsigned AxiIdWidth       = 32'd1,
    /// Number of transaction that can be in-flight concurrently
    parameter int unsigned NumAxInFlight    = 32'd2,
    /// The depth of the internal reorder buffer:
    /// - '2': minimal possible configuration
    /// - '3': efficiently handle misaligned transfers (recommended)
    parameter int unsigned BufferDepth      = 32'd2,
    /// With of a transfer: max transfer size is `2**TFLenWidth` bytes
    parameter int unsigned TFLenWidth       = 32'd24,
    /// The depth of the memory system the backend is attached to
    parameter int unsigned MemSysDepth      = 32'd0,
    /// Burst Len (for actual burst length do 8 byte * 2^(BurstLen))
    parameter int unsigned BurstLen = 4'd8,
    /// Should both data shifts be done before the dataflow element?
    /// If this is enabled, then the data inserted into the dataflow element
    /// will no longer be word aligned, but only a single shifter is needed
    parameter bit          CombinedShifter  = 1'b0,
% if compute_eligible:
    /// Elaborate the optional on-the-fly compute engine
    parameter bit          EnableCompute    = 1'b0,
    /// Per-operation compute support mask
    parameter idma_pkg::compute_enable_t ComputeOps = '1,
    /// Implementation tuning knobs for the compute engines
    parameter idma_pkg::compute_tuning_t ComputeTuning = '1,
% endif
    /// Should the `R`-`AW` coupling hardware be present? (recommended)
    parameter bit          RAWCouplingAvail = 1'b\
% if one_read_port and one_write_port and ('axi' in used_read_protocols) and ('axi' in used_write_protocols):
1,
% else:
0,
%endif
    /// Mask invalid data on the manager interface
    parameter bit MaskInvalidData            = 1'b1,
    /// Should hardware legalization be present? (recommended)
    /// If not, software legalization is required to ensure the transfers are
    /// AXI4-conformal
    parameter bit HardwareLegalizer          = 1'b1,
    /// Reject zero-length transfers
    parameter bit RejectZeroTransfers        = 1'b1,
    /// Should the error handler be present?
    parameter idma_pkg::error_cap_e ErrorCap = idma_pkg::NO_ERROR_HANDLING,
    /// Print the info of the FIFO configuration
    parameter bit PrintFifoInfo              = 1'b0,
    /// 1D iDMA request type
    parameter type idma_req_t                = logic,
    /// iDMA response type
    parameter type idma_rsp_t                = logic,
    /// Error Handler request type
    parameter type idma_eh_req_t             = logic,
    /// iDMA busy signal
    parameter type idma_busy_t               = logic\
% for protocol in used_protocols:
,
    /// ${database[protocol]['full_name']} Request and Response channel type
    % if database[protocol]['read_slave'] == 'true':
        % if (protocol in used_read_protocols) and (protocol in used_write_protocols):
    parameter type ${protocol}_read_req_t = logic,
    parameter type ${protocol}_read_rsp_t = logic,

    parameter type ${protocol}_write_req_t = logic,
    parameter type ${protocol}_write_rsp_t = logic\
        % elif protocol in used_read_protocols:
    parameter type ${protocol}_read_req_t = logic,
    parameter type ${protocol}_read_rsp_t = logic\
        % elif protocol in used_write_protocols:
    parameter type ${protocol}_write_req_t = logic,
    parameter type ${protocol}_write_rsp_t = logic\
        % endif
    % else:
    parameter type ${protocol}_req_t = logic,
    parameter type ${protocol}_rsp_t = logic\
    % endif
% endfor
,
    /// Address Read Channel type
    parameter type read_meta_channel_t  = logic,
    /// Address Write Channel type
    parameter type write_meta_channel_t = logic,
    /// Strobe Width (do not override!)
    parameter int unsigned StrbWidth    = DataWidth / 8,
    /// Offset Width (do not override!)
    parameter int unsigned OffsetWidth  = $clog2(StrbWidth)
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,

    /// 1D iDMA request
    input  idma_req_t idma_req_i,
    /// 1D iDMA request valid
    input  logic req_valid_i,
    /// 1D iDMA request ready
    output logic req_ready_o,

    /// iDMA response
    output idma_rsp_t idma_rsp_o,
    /// iDMA response valid
    output logic rsp_valid_o,
    /// iDMA response ready
    input  logic rsp_ready_i,

    /// Error handler request
    input  idma_eh_req_t idma_eh_req_i,
    /// Error handler request valid
    input  logic eh_req_valid_i,
    /// Error handler request ready
    output logic eh_req_ready_o,
% for protocol in used_read_protocols:

    /// ${database[protocol]['full_name']} read request
% if database[protocol]['passive_req'] == 'true':
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_req_t ${mh_format['ar'][protocol]}${protocol}_read_req_i,
% else:
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_req_t ${mh_format['ar'][protocol]}${protocol}_read_req_o,
% endif
    /// ${database[protocol]['full_name']} read response
% if database[protocol]['passive_req'] == 'true':
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_rsp_t ${mh_format['ar'][protocol]}${protocol}_read_rsp_o,
% else:
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_read\
% endif
_rsp_t ${mh_format['ar'][protocol]}${protocol}_read_rsp_i,
% endif
% endfor
% for protocol in used_write_protocols:

    /// ${database[protocol]['full_name']} write request
    output ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_write\
% endif
_req_t ${mh_format['aw'][protocol]}${protocol}_write_req_o,
    /// ${database[protocol]['full_name']} write response
    input  ${protocol}\
% if database[protocol]['read_slave'] == 'true':
_write\
% endif
_rsp_t ${mh_format['aw'][protocol]}${protocol}_write_rsp_i,
% endfor

    /// iDMA busy flags
    output idma_busy_t busy_o
);

    /// Extra write-descriptor slots covering the compute (transpose) tile-fill latency.
% if compute_eligible:
    localparam int unsigned ComputeFifoDepth = EnableCompute ? StrbWidth : 32'd0;
% else:
    localparam int unsigned ComputeFifoDepth = 32'd0;
% endif

    /// The localparam MetaFifoDepth holds the maximum number of transfers that can be
    /// in-flight under any circumstances.
    localparam int unsigned MetaFifoDepth = BufferDepth + NumAxInFlight + MemSysDepth + ComputeFifoDepth;

    /// Address type
    typedef logic [AddrWidth-1:0]   addr_t;
    /// DAta type
    typedef logic [DataWidth-1:0]   data_t;
    /// Strobe type
    typedef logic [StrbWidth-1:0]   strb_t;
    /// User type
    typedef logic [UserWidth-1:0]   user_t;
    /// ID type
    typedef logic [AxiIdWidth-1:0]  id_t;
    /// Offset type
    typedef logic [OffsetWidth-1:0] offset_t;
    /// Transfer length type
    typedef logic [TFLenWidth-1:0]  tf_len_t;

    /// The datapath read request type holds all the information required to configure the read
    /// part of the datapath. The type consists of:
    /// - `offset`: The bus offset of the read
    /// - `trailer`: How many empty bytes are required to pad the transfer to a multiple of the
    ///              bus width.
    /// - `shift`: The amount the data needs to be shifted
    /// - `decouple_aw`: If the transfer has the AW decoupled from the R
    /// - `is_single`: Is this transfer just one beat long? `(len == 0)`
    typedef struct packed {
        idma_pkg::protocol_e  src_protocol;
        idma_pkg::multihead_t src_head;  // ignored unless multi-head (one head: tied 0)
        offset_t              offset;
        offset_t              tailer;
        offset_t              shift;
        logic                 decouple_aw;
        logic                 is_single;
    } r_dp_req_t;

    /// The datapath read response type provides feedback from the read part of the datapath:
    /// - `resp`: The response from the R channel of the AXI4 manager interface
    /// - `last`: The last flag from the R channel of the AXI4 manager interface
    /// - `first`: Is the current item first beat in the burst
    typedef struct packed {
        axi_pkg::resp_t resp;
        logic           last;
        logic           first;
    } r_dp_rsp_t;

    /// The datapath write request type holds all the information required to configure the write
    /// part of the datapath. The type consists of:
    /// - `offset`: The bus offset of the write
    /// - `trailer`: How many empty bytes are required to pad the transfer to a multiple of the
    ///              bus width.
    /// - `shift`: The amount the data needs to be shifted
    /// - `num_beats`: The number of beats this burst consist of
    /// - `is_single`: Is this transfer just one beat long? `(len == 0)`
    typedef struct packed {
        idma_pkg::protocol_e  dst_protocol;
        idma_pkg::multihead_t dst_head;  // ignored unless multi-head (one head: tied 0)
        offset_t              offset;
        offset_t              tailer;
        offset_t              shift;
        axi_pkg::len_t        num_beats;
        logic                 is_single;
        idma_pkg::compute_options_t compute;
    } w_dp_req_t;

    /// The datapath write response type provides feedback from the write part of the datapath:
    /// - `resp`: The response from the B channel of the AXI4 manager interface
    /// - `user`: The user field from the B channel of the AXI4 manager interface
    typedef struct packed {
        axi_pkg::resp_t resp;
        user_t          user;
    } w_dp_rsp_t;

    /// The iDMA read request bundles an `AR` type and a datapath read response type together.
    typedef struct packed {
        r_dp_req_t          r_dp_req;
        read_meta_channel_t ar_req;
    } idma_r_req_t;
% if not one_read_port:
    typedef struct packed {
        idma_pkg::protocol_e  src_protocol;
        idma_pkg::multihead_t src_head;
        read_meta_channel_t   ar_req;
    } read_meta_channel_tagged_t;
% endif

    /// The iDMA write request bundles an `AW` type and a datapath write response type together. It
    /// has an additional flags:
    /// - `last`: indicating the current burst is the last one of the generic 1D transfer currently
    ///    being processed
    /// - `midend_last`: The current transfer is marked by the controlling as last
    /// - `decouple_aw`: indicates this is an R-AW decoupled transfer
    typedef struct packed {
        w_dp_req_t           w_dp_req;
        write_meta_channel_t aw_req;
        logic                last;
        logic                super_last;
        logic                decouple_aw;
    } idma_w_req_t;
% if not one_write_port:
    typedef struct packed {
        idma_pkg::protocol_e  dst_protocol;
        idma_pkg::multihead_t dst_head;
        write_meta_channel_t  aw_req;
    } write_meta_channel_tagged_t;
% endif

    /// The mutable transfer options type holds important information that is mutated by the
    /// `legalizer` block.
    typedef struct packed {
        idma_pkg::protocol_e    src_protocol;
        idma_pkg::protocol_e    dst_protocol;
        idma_pkg::multihead_t   src_head;
        idma_pkg::multihead_t   dst_head;
        offset_t                read_shift;
        offset_t                write_shift;
        logic                   decouple_rw;
        logic                   decouple_aw;
        logic [2:0]             src_max_llen;
        logic [2:0]             dst_max_llen;
        logic                   src_reduce_len;
        logic                   dst_reduce_len;
        id_t                    axi_id;
        idma_pkg::axi_options_t src_axi_opt;
        idma_pkg::axi_options_t dst_axi_opt;
        logic                   super_last;
        idma_pkg::compute_options_t compute;
    } idma_mut_tf_opt_t;

    /// The mutable transfer type holds important information that is mutated by the
    /// `legalizer` block.
    typedef struct packed {
        tf_len_t length;
        addr_t   addr;
        logic    valid;
        addr_t   base_addr;
        user_t   user;
    } idma_mut_tf_t;


    // datapath busy indicates the datapath is actively working on a transfer. It is composed of
    // the activity of the buffer as well as both the read and write machines
    logic dp_busy;
    // blanks invalid data
    logic dp_poison;

    // read and write requests and their handshaking signals
    idma_r_req_t r_req;
    idma_w_req_t w_req;
    logic        r_valid, w_valid;
    logic        r_ready, w_ready;
% if not one_read_port:
    read_meta_channel_tagged_t  r_meta_req_tagged;
% endif
% if not one_write_port:
    write_meta_channel_tagged_t w_meta_req_tagged;
%endif

    // It the current transfer the last burst in the 1D transfer?
    logic w_last_burst;
    logic w_last_ready;

    // Super last flag: The current transfer is indicated as the last one by the controlling
    // unit; e.g. by a midend
    logic w_super_last;

    // Datapath FIFO signals -> used to decouple legalizer and datapath
    logic r_dp_req_in_ready,  w_dp_req_in_ready;
    logic r_dp_req_out_valid, w_dp_req_out_valid;
    logic r_dp_req_out_ready, w_dp_req_out_ready;
    r_dp_req_t r_dp_req_out;
    w_dp_req_t w_dp_req_out;

    // datapah responses
    r_dp_rsp_t r_dp_rsp;
    w_dp_rsp_t w_dp_rsp;
    logic r_dp_rsp_valid, w_dp_rsp_valid;
    logic r_dp_rsp_ready, w_dp_rsp_ready;

    // Ax handshaking
    logic ar_ready,    ar_ready_dp;
    logic aw_ready,    aw_ready_dp;
    logic aw_valid_dp, ar_valid_dp;

    // Ax request from R-AW coupler to datapath
% if one_write_port:
    write_meta_channel_t aw_req_dp;
% else:
    write_meta_channel_tagged_t aw_req_dp;
% endif

    // Ax request from the decoupling stage to the datapath
% if one_read_port:
    read_meta_channel_t ar_req_dp;
% else:
    read_meta_channel_tagged_t ar_req_dp;
% endif

    // flush and preemptively empty the legalizer
    logic legalizer_flush, legalizer_kill;

    /// intermediate signals to reject zero length transfers
    logic      is_length_zero;
    logic      req_valid;
    logic      zero_len_stall;
    idma_rsp_t idma_rsp;
    logic      rsp_valid;
    logic      rsp_ready;

    // Write channel valid, ready and first -> needed to send AWs when Ws are available
    logic w_chan_valid;
    logic w_chan_ready;
    logic w_chan_first;

    //--------------------------------------
    // Handle Zero Length Transfers
    //--------------------------------------
    // A zero length transfer moves no bytes and never reaches the legalizer: zero bytes have
    // no encoding downstream; AxLEN = beats - 1 underflows to a full burst and the datapath
    // mask aliases tailer = 0 to full width. Both settings therefore suppress the request and
    // synthesize the one response it owes; RejectZeroTransfers only picks the payload.
    /// number of accepted transfers that still owe a response
    typedef logic [$clog2(MetaFifoDepth + 32'd2)-1:0] num_outst_t;

    num_outst_t num_outst_q;
    logic       tf_accept, tf_complete;
    logic       zero_len_accept, zero_rsp_pending_q, zero_rsp_last_q;

    // is the current transfer length 0?
    assign is_length_zero = idma_req_i.length == '0;

    // bypass valid as long as length is not zero, otherwise suppress it
    assign req_valid = is_length_zero ? 1'b0 : req_valid_i;

    // hold a zero length request back while a transfer still owes a response or an older
    // synthesized response is unaccepted; the injected response must not overtake either
    assign zero_len_stall = is_length_zero & (zero_rsp_pending_q | (num_outst_q != '0));

    // outstanding transfer counter; mirrors the one in the error handler
    assign tf_accept   = req_valid & req_ready_o;
    assign tf_complete = rsp_valid & rsp_ready & ~idma_rsp.error;

    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_num_outst
        if (!rst_ni)                        num_outst_q <= '0;
        else if (tf_accept & ~tf_complete)  num_outst_q <= num_outst_q + 'd1;
        else if (tf_complete & ~tf_accept)  num_outst_q <= num_outst_q - 'd1;
    end

    // the synthesized response is a proper stream: it is held until the consumer accepts it
    assign zero_len_accept = is_length_zero & req_valid_i & req_ready_o;

    // last is captured at accept time; the request is long gone when the response is emitted
    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_zero_rsp_pending
        if (!rst_ni) begin
            zero_rsp_pending_q <= 1'b0;
            zero_rsp_last_q    <= 1'b0;
        end else if (zero_len_accept) begin
            zero_rsp_pending_q <= 1'b1;
            zero_rsp_last_q    <= idma_req_i.opt.last;
        end else if (zero_rsp_pending_q & rsp_ready_i) begin
            zero_rsp_pending_q <= 1'b0;
        end
    end

    // modify response
    always_comb begin : proc_modify_response_zero_length
        // default: bypass
        idma_rsp_o  = idma_rsp;
        rsp_ready   = rsp_ready_i;
        rsp_valid_o = rsp_valid;

        // a zero transfer is pending
        if (zero_rsp_pending_q) begin
            // block backend
            rsp_ready = 1'b0;
            // generate new response
            rsp_valid_o             = 1'b1;
            idma_rsp_o              =  '0;
            idma_rsp_o.last         = zero_rsp_last_q;
            // reject: the request was illegal; accept: it completed with nothing to do
            if (RejectZeroTransfers) begin
                idma_rsp_o.error        = 1'b1;
                idma_rsp_o.pld.err_type = idma_pkg::BACKEND;
            end
        end
    end


    //--------------------------------------
    // Compute config serialization interlock
    //--------------------------------------
    logic req_valid_leg, leg_ready;
% if compute_eligible:
    if (EnableCompute) begin : gen_compute_cfg_gate
        // a request whose compute config differs from the last accepted one waits
        // until the datapath drained: its reads must not race a draining engine
        idma_pkg::compute_options_t cmp_cfg_q;
        logic backend_active, cmp_cfg_stall;
        assign backend_active = busy_o.buffer_busy | busy_o.r_dp_busy | busy_o.w_dp_busy |
                                busy_o.r_leg_busy | busy_o.w_leg_busy | busy_o.raw_coupler_busy;
        assign cmp_cfg_stall  = req_valid & (idma_req_i.opt.compute != cmp_cfg_q) & backend_active;
        assign req_valid_leg  = req_valid & ~cmp_cfg_stall;
        assign req_ready_o    = leg_ready & ~cmp_cfg_stall & ~zero_len_stall;
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni)                        cmp_cfg_q <= '0;
            else if (req_valid_leg & leg_ready) cmp_cfg_q <= idma_req_i.opt.compute;
        end
    end else begin : gen_no_compute_cfg_gate
        assign req_valid_leg = req_valid;
        assign req_ready_o   = leg_ready & ~zero_len_stall;
    end
% else:
    assign req_valid_leg = req_valid;
    assign req_ready_o   = leg_ready & ~zero_len_stall;
% endif

    //--------------------------------------
    // Legalization
    //--------------------------------------
    if (HardwareLegalizer) begin : gen_hw_legalizer
        // hardware legalizer is present
        idma_legalizer_${name_uniqueifier} #(
            .CombinedShifter   ( CombinedShifter   ),
% if compute_eligible:
            .EnableCompute     ( EnableCompute     ),
            .ComputeOps        ( ComputeOps        ),
% endif
            .DataWidth         ( DataWidth         ),
            .AddrWidth         ( AddrWidth         ),
            .BurstLen          ( BurstLen          ),
            .idma_req_t        ( idma_req_t        ),
            .idma_r_req_t      ( idma_r_req_t      ),
            .idma_w_req_t      ( idma_w_req_t      ),
            .idma_mut_tf_t     ( idma_mut_tf_t     ),
            .idma_mut_tf_opt_t ( idma_mut_tf_opt_t )
        ) i_idma_legalizer (
            .clk_i     ( clk_i             ),
            .rst_ni    ( rst_ni            ),
            .req_i     ( idma_req_i        ),
            .valid_i   ( req_valid_leg     ),
            .ready_o   ( leg_ready         ),
            .r_req_o   ( r_req             ),
            .w_req_o   ( w_req             ),
            .r_valid_o ( r_valid           ),
            .w_valid_o ( w_valid           ),
            .r_ready_i ( r_ready           ),
            .w_ready_i ( w_ready           ),
            .flush_i   ( legalizer_flush   ),
            .kill_i    ( legalizer_kill    ),
            .r_busy_o  ( busy_o.r_leg_busy ),
            .w_busy_o  ( busy_o.w_leg_busy )
        );

    end else begin : gen_no_hw_legalizer
        // stream fork is used to synchronize the two decoupled channels without the need for a
        // FIFO here.
        cc_stream_fork #(
            .NumOup  ( 32'd2 )
        ) i_stream_fork (
            .clk_i   ( clk_i                ),
            .rst_ni  ( rst_ni               ),
            .clr_i   ( 1'b0                 ),
            .valid_i ( req_valid_leg        ),
            .ready_o ( leg_ready            ),
            .valid_o ( { r_valid, w_valid } ),
            .ready_i ( { r_ready, w_ready } )
        );

        // local signal holding the length -> explicitly only doing the computation once
        axi_pkg::len_t len;
        assign len = ((idma_req_i.length + idma_req_i.src_addr[OffsetWidth-1:0] -
                     'd1) >> OffsetWidth);

        // assemble read datapath request
        assign r_req.r_dp_req = '{
            src_protocol: idma_req_i.opt.src_protocol,
            src_head:     idma_req_i.opt.src_head,
            offset:       idma_req_i.src_addr[OffsetWidth-1:0],
            tailer:       OffsetWidth'(idma_req_i.length + idma_req_i.src_addr[OffsetWidth-1:0]),
            shift:        OffsetWidth'(idma_req_i.src_addr[OffsetWidth-1:0]),
            decouple_aw:  idma_req_i.opt.beo.decouple_aw,
            is_single:    len == '0
        };

        // assemble write datapath request
        assign w_req.w_dp_req = '{
            dst_protocol: idma_req_i.opt.dst_protocol,
            dst_head:     idma_req_i.opt.dst_head,
            offset:       idma_req_i.dst_addr[OffsetWidth-1:0],
            tailer:       OffsetWidth'(idma_req_i.length + idma_req_i.dst_addr[OffsetWidth-1:0]),
            shift:        OffsetWidth'(- idma_req_i.dst_addr[OffsetWidth-1:0]),
            num_beats:    len,
            is_single:    len == '0,
            compute:      idma_req_i.opt.compute
        };

        // if the legalizer is bypassed; every burst is the last of the 1D transfer
        assign w_req.last = 1'b1;

        // assign the last flag of the controlling unit
        assign w_req.super_last = idma_req_i.opt.last;

        // bypass decouple signal
        assign w_req.decouple_aw = idma_req_i.opt.beo.decouple_aw;

        // there is no unit to be busy
        assign busy_o.r_leg_busy = 1'b0;
        assign busy_o.w_leg_busy = 1'b0;
    end

    // data path, meta channels, and last queues have to be ready for the legalizer to be ready
    assign r_ready = r_dp_req_in_ready & ar_ready;
    assign w_ready = w_dp_req_in_ready & aw_ready & w_last_ready;


    //--------------------------------------
    // Error handler
    //--------------------------------------
    if (ErrorCap == idma_pkg::ERROR_HANDLING) begin : gen_error_handler
% if one_read_port and one_write_port and ('axi' in used_read_protocols) and ('axi' in used_write_protocols):
        idma_error_handler #(
            .MetaFifoDepth ( MetaFifoDepth ),
            .PrintFifoInfo ( PrintFifoInfo ),
            .idma_rsp_t    ( idma_rsp_t    ),
            .idma_eh_req_t ( idma_eh_req_t ),
            .addr_t        ( addr_t        ),
            .r_dp_rsp_t    ( r_dp_rsp_t    ),
            .w_dp_rsp_t    ( w_dp_rsp_t    )
        ) i_idma_error_handler (
            .clk_i             ( clk_i              ),
            .rst_ni            ( rst_ni             ),
            .rsp_o             ( idma_rsp           ),
            .rsp_valid_o       ( rsp_valid          ),
            .rsp_ready_i       ( rsp_ready          ),
            .req_valid_i       ( req_valid          ),
            .req_ready_i       ( req_ready_o        ),
            .eh_i              ( idma_eh_req_i      ),
            .eh_valid_i        ( eh_req_valid_i     ),
            .eh_ready_o        ( eh_req_ready_o     ),
            .r_addr_i          ( r_req.ar_req.axi.ar_chan.addr ),
            .w_addr_i          ( w_req.aw_req.axi.aw_chan.addr ),
            .r_consume_i       ( r_valid & r_ready  ),
            .w_consume_i       ( w_valid & w_ready  ),
            .legalizer_flush_o ( legalizer_flush    ),
            .legalizer_kill_o  ( legalizer_kill     ),
            .dp_busy_i         ( dp_busy            ),
            .dp_poison_o       ( dp_poison          ),
            .r_dp_rsp_i        ( r_dp_rsp           ),
            .r_dp_valid_i      ( r_dp_rsp_valid     ),
            .r_dp_ready_o      ( r_dp_rsp_ready     ),
            .w_dp_rsp_i        ( w_dp_rsp           ),
            .w_dp_valid_i      ( w_dp_rsp_valid     ),
            .w_dp_ready_o      ( w_dp_rsp_ready     ),
            .w_last_burst_i    ( w_last_burst       ),
            .w_super_last_i    ( w_super_last       ),
            .fsm_busy_o        ( busy_o.eh_fsm_busy ),
            .cnt_busy_o        ( busy_o.eh_cnt_busy )
        );
% else:
        `IDMA_NONSYNTH_BLOCK(
        initial begin
            $fatal(1, "Error Handling only implemented for AXI to AXI DMA!");
        end
        )
% endif
    end else if (ErrorCap == idma_pkg::NO_ERROR_HANDLING) begin : gen_no_error_handler
        // bypass the signals, assign their neutral values
        assign idma_rsp.error     = 1'b0;
        assign idma_rsp.pld       = 1'b0;
        assign idma_rsp.last      = w_super_last;
        assign rsp_valid          = w_dp_rsp_valid & w_last_burst;
        assign eh_req_ready_o     = 1'b0;
        assign legalizer_flush    = 1'b0;
        assign legalizer_kill     = 1'b0;
        assign dp_poison          = 1'b0;
        assign r_dp_rsp_ready     = rsp_ready;
        assign w_dp_rsp_ready     = rsp_ready;
        assign busy_o.eh_fsm_busy = 1'b0;
        assign busy_o.eh_cnt_busy = 1'b0;

    end else begin : gen_param_error
        `IDMA_NONSYNTH_BLOCK(
        initial begin
            $fatal(1, "Unexpected Error Capability");
        end
        )
    end


    //--------------------------------------
    // Datapath busy signal
    //--------------------------------------
    assign dp_busy = busy_o.buffer_busy |
                     busy_o.r_dp_busy   |
                     busy_o.w_dp_busy;


    //--------------------------------------
    // Datapath decoupling
    //--------------------------------------
    cc_stream_fifo_optimal_wrap #(
        .Depth     ( NumAxInFlight ),
        .data_t    ( r_dp_req_t    ),
        .PrintInfo ( PrintFifoInfo )
    ) i_r_dp_req (
        .clk_i      ( clk_i               ),
        .rst_ni     ( rst_ni              ),
        .clr_i      ( 1'b0                ),
        .flush_i    ( 1'b0                ),
        .usage_o    ( /* NOT CONNECTED */ ),
        .data_i     ( r_req.r_dp_req      ),
        .valid_i    ( r_valid             ),
        .ready_o    ( r_dp_req_in_ready   ),
        .data_o     ( r_dp_req_out        ),
        .valid_o    ( r_dp_req_out_valid  ),
        .ready_i    ( r_dp_req_out_ready  )
    );

    cc_stream_fifo_optimal_wrap #(
        .Depth     ( NumAxInFlight + ComputeFifoDepth ),
        .data_t    ( w_dp_req_t    ),
        .PrintInfo ( PrintFifoInfo )
    ) i_w_dp_req (
        .clk_i      ( clk_i               ),
        .rst_ni     ( rst_ni              ),
        .clr_i      ( 1'b0                ),
        .flush_i    ( 1'b0                ),
        .usage_o    ( /* NOT CONNECTED */ ),
        .data_i     ( w_req.w_dp_req      ),
        .valid_i    ( w_valid             ),
        .ready_o    ( w_dp_req_in_ready   ),
        .data_o     ( w_dp_req_out        ),
        .valid_o    ( w_dp_req_out_valid  ),
        .ready_i    ( w_dp_req_out_ready  )
    );

    // Add fall-through register to allow the input to be ready if the output is not. This
    // does not add a cycle of delay
% if not one_read_port:
    always_comb begin : assign_r_meta_req
        r_meta_req_tagged.src_protocol = r_req.r_dp_req.src_protocol;
        r_meta_req_tagged.src_head = r_req.r_dp_req.src_head;
        r_meta_req_tagged.ar_req       = r_req.ar_req;
    end
% endif

    cc_fall_through_register #(
        .data_t     (\
% if one_read_port:
 read_meta_channel_t\
% else:
 read_meta_channel_tagged_t\
% endif
 )
    ) i_ar_fall_through_register (
        .clk_i      ( clk_i             ),
        .rst_ni     ( rst_ni            ),
        .clr_i      ( 1'b0              ),
        .valid_i    ( r_valid           ),
        .ready_o    ( ar_ready          ),
        .data_i     (\
% if one_read_port:
 r_req.ar_req\
% else:
 r_meta_req_tagged\
% endif
 ),
        .valid_o    ( ar_valid_dp       ),
        .ready_i    ( ar_ready_dp       ),
        .data_o     ( ar_req_dp         )
    );


    //--------------------------------------
    // Last flag store
    //--------------------------------------
    cc_stream_fifo_optimal_wrap #(
        .Depth        ( MetaFifoDepth ),
        .data_t       ( logic [1:0]   ),
        .PrintInfo    ( PrintFifoInfo )
    ) i_w_last (
        .clk_i      ( clk_i                           ),
        .rst_ni     ( rst_ni                          ),
        .clr_i      ( 1'b0                            ),
        .flush_i    ( 1'b0                            ),
        .usage_o    ( /* NOT CONNECTED */             ),
        .data_i     ( {w_req.super_last, w_req.last}  ),
        .valid_i    ( w_valid & w_ready               ),
        .ready_o    ( w_last_ready                    ),
        .data_o     ( {w_super_last, w_last_burst}    ),
        .valid_o    ( /* NOT CONNECTED */             ),
        .ready_i    ( w_dp_rsp_valid & w_dp_rsp_ready )
    );

    //--------------------------------------
    // Transport Layer / Datapath
    //--------------------------------------
    idma_transport_layer_${name_uniqueifier} #(
        .NumAxInFlight               ( NumAxInFlight               ),
        .DataWidth                   ( DataWidth                   ),
        .BufferDepth                 ( BufferDepth                 ),
        .MaskInvalidData             ( MaskInvalidData             ),
% if compute_eligible:
        .EnableCompute               ( EnableCompute               ),
        .ComputeOps                  ( ComputeOps                  ),
        .ComputeTuning               ( ComputeTuning               ),
% endif
        .PrintFifoInfo               ( PrintFifoInfo               ),
        .r_dp_req_t                  ( r_dp_req_t                  ),
        .w_dp_req_t                  ( w_dp_req_t                  ),
        .r_dp_rsp_t                  ( r_dp_rsp_t                  ),
        .w_dp_rsp_t                  ( w_dp_rsp_t                  ),
        .write_meta_channel_t        ( write_meta_channel_t        ),
% if not one_write_port:
        .write_meta_channel_tagged_t ( write_meta_channel_tagged_t ),
% endif
        .read_meta_channel_t         ( read_meta_channel_t         )\
% if not one_read_port:
,
        .read_meta_channel_tagged_t  ( read_meta_channel_tagged_t  )\
% endif
% for protocol in used_protocols:
,
    % if database[protocol]['read_slave'] == 'true':
        % if (protocol in used_read_protocols) and (protocol in used_write_protocols):
        .${protocol}_read_req_t              ( ${protocol}_read_req_t              ),
        .${protocol}_read_rsp_t              ( ${protocol}_read_rsp_t              ),
        .${protocol}_write_req_t             ( ${protocol}_write_req_t             ),
        .${protocol}_write_rsp_t             ( ${protocol}_write_rsp_t             )\
        % elif protocol in used_read_protocols:
        .${protocol}_read_req_t              ( ${protocol}_read_req_t              ),
        .${protocol}_read_rsp_t              ( ${protocol}_read_rsp_t              )\
        % else:
        .${protocol}_write_req_t             ( ${protocol}_write_req_t             ),
        .${protocol}_write_rsp_t             ( ${protocol}_write_rsp_t             )\
        % endif
    % else:
        .${protocol}_req_t                   ( ${protocol}_req_t                   ),
        .${protocol}_rsp_t                   ( ${protocol}_rsp_t                   )\
    % endif
% endfor

    ) i_idma_transport_layer (
        .clk_i           ( clk_i                ),
        .rst_ni          ( rst_ni               )\
% for protocol in used_read_protocols:
,
% if database[protocol]['passive_req'] == 'true':
        .${protocol}_read_req_i  ( ${protocol}_read_req_i       ),
        .${protocol}_read_rsp_o  ( ${protocol}_read_rsp_o       )\
% else:
        .${protocol}_read_req_o  ( ${protocol}_read_req_o       ),
        .${protocol}_read_rsp_i  ( ${protocol}_read_rsp_i       )\
% endif
% endfor
% for protocol in used_write_protocols:
,
        .${protocol}_write_req_o ( ${protocol}_write_req_o      ),
        .${protocol}_write_rsp_i ( ${protocol}_write_rsp_i      )\
% endfor
,
        .r_dp_req_i      ( r_dp_req_out         ),
        .r_dp_valid_i    ( r_dp_req_out_valid   ),
        .r_dp_ready_o    ( r_dp_req_out_ready   ),
        .r_dp_rsp_o      ( r_dp_rsp             ),
        .r_dp_valid_o    ( r_dp_rsp_valid       ),
        .r_dp_ready_i    ( r_dp_rsp_ready       ),
        .w_dp_req_i      ( w_dp_req_out         ),
        .w_dp_valid_i    ( w_dp_req_out_valid   ),
        .w_dp_ready_o    ( w_dp_req_out_ready   ),
        .w_dp_rsp_o      ( w_dp_rsp             ),
        .w_dp_valid_o    ( w_dp_rsp_valid       ),
        .w_dp_ready_i    ( w_dp_rsp_ready       ),
        .ar_req_i        ( ar_req_dp            ),
        .ar_valid_i      ( ar_valid_dp          ),
        .ar_ready_o      ( ar_ready_dp          ),
        .aw_req_i        ( aw_req_dp            ),
        .aw_valid_i      ( aw_valid_dp          ),
        .aw_ready_o      ( aw_ready_dp          ),
        .dp_poison_i     ( dp_poison            ),
        .r_dp_busy_o     ( busy_o.r_dp_busy     ),
        .w_dp_busy_o     ( busy_o.w_dp_busy     ),
        .buffer_busy_o   ( busy_o.buffer_busy   ),
        .w_chan_valid_o  ( w_chan_valid         ),
        .w_chan_ready_o  ( w_chan_ready         ),
        .w_chan_first_o  ( w_chan_first         )
    );

    //--------------------------------------
    // R-AW channel coupler
    //--------------------------------------
% if not one_write_port:
    always_comb begin : assign_tagged_w_req // need to have an always_comb block for Questa to not crap itself
        w_meta_req_tagged.dst_protocol = w_req.w_dp_req.dst_protocol;
        w_meta_req_tagged.dst_head = w_req.w_dp_req.dst_head;
        w_meta_req_tagged.aw_req = w_req.aw_req;
    end
% endif

    if (RAWCouplingAvail) begin : gen_r_aw_coupler
% if one_read_port and one_write_port and (used_read_protocols[0] == used_write_protocols[0]):
        // per-transfer decouple_aw tag travelling with the write datapath request
        logic w_decouple_aw_out;

        // mirrors i_w_dp_req exactly: same depth, same push valid, same pop ready
        cc_stream_fifo_optimal_wrap #(
            .Depth     ( NumAxInFlight + ComputeFifoDepth ),
            .data_t    ( logic                            ),
            .PrintInfo ( PrintFifoInfo                    )
        ) i_w_decouple_aw (
            .clk_i      ( clk_i               ),
            .rst_ni     ( rst_ni              ),
            .clr_i      ( 1'b0                ),
            .flush_i    ( 1'b0                ),
            .usage_o    ( /* NOT CONNECTED */ ),
            .data_i     ( w_req.decouple_aw   ),
            .valid_i    ( w_valid             ),
            .ready_o    ( /* NOT CONNECTED */ ),
            .data_o     ( w_decouple_aw_out   ),
            .valid_o    ( /* NOT CONNECTED */ ),
            .ready_i    ( w_dp_req_out_ready  )
        );

        // instantiate the channel coupler
        idma_channel_coupler #(
            .NumAxInFlight   ( NumAxInFlight               ),
            .AddrWidth       ( AddrWidth                   ),
            .UserWidth       ( UserWidth                   ),
            .AxiIdWidth      ( AxiIdWidth                  ),
            .PrintFifoInfo   ( PrintFifoInfo               ),
            .axi_aw_chan_t   (\
% if one_write_port:
 write_meta_channel_t        )
% else:
 write_meta_channel_tagged_t )
% endif
        ) i_idma_channel_coupler (
            .clk_i            ( clk_i                       ),
            .rst_ni           ( rst_ni                      ),
            .w_req_valid_i    ( w_chan_valid                ),
            .w_req_ready_i    ( w_chan_ready                ),
            .w_req_first_i    ( w_chan_first                ),
            .w_decouple_aw_i  ( w_decouple_aw_out           ),
            .aw_decouple_aw_i ( \
% if one_write_port:
w_req.decouple_aw\
% else:
w_req.decouple_aw || (w_req.w_dp_req.dst_protocol inside {\
    % for index, protocol in enumerate(used_non_bursting_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
        % if index != len(used_non_bursting_write_protocols)-1:
,\
        % endif
    % endfor
 })\
% endif
 ),
            .aw_req_i         (\
% if one_write_port:
 w_req.aw_req                ),
% else:           
 w_meta_req_tagged           ),
% endif
            .aw_valid_i       ( w_valid                     ),
            .aw_ready_o       ( aw_ready                    ),
            .aw_req_o         ( aw_req_dp                   ),
            .aw_valid_o       ( aw_valid_dp                 ),
            .aw_ready_i       ( aw_ready_dp                 ),
            .busy_o           ( busy_o.raw_coupler_busy     )
        );
% else:
        `IDMA_NONSYNTH_BLOCK(
        initial begin
            $fatal(1, "Channel Coupler only implemented for AXI DMAs!");
        end
        )
% endif
    end else begin : gen_r_aw_bypass
% if combined_aw_and_w:
    % if compute_eligible:
        // combined aw+w read-meta buffer; deepened for the compute engine tile read-ahead (cf. i_w_dp_req)
        cc_stream_fifo_optimal_wrap #(
            .Depth        ( EnableCompute ? NumAxInFlight + ComputeFifoDepth : 32'd2 ),
    % else:
        // Atleast one write protocol uses combined aw and w -> Need to buffer read meta requests
        // As a write could depend on up to two reads
        cc_stream_fifo_optimal_wrap #(
            .Depth        ( 2                    ),
    % endif
            .data_t       (\
    % if one_write_port:
 write_meta_channel_t ),
    % else:
 write_meta_channel_tagged_t ),
    % endif
            .PrintInfo    ( PrintFifoInfo        )
        ) i_aw_fifo (
            .clk_i,
            .rst_ni,
            .clr_i     ( 1'b0                       ),
            .flush_i   ( 1'b0                       ),
            .usage_o   ( /* NOT CONNECTED */        ),
            .data_i    ( \
    % if one_write_port:
 w_req.aw_req              ),
    % else:
 w_meta_req_tagged         ),
    % endif
            .valid_i   ( w_valid && aw_ready        ),
            .ready_o   ( aw_ready                   ),
            .data_o    ( aw_req_dp                  ),
            .valid_o   ( aw_valid_dp                ),
            .ready_i   ( aw_ready_dp && aw_valid_dp )
        );
% else:
        // Add fall-through register to allow the input to be ready if the output is not. This
        // does not add a cycle of delay
        cc_fall_through_register #(
            .data_t     (\
    % if one_write_port:
 write_meta_channel_t        )
    % else:
 write_meta_channel_tagged_t )
    % endif
        ) i_aw_fall_through_register (
            .clk_i      ( clk_i             ),
            .rst_ni     ( rst_ni            ),
            .clr_i      ( 1'b0              ),
            .valid_i    ( w_valid           ),
            .ready_o    ( aw_ready          ),
            .data_i     (\
    % if one_write_port:
 w_req.aw_req      ),
    % else:
 w_meta_req_tagged ),
    % endif
            .valid_o    ( aw_valid_dp       ),
            .ready_i    ( aw_ready_dp       ),
            .data_o     ( aw_req_dp         )
        );
% endif

        // no unit: not busy
        assign busy_o.raw_coupler_busy = 1'b0;
    end


    //--------------------------------------
    // Assertions
    //--------------------------------------
    `IDMA_NONSYNTH_BLOCK(
    initial begin : proc_assert_params
        axi_addr_width : assert(AddrWidth >= 32'd12) else
            $fatal(1, "Parameter AddrWidth has to be >= 12!");
        axi_id_width   : assert(AxiIdWidth > 32'd0) else
            $fatal(1, "Parameter AxiIdWidth has to be > 0!");
        axi_data_width : assert(DataWidth inside {32'd16, 32'd32, 32'd64, 32'd128, 32'd256,
                                                  32'd512, 32'd1024}) else
            $fatal(1, "Parameter DataWidth has to be at least 16 and inside the AXI4 spec!");
        axi_user_width : assert(UserWidth > 32'd0) else
            $fatal(1, "Parameter UserWidth has to be > 0!");
        num_ax_in_flight : assert(NumAxInFlight > 32'd1) else
            $fatal(1, "Parameter NumAxInFlight has to be > 1!");
        buffer_depth : assert(BufferDepth > 32'd1) else
            $fatal(1, "Parameter BufferDepth has to be > 1!");
        tf_len_width : assert(TFLenWidth >= 32'd12) else
            $fatal(1, "Parameter BufferDepth has to be >= 12!");
        tf_len_width_max : assert(TFLenWidth <= AddrWidth) else
            $fatal(1, "Parameter TFLenWidth has to be <= AddrWidth!");
% if compute_eligible:
        compute_error_handling : assert(!EnableCompute || ErrorCap == idma_pkg::NO_ERROR_HANDLING) else
            $fatal(1, "EnableCompute requires ErrorCap == NO_ERROR_HANDLING!");
        compute_combined_shifter : assert(!EnableCompute || !CombinedShifter) else
            $fatal(1, "EnableCompute requires CombinedShifter == 0!");
        compute_mxfp16_width : assert(!EnableCompute || !ComputeOps.mxfp16 ||
                                      StrbWidth <= 32'd64) else
            $fatal(1, "ComputeMxFp16Width: MX FP16 requires StrbWidth <= 64!");
% endif
    end
    )

endmodule

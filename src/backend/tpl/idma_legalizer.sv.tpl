// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"
`include "idma/guard.svh"

/// Legalizes a generic 1D transfer according to the rules given by the
/// used protocol.
module idma_legalizer_${name_uniqueifier} #(
    /// Should both data shifts be done before the dataflow element?
    /// If this is enabled, then the data inserted into the dataflow element
    /// will no longer be word aligned, but only a single shifter is needed
    parameter bit          CombinedShifter = 1'b0,
    /// Data width
    parameter int unsigned DataWidth       = 32'd16,
    /// Address width
    parameter int unsigned AddrWidth       = 32'd24,
    /// 1D iDMA request type:
    /// - `length`: the length of the transfer in bytes
    /// - `*_addr`: the source / target byte addresses of the transfer
    /// - `opt`: the options field
    parameter type idma_req_t        = logic,
    /// Read request type
    parameter type idma_r_req_t      = logic,
    /// Write request type
    parameter type idma_w_req_t      = logic,
    /// Mutable transfer type
    parameter type idma_mut_tf_t     = logic,
    /// Mutable options type
    parameter type idma_mut_tf_opt_t = logic
)(
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,

    /// 1D request
    input  idma_req_t req_i,
    /// 1D request valid
    input  logic valid_i,
    /// 1D request ready
    output logic ready_o,

    /// Read request; contains datapath and meta information
    output idma_r_req_t r_req_o,
    /// Read request valid
    output logic r_valid_o,
    /// Read request ready
    input  logic r_ready_i,

    /// Write request; contains datapath and meta information
    output idma_w_req_t w_req_o,
    /// Write request valid
    output logic w_valid_o,
    /// Write request ready
    input  logic w_ready_i,

    /// Invalidate the current burst transfer, stops emission of requests
    input  logic flush_i,
    /// Kill the active 1D transfer; reload a new transfer
    input  logic kill_i,

    /// Read machine of the legalizer is busy
    output logic r_busy_o,
    /// Write machine of the legalizer is busy
    output logic w_busy_o
);
% if len(used_protocols) != 1:
    function int unsigned max_size(input int unsigned a, b);
        return a > b ? a : b;
    endfunction

% endif
    /// Stobe width
    localparam int unsigned StrbWidth     = DataWidth / 8;
    /// Offset width
    localparam int unsigned OffsetWidth   = $clog2(StrbWidth);
    /// The size of a page in byte
    localparam int unsigned PageSize      = \
% if len(used_protocols) == 1:
    % if database[used_protocols[0]]['bursts'] == 'not_supported':
StrbWidth;
    % elif database[used_protocols[0]]['bursts'] == 'only_pow2':
${database[used_protocols[0]]['page_size']};
    % elif database[used_protocols[0]]['bursts'] == 'split_at_page_boundary':
${database[used_read_protocols[0]]['max_beats_per_burst']} * StrbWidth > ${database[used_protocols[0]]['page_size']}\
 ? ${database[used_protocols[0]]['page_size']} : ${database[used_read_protocols[0]]['max_beats_per_burst']} * StrbWidth;
    % endif
% else:
        % for index, p in enumerate(used_protocols):
            % if index < len(used_protocols)-1:
max_size(\
    % if database[p]['bursts'] == 'not_supported':
StrbWidth\
    % elif database[p]['bursts'] == 'only_pow2':
${database[p]['page_size']}\
    % elif database[p]['bursts'] == 'split_at_page_boundary':
${database[p]['max_beats_per_burst']} * StrbWidth > ${database[p]['page_size']}\
 ? ${database[p]['page_size']} : ${database[p]['max_beats_per_burst']} * StrbWidth\
    % endif
, \
            % else:
    % if database[p]['bursts'] == 'not_supported':
StrbWidth\
    % elif database[p]['bursts'] == 'only_pow2':
${database[p]['page_size']}\
    % elif database[p]['bursts'] == 'split_at_page_boundary':
${database[p]['max_beats_per_burst']} * StrbWidth > ${database[p]['page_size']}\
 ? ${database[p]['page_size']} : ${database[p]['max_beats_per_burst']} * StrbWidth\
    % endif
            % endif
        % endfor
        % for i in range(0, len(used_protocols)-1):
)\
        % endfor
;
% endif
    /// The width of page offset byte addresses
    localparam int unsigned PageAddrWidth = $clog2(PageSize);

    /// Offset type
    typedef logic [  OffsetWidth-1:0] offset_t;
    /// Address type
    typedef logic [    AddrWidth-1:0] addr_t;
    /// Page address type
    typedef logic [PageAddrWidth-1:0] page_addr_t;
    /// Page length type
    typedef logic [  PageAddrWidth:0] page_len_t;


    // state: internally hold one transfer, this is mutated
    idma_mut_tf_t     r_tf_d,   r_tf_q;
    idma_mut_tf_t     w_tf_d,   w_tf_q;
    idma_mut_tf_opt_t opt_tf_d, opt_tf_q;

    // enable signals for next mutable transfer storage
    logic r_tf_ena;
    logic w_tf_ena;

    // page boundaries
% if no_read_bursting or has_page_read_bursting:
    page_len_t r_page_num_bytes_to_pb;
% endif
% for read_protocol in used_read_protocols:
    % if database[read_protocol]['bursts'] == 'only_pow2':
    page_len_t r_${database[read_protocol]['prefix']}_num_bytes_to_pb;
    % endif
% endfor
    page_len_t r_num_bytes_to_pb;
% if no_write_bursting or has_page_write_bursting:
    page_len_t w_page_num_bytes_to_pb;
% endif
% for write_protocol in used_write_protocols:
    % if database[write_protocol]['bursts'] == 'only_pow2':
    page_len_t w_${database[write_protocol]['prefix']}_num_bytes_to_pb;
    % endif
% endfor
    page_len_t w_num_bytes_to_pb;
    page_len_t c_num_bytes_to_pb;

    // read process
    page_len_t r_num_bytes_possible;
    page_len_t r_num_bytes;
    offset_t   r_addr_offset;
    logic      r_done;

    // write process
    page_len_t w_num_bytes_possible;
    page_len_t w_num_bytes;
    offset_t   w_addr_offset;
    logic      w_done;


    //--------------------------------------
    // read boundary check
    //--------------------------------------
% if no_read_bursting or has_page_read_bursting:
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth   ),
        .PageAddrWidth ( PageAddrWidth ),
        .addr_t        ( addr_t        ),
        .page_len_t    ( page_len_t    ),
        .page_addr_t   ( page_addr_t   )
    ) i_read_page_splitter (
    % if no_read_bursting:
        .not_bursting_i    ( 1'b1 ),
    % elif len(used_non_bursting_read_protocols) == 0:
        .not_bursting_i    ( 1'b0 ),
    % else:
        .not_bursting_i    ( opt_tf_q.src_protocol inside {\
        % for index, protocol in enumerate(used_non_bursting_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
            % if index != len(used_non_bursting_read_protocols)-1:
,\
            % endif
        % endfor       
} ),
    % endif

        .reduce_len_i      ( opt_tf_q.src_reduce_len ),
        .max_llen_i        ( opt_tf_q.src_max_llen   ),

        .addr_i            ( r_tf_q.addr             ),
        .num_bytes_to_pb_o ( r_page_num_bytes_to_pb  )
    );

% endif
% for read_protocol in used_read_protocols:
    % if database[read_protocol]['bursts'] == 'only_pow2':
    idma_legalizer_pow2_splitter #(
        .PageAddrWidth ( $clog2(${database[read_protocol]['page_size']}) ),
        .OffsetWidth   ( OffsetWidth ),
        .addr_t        ( addr_t      ),
        .len_t         ( page_len_t  )
    ) i_read_pow2_splitter ( 
        .addr_i              ( r_tf_q.addr ),
        .length_i            ( \
        % if database[read_protocol]['tltoaxi4_compatibility_mode'] == "true":
|r_tf_q.length[$bits(r_tf_q.length)-1:PageAddrWidth] ? page_len_t'('d${database[read_protocol]['page_size']} - r_tf_q.addr[PageAddrWidth-1:0]) : r_tf_q.length[PageAddrWidth:0] ),
        .length_larger_i     ( 1'b0 ),
        % else:
r_tf_q.length[PageAddrWidth:0] ),
        .length_larger_i     ( |r_tf_q.length[$bits(r_tf_q.length)-1:PageAddrWidth+1] ),
        % endif
        .bytes_to_transfer_o ( r_${database[read_protocol]['prefix']}_num_bytes_to_pb )
    );

    % endif
% endfor
% if one_read_port:
    % if has_pow2_read_bursting:
    assign r_num_bytes_to_pb = r_${database[used_read_protocols[0]]['prefix']}_num_bytes_to_pb;
    % else:
    assign r_num_bytes_to_pb = r_page_num_bytes_to_pb;
    % endif
% else:
    always_comb begin : gen_read_num_bytes_to_pb_logic
        case (opt_tf_q.src_protocol)
    % for read_protocol in used_read_protocols:
        idma_pkg::${database[read_protocol]['protocol_enum']}: \
        % if database[read_protocol]['bursts'] == 'only_pow2':
r_num_bytes_to_pb = r_${database[read_protocol]['prefix']}_num_bytes_to_pb;
        % else:
r_num_bytes_to_pb = r_page_num_bytes_to_pb;
        % endif
    % endfor
        default: r_num_bytes_to_pb = '0;
        endcase
    end
% endif

    //--------------------------------------
    // write boundary check
    //--------------------------------------
% if no_write_bursting or has_page_write_bursting:
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth   ),
        .PageAddrWidth ( PageAddrWidth ),
        .addr_t        ( addr_t        ),
        .page_len_t    ( page_len_t    ),
        .page_addr_t   ( page_addr_t   )
    ) i_write_page_splitter (
    % if no_write_bursting:
        .not_bursting_i    ( 1'b1 ),
    % elif len(used_non_bursting_write_protocols) == 0:
        .not_bursting_i    ( 1'b0 ),
    % else:
        .not_bursting_i    ( opt_tf_q.dst_protocol inside {\
        % for index, protocol in enumerate(used_non_bursting_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
            % if index != len(used_non_bursting_write_protocols)-1:
,\
            % endif
        % endfor       
} ),
    % endif

        .reduce_len_i      ( opt_tf_q.dst_reduce_len ),
        .max_llen_i        ( opt_tf_q.dst_max_llen   ),

        .addr_i            ( w_tf_q.addr             ),
        .num_bytes_to_pb_o ( w_page_num_bytes_to_pb  )
    );

% endif
% for write_protocol in used_write_protocols:
    % if database[write_protocol]['bursts'] == 'only_pow2':
    idma_legalizer_pow2_splitter #(
        .PageAddrWidth ( \
% if database[write_protocol]['tltoaxi4_compatibility_mode'] == "true":
$clog2((32 * StrbWidth) > ${database[write_protocol]['page_size']} ? ${database[write_protocol]['page_size']} : (32 * StrbWidth)) ),
% else:
$clog2(${database[write_protocol]['page_size']}) ),
% endif
        .OffsetWidth   ( OffsetWidth ),
        .addr_t        ( addr_t      ),
        .len_t         ( page_len_t  )
    ) i_write_pow2_splitter ( 
        .addr_i              ( w_tf_q.addr ),
        .length_i            ( \
        % if database[write_protocol]['tltoaxi4_compatibility_mode'] == "true":
|w_tf_q.length[$bits(w_tf_q.length)-1:PageAddrWidth] ? page_len_t'('d${database[write_protocol]['page_size']} - w_tf_q.addr[PageAddrWidth-1:0]) : w_tf_q.length[PageAddrWidth:0] ),
        .length_larger_i     ( 1'b0 ),
        % else:
w_tf_q.length[PageAddrWidth:0] ),
        .length_larger_i     ( |w_tf_q.length[$bits(w_tf_q.length)-1:PageAddrWidth+1] ),
        % endif
        .bytes_to_transfer_o ( w_${database[write_protocol]['prefix']}_num_bytes_to_pb )
    );

    % endif
% endfor
% if one_write_port:
    % if has_pow2_write_bursting:
    assign w_num_bytes_to_pb = w_${database[used_write_protocols[0]]['prefix']}_num_bytes_to_pb;
    % else:
    assign w_num_bytes_to_pb = w_page_num_bytes_to_pb;
    % endif
% else:
    always_comb begin : gen_write_num_bytes_to_pb_logic
        case (opt_tf_q.dst_protocol)
    % for write_protocol in used_write_protocols:
        idma_pkg::${database[write_protocol]['protocol_enum']}: \
        % if database[write_protocol]['bursts'] == 'only_pow2':
w_num_bytes_to_pb = w_${database[write_protocol]['prefix']}_num_bytes_to_pb;
        % else:
w_num_bytes_to_pb = w_page_num_bytes_to_pb;
        % endif
    % endfor
        default: w_num_bytes_to_pb = '0;
        endcase
    end
% endif

    //--------------------------------------
    // page boundary check
    //--------------------------------------
    // how many transfers are remaining when concerning both r/w pages?
    // take the boundary that is closer
    assign c_num_bytes_to_pb = (r_num_bytes_to_pb > w_num_bytes_to_pb) ?
                                w_num_bytes_to_pb : r_num_bytes_to_pb;


    //--------------------------------------
    // Synchronized R/W process
    //--------------------------------------
    always_comb begin : proc_num_bytes_possible
        // Default: Coupled
        r_num_bytes_possible = c_num_bytes_to_pb;
        w_num_bytes_possible = c_num_bytes_to_pb;

        if (opt_tf_q.decouple_rw\
    % if len(used_non_bursting_or_force_decouple_read_protocols) != 0:

            || (opt_tf_q.src_protocol inside {\
        % for index, protocol in enumerate(used_non_bursting_or_force_decouple_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
            % if index != len(used_non_bursting_or_force_decouple_read_protocols)-1:
,\
            % endif
        % endfor 
 })\
    % endif
    % if len(used_non_bursting_or_force_decouple_write_protocols) != 0:

            || (opt_tf_q.dst_protocol inside {\
        % for index, protocol in enumerate(used_non_bursting_or_force_decouple_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
            % if index != len(used_non_bursting_or_force_decouple_write_protocols)-1:
,\
            % endif
        % endfor 
 })\
    % endif
) begin
            r_num_bytes_possible = r_num_bytes_to_pb;
            w_num_bytes_possible = w_num_bytes_to_pb;
        end
    end

    assign r_addr_offset = r_tf_q.addr[OffsetWidth-1:0];
    assign w_addr_offset = w_tf_q.addr[OffsetWidth-1:0];

    // legalization process -> read and write is coupled together
    always_comb begin : proc_read_write_transaction

        // default: keep state
        r_tf_d   = r_tf_q;
        w_tf_d   = w_tf_q;
        opt_tf_d = opt_tf_q;

        // default: not done
        r_done = 1'b0;
        w_done = 1'b0;

        //--------------------------------------
        // Legalize read transaction
        //--------------------------------------
        // more bytes remaining than we can read
        if (r_tf_q.length > r_num_bytes_possible) begin
            r_num_bytes = r_num_bytes_possible;
            // calculate remainder
            r_tf_d.length = r_tf_q.length - r_num_bytes_possible;
            // next address
            r_tf_d.addr = r_tf_q.addr + r_num_bytes;

        // remaining bytes fit in one burst
        end else begin
            r_num_bytes = r_tf_q.length[PageAddrWidth:0];
            // finished
            r_tf_d.valid = 1'b0;
            r_done = 1'b1;
        end

        //--------------------------------------
        // Legalize write transaction
        //--------------------------------------
        // more bytes remaining than we can write
        if (w_tf_q.length > w_num_bytes_possible) begin
            w_num_bytes = w_num_bytes_possible;
            // calculate remainder
            w_tf_d.length = w_tf_q.length - w_num_bytes_possible;
            // next address
            w_tf_d.addr = w_tf_q.addr + w_num_bytes;

        // remaining bytes fit in one burst
        end else begin
            w_num_bytes = w_tf_q.length[PageAddrWidth:0];
            // finished
            w_tf_d.valid = 1'b0;
            w_done = 1'b1;
        end

        //--------------------------------------
        // Kill
        //--------------------------------------
        if (kill_i) begin
            // kill the current state
            r_tf_d = '0;
            w_tf_d = '0;
            r_done = 1'b1;
            w_done = 1'b1;
        end

        //--------------------------------------
        // Refill
        //--------------------------------------
        // new request is taken in if both r and w machines are ready.
        if (ready_o & valid_i) begin

            // load all three mutable objects (source, destination, option)
            // source or read
            r_tf_d = '{
                length: req_i.length,
                addr:   req_i.src_addr,
                valid:   1'b1,
                base_addr: req_i.src_addr
            };
            // destination or write
            w_tf_d = '{
                length: req_i.length,
                addr:   req_i.dst_addr,
                valid:   1'b1,
                base_addr: req_i.dst_addr
            };
            // options
            opt_tf_d = '{
                src_protocol:   req_i.opt.src_protocol,
                dst_protocol:   req_i.opt.dst_protocol,
                read_shift:     '0,
                write_shift:    '0,
                decouple_rw:    req_i.opt.beo.decouple_rw,
                decouple_aw:    req_i.opt.beo.decouple_aw,
                src_max_llen:   req_i.opt.beo.src_max_llen,
                dst_max_llen:   req_i.opt.beo.dst_max_llen,
                src_reduce_len: req_i.opt.beo.src_reduce_len,
                dst_reduce_len: req_i.opt.beo.dst_reduce_len,
                axi_id:         req_i.opt.axi_id,
                src_axi_opt:    req_i.opt.src,
                dst_axi_opt:    req_i.opt.dst,
                super_last:     req_i.opt.last
            };
            // determine shift amount
            if (CombinedShifter) begin
                opt_tf_d.read_shift  = req_i.src_addr[OffsetWidth-1:0] -
                                       req_i.dst_addr[OffsetWidth-1:0];
                opt_tf_d.write_shift = '0;
            end else begin
                opt_tf_d.read_shift  =   req_i.src_addr[OffsetWidth-1:0];
                opt_tf_d.write_shift = - req_i.dst_addr[OffsetWidth-1:0];
            end
        end
    end


    //--------------------------------------
    // Connect outputs
    //--------------------------------------

    // Read meta channel
% if one_read_port:
    always_comb begin
${database[used_read_protocols[0]]['legalizer_read_meta_channel']}
    end
% else:
    always_comb begin : gen_read_meta_channel
        r_req_o.ar_req = '0;
        case(opt_tf_q.src_protocol)
    % for protocol in used_read_protocols:
        idma_pkg::${database[protocol]['protocol_enum']}: begin
${database[protocol]['legalizer_read_meta_channel']}
        end
    % endfor
        default:
            r_req_o.ar_req = '0;
        endcase
    end
% endif

    // assign the signals needed to set-up the read data path
    assign r_req_o.r_dp_req = '{
        src_protocol: opt_tf_q.src_protocol,
        offset:       r_addr_offset,
        tailer:       OffsetWidth'(r_num_bytes + r_addr_offset),
        shift:        opt_tf_q.read_shift,
        decouple_aw:  opt_tf_q.decouple_aw,
        is_single:    r_num_bytes <= StrbWidth
    };

    // Write meta channel and data path
% if one_write_port:
    always_comb begin
${database[used_write_protocols[0]]['legalizer_write_meta_channel']}
    % if 'legalizer_write_data_path' in database[used_write_protocols[0]]:
${database[used_write_protocols[0]]['legalizer_write_data_path']}
    % else:
        w_req_o.w_dp_req = '{
            dst_protocol: opt_tf_q.dst_protocol,
            offset:       w_addr_offset,
            tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
            shift:        opt_tf_q.write_shift,
            num_beats:    'd0,
            is_single:    1'b1
        };
    % endif
    end
% else:
    always_comb begin : gen_write_meta_channel
        w_req_o.aw_req = '0;
        case(opt_tf_q.dst_protocol)
    % for protocol in used_write_protocols:
        idma_pkg::${database[protocol]['protocol_enum']}: begin
${database[protocol]['legalizer_write_meta_channel']}
        end
    % endfor
        default:
            w_req_o.aw_req = '0;
        endcase
    end

    // assign the signals needed to set-up the write data path
    always_comb begin : gen_write_data_path
        case (opt_tf_q.dst_protocol)
        % for protocol in used_write_protocols:
            % if 'legalizer_write_data_path' in database[protocol]:
        idma_pkg::${database[protocol]['protocol_enum']}:
${database[protocol]['legalizer_write_data_path']}
            % endif
        % endfor
        default:
            w_req_o.w_dp_req = '{
                dst_protocol: opt_tf_q.dst_protocol,
                offset:       w_addr_offset,
                tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
                shift:        opt_tf_q.write_shift,
                num_beats:    'd0,
                is_single:    1'b1
            };
        endcase
    end

% endif

    // last burst in generic 1D transfer?
    assign w_req_o.last = w_done;

    // last burst indicated by midend
    assign w_req_o.super_last = opt_tf_q.super_last;

    // assign aw decouple flag
    assign w_req_o.decouple_aw = opt_tf_q.decouple_aw;

    // busy output
    assign r_busy_o = r_tf_q.valid;
    assign w_busy_o = w_tf_q.valid;


    //--------------------------------------
    // Flow Control
    //--------------------------------------
    // only advance to next state if:
    // * rw_coupled: both machines advance
    // * rw_decoupled: either machine advances

    always_comb begin : proc_legalizer_flow_control
        if ( opt_tf_q.decouple_rw\
        % if len(used_non_bursting_or_force_decouple_read_protocols) != 0:

            || (opt_tf_q.src_protocol inside {\
            % for index, protocol in enumerate(used_non_bursting_or_force_decouple_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
                % if index != len(used_non_bursting_or_force_decouple_read_protocols)-1:
,\
                % endif
            % endfor 
 })\
        % endif
        % if len(used_non_bursting_or_force_decouple_write_protocols) != 0:

            || (opt_tf_q.dst_protocol inside {\
            % for index, protocol in enumerate(used_non_bursting_or_force_decouple_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
                % if index != len(used_non_bursting_or_force_decouple_write_protocols)-1:
,\
                % endif
            % endfor 
 })\
        % endif       
) begin
            r_tf_ena  = (r_ready_i & !flush_i) | kill_i;
            w_tf_ena  = (w_ready_i & !flush_i) | kill_i;

            r_valid_o = r_tf_q.valid & r_ready_i & !flush_i;
            w_valid_o = w_tf_q.valid & w_ready_i & !flush_i;
        end else begin
            r_tf_ena  = (r_ready_i & w_ready_i & !flush_i) | kill_i;
            w_tf_ena  = (r_ready_i & w_ready_i & !flush_i) | kill_i;

            r_valid_o = r_tf_q.valid & w_ready_i & r_ready_i & !flush_i;
            w_valid_o = w_tf_q.valid & r_ready_i & w_ready_i & !flush_i;
        end
    end

    // load next idma request: if both machines are done!
    assign ready_o = r_done & w_done & r_ready_i & w_ready_i & !flush_i;


    //--------------------------------------
    // State
    //--------------------------------------
    `FF (opt_tf_q, opt_tf_d,           '0, clk_i, rst_ni)
    `FFL(r_tf_q,   r_tf_d,   r_tf_ena, '0, clk_i, rst_ni)
    `FFL(w_tf_q,   w_tf_d,   w_tf_ena, '0, clk_i, rst_ni)


    //--------------------------------------
    // Assertions
    //--------------------------------------
    // only support the decomposition of incremental bursts
    `ASSERT_NEVER(OnlyIncrementalBurstsSRC, (ready_o & valid_i &
                  req_i.opt.src.burst != axi_pkg::BURST_INCR), clk_i, !rst_ni)
    `ASSERT_NEVER(OnlyIncrementalBurstsDST, (ready_o & valid_i &
                  req_i.opt.dst.burst != axi_pkg::BURST_INCR), clk_i, !rst_ni)

endmodule

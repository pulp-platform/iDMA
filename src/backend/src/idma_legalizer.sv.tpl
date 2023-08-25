// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Thomas Benz  <tbenz@ethz.ch>
// Tobias Senti <tsenti@student.ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"
`include "idma/guard.svh"

/// Legalizes a generic 1D transfer according to the rules given by the
/// used protocol.
module idma_legalizer${name_uniqueifier} #(
    /// Data width
    parameter int unsigned DataWidth = 32'd16,
    /// Address width
    parameter int unsigned AddrWidth = 32'd24,
    /// 1D iDMA request type:
    /// - `length`: the length of the transfer in bytes
    /// - `*_addr`: the source / target byte addresses of the transfer
    /// - `opt`: the options field
    parameter type idma_req_t = logic,
    /// Read request type
    parameter type idma_r_req_t = logic,
    /// Write request type
    parameter type idma_w_req_t = logic,
    /// Mutable transfer type
    parameter type idma_mut_tf_t = logic,
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
    page_len_t  r_num_bytes_to_pb;
    page_len_t  w_num_bytes_to_pb;
    page_len_t  c_num_bytes_to_pb;

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
% if one_read_port:
    % if database[used_read_protocols[0]]['bursts'] == 'not_supported':
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth ),
        .PageAddrWidth ( PageSize    ),
        .addr_t        ( addr_t      ),
        .page_len_t    ( page_len_t  ),
        .page_addr_t   ( page_addr_t )
    ) i_read_page_splitter (
        .not_bursting_i    ( 1'b1                    ),

        .reduce_len_i      ( opt_tf_q.src_reduce_len ),
        .max_llen_i        ( opt_tf_q.src_max_llen   ),
        
        .addr_i            ( r_tf_q.addr             ),
        .num_bytes_to_pb_o ( r_num_bytes_to_pb       )
    );
    % elif database[used_read_protocols[0]]['bursts'] == 'split_at_page_boundary':
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth ),
        .PageAddrWidth ( $clog2((${database[used_read_protocols[0]]['max_beats_per_burst']} * StrbWidth\
 > ${database[used_read_protocols[0]]['page_size']}) ?\
 ${database[used_read_protocols[0]]['page_size']} :\
 ${database[used_read_protocols[0]]['max_beats_per_burst']} * StrbWidth) ),
        .addr_t        ( addr_t      ),
        .page_len_t    ( page_len_t  ),
        .page_addr_t   ( page_addr_t )
    ) i_read_page_splitter (
        .not_bursting_i    ( 1'b0                    ),
        .reduce_len_i      ( opt_tf_q.src_reduce_len ),
        .max_llen_i        ( opt_tf_q.src_max_llen   ),
        
        .addr_i            ( r_tf_q.addr             ),
        .num_bytes_to_pb_o ( r_num_bytes_to_pb       )
    );
    % elif database[used_read_protocols[0]]['bursts'] == 'only_pow2':
    idma_legalizer_pow2_splitter #(
        .PageAddrWidth ( $clog2(${database[used_read_protocols[0]]['page_size']}) ),
        .OffsetWidth   ( OffsetWidth   ),
        .addr_t        ( addr_t        ),
        .len_t         ( page_len_t    )
    ) i_read_pow2_splitter ( 
        .addr_i              ( r_tf_q.addr       ),
        .length_i            ( \
% if database[used_read_protocols[0]]['tltoaxi4_compatibility_mode'] == "true":
|r_tf_q.length[$bits(r_tf_q.length)-1:PageAddrWidth] ? page_len_t'('d${database[used_read_protocols[0]]['page_size']} - r_tf_q.addr[PageAddrWidth-1:0]) : r_tf_q.length[PageAddrWidth:0] ),
        .length_larger_i     ( 1'b0 ),
% else:
r_tf_q.length[PageAddrWidth:0] ),
        .length_larger_i     ( |r_tf_q.length[$bits(r_tf_q.length)-1:PageAddrWidth+1] ),
% endif
        .bytes_to_transfer_o ( r_num_bytes_to_pb )
    );
    % else:
    `IDMA_NONSYNTH_BLOCK(
    initial begin
        $fatal(1, "bursts value '${database[used_read_protocols[0]]['bursts']}' for read protocol ${database[used_read_protocols[0]]['full_name']} not implemented in template!");
    end
    )
    assign r_page_addr_width = '0;
    % endif
% elif no_read_bursting:
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth ),
        .PageAddrWidth ( PageSize    ),
        .addr_t        ( addr_t      ),
        .page_len_t    ( page_len_t  ),
        .page_addr_t   ( page_addr_t )
    ) i_read_page_splitter (
        .not_bursting_i    ( 1'b1                    ),

        .reduce_len_i      ( opt_tf_q.src_reduce_len ),
        .max_llen_i        ( opt_tf_q.src_max_llen   ),
        
        .addr_i            ( r_tf_q.addr             ),
        .num_bytes_to_pb_o ( r_num_bytes_to_pb       )
    );
% else:
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth ),
        .PageAddrWidth ( PageSize    ),
        .addr_t        ( addr_t      ),
        .page_len_t    ( page_len_t  ),
        .page_addr_t   ( page_addr_t )
    ) i_read_page_splitter (
        .not_bursting_i    ( opt_tf_q.src_protocol inside {\
    % for index, protocol in enumerate(used_non_bursting_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
        % if index != len(used_non_bursting_read_protocols)-1:
,\
        % endif
    % endfor       
} ),

        .reduce_len_i      ( opt_tf_q.src_reduce_len ),
        .max_llen_i        ( opt_tf_q.src_max_llen   ),
        
        .addr_i            ( r_tf_q.addr             ),
        .num_bytes_to_pb_o ( r_num_bytes_to_pb       )
    );
% endif

    //--------------------------------------
    // write boundary check
    //--------------------------------------
% if one_write_port:
    % if database[used_write_protocols[0]]['bursts'] == 'not_supported':
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth ),
        .PageAddrWidth ( PageSize    ),
        .addr_t        ( addr_t      ),
        .page_len_t    ( page_len_t  ),
        .page_addr_t   ( page_addr_t )
    ) i_write_page_splitter (
        .not_bursting_i    ( 1'b1                    ),

        .reduce_len_i      ( opt_tf_q.dst_reduce_len ),
        .max_llen_i        ( opt_tf_q.dst_max_llen   ),
        
        .addr_i            ( w_tf_q.addr             ),
        .num_bytes_to_pb_o ( w_num_bytes_to_pb       )
    );
    % elif database[used_write_protocols[0]]['bursts'] == 'split_at_page_boundary':
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth ),
        .PageAddrWidth ( $clog2((${database[used_write_protocols[0]]['max_beats_per_burst']} * StrbWidth\
 > ${database[used_write_protocols[0]]['page_size']}) ?\
 ${database[used_write_protocols[0]]['page_size']} :\
 ${database[used_write_protocols[0]]['max_beats_per_burst']} * StrbWidth) ),
        .addr_t        ( addr_t      ),
        .page_len_t    ( page_len_t  ),
        .page_addr_t   ( page_addr_t )
    ) i_write_page_splitter (
        .not_bursting_i    ( 1'b0                    ),
        .reduce_len_i      ( opt_tf_q.dst_reduce_len ),
        .max_llen_i        ( opt_tf_q.dst_max_llen   ),
        
        .addr_i            ( w_tf_q.addr             ),
        .num_bytes_to_pb_o ( w_num_bytes_to_pb       )
    );
    % elif database[used_write_protocols[0]]['bursts'] == 'only_pow2':
    idma_legalizer_pow2_splitter #(
        .PageAddrWidth ( \
% if database[used_write_protocols[0]]['tltoaxi4_compatibility_mode'] == "true":
$clog2((32 * StrbWidth) > ${database[used_write_protocols[0]]['page_size']} ? ${database[used_write_protocols[0]]['page_size']} : (32 * StrbWidth)) ),
% else:
$clog2(${database[used_write_protocols[0]]['page_size']}) ),
% endif
        .OffsetWidth   ( OffsetWidth   ),
        .addr_t        ( addr_t        ),
        .len_t         ( page_len_t    )
    ) i_write_pow2_splitter ( 
        .addr_i              ( w_tf_q.addr       ),
        .length_i            ( \
% if database[used_write_protocols[0]]['tltoaxi4_compatibility_mode'] == "true":
|w_tf_q.length[$bits(w_tf_q.length)-1:PageAddrWidth] ? page_len_t'('d${database[used_write_protocols[0]]['page_size']} - w_tf_q.addr[PageAddrWidth-1:0]) : w_tf_q.length[PageAddrWidth:0] ),
        .length_larger_i     ( 1'b0 ),
% else:
w_tf_q.length[PageAddrWidth:0] ),
        .length_larger_i     ( |w_tf_q.length[$bits(w_tf_q.length)-1:PageAddrWidth+1] ),
% endif
        .bytes_to_transfer_o ( w_num_bytes_to_pb )
    ); 
    % else:
    `IDMA_NONSYNTH_BLOCK(
    initial begin
        $fatal(1, "bursts value '${database[used_write_protocols[0]]['bursts']}' for write protocol ${database[used_write_protocols[0]]['full_name']} not implemented in template!");
    end
    )
    assign w_page_addr_width = '0;
    % endif
% elif no_write_bursting:
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth ),
        .PageAddrWidth ( PageSize    ),
        .addr_t        ( addr_t      ),
        .page_len_t    ( page_len_t  ),
        .page_addr_t   ( page_addr_t )
    ) i_write_page_splitter (
        .not_bursting_i    ( 1'b1                    ),

        .reduce_len_i      ( opt_tf_q.dst_reduce_len ),
        .max_llen_i        ( opt_tf_q.dst_max_llen   ),
        
        .addr_i            ( w_tf_q.addr             ),
        .num_bytes_to_pb_o ( w_num_bytes_to_pb       )
    );
% else:
    idma_legalizer_page_splitter #(
        .OffsetWidth   ( OffsetWidth ),
        .PageAddrWidth ( PageSize    ),
        .addr_t        ( addr_t      ),
        .page_len_t    ( page_len_t  ),
        .page_addr_t   ( page_addr_t )
    ) i_write_page_splitter (
        .not_bursting_i    ( opt_tf_q.dst_protocol inside {\
    % for index, protocol in enumerate(used_non_bursting_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
        % if index != len(used_non_bursting_write_protocols)-1:
,\
        % endif
    % endfor       
} ),

        .reduce_len_i      ( opt_tf_q.dst_reduce_len ),
        .max_llen_i        ( opt_tf_q.dst_max_llen   ),
        
        .addr_i            ( w_tf_q.addr             ),
        .num_bytes_to_pb_o ( w_num_bytes_to_pb       )
    );
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
% if one_read_port and one_write_port:
    % if (no_read_bursting or no_write_bursting) or ('tilelink' in used_protocols):
    assign r_num_bytes_possible = r_num_bytes_to_pb;
    assign w_num_bytes_possible = w_num_bytes_to_pb;
    % else:
    assign r_num_bytes_possible = opt_tf_q.decouple_rw ?
                                  r_num_bytes_to_pb : c_num_bytes_to_pb;
    assign w_num_bytes_possible = opt_tf_q.decouple_rw ?
                                  w_num_bytes_to_pb : c_num_bytes_to_pb;
    % endif
% else:
    % if no_read_bursting and no_write_bursting:
    // No Bursting at all
    assign r_num_bytes_possible = opt_tf_q.decouple_rw ?
                                  r_num_bytes_to_pb : c_num_bytes_to_pb;
    assign w_num_bytes_possible = opt_tf_q.decouple_rw ?
                                  w_num_bytes_to_pb : c_num_bytes_to_pb;
    % elif no_read_bursting and (not no_write_bursting):
    // Only write bursts possible
    assign r_num_bytes_possible = r_num_bytes_to_pb;
    assign w_num_bytes_possible = (opt_tf_q.decouple_rw || (opt_tf_q.dst_protocol inside {\
        % for index, protocol in enumerate(used_non_bursting_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
            % if index != len(used_non_bursting_write_protocols)-1:
,\
            % endif
        % endfor       
 })) ?
                                  w_num_bytes_to_pb : c_num_bytes_to_pb;
    % elif (not no_read_bursting) and no_write_bursting: 
    // Only read bursts possible
    assign w_num_bytes_possible = w_num_bytes_to_pb;
    assign r_num_bytes_possible = (opt_tf_q.decouple_rw || (opt_tf_q.src_protocol inside {\
        % for index, protocol in enumerate(used_non_bursting_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
            % if index != len(used_non_bursting_read_protocols)-1:
,\
            % endif
        % endfor       
 })) ?
                                  r_num_bytes_to_pb : c_num_bytes_to_pb;
    % else:
    // Both read and write bursts possible
    always_comb begin
        r_num_bytes_possible = c_num_bytes_to_pb;
        w_num_bytes_possible = c_num_bytes_to_pb;

        if ( opt_tf_q.decouple_rw\
    % if len(used_non_bursting_read_protocols) != 0:

            || (opt_tf_q.src_protocol inside {\
        % for index, protocol in enumerate(used_non_bursting_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
            % if index != len(used_non_bursting_read_protocols)-1:
,\
            % endif
        % endfor 
 })\
    % endif
    % if len(used_non_bursting_write_protocols) != 0:

            || (opt_tf_q.dst_protocol inside {\
        % for index, protocol in enumerate(used_non_bursting_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
            % if index != len(used_non_bursting_write_protocols)-1:
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
    % endif
% endif

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
            r_tf_d =  '0;
            r_done = 1'b1;
            w_tf_d =  '0;
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
% if combined_shifter:
                read_shift:     req_i.src_addr[OffsetWidth-1:0] - req_i.dst_addr[OffsetWidth-1:0],
                write_shift:    '0,
% else:
                read_shift:     req_i.src_addr[OffsetWidth-1:0],
                write_shift:  - req_i.dst_addr[OffsetWidth-1:0],
% endif
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
        end
    end


    //--------------------------------------
    // Connect outputs
    //--------------------------------------
% if one_read_port:
    always_comb begin
${database[used_read_protocols[0]]['legalizer_read_meta_channel']}
    end
% else:
    always_comb begin : gen_read_meta_channel
        r_req_o.ar_req = '0;
        case(opt_tf_q.src_protocol)
    % for protocol in used_read_protocols:
        idma_pkg::${database[protocol]['protocol_enum']}:
        % if protocol == 'tilelink':
            r_req_o.ar_req.tilelink.a_chan = '{
                opcode:  3'd4,
                param:   3'd0,
                size:    OffsetWidth, // Why is this different than one_read_port version?
                source:  opt_tf_q.axi_id,
                address: { r_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
                mask:    '1,
                data:    '0,
                corrupt: 1'b0
            };

        % else:
${database[protocol]['legalizer_read_meta_channel']}
        % endif
    % endfor
        default:
            r_req_o.ar_req = '0;
        endcase
    end
% endif

% if one_write_port:
    % if 'axi' in used_write_protocols: 
    assign w_req_o.aw_req.axi.aw_chan = '{
        id:     opt_tf_q.axi_id,
        addr:   { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
        len:    ((w_num_bytes + w_addr_offset - 'd1) >> OffsetWidth),
        size:   axi_pkg::size_t'(OffsetWidth),
        burst:  opt_tf_q.dst_axi_opt.burst,
        lock:   opt_tf_q.dst_axi_opt.lock,
        cache:  opt_tf_q.dst_axi_opt.cache,
        prot:   opt_tf_q.dst_axi_opt.prot,
        qos:    opt_tf_q.dst_axi_opt.qos,
        region: opt_tf_q.dst_axi_opt.region,
        user:   '0,
        atop:   '0
    };
    assign w_req_o.w_dp_req = '{
        dst_protocol: opt_tf_q.dst_protocol,
        offset:       w_addr_offset,
        tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
        shift:        opt_tf_q.write_shift,
        num_beats:    w_req_o.aw_req.axi.aw_chan.len,
        is_single:    w_req_o.aw_req.axi.aw_chan.len == '0
    };
    % elif 'axi_lite' in used_write_protocols:
    assign w_req_o.aw_req.axi_lite.aw_chan = '{
        addr:   { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
        prot:   opt_tf_q.dst_axi_opt.prot
    };

    assign w_req_o.w_dp_req = '{
        dst_protocol: opt_tf_q.dst_protocol,
        offset:       w_addr_offset,
        tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
        shift:        opt_tf_q.write_shift,
        num_beats:    'd0,
        is_single:    1'b1
    };
    % elif 'obi' in used_write_protocols:
    assign w_req_o.aw_req.obi.a_chan = '{
        addr:   { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
        be:     '0,
        we:     1,
        wdata: '0,
        aid:    opt_tf_q.axi_id
    };

    assign w_req_o.w_dp_req = '{
        dst_protocol: opt_tf_q.dst_protocol,
        offset:       w_addr_offset,
        tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
        shift:        opt_tf_q.write_shift,
        num_beats:    'd0,
        is_single:    1'b1
    };
    % elif 'tilelink' in used_write_protocols:
    always_comb begin
        w_req_o.aw_req.tilelink.a_chan.size = '0;
        for (int i = 0; i < PageAddrWidth; i++) begin
            if ((1 << i) == w_num_bytes) begin
                w_req_o.aw_req.tilelink.a_chan.size = i;
            end
        end
        w_req_o.aw_req.tilelink.a_chan.opcode  = 3'd1;
        w_req_o.aw_req.tilelink.a_chan.param   = 3'd0;
        w_req_o.aw_req.tilelink.a_chan.source  = opt_tf_q.axi_id;
        w_req_o.aw_req.tilelink.a_chan.address = { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} };
        w_req_o.aw_req.tilelink.a_chan.mask    = '0;
        w_req_o.aw_req.tilelink.a_chan.data    = '0;
        w_req_o.aw_req.tilelink.a_chan.corrupt = 1'b0;
    end

    assign w_req_o.w_dp_req = '{
        dst_protocol: opt_tf_q.dst_protocol,
        offset:       w_addr_offset,
        tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
        shift:        opt_tf_q.write_shift,
        num_beats:    'd0,
        is_single:    w_num_bytes <= StrbWidth
    };
    % elif 'axi_stream' in used_write_protocols:
    assign w_req_o.aw_req.axi_stream.t_chan = '{
        data: '0,
        strb: '1,
        keep: '0,
        last: w_tf_q.length == w_num_bytes,
        id:   opt_tf_q.axi_id,
        dest: w_tf_q.base_addr[$bits(w_req_o.aw_req.axi_stream.t_chan.dest)-1:0],
        user: w_tf_q.base_addr[$bits(w_req_o.aw_req.axi_stream.t_chan.user)-1+:$bits(w_req_o.aw_req.axi_stream.t_chan.dest)]
    };

    assign w_req_o.w_dp_req = '{
        dst_protocol: opt_tf_q.dst_protocol,
        offset:       w_addr_offset,
        tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
        shift:        opt_tf_q.write_shift,
        num_beats:    'd0,
        is_single:    1'b1
    };
    % else:
    `IDMA_NONSYNTH_BLOCK(
    initial begin
        $fatal(1, "Single write protocol not implemented!");
    end
    )
    % endif
% else:
    always_comb begin : gen_write_meta_channel
        w_req_o.aw_req = '0;
        case(opt_tf_q.dst_protocol)
    % if 'axi' in used_write_protocols:
        idma_pkg::AXI:
            w_req_o.aw_req.axi.aw_chan = '{
                id:     opt_tf_q.axi_id,
                addr:   { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
                len:    ((w_num_bytes + w_addr_offset - 'd1) >> OffsetWidth),
                size:   axi_pkg::size_t'(OffsetWidth),
                burst:  opt_tf_q.dst_axi_opt.burst,
                lock:   opt_tf_q.dst_axi_opt.lock,
                cache:  opt_tf_q.dst_axi_opt.cache,
                prot:   opt_tf_q.dst_axi_opt.prot,
                qos:    opt_tf_q.dst_axi_opt.qos,
                region: opt_tf_q.dst_axi_opt.region,
                user:   '0,
                atop:   '0
            };
    % endif
    % if 'axi_lite' in used_write_protocols:
        idma_pkg::AXI_LITE:
            w_req_o.aw_req.axi_lite.aw_chan = '{
                addr:   { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
                prot:   opt_tf_q.dst_axi_opt.prot
            };
    % endif
    % if 'obi' in used_write_protocols:
        idma_pkg::OBI:
            w_req_o.aw_req.obi.a_chan = '{
                addr:   { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
                be:     '0,
                we:     1,
                wdata: '0,
                aid:    opt_tf_q.axi_id
            };
    % endif
    % if 'tilelink' in used_write_protocols:
        idma_pkg::TILELINK:
            w_req_o.aw_req.tilelink.a_chan = '{
                opcode:  3'd1,
                param:   3'd0,
                size:    OffsetWidth,
                source:  opt_tf_q.axi_id,
                address: { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
                mask:    '0,
                data:    '0,
                corrupt: 1'b0
            };
    % endif
    % if 'axi_stream' in used_write_protocols:
        idma_pkg::AXI_STREAM: 
            w_req_o.aw_req.axi_stream.t_chan = '{
                data: '0,
                strb: '1,
                keep: '0,
                last: w_tf_q.length == w_num_bytes,
                id:   opt_tf_q.axi_id,
                dest: w_tf_q.base_addr[$bits(w_req_o.aw_req.axi_stream.t_chan.dest)-1:0],
                user: w_tf_q.base_addr[$bits(w_req_o.aw_req.axi_stream.t_chan.user)-1+:$bits(w_req_o.aw_req.axi_stream.t_chan.dest)]
            };
    % endif
        default:
            w_req_o.aw_req = '0;
        endcase
    end

    // assign the signals needed to set-up the write data path
    % if 'axi' in used_write_protocols:
    always_comb begin : gen_write_data_path
        if (opt_tf_q.dst_protocol == idma_pkg::AXI) begin
            w_req_o.w_dp_req = '{
                dst_protocol: opt_tf_q.dst_protocol,
                offset:       w_addr_offset,
                tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
                shift:        opt_tf_q.write_shift,
                num_beats:    w_req_o.aw_req.axi.aw_chan.len,
                is_single:    w_req_o.aw_req.axi.aw_chan.len == '0
            };
        end else begin
            w_req_o.w_dp_req = '{
                dst_protocol: opt_tf_q.dst_protocol,
                offset:       w_addr_offset,
                tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
                shift:        opt_tf_q.write_shift,
                num_beats:    'd0,
                is_single:    1'b1
            };
        end
    end
    % else:
    assign w_req_o.w_dp_req = '{
        dst_protocol: opt_tf_q.dst_protocol,
        offset:       w_addr_offset,
        tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
        shift:        opt_tf_q.write_shift,
        num_beats:    'd0,
        is_single:    1'b1
    };
    % endif

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
% if one_read_port and one_write_port:
    % if (no_read_bursting != no_write_bursting) or 'tilelink' in used_protocols:
    always_comb begin : proc_legalizer_flow_control
        //Onesided bursting -> decouple
        r_tf_ena  = (r_ready_i & !flush_i) | kill_i;
        w_tf_ena  = (w_ready_i & !flush_i) | kill_i;

        r_valid_o = r_tf_q.valid & r_ready_i & !flush_i;
        w_valid_o = w_tf_q.valid & w_ready_i & !flush_i;
    end
    % else:
    always_comb begin : proc_legalizer_flow_control
        if ( opt_tf_q.decouple_rw ) begin
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
    % endif
% else:
    always_comb begin : proc_legalizer_flow_control
        if ( opt_tf_q.decouple_rw\
% if (not one_read_port) or (not one_write_port):
% if len(used_non_bursting_read_protocols) != 0:

            || (opt_tf_q.src_protocol inside {\
    % for index, protocol in enumerate(used_non_bursting_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
        % if index != len(used_non_bursting_read_protocols)-1:
,\
        % endif
    % endfor 
 })\
% endif
% if len(used_non_bursting_write_protocols) != 0:

            || (opt_tf_q.dst_protocol inside {\
    % for index, protocol in enumerate(used_non_bursting_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
        % if index != len(used_non_bursting_write_protocols)-1:
,\
        % endif
    % endfor 
 })\
% endif       
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
% endif
    // load next idma request: if both machines are done!
    assign ready_o = r_done & w_done & r_ready_i & w_ready_i & !flush_i;


    //--------------------------------------
    // State
    //--------------------------------------
    `FF(opt_tf_q, opt_tf_d, '0, clk_i, rst_ni)
    `FFL(r_tf_q, r_tf_d, r_tf_ena, '0, clk_i, rst_ni)
    `FFL(w_tf_q, w_tf_d, w_tf_ena, '0, clk_i, rst_ni)


    //--------------------------------------
    // Assertions
    //--------------------------------------
    // only support the decomposition of incremental bursts
    `ASSERT_NEVER(OnlyIncrementalBurstsSRC, (ready_o & valid_i &
                  req_i.opt.src.burst != axi_pkg::BURST_INCR), clk_i, !rst_ni)
    `ASSERT_NEVER(OnlyIncrementalBurstsDST, (ready_o & valid_i &
                  req_i.opt.dst.burst != axi_pkg::BURST_INCR), clk_i, !rst_ni)

endmodule : idma_legalizer${name_uniqueifier}

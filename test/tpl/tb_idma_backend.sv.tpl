// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz  <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`timescale 1ns/1ns
`include "axi/typedef.svh"
`include "axi_stream/typedef.svh"
`include "idma/tracer.svh"
`include "idma/typedef.svh"
`include "obi/typedef.svh"
`include "tilelink/typedef.svh"

// Protocol testbench defines
${tb_defines}
module tb_idma_backend_${name_uniqueifier} import idma_pkg::*; #(
    parameter int unsigned BufferDepth           = 3,
    parameter int unsigned NumAxInFlight         = 3,
    parameter int unsigned DataWidth             = \
% if 'tilelink' in used_protocols:
64,
% else:
32,
%endif
    parameter int unsigned AddrWidth             = 32,
    parameter int unsigned UserWidth             = 1,
    // ID is currently used to differentiate transfers in testbench. We need to fix this
    // eventually.
    parameter int unsigned AxiIdWidth            = \
% if 'tilelink' in used_protocols:
12,
% else:
12,
% endif
    parameter int unsigned TFLenWidth            = 32,
    parameter int unsigned MemSysDepth           = 0,
% for protocol in used_protocols:
    parameter bit          ${database[protocol]['protocol_enum']}_IdealMemory       = 1,
    parameter int unsigned ${database[protocol]['protocol_enum']}_MemNumReqOutst    = 1,
    parameter int unsigned ${database[protocol]['protocol_enum']}_MemLatency        = 0,
% endfor
    parameter bit          CombinedShifter       = 1'b\
% if combined_shifter:
1,
% else:
0,
% endif
    parameter int unsigned WatchDogNumCycles     = 100,
    parameter bit          MaskInvalidData       = 1,
    parameter bit          RAWCouplingAvail      = \
% if one_read_port and one_write_port and ('axi' in used_read_protocols) and ('axi' in used_write_protocols):
1,
% else:
0,
%endif
    parameter bit          HardwareLegalizer     = 1,
    parameter bit          RejectZeroTransfers   = 1,
    parameter bit          ErrorHandling         = 0,
    parameter bit          DmaTracing            = 1
);

    // timing parameters
    localparam time TA  =  1ns;
    localparam time TT  =  9ns;
    localparam time TCK = 10ns;

    // debug
    localparam bit Debug         = 1'b0;
    localparam bit ModelOutput   = 1'b0;
    localparam bit PrintFifoInfo = 1'b1;

    // TB parameters
    // dependent parameters
    localparam int unsigned StrbWidth       = DataWidth / 8;
    localparam int unsigned OffsetWidth     = $clog2(StrbWidth);

    // parse error handling caps
    localparam idma_pkg::error_cap_e ErrorCap = ErrorHandling ? idma_pkg::ERROR_HANDLING :
                                                                idma_pkg::NO_ERROR_HANDLING;

    // static types
    typedef logic [7:0] byte_t;

    // dependent typed
    typedef logic [AddrWidth-1:0]   addr_t;
    typedef logic [DataWidth-1:0]   data_t;
    typedef logic [StrbWidth-1:0]   strb_t;
    typedef logic [UserWidth-1:0]   user_t;
    typedef logic [AxiIdWidth-1:0]  id_t;
    typedef logic [OffsetWidth-1:0] offset_t;
    typedef logic [TFLenWidth-1:0]  tf_len_t;

    // ${database['axi']['full_name']} typedefs
${database['axi']['typedefs']}
% if ('obi' in used_protocols) or ('axis' in used_protocols):
    // ${database['obi']['full_name']} typedefs
${database['obi']['typedefs']}
% endif
% for protocol in used_protocols:
    % if (protocol != 'axi') and (protocol != 'obi'):
    // ${database[protocol]['full_name']} typedefs
${database[protocol]['typedefs']}
    % endif
% endfor
    // Meta Channel Widths
% for protocol in used_write_protocols:
    % if 'write_meta_channel_width' in database[protocol]:
    ${database[protocol]['write_meta_channel_width']}
    % endif
% endfor
% for protocol in used_read_protocols:
    % if 'read_meta_channel_width' in database[protocol]:
    ${database[protocol]['read_meta_channel_width']}
    % endif
% endfor
% for protocol in used_protocols:
    % if 'meta_channel_width' in database[protocol]:
    ${database[protocol]['meta_channel_width']}
    % endif
% endfor

    // iDMA request / response types
    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

% if (not one_read_port) or (not one_write_port):
    function int unsigned max_width(input int unsigned a, b);
        return (a > b) ? a : b;
    endfunction
% endif

% if one_read_port:
    typedef struct packed {
        ${used_read_protocols[0]}_${database[used_read_protocols[0]]['read_meta_channel']}_t ${database[used_read_protocols[0]]['read_meta_channel']};
    } ${used_read_protocols[0]}_read_meta_channel_t;

    typedef struct packed {
        ${used_read_protocols[0]}_read_meta_channel_t ${used_read_protocols[0]};
    } read_meta_channel_t;
% else:
    % for protocol in used_read_protocols:
    typedef struct packed {
        ${protocol}_${database[protocol]['read_meta_channel']}_t ${database[protocol]['read_meta_channel']};
        logic[\
        % for index, p in enumerate(used_read_protocols):
            % if index < len(used_read_protocols)-1:
max_width(${p}_${database[p]['read_meta_channel']}_width, \
            % else:
${p}_${database[p]['read_meta_channel']}_width\
            % endif
        % endfor
        % for i in range(0, len(used_read_protocols)-1):
)\
        % endfor
-${protocol}_${database[protocol]['read_meta_channel']}_width:0] padding;
    } ${protocol}_read_${database[protocol]['read_meta_channel']}_padded_t;

    % endfor
    typedef union packed {
    % for protocol in used_read_protocols:
        ${protocol}_read_${database[protocol]['read_meta_channel']}_padded_t ${protocol};
    % endfor
    } read_meta_channel_t;
% endif

% if one_write_port:
    typedef struct packed {
        ${used_write_protocols[0]}_${database[used_write_protocols[0]]['write_meta_channel']}_t ${database[used_write_protocols[0]]['write_meta_channel']};
    } ${used_write_protocols[0]}_write_meta_channel_t;

    typedef struct packed {
        ${used_write_protocols[0]}_write_meta_channel_t ${used_write_protocols[0]};
    } write_meta_channel_t;
% else:
    % for protocol in used_write_protocols:
    typedef struct packed {
        ${protocol}_${database[protocol]['write_meta_channel']}_t ${database[protocol]['write_meta_channel']};
        logic[\
        % for index, p in enumerate(used_write_protocols):
            % if index < len(used_write_protocols)-1:
max_width(${p}_${database[p]['write_meta_channel']}_width, \
            % else:
${p}_${database[p]['write_meta_channel']}_width\
            % endif
        % endfor
        % for i in range(0, len(used_write_protocols)-1):
)\
        % endfor
-${protocol}_${database[protocol]['write_meta_channel']}_width:0] padding;
    } ${protocol}_write_${database[protocol]['write_meta_channel']}_padded_t;

    % endfor
    typedef union packed {
    % for protocol in used_write_protocols:
        ${protocol}_write_${database[protocol]['write_meta_channel']}_padded_t ${protocol};
    % endfor
    } write_meta_channel_t;
% endif

    //--------------------------------------
    // Physical Signals to the DUT
    //--------------------------------------
    // clock reset signals
    logic clk;
    logic rst_n;

    // dma request
    idma_req_t idma_req;
    logic req_valid;
    logic req_ready;

    // dma response
    idma_rsp_t idma_rsp;
    logic rsp_valid;
    logic rsp_ready;
% if 'axis' in used_write_protocols and False:
    idma_rsp_t idma_rsp_w, idma_rsp_w2;
    logic rsp_valid_w, rsp_ready_w, rsp_valid_w2, rsp_ready_w2;
% endif

    // error handler
    idma_eh_req_t idma_eh_req;
    logic eh_req_valid;
    logic eh_req_ready;

% for protocol in used_protocols:
    // ${database[protocol]['full_name']} request and response
    % if protocol == 'axi':
    axi_req_t\
        % if protocol in used_read_protocols:
 axi_read_req,\
        % endif
        % if protocol in used_write_protocols:
 axi_write_req,\
        % endif
 axi_req, axi_req_mem;
    axi_rsp_t\
        % if protocol in used_read_protocols:
 axi_read_rsp,\
        % endif
        % if protocol in used_write_protocols:
 axi_write_rsp,\
        % endif
 axi_rsp, axi_rsp_mem;
    % else:
        % if protocol in used_read_protocols:
            % if database[protocol]['read_slave'] == 'true':
    ${protocol}_req_t ${protocol}_read_req;
    ${protocol}_rsp_t ${protocol}_read_rsp;
            % else:
    ${protocol}_req_t ${protocol}_read_req;
    ${protocol}_rsp_t ${protocol}_read_rsp;
            % endif
        % endif

        % if protocol in used_write_protocols:
    ${protocol}_req_t ${protocol}_write_req;
    ${protocol}_rsp_t ${protocol}_write_rsp;
        % endif

    axi_req_t\
        % if protocol in used_read_protocols:
 ${protocol}_axi_read_req,\
        % endif
        % if protocol in used_write_protocols:
 ${protocol}_axi_write_req,\
        % endif
 ${protocol}_axi_req, ${protocol}_axi_req_mem;
    axi_rsp_t\
        % if protocol in used_read_protocols:
 ${protocol}_axi_read_rsp,\
        % endif
        % if protocol in used_write_protocols:
 ${protocol}_axi_write_rsp,\
        % endif 
 ${protocol}_axi_rsp, ${protocol}_axi_rsp_mem;
    % endif

% endfor
    // busy signal
    idma_busy_t busy;


    //--------------------------------------
    // DMA Driver
    //--------------------------------------
    // virtual interface definition
    IDMA_DV #(
        .DataWidth  ( DataWidth   ),
        .AddrWidth  ( AddrWidth   ),
        .UserWidth  ( UserWidth   ),
        .AxiIdWidth ( AxiIdWidth  ),
        .TFLenWidth ( TFLenWidth  )
    ) idma_dv (clk);

    // DMA driver type
    typedef idma_test::idma_driver #(
        .DataWidth  ( DataWidth   ),
        .AddrWidth  ( AddrWidth   ),
        .UserWidth  ( UserWidth   ),
        .AxiIdWidth ( AxiIdWidth  ),
        .TFLenWidth ( TFLenWidth  ),
        .TA         ( TA          ),
        .TT         ( TT          )
    ) drv_t;

    // instantiation of the driver
    drv_t drv = new(idma_dv);


    //--------------------------------------
    // DMA Job Queue
    //--------------------------------------
    // job type definition
    typedef idma_test::idma_job #(
        .AddrWidth   ( AddrWidth  ),
        .IdWidth     ( AxiIdWidth )
    ) tb_dma_job_t;

    // request and response queues
    tb_dma_job_t req_jobs [$];
    tb_dma_job_t rsp_jobs [$];
    tb_dma_job_t trf_jobs [$];

    //--------------------------------------
    // DMA Model
    //--------------------------------------
    // model type definition
    typedef idma_test::idma_model #(
        .AddrWidth   ( AddrWidth   ),
        .DataWidth   ( DataWidth   ),
        .ModelOutput ( ModelOutput )
    ) model_t;

    // instantiation of the model
    model_t model = new();


    //--------------------------------------
    // Misc TB Signals
    //--------------------------------------
    logic match;


    //--------------------------------------
    // TB Modules
    //--------------------------------------
    // clocking block
    clk_rst_gen #(
        .ClkPeriod    ( TCK  ),
        .RstClkCycles ( 1    )
    ) i_clk_rst_gen (
        .clk_o        ( clk     ),
        .rst_no       ( rst_n   )
    );
% for protocol in used_protocols:
    // ${database[protocol]['full_name']} sim memory
    % if protocol == 'axi':
    axi_sim_mem #(
        .AddrWidth         ( AddrWidth    ),
        .DataWidth         ( DataWidth    ),
        .IdWidth           ( AxiIdWidth   ),
        .UserWidth         ( UserWidth    ),
        .axi_req_t         ( axi_req_t    ),
        .axi_rsp_t         ( axi_rsp_t    ),
        .WarnUninitialized ( 1'b0         ),
        .ClearErrOnAccess  ( 1'b1         ),
        .ApplDelay         ( TA           ),
        .AcqDelay          ( TT           )
    ) i_axi_sim_mem (
        .clk_i              ( clk                 ),
        .rst_ni             ( rst_n               ),
        .axi_req_i          ( axi_req_mem         ),
        .axi_rsp_o          ( axi_rsp_mem         ),
        .mon_r_last_o       ( /* NOT CONNECTED */ ),
        .mon_r_beat_count_o ( /* NOT CONNECTED */ ),
        .mon_r_user_o       ( /* NOT CONNECTED */ ),
        .mon_r_id_o         ( /* NOT CONNECTED */ ),
        .mon_r_data_o       ( /* NOT CONNECTED */ ),
        .mon_r_addr_o       ( /* NOT CONNECTED */ ),
        .mon_r_valid_o      ( /* NOT CONNECTED */ ),
        .mon_w_last_o       ( /* NOT CONNECTED */ ),
        .mon_w_beat_count_o ( /* NOT CONNECTED */ ),
        .mon_w_user_o       ( /* NOT CONNECTED */ ),
        .mon_w_id_o         ( /* NOT CONNECTED */ ),
        .mon_w_data_o       ( /* NOT CONNECTED */ ),
        .mon_w_addr_o       ( /* NOT CONNECTED */ ),
        .mon_w_valid_o      ( /* NOT CONNECTED */ )
    );
    % else:
    axi_sim_mem #(
        .AddrWidth         ( AddrWidth    ),
        .DataWidth         ( DataWidth    ),
        .IdWidth           ( AxiIdWidth   ),
        .UserWidth         ( UserWidth    ),
        .axi_req_t         ( axi_req_t    ),
        .axi_rsp_t         ( axi_rsp_t    ),
        .WarnUninitialized ( 1'b0         ),
        .ClearErrOnAccess  ( 1'b1         ),
        .ApplDelay         ( TA           ),
        .AcqDelay          ( TT           )
    ) i_${protocol}_axi_sim_mem (
        .clk_i              ( clk                 ),
        .rst_ni             ( rst_n               ),
        .axi_req_i          ( ${protocol}_axi_req_mem ),
        .axi_rsp_o          ( ${protocol}_axi_rsp_mem ),
        .mon_r_last_o       ( /* NOT CONNECTED */ ),
        .mon_r_beat_count_o ( /* NOT CONNECTED */ ),
        .mon_r_user_o       ( /* NOT CONNECTED */ ),
        .mon_r_id_o         ( /* NOT CONNECTED */ ),
        .mon_r_data_o       ( /* NOT CONNECTED */ ),
        .mon_r_addr_o       ( /* NOT CONNECTED */ ),
        .mon_r_valid_o      ( /* NOT CONNECTED */ ),
        .mon_w_last_o       ( /* NOT CONNECTED */ ),
        .mon_w_beat_count_o ( /* NOT CONNECTED */ ),
        .mon_w_user_o       ( /* NOT CONNECTED */ ),
        .mon_w_id_o         ( /* NOT CONNECTED */ ),
        .mon_w_data_o       ( /* NOT CONNECTED */ ),
        .mon_w_addr_o       ( /* NOT CONNECTED */ ),
        .mon_w_valid_o      ( /* NOT CONNECTED */ )
    );
    % endif
% endfor

% if len(unused_protocols) > 0:
    // Dummy memory
    typedef struct {
        logic [7:0]     mem[addr_t];
        axi_pkg::resp_t rerr[addr_t];
        axi_pkg::resp_t werr[addr_t];
    } dummy_mem_t;

    % for protocol in unused_protocols:
        % if protocol == 'axi':
    dummy_mem_t i_axi_sim_mem;
        % else:
    dummy_mem_t i_${protocol}_axi_sim_mem;
        % endif
    % endfor
% endif

    //--------------------------------------
    // TB Monitors
    //--------------------------------------
% for protocol in used_protocols:
    % if protocol == 'axi':
    // ${database[protocol]['full_name']} Signal Highlighters
    signal_highlighter #(.T(axi_aw_chan_t)) i_aw_hl (.ready_i(axi_rsp.aw_ready), .valid_i(axi_req.aw_valid), .data_i(axi_req.aw));
    signal_highlighter #(.T(axi_ar_chan_t)) i_ar_hl (.ready_i(axi_rsp.ar_ready), .valid_i(axi_req.ar_valid), .data_i(axi_req.ar));
    signal_highlighter #(.T(axi_w_chan_t))  i_w_hl  (.ready_i(axi_rsp.w_ready),  .valid_i(axi_req.w_valid),  .data_i(axi_req.w));
    signal_highlighter #(.T(axi_r_chan_t))  i_r_hl  (.ready_i(axi_req.r_ready),  .valid_i(axi_rsp.r_valid),  .data_i(axi_rsp.r));
    signal_highlighter #(.T(axi_b_chan_t))  i_b_hl  (.ready_i(axi_req.b_ready),  .valid_i(axi_rsp.b_valid),  .data_i(axi_rsp.b));
    % else:
    // ${database[protocol]['full_name']}-AXI Signal Highlighters
    signal_highlighter #(.T(axi_aw_chan_t)) i_${protocol}_aw_hl (.ready_i(${protocol}_axi_rsp.aw_ready), .valid_i(${protocol}_axi_req.aw_valid), .data_i(${protocol}_axi_req.aw));
    signal_highlighter #(.T(axi_ar_chan_t)) i_${protocol}_ar_hl (.ready_i(${protocol}_axi_rsp.ar_ready), .valid_i(${protocol}_axi_req.ar_valid), .data_i(${protocol}_axi_req.ar));
    signal_highlighter #(.T(axi_w_chan_t))  i_${protocol}_w_hl  (.ready_i(${protocol}_axi_rsp.w_ready),  .valid_i(${protocol}_axi_req.w_valid),  .data_i(${protocol}_axi_req.w));
    signal_highlighter #(.T(axi_r_chan_t))  i_${protocol}_r_hl  (.ready_i(${protocol}_axi_req.r_ready),  .valid_i(${protocol}_axi_rsp.r_valid),  .data_i(${protocol}_axi_rsp.r));
    signal_highlighter #(.T(axi_b_chan_t))  i_${protocol}_b_hl  (.ready_i(${protocol}_axi_req.b_ready),  .valid_i(${protocol}_axi_rsp.b_valid),  .data_i(${protocol}_axi_rsp.b));
    % endif

% endfor
    // DMA types
    signal_highlighter #(.T(idma_req_t))    i_req_hl (.ready_i(req_ready),    .valid_i(req_valid),    .data_i(idma_req));
    signal_highlighter #(.T(idma_rsp_t))    i_rsp_hl (.ready_i(rsp_ready),    .valid_i(rsp_valid),    .data_i(idma_rsp));
    signal_highlighter #(.T(idma_eh_req_t)) i_eh_hl  (.ready_i(eh_req_ready), .valid_i(eh_req_valid), .data_i(idma_eh_req));

    // Watchdogs
% for protocol in used_protocols:
    % if (protocol != 'init') and (protocol in used_read_protocols):
    stream_watchdog #(.NumCycles(WatchDogNumCycles))\
        % if protocol == 'axi':
 i_axi_r_watchdog\
        % else:
 i_${protocol}_r_watchdog\
        % endif     
 (.clk_i(clk), .rst_ni(rst_n\
        % for p2 in used_read_protocols:
            % if protocol != p2:
                % if p2 == 'axi':
 && !(axi_rsp.r_valid && axi_req.r_ready)\
                % elif p2 == 'init':
 && !(init_read_rsp.rsp_valid && init_read_req.rsp_ready)\
                % else:
 && !(${p2}_axi_rsp.r_valid && ${p2}_axi_req.r_ready)\
                % endif
            % endif
        % endfor
),
        % if protocol == 'axi':
        .valid_i(axi_rsp.r_valid), .ready_i(axi_req.r_ready));
        % else:
        .valid_i(${protocol}_axi_rsp.r_valid), .ready_i(${protocol}_axi_req.r_ready));
        % endif
    % endif
    % if protocol in used_write_protocols:
    stream_watchdog #(.NumCycles(WatchDogNumCycles))\
        % if protocol == 'axi':
 i_axi_w_watchdog\
        % else:
 i_${protocol}_w_watchdog\
        % endif     
 (.clk_i(clk), .rst_ni(rst_n\
        % for p2 in used_write_protocols:
            % if protocol != p2:
                % if p2 == 'axi':
 && !(axi_req.w_valid && axi_rsp.w_ready)\
                % else:
 && !(${p2}_axi_req.w_valid && ${p2}_axi_rsp.w_ready)\
                % endif
            % endif
        % endfor
),
        % if protocol == 'axi':
        .valid_i(axi_req.w_valid), .ready_i(axi_rsp.w_ready));
        % else:
        .valid_i(${protocol}_axi_req.w_valid), .ready_i(${protocol}_axi_rsp.w_ready));
        % endif
    % endif

% endfor
    //--------------------------------------
    // DUT
    //--------------------------------------

    idma_backend_${name_uniqueifier} #(
        .CombinedShifter      ( CombinedShifter      ),
        .DataWidth            ( DataWidth            ),
        .AddrWidth            ( AddrWidth            ),
        .AxiIdWidth           ( AxiIdWidth           ),
        .UserWidth            ( UserWidth            ),
        .TFLenWidth           ( TFLenWidth           ),
        .MaskInvalidData      ( MaskInvalidData      ),
        .BufferDepth          ( BufferDepth          ),
        .RAWCouplingAvail     ( RAWCouplingAvail     ),
        .HardwareLegalizer    ( HardwareLegalizer    ),
        .RejectZeroTransfers  ( RejectZeroTransfers  ),
        .ErrorCap             ( ErrorCap             ),
        .PrintFifoInfo        ( PrintFifoInfo        ),
        .NumAxInFlight        ( NumAxInFlight        ),
        .MemSysDepth          ( MemSysDepth          ),
        .idma_req_t           ( idma_req_t           ),
        .idma_rsp_t           ( idma_rsp_t           ),
        .idma_eh_req_t        ( idma_eh_req_t        ),
        .idma_busy_t          ( idma_busy_t          )\
% for protocol in used_protocols:
,
    % if database[protocol]['read_slave'] == 'true':
        % if (protocol in used_read_protocols) and (protocol in used_write_protocols):
        .${protocol}_read_req_t  ( ${protocol}_rsp_t ),
        .${protocol}_read_rsp_t  ( ${protocol}_req_t ),
        .${protocol}_write_req_t ( ${protocol}_req_t ),
        .${protocol}_write_rsp_t ( ${protocol}_rsp_t )\
        % elif protocol in used_read_protocols:
        .${protocol}_read_req_t ( ${protocol}_rsp_t ),
        .${protocol}_read_rsp_t ( ${protocol}_req_t )\
        % else:
        .${protocol}_write_req_t ( ${protocol}_req_t ),
        .${protocol}_write_rsp_t ( ${protocol}_rsp_t )\
        % endif
    % else:
        .${protocol}_req_t ( ${protocol}_req_t ),
        .${protocol}_rsp_t ( ${protocol}_rsp_t )\
    % endif
% endfor
,
        .write_meta_channel_t ( write_meta_channel_t ),
        .read_meta_channel_t  ( read_meta_channel_t  )
    ) i_idma_backend  (
        .clk_i                ( clk             ),
        .rst_ni               ( rst_n           ),
        .testmode_i           ( 1'b0            ),
        .idma_req_i           ( idma_req        ),
        .req_valid_i          ( req_valid       ),
        .req_ready_o          ( req_ready       ),
        .idma_rsp_o           ( idma_rsp        ),
        .rsp_valid_o          ( rsp_valid       ),
        .rsp_ready_i          ( rsp_ready       ),
        .idma_eh_req_i        ( idma_eh_req     ),
        .eh_req_valid_i       ( eh_req_valid    ),
        .eh_req_ready_o       ( eh_req_ready    )\
% for protocol in used_read_protocols:
,
% if database[protocol]['passive_req'] == 'true':
        .${protocol}_read_req_i       ( ${protocol}_read_req    ),
        .${protocol}_read_rsp_o       ( ${protocol}_read_rsp    )\
% else:
        .${protocol}_read_req_o       ( ${protocol}_read_req    ),
        .${protocol}_read_rsp_i       ( ${protocol}_read_rsp    )\
% endif
% endfor
% for protocol in used_write_protocols:
,
        .${protocol}_write_req_o      ( ${protocol}_write_req   ),
        .${protocol}_write_rsp_i      ( ${protocol}_write_rsp   )\
% endfor
,
        .busy_o               ( busy            )
    );


    //--------------------------------------
    // DMA Tracer
    //--------------------------------------
    // only activate tracer if requested
    if (DmaTracing) begin
        // fetch the name of the trace file from CMD line
        string trace_file;
        initial begin
            void'($value$plusargs("trace_file=%s", trace_file));
        end
        // attach the tracer
        `IDMA_TRACER_${name_uniqueifier.upper()}(i_idma_backend, trace_file);
    end


    //--------------------------------------
    // TB connections
    //--------------------------------------
% if 'axis' in used_write_protocols and False:
    // Delay iDMA response 2 cycles such that all axi stream writes are finished 

    spill_register #(
        .T      ( idma_rsp_t ),
        .Bypass ( 1'b0       )
    ) i_idma_rsp_cut (
        .clk_i   ( clk          ),
        .rst_ni  ( rst_n        ), 
        .valid_i ( rsp_valid_w  ),
        .ready_o ( rsp_ready_w  ),
        .data_i  ( idma_rsp_w   ),
        .valid_o ( rsp_valid_w2 ),
        .ready_i ( rsp_ready_w2 ),
        .data_o  ( idma_rsp_w2  )
    );

    spill_register #(
        .T      ( idma_rsp_t ),
        .Bypass ( 1'b0       )
    ) i_idma_rsp_cut_2 (
        .clk_i   ( clk          ),
        .rst_ni  ( rst_n        ),
        .valid_i ( rsp_valid_w2 ),
        .ready_o ( rsp_ready_w2 ),
        .data_i  ( idma_rsp_w2  ),
        .valid_o ( rsp_valid    ),
        .ready_i ( rsp_ready    ),
        .data_o  ( idma_rsp     )
    );
% endif

% for protocol in used_read_protocols:
    % if protocol != 'axi':
${rendered_read_bridges[protocol]}
    % endif
%endfor

% for protocol in used_write_protocols:
    % if protocol != 'axi':
${rendered_write_bridges[protocol]}
    % endif
%endfor

    // Read Write Join
% for protocol in used_protocols:
    % if (protocol in used_read_protocols) and (protocol in used_write_protocols):
    axi_rw_join #(
        .axi_req_t        ( axi_req_t ),
        .axi_resp_t       ( axi_rsp_t )
    )\
% if protocol == 'axi':
 i_axi_rw_join\
% else:
 i_${protocol}_axi_rw_join\
% endif
 (
        % if protocol == 'axi':
        .clk_i            ( clk           ),
        .rst_ni           ( rst_n         ),
        .slv_read_req_i   ( axi_read_req  ),
        .slv_read_resp_o  ( axi_read_rsp  ),
        .slv_write_req_i  ( axi_write_req ),
        .slv_write_resp_o ( axi_write_rsp ),
        .mst_req_o        ( axi_req       ),
        .mst_resp_i       ( axi_rsp       )
        % else:        
        .clk_i            ( clk               ),
        .rst_ni           ( rst_n             ),
        .slv_read_req_i   ( ${protocol}_axi_read_req  ),
        .slv_read_resp_o  ( ${protocol}_axi_read_rsp  ),
        .slv_write_req_i  ( ${protocol}_axi_write_req ),
        .slv_write_resp_o ( ${protocol}_axi_write_rsp ),
        .mst_req_o        ( ${protocol}_axi_req       ),
        .mst_resp_i       ( ${protocol}_axi_rsp       )
        % endif
    );
    % elif protocol in used_read_protocols:
        % if protocol == 'axi':
    assign axi_req      = axi_read_req;
    assign axi_read_rsp = axi_rsp;
        % else:
    assign ${protocol}_axi_req = ${protocol}_axi_read_req;
    assign ${protocol}_axi_read_rsp = ${protocol}_axi_rsp;
        % endif
    % elif protocol in used_write_protocols:
            % if protocol == 'axi':
    assign axi_req       = axi_write_req;
    assign axi_write_rsp = axi_rsp;
        % else:
    assign ${protocol}_axi_req = ${protocol}_axi_write_req;
    assign ${protocol}_axi_write_rsp = ${protocol}_axi_rsp;
        % endif
    % endif

% endfor

    // connect virtual driver interface to structs
    assign idma_req              = idma_dv.req;
    assign req_valid             = idma_dv.req_valid;
    assign rsp_ready             = idma_dv.rsp_ready;
    assign idma_eh_req           = idma_dv.eh_req;
    assign eh_req_valid          = idma_dv.eh_req_valid;
    // connect struct to virtual driver interface
    assign idma_dv.req_ready     = req_ready;
    assign idma_dv.rsp           = idma_rsp;
    assign idma_dv.rsp_valid     = rsp_valid;
    assign idma_dv.eh_req_ready  = eh_req_ready;

% for protocol in used_protocols:
    // throttle the\
    % if protocl != 'axi':
${database[protocol]['full_name']}-\
    % endif
 AXI bus
    if (${database[protocol]['protocol_enum']}_IdealMemory) begin : gen_${protocol}_ideal_mem_connect

        // if the memory is ideal: 0 cycle latency here
    % if protocol == 'axi':
        assign axi_req_mem = axi_req;
        assign axi_rsp = axi_rsp_mem;
    % elif protocol == 'axi_lite':
        always_comb begin
            // Assign AW prot to AW id -> needed for tracking inflight transfers 
            ${protocol}_axi_req_mem       = ${protocol}_axi_req;
            ${protocol}_axi_req_mem.aw.id = ${protocol}_axi_req.aw.prot;
        end
        assign ${protocol}_axi_rsp = ${protocol}_axi_rsp_mem;
    % else:
        assign ${protocol}_axi_req_mem = ${protocol}_axi_req;
        assign ${protocol}_axi_rsp = ${protocol}_axi_rsp_mem;
    % endif

    end else begin : gen_${protocol}_delayed_mem_connect
        // the throttled AXI buses
    % if protocol == 'axi_lite':
        axi_req_t ${protocol}_axi_req_lite;
        always_comb begin
            // Assign AW prot to AW id -> needed for tracking inflight transfers 
            ${protocol}_axi_req_lite       = ${protocol}_axi_req;
            ${protocol}_axi_req_lite.aw.id = ${protocol}_axi_req.aw.prot;
        end
    % endif
        axi_req_t\
    % if protocol == 'axi':
 axi_req_throttled;
    % else:
 ${protocol}_axi_req_throttled;
    % endif
        axi_rsp_t\
    % if protocol == 'axi':
 axi_rsp_throttled;
    % else:
 ${protocol}_axi_rsp_throttled;
    % endif

        // axi throttle: limit the amount of concurrent requests in the memory system
        axi_throttle #(
            .MaxNumAwPending ( 2**32 - 1  ),
            .MaxNumArPending ( 2**32 - 1  ),
            .axi_req_t       ( axi_req_t  ),
            .axi_rsp_t       ( axi_rsp_t  )
        ) i_\
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_throttle (
            .clk_i       ( clk               ),
            .rst_ni      ( rst_n             ),
            .req_i       ( \
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_req\
    % if protocol == 'axi_lite':
_lite\
    % endif
           ),
            .rsp_o       ( \
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_rsp           ),
            .req_o       ( \
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_req_throttled ),
            .rsp_i       ( \
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_rsp_throttled ),
            .w_credit_i  ( ${database[protocol]['protocol_enum']}_MemNumReqOutst ),
            .r_credit_i  ( ${database[protocol]['protocol_enum']}_MemNumReqOutst )
        );

        // delay the signals using AXI4 multicuts
        axi_multicut #(
            .NoCuts     ( ${database[protocol]['protocol_enum']}_MemLatency ),
            .aw_chan_t  ( axi_aw_chan_t ),
            .w_chan_t   ( axi_w_chan_t  ),
            .b_chan_t   ( axi_b_chan_t  ),
            .ar_chan_t  ( axi_ar_chan_t ),
            .r_chan_t   ( axi_r_chan_t  ),
            .axi_req_t  ( axi_req_t     ),
            .axi_resp_t ( axi_rsp_t     )
        ) i_\
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_multicut (
            .clk_i       ( clk               ),
            .rst_ni      ( rst_n             ),
            .slv_req_i   ( \
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_req_throttled ),
            .slv_resp_o  ( \
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_rsp_throttled ),
            .mst_req_o   ( \
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_req_mem       ),
            .mst_resp_i  ( \
    % if protocol != 'axi':
${protocol}_\
    % endif
axi_rsp_mem       )
        );
    end
% endfor


    //--------------------------------------
    // Various TB Tasks
    //--------------------------------------
    `include "include/tb_tasks.svh"


    // --------------------- Begin TB --------------------------


    //--------------------------------------
    // Read Job queue from File
    //--------------------------------------
    initial begin
        string job_file;
        void'($value$plusargs("job_file=%s", job_file));
        $display("Reading from %s", job_file);
        read_jobs(job_file, req_jobs);
        read_jobs(job_file, rsp_jobs);
        read_jobs(job_file, trf_jobs);
    end


    //--------------------------------------
    // Launch Transfers
    //--------------------------------------
    initial begin
        tb_dma_job_t previous;
        bit overlap;
        previous = null;

        // reset driver
        drv.reset_driver();
        // wait until reset has completed
        wait (rst_n);
        // print a job summary
        print_summary(req_jobs);
        // wait some additional time
        #100ns;

        // run all requests in queue
        while (req_jobs.size() != 0) begin
            // pop front to get a job
            automatic tb_dma_job_t now = req_jobs.pop_front();
            if (!(now.src_protocol inside {\
% for index, protocol in enumerate(used_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
    % if index != len(used_read_protocols)-1:
,\
    % endif
% endfor
 })) begin
                now.src_protocol = idma_pkg::${database[used_read_protocols[-1]]['protocol_enum']};
            end
            if (!(now.dst_protocol inside {\
% for index, protocol in enumerate(used_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
    % if index != len(used_write_protocols)-1:
,\
    % endif
% endfor
 })) begin
                now.dst_protocol = idma_pkg::${database[used_write_protocols[-1]]['protocol_enum']};
            end
            if (previous != null) begin
                overlap = 1'b0;

                // Check if previous destination and this jobs source overlap -> New job's src init could override dst of previous job 
                overlap = overlap || ((now.src_protocol == previous.dst_protocol) && ( (now.src_addr inside {[previous.dst_addr:previous.dst_addr+previous.length]})
                || ((now.src_addr + now.length) inside {[previous.dst_addr:previous.dst_addr+previous.length]}) ));

                // Check if previous destination and this jobs destination overlap -> New job's dst could override dst of previous job
                overlap = overlap || ((now.dst_protocol == previous.dst_protocol) && ( (now.dst_addr inside {[previous.dst_addr:previous.dst_addr+previous.length]})
                || ((now.dst_addr + now.length) inside {[previous.dst_addr:previous.dst_addr+previous.length]}) ));

                if (overlap) begin
                    $display("Overlap!");
                    // Wait until previous job is no longer in response queue -> Got checked
                    while (overlap) begin
                        overlap = 1'b0;
                        foreach (rsp_jobs[index]) begin
                            if ((rsp_jobs[index].src_addr == previous.src_addr)
                             && (rsp_jobs[index].dst_addr == previous.dst_addr))
                                overlap = 1'b1;
                        end
                        if(overlap) begin
                            @(posedge clk);
                        end
                    end
                    $display("Resolved!");
                end
            end
            // print job to terminal
            $display("%s", now.pprint());
            // init mem (model and sim-memory)
            init_mem({\
% for index, protocol in enumerate(used_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
    % if index != len(used_protocols)-1:
,\
    % endif
% endfor          
 }, now);
            // launch DUT
            drv.launch_tf(
                          now.length,
                          now.src_addr,
                          now.dst_addr,
                          now.src_protocol,
                          now.dst_protocol,
                          now.aw_decoupled,
                          now.rw_decoupled,
                          $clog2(now.max_src_len),
                          $clog2(now.max_dst_len),
                          now.max_src_len != 'd256,
                          now.max_dst_len != 'd256,
                          now.id
                         );
            previous = now;
        end
        // once done: launched all transfers
        $display("Launched all Transfers.");
    end

    // Keep track of writes still outstanding
    int unsigned writes_in_flight [idma_pkg::protocol_e][id_t];

    initial begin
        id_t id;
        idma_pkg::protocol_e proto;
        forever begin
            @(posedge clk);
% for protocol in used_write_protocols:
    % if protocol == 'axi':
            proto = idma_pkg::${database[protocol]['protocol_enum']};
            if ( axi_req_mem.aw_valid && axi_rsp_mem.aw_ready ) begin
                id = axi_req_mem.aw.id;
                if ( writes_in_flight.exists(proto) && writes_in_flight[proto].exists(id) )
                    writes_in_flight[proto][id]++;
                else
                    writes_in_flight[proto][id] = 1;

                //if (writes_in_flight[proto][id] == 1)
                    //$display("Started transfer %d id @%d ns", id, $time);
            end
            if ( axi_rsp_mem.b_valid && axi_req_mem.b_ready ) begin
                id = axi_rsp_mem.b.id;
                if ( !writes_in_flight.exists(proto) )
                    $fatal(1, "B response protocol not in scoreboard!");
                if ( !writes_in_flight[proto].exists(id) )
                    $fatal(1, "B response id not in scoreboard!");
                if ( writes_in_flight[proto][id] == 0 )
                    $fatal(1, "Tried to decrement 0");
                writes_in_flight[proto][id]--;
                //if (writes_in_flight[proto][id] == 0)
                    //$display("Stopped transfer %d id @%d ns", id, $time);
            end
    % else:
            proto = idma_pkg::${database[protocol]['protocol_enum']};
            if ( ${protocol}_axi_req_mem.aw_valid && ${protocol}_axi_rsp_mem.aw_ready ) begin
        % if protocol == 'axi_lite':
                id = ${protocol}_axi_req_mem.aw.id[2:0];
        % elif protocol == 'tilelink':
                id = ${protocol}_axi_req_mem.aw.id[4:0];
        % else:
                id = ${protocol}_axi_req_mem.aw.id;
        % endif
                if ( writes_in_flight.exists(proto) && writes_in_flight[proto].exists(id) )
                    writes_in_flight[proto][id]++;
                else
                    writes_in_flight[proto][id] = 1;

                //if (writes_in_flight[proto][id] == 1)
                    //$display("Started transfer %d id @%d ns", id, $time);
            end
            if ( ${protocol}_axi_rsp_mem.b_valid && ${protocol}_axi_req_mem.b_ready ) begin
        % if protocol == 'axi_lite':
                id = ${protocol}_axi_rsp_mem.b.id[2:0];
        % elif protocol == 'tilelink':
                id = ${protocol}_axi_rsp_mem.b.id[4:0];
        % else:
                id = ${protocol}_axi_rsp_mem.b.id;
        % endif
                if ( !writes_in_flight.exists(proto) )
                    $fatal(1, "B response protocol not in scoreboard!");
                if ( !writes_in_flight[proto].exists(id) )
                    $fatal(1, "B response id not in scoreboard!");
                if ( writes_in_flight[proto][id] == 0 )
                    $fatal(1, "Tried to decrement 0");
                writes_in_flight[proto][id]--;
                //if (writes_in_flight[proto][id] == 0)
                    //$display("Stopped transfer %d id @%d ns", id, $time);
            end
    % endif
% endfor
        end
    end

    //--------------------------------------
    // Ack Transfers and Compare Memories
    //--------------------------------------
    initial begin
        id_t id;
        // wait until reset has completed
        wait (rst_n);
        // wait some additional time
        #100ns;
        // receive
        while (rsp_jobs.size() != 0) begin
            // peek front to get a job
            automatic tb_dma_job_t now = rsp_jobs[0];
            if (!(now.src_protocol inside {\
% for index, protocol in enumerate(used_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
    % if index != len(used_read_protocols)-1:
,\
    % endif
% endfor
 })) begin
                $fatal(1, "Requested Source Protocol (%d) Not Supported", now.src_protocol);
            end
            if (!(now.dst_protocol inside {\
% for index, protocol in enumerate(used_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
    % if index != len(used_write_protocols)-1:
,\
    % endif
% endfor
 })) begin
                $fatal(1, "Requested Destination Protocol (%d) Not Supported", now.dst_protocol);
            end
            // wait for DMA to complete
            ack_tf_handle_err(now);
            // Check if corresponding writes went through
            case(now.dst_protocol)
    % for protocol in used_write_protocols:
        idma_pkg::${database[protocol]['protocol_enum']}:
        % if (protocol == 'axi') or (protocol == 'axis') or (protocol == 'obi') or (protocol == 'init'):
                id = now.id;
        % elif protocol == 'axi_lite':
                id = now.id[2:0];
        % elif protocol == 'tilelink':
                id = now.id[4:0];
        % endif
    % endfor
            endcase
            if (now.err_addr.size() == 0) begin
                while (writes_in_flight[now.dst_protocol][id] > 0) begin
                    $display("Waiting for write to finish!");
                    @(posedge clk);
                end
            end
            // finished job
            // $display("vvv Finished: vvv%s\n^^^ Finished: ^^^", now.pprint());
            // launch model
            model.transfer(
                           now.length,
                           now.src_addr,
                           now.dst_addr,
                           now.src_protocol,
                           now.dst_protocol,
                           now.max_src_len,
                           now.max_dst_len,
                           now.rw_decoupled,
                           now.err_addr,
                           now.err_is_read,
                           now.err_action
                          );
            // check memory
            compare_mem(now.length, now.dst_addr, now.dst_protocol, match);
            // fail if there is a mismatch
            if (!match)
                $fatal(1, "Mismatch!");
            // pop front
            rsp_jobs.pop_front();
        end
        // wait some additional time
        #100ns;
        // we are done!
        $finish();
    end


    //--------------------------------------
    // Show first non-acked Transfer
    //--------------------------------------
    initial begin
        wait (rst_n);
        forever begin
            if(rsp_jobs.size() > 0) begin
                automatic tb_dma_job_t now = rsp_jobs[0];
                if (!(now.src_protocol inside {\
% for index, protocol in enumerate(used_read_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
    % if index != len(used_read_protocols)-1:
,\
    % endif
% endfor
 })) begin
                    now.src_protocol = idma_pkg::${database[used_read_protocols[-1]]['protocol_enum']};
                end
                if (!(now.dst_protocol inside {\
% for index, protocol in enumerate(used_write_protocols):
 idma_pkg::${database[protocol]['protocol_enum']}\
    % if index != len(used_write_protocols)-1:
,\
    % endif
% endfor
 })) begin
                    now.dst_protocol = idma_pkg::${database[used_write_protocols[-1]]['protocol_enum']};
                end
                // at least one watch dog triggers
                if (
% for protocol in used_read_protocols:
    % if protocol != 'init':
                    (now.src_protocol == idma_pkg::${database[protocol]['protocol_enum']} &&\
 i_${protocol}_r_watchdog\
.cnt == 0) |
    % endif
% endfor
% for index, protocol in enumerate(used_write_protocols):
                    (now.dst_protocol == idma_pkg::${database[protocol]['protocol_enum']} &&\
 i_${protocol}_w_watchdog\
.cnt == 0)\
    % if index != len(used_write_protocols)-1:
 |
    % endif
% endfor
) 
                begin
                    $error("First non-acked transfer:%s\n\n", now.pprint());
                end
            end
            @(posedge clk);
        end
    end

endmodule

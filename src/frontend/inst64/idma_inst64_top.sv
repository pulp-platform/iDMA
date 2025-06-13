// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"
`include "idma/typedef.svh"
`include "idma/tracer.svh"

/// Implements the tightly-coupled frontend. This module can directly be connected
/// to an accelerator bus in the snitch system
module idma_inst64_top #(
    parameter int unsigned AxiDataWidth    = 32'd0,
    parameter int unsigned AxiAddrWidth    = 32'd0,
    parameter int unsigned AxiUserWidth    = 32'd0,
    parameter int unsigned AxiIdWidth      = 32'd0,
    parameter int unsigned NumAxInFlight   = 32'd3,
    parameter int unsigned DMAReqFifoDepth = 32'd3,
    parameter int unsigned NumChannels     = 32'd1,
    parameter int unsigned DMATracing      = 32'd0,
    parameter type         axi_ar_chan_t   = logic,
    parameter type         axi_aw_chan_t   = logic,
    parameter type         axi_req_t       = logic,
    parameter type         axi_res_t       = logic,
    parameter type         acc_req_t       = logic,
    parameter type         acc_res_t       = logic,
    parameter type         dma_events_t    = logic
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    input  logic                          testmode_i,
    // AXI4 bus
    output axi_req_t    [NumChannels-1:0] axi_req_o,
    input  axi_res_t    [NumChannels-1:0] axi_res_i,
    // debug output
    output logic        [NumChannels-1:0] busy_o,
    // accelerator interface
    input  acc_req_t                      acc_req_i,
    input  logic                          acc_req_valid_i,
    output logic                          acc_req_ready_o,

    output acc_res_t                      acc_res_o,
    output logic                          acc_res_valid_o,
    input  logic                          acc_res_ready_i,
    // hart id of the frankensnitch
    input  logic [31:0]                   hart_id_i,
    // performance output
    output dma_events_t [NumChannels-1:0] events_o
);

    // constants
    localparam int unsigned TfIdWidth    = 32'd32;
    localparam int unsigned TFLenWidth   = AxiAddrWidth;
    localparam int unsigned RepWidth     = 32'd32;
    localparam int unsigned NumDim       = 32'd2;
    localparam int unsigned BufferDepth  = 32'd3;

    // derived constants and types
    localparam int unsigned StrbWidth    = AxiDataWidth / 32'd8;
    localparam int unsigned OffsetWidth  = $clog2(StrbWidth);
    localparam type addr_t               = logic[AxiAddrWidth-1:0];
    localparam type data_t               = logic[AxiDataWidth-1:0];
    localparam type strb_t               = logic[StrbWidth-1:0];
    localparam type user_t               = logic[AxiUserWidth-1:0];
    localparam type id_t                 = logic[AxiIdWidth-1:0];
    localparam type tf_len_t             = logic[TFLenWidth-1:0];
    localparam type offset_t             = logic[OffsetWidth-1:0];
    localparam type strides_t            = logic[RepWidth-1:0];
    localparam type reps_t               = logic[RepWidth-1:0];
    localparam type tf_id_t              = logic[TfIdWidth-1:0];

    // iDMA backend types
    `IDMA_TYPEDEF_OPTIONS_T(options_t, id_t)
    `IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, addr_t, options_t, user_t)
    `IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, addr_t)
    `IDMA_TYPEDEF_RSP_T(idma_rsp_t, err_payload_t)

    // iDMA ND
    `IDMA_TYPEDEF_D_REQ_T(idma_d_req_t, reps_t, strides_t)
    `IDMA_TYPEDEF_ND_REQ_T(idma_nd_req_t, idma_req_t, idma_d_req_t)

    // AXI meta channels
    typedef struct packed {
        axi_ar_chan_t ar_chan;
    } axi_read_meta_channel_t;

    typedef struct packed {
        axi_read_meta_channel_t axi;
    } read_meta_channel_t;

    typedef struct packed {
        axi_aw_chan_t aw_chan;
    } axi_write_meta_channel_t;

    typedef struct packed {
        axi_write_meta_channel_t axi;
    } write_meta_channel_t;

    // internal AXI channels
    axi_req_t [NumChannels-1:0] axi_read_req, axi_write_req;
    axi_res_t [NumChannels-1:0] axi_read_rsp, axi_write_rsp;

    // backend signals
    idma_req_t [NumChannels-1:0] idma_req;
    logic      [NumChannels-1:0] idma_req_valid;
    logic      [NumChannels-1:0] idma_req_ready;
    idma_rsp_t [NumChannels-1:0] idma_rsp;
    logic      [NumChannels-1:0] idma_rsp_valid;
    logic      [NumChannels-1:0] idma_rsp_ready;

    // nd signals
    idma_nd_req_t [NumChannels-1:0] idma_nd_req;
    logic         [NumChannels-1:0] idma_nd_req_valid;
    logic         [NumChannels-1:0] idma_nd_req_ready;
    idma_rsp_t    [NumChannels-1:0] idma_nd_rsp;
    logic         [NumChannels-1:0] idma_nd_rsp_valid;
    logic         [NumChannels-1:0] idma_nd_rsp_ready;

    // frontend
    idma_nd_req_t idma_fe_req_d, idma_fe_req_q, idma_fe_req;
    logic         [NumChannels-1:0] idma_fe_req_valid;
    logic         [NumChannels-1:0] idma_fe_req_ready;

    // frontend state
    logic [1:0] idma_fe_cfg;
    logic [1:0] idma_fe_status;
    logic [2:0] idma_fe_sel_chan;
    logic       idma_fe_twod;

    // busy signals
    idma_pkg::idma_busy_t [NumChannels-1:0] idma_busy;
    logic                 [NumChannels-1:0] idma_nd_busy;

    // counter signals
    logic   [NumChannels-1:0] issue_id;
    logic   [NumChannels-1:0] retire_id;
    tf_id_t [NumChannels-1:0] next_id;
    tf_id_t [NumChannels-1:0] completed_id;

    // accelerator bus decoupled signals
    acc_res_t acc_res;
    logic     acc_res_valid;
    logic     acc_res_ready;


    //--------------------------------------
    // Backend instantiation
    //--------------------------------------
    for (genvar c = 0; c < NumChannels; c++) begin : gen_backend
        idma_backend_rw_axi #(
            .DataWidth            ( AxiDataWidth                ),
            .AddrWidth            ( AxiAddrWidth                ),
            .UserWidth            ( AxiUserWidth                ),
            .AxiIdWidth           ( AxiIdWidth                  ),
            .NumAxInFlight        ( NumAxInFlight               ),
            .BufferDepth          ( BufferDepth                 ),
            .TFLenWidth           ( TFLenWidth                  ),
            .MemSysDepth          ( 32'd16                      ),
            .CombinedShifter      ( 1'b1                        ),
            .RAWCouplingAvail     ( 1'b1                        ),
            .MaskInvalidData      ( 1'b0                        ),
            .HardwareLegalizer    ( 1'b1                        ),
            .RejectZeroTransfers  ( 1'b1                        ),
            .ErrorCap             ( idma_pkg::NO_ERROR_HANDLING ),
            .PrintFifoInfo        ( 1'b0                        ),
            .idma_req_t           ( idma_req_t                  ),
            .idma_rsp_t           ( idma_rsp_t                  ),
            .idma_eh_req_t        ( idma_pkg::idma_eh_req_t     ),
            .idma_busy_t          ( idma_pkg::idma_busy_t       ),
            .axi_req_t            ( axi_req_t                   ),
            .axi_rsp_t            ( axi_res_t                   ),
            .read_meta_channel_t  ( read_meta_channel_t         ),
            .write_meta_channel_t ( write_meta_channel_t        )
        ) i_idma_backend_rw_axi (
            .clk_i,
            .rst_ni,
            .testmode_i,
            .idma_req_i      ( idma_req       [c] ),
            .req_valid_i     ( idma_req_valid [c] ),
            .req_ready_o     ( idma_req_ready [c] ),
            .idma_rsp_o      ( idma_rsp       [c] ),
            .rsp_valid_o     ( idma_rsp_valid [c] ),
            .rsp_ready_i     ( idma_rsp_ready [c] ),
            .idma_eh_req_i   ( '0                 ),
            .eh_req_valid_i  ( 1'b0               ),
            .eh_req_ready_o  ( /* NC */           ),
            .axi_read_req_o  ( axi_read_req   [c] ),
            .axi_read_rsp_i  ( axi_read_rsp   [c] ),
            .axi_write_req_o ( axi_write_req  [c] ),
            .axi_write_rsp_i ( axi_write_rsp  [c] ),
            .busy_o          ( idma_busy      [c] )
        );

        axi_rw_join #(
            .axi_req_t  ( axi_req_t ),
            .axi_resp_t ( axi_res_t )
        ) i_axi_rw_join (
            .clk_i,
            .rst_ni,
            .slv_read_req_i   ( axi_read_req  [c] ),
            .slv_read_resp_o  ( axi_read_rsp  [c] ),
            .slv_write_req_i  ( axi_write_req [c] ),
            .slv_write_resp_o ( axi_write_rsp [c] ),
            .mst_req_o        ( axi_req_o     [c] ),
            .mst_resp_i       ( axi_res_i     [c] )
        );

        assign busy_o[c] = (|idma_busy[c]) | idma_nd_busy[c];
    end


    //--------------------------------------
    // 2D Extension
    //--------------------------------------
    for (genvar c = 0; c < NumChannels; c++) begin : gen_nd_midend
        idma_nd_midend #(
            .NumDim        ( NumDim        ),
            .addr_t        ( addr_t        ),
            .idma_req_t    ( idma_req_t    ),
            .idma_rsp_t    ( idma_rsp_t    ),
            .idma_nd_req_t ( idma_nd_req_t ),
            .RepWidths     ( RepWidth      )
        ) i_idma_nd_midend (
            .clk_i,
            .rst_ni,
            .nd_req_i          ( idma_nd_req       [c] ),
            .nd_req_valid_i    ( idma_nd_req_valid [c] ),
            .nd_req_ready_o    ( idma_nd_req_ready [c] ),
            .nd_rsp_o          ( idma_nd_rsp       [c] ),
            .nd_rsp_valid_o    ( idma_nd_rsp_valid [c] ),
            .nd_rsp_ready_i    ( idma_nd_rsp_ready [c] ),
            .burst_req_o       ( idma_req          [c] ),
            .burst_req_valid_o ( idma_req_valid    [c] ),
            .burst_req_ready_i ( idma_req_ready    [c] ),
            .burst_rsp_i       ( idma_rsp          [c] ),
            .burst_rsp_valid_i ( idma_rsp_valid    [c] ),
            .burst_rsp_ready_o ( idma_rsp_ready    [c] ),
            .busy_o            ( idma_nd_busy      [c] )
        );

        stream_fifo_optimal_wrap #(
            .Depth     ( DMAReqFifoDepth ),
            .type_t    ( idma_nd_req_t   ),
            .PrintInfo ( 1'b0            )
        ) i_stream_fifo_optimal_wrap (
            .clk_i,
            .rst_ni,
            .testmode_i,
            .flush_i    ( 1'b0                  ),
            .usage_o    ( /* NC */              ),
            .data_i     ( idma_fe_req           ),
            .valid_i    ( idma_fe_req_valid [c] ),
            .ready_o    ( idma_fe_req_ready [c] ),
            .data_o     ( idma_nd_req       [c] ),
            .valid_o    ( idma_nd_req_valid [c] ),
            .ready_i    ( idma_nd_req_ready [c] )
        );
    end


    //--------------------------------------
    // ID gen
    //--------------------------------------
    for (genvar c = 0; c < NumChannels; c++) begin : gen_transfer_id_gen
        idma_transfer_id_gen #(
            .IdWidth ( TfIdWidth )
        ) i_idma_transfer_id_gen (
            .clk_i,
            .rst_ni,
            .issue_i     ( issue_id     [c] ),
            .retire_i    ( retire_id    [c] ),
            .next_o      ( next_id      [c] ),
            .completed_o ( completed_id [c] )
        );

        // we are always ready to accept responses
        assign idma_nd_rsp_ready [c] = 1'b1;
        assign issue_id [c] = idma_nd_req_valid[c] & idma_nd_req_ready[c];
        assign retire_id[c] = idma_nd_rsp_valid[c] & idma_nd_rsp_ready[c];
    end


    //--------------------------------------
    // Performance events
    //--------------------------------------
    for (genvar c = 0; c < NumChannels; c++) begin : gen_events
        idma_inst64_events #(
            .DataWidth    ( AxiDataWidth ),
            .axi_req_t    ( axi_req_t    ),
            .axi_res_t    ( axi_res_t    ),
            .dma_events_t ( dma_events_t )
        ) i_idma_inst64_events (
            .clk_i,
            .rst_ni,
            .axi_req_i      ( axi_req_o [c] ),
            .axi_rsp_i      ( axi_res_i [c] ),
            .busy_i         ( busy_o    [c] ),
            .events_o       ( events_o  [c] )
        );
    end


    //--------------------------------------
    // Spill register for response channel
    //--------------------------------------
    // the response path needs to be decoupled
    spill_register #(
        .T            ( acc_res_t )
    ) i_spill_register (
        .clk_i,
        .rst_ni,
        .valid_i ( acc_res_valid   ),
        .ready_o ( acc_res_ready   ),
        .data_i  ( acc_res         ),
        .valid_o ( acc_res_valid_o ),
        .ready_i ( acc_res_ready_i ),
        .data_o  ( acc_res_o       )
    );


    //--------------------------------------
    // Instruction decode
    //--------------------------------------
    logic            is_dma_op;
    logic [12*8-1:0] dma_op_name;
    user_t           decoded_user;

    // Helper to avoid parsing the user field inside the always comb block
    if(AxiUserWidth > 32) begin : gen_parseUser64bit
        assign decoded_user[31:0] = acc_req_i.data_arga[31:0];
        assign decoded_user[AxiUserWidth-1:32] = acc_req_i.data_argb[AxiUserWidth-33:0];
    end else begin : gen_parseUser32bit
        assign decoded_user[AxiUserWidth-1:0] = acc_req_i.data_arga[AxiUserWidth-1:0];
    end

    always_comb begin : proc_fe_inst_decode

        // defaults for iDMA job
        idma_fe_req_d                                  = idma_fe_req_q;
        idma_fe_req_d.burst_req.opt.src_protocol       = idma_pkg::AXI;
        idma_fe_req_d.burst_req.opt.dst_protocol       = idma_pkg::AXI;
        idma_fe_req_d.burst_req.opt.axi_id             = '0;
        idma_fe_req_d.burst_req.opt.src.burst          = axi_pkg::BURST_INCR;
        idma_fe_req_d.burst_req.opt.src.cache          = axi_pkg::CACHE_MODIFIABLE;
        idma_fe_req_d.burst_req.opt.src.lock           = 1'b0;
        idma_fe_req_d.burst_req.opt.src.prot           = 3'b0;
        idma_fe_req_d.burst_req.opt.src.qos            = 4'b0;
        idma_fe_req_d.burst_req.opt.src.region         = 4'b0;
        idma_fe_req_d.burst_req.opt.dst.burst          = axi_pkg::BURST_INCR;
        idma_fe_req_d.burst_req.opt.dst.cache          = axi_pkg::CACHE_MODIFIABLE;
        idma_fe_req_d.burst_req.opt.dst.lock           = 1'b0;
        idma_fe_req_d.burst_req.opt.dst.prot           = 3'b0;
        idma_fe_req_d.burst_req.opt.dst.qos            = 4'b0;
        idma_fe_req_d.burst_req.opt.dst.region         = 4'b0;
        idma_fe_req_d.burst_req.opt.beo.decouple_aw    = 1'b0;
        idma_fe_req_d.burst_req.opt.beo.decouple_rw    = 1'b0;
        idma_fe_req_d.burst_req.opt.beo.src_max_llen   = 3'b0;
        idma_fe_req_d.burst_req.opt.beo.dst_max_llen   = 3'b0;
        idma_fe_req_d.burst_req.opt.beo.src_reduce_len = 1'b0;
        idma_fe_req_d.burst_req.opt.beo.dst_reduce_len = 1'b0;
        idma_fe_req_d.burst_req.opt.last               = 1'b0;

        // frontend config
        idma_fe_cfg      = '0;
        idma_fe_status   = '0;
        idma_fe_sel_chan = '0;

        // default handshaking
        idma_fe_req_valid =  '0;
        acc_req_ready_o   = 1'b0;
        acc_res_valid     = 1'b0;

        // defaults accelerator bus
        acc_res       = '0;
        acc_res.error = 1'b1;

        // debug signal for simulation / wave
        is_dma_op        = 1'b0;
        dma_op_name      = "Invalid";

        // decode
        if (acc_req_valid_i) begin
            unique casez (acc_req_i.data_op)
                // manipulate the source register
                idma_inst64_snitch_pkg::DMSRC : begin
                    idma_fe_req_d.burst_req.src_addr[31:0] = acc_req_i.data_arga[31:0];
                    idma_fe_req_d.burst_req.src_addr[AxiAddrWidth-1:32] =
                        acc_req_i.data_argb[AxiAddrWidth-1-32:0];
                    acc_req_ready_o = 1'b1;
                    is_dma_op       = 1'b1;
                    dma_op_name     = "DMSRC";
                end

                // manipulate the destination register
                idma_inst64_snitch_pkg::DMDST : begin
                    idma_fe_req_d.burst_req.dst_addr[31:0] = acc_req_i.data_arga[31:0];
                    idma_fe_req_d.burst_req.dst_addr[AxiAddrWidth-1:32] =
                        acc_req_i.data_argb[AxiAddrWidth-1-32:0];
                    acc_req_ready_o = 1'b1;
                    is_dma_op       = 1'b1;
                    dma_op_name     = "DMDST";
                end

                // start the DMA
                idma_inst64_snitch_pkg::DMCPYI,
                idma_inst64_snitch_pkg::DMCPY : begin
                    // Parse the transfer parameters from the register or immediate.
                    unique casez (acc_req_i.data_op)
                        idma_inst64_snitch_pkg::DMCPYI : begin
                            idma_fe_cfg      = acc_req_i.data_op[21:20];
                            idma_fe_sel_chan = acc_req_i.data_op[24:22];
                        end
                        idma_inst64_snitch_pkg::DMCPY : begin
                            idma_fe_cfg      = acc_req_i.data_argb[1:0];
                            idma_fe_sel_chan = acc_req_i.data_argb[4:2];
                        end
                        default:;
                    endcase

                    dma_op_name = "DMCPY";
                    is_dma_op   = 1'b1;
                    idma_fe_req_d.burst_req.opt.axi_id = idma_fe_sel_chan;
                    idma_fe_req_d.burst_req.length = acc_req_i.data_arga;

                    // Perform the following sequence:
                    // 1. wait for acc response channel to be ready (pready)
                    // 2. request twod transfer (valid)
                    // 3. wait for twod transfer to be accepted (ready)
                    // 4. send acc response (pvalid)
                    // 5. acknowledge acc request (qready)
                    if (acc_res_ready) begin
                        idma_fe_req_valid [idma_fe_sel_chan] = 1'b1;
                        if (idma_fe_req_ready[idma_fe_sel_chan]) begin
                            acc_res.id      = acc_req_i.id;
                            acc_res.data    = next_id[idma_fe_sel_chan];
                            acc_res.error   = 1'b0;
                            acc_res_valid   = 1'b1;
                            acc_req_ready_o = idma_fe_req_ready[idma_fe_sel_chan];
                        end
                    end
                end

                // status of the DMA
                idma_inst64_snitch_pkg::DMSTATI,
                idma_inst64_snitch_pkg::DMSTAT: begin
                    // Parse the status index from the register or immediate.
                    unique casez (acc_req_i.data_op)
                        idma_inst64_snitch_pkg::DMSTATI : begin
                            idma_fe_status   = acc_req_i.data_op[21:20];
                            idma_fe_sel_chan = acc_req_i.data_op[24:22];
                        end
                        idma_inst64_snitch_pkg::DMSTAT : begin
                            idma_fe_status   = acc_req_i.data_argb[1:0];
                            idma_fe_sel_chan = acc_req_i.data_argb[4:2];
                        end
                        default:;
                    endcase
                    dma_op_name = "DMSTAT";
                    is_dma_op   = 1'b1;

                    // Compose the response
                    acc_res.id    = acc_req_i.id;
                    acc_res.error = 1'b0;
                    case (idma_fe_status)
                        2'b00 : acc_res.data = completed_id[idma_fe_sel_chan];
                        2'b01 : acc_res.data = next_id[idma_fe_sel_chan];
                        2'b10 : acc_res.data = {{{8'd63}{1'b0}}, busy_o[idma_fe_sel_chan]};
                        2'b11 : acc_res.data = {{{8'd63}{1'b0}},
                                                !idma_fe_req_ready[idma_fe_sel_chan]};
                        default:;
                    endcase

                    // Wait for acc response channel to become ready, then ack the
                    // request.
                    if (acc_res_ready) begin
                        acc_res_valid   = 1'b1;
                        acc_req_ready_o = 1'b1;
                    end
                end

                // manipulate the strides
                idma_inst64_snitch_pkg::DMSTR : begin
                    idma_fe_req_d.d_req[0].src_strides = acc_req_i.data_arga;
                    idma_fe_req_d.d_req[0].dst_strides = acc_req_i.data_argb;
                    acc_req_ready_o = 1'b1;
                    is_dma_op       = 1'b1;
                    dma_op_name     = "DMSTR";
                end

                // manipulate the repetitions
                idma_inst64_snitch_pkg::DMREP : begin
                    idma_fe_req_d.d_req[0].reps = acc_req_i.data_arga;
                    acc_req_ready_o = 1'b1;
                    is_dma_op       = 1'b1;
                    dma_op_name     = "DMREP";
                end

                // write the user field
                idma_inst64_snitch_pkg::DMUSER : begin
                    // Assign the user bits according to the size of AxiUserWidth
                    idma_fe_req_d.burst_req.user = decoded_user;
                    acc_req_ready_o = 1'b1;
                    is_dma_op       = 1'b1;
                    dma_op_name     = "DMUSER";
                end

                default:;
            endcase
        end
    end

    // twod handling
    assign idma_fe_twod = idma_fe_cfg[1];
    always_comb begin : gen_twod_bypass
        // default: pass-through
        idma_fe_req = idma_fe_req_d;
        if (!idma_fe_twod) begin
            idma_fe_req.d_req[0].reps = 'd1;
        end
    end

    //--------------------------------------
    // State
    //--------------------------------------
    `FF(idma_fe_req_q, idma_fe_req_d, '0)


    //--------------------------------------
    // DMA Tracer
    //--------------------------------------
    // only activate tracer if requested
`ifndef SYNTHESIS
    if (DMATracing) begin : gen_tracer
        for (genvar c = 0; c < NumChannels; c++) begin : gen_channels
            // derive the name of the trace file from the hart and channel IDs
            string trace_file;
            initial begin
                // We need to schedule the assignment into a safe region, otherwise
                // `hart_id_i` won't have a value assigned at the beginning of the first
                // delta cycle.
`ifndef VERILATOR
                #0;
`endif
                $sformat(trace_file, "dma_trace_%05x_%05x.log", hart_id_i, c);
            end
            // attach the tracer
            `IDMA_TRACER_RW_AXI(gen_backend[c].i_idma_backend_rw_axi, trace_file);
        end
    end
`endif

    //--------------------------------------
    // ASSERTION
    //--------------------------------------
    // The DMUSER field op-code supports axi user field width only up to 64 Bits.
    `ASSERT_INIT(CheckAxiUserField, AxiUserWidth <= 64);

endmodule

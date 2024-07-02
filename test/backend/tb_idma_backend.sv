// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>
// - Liam Braun <libraun@student.ethz.ch>

`ifdef PORT_AXI4
`include "axi/typedef.svh"
`endif

`ifdef PORT_OBI
`include "obi/typedef.svh"
`endif

`include "idma/typedef.svh"

`ifndef BACKEND_NAME
`define BACKEND_NAME idma_backend_unknown
`endif

/// Synthesis wrapper for the iDMA backend. Unpacks all the interfaces to simple logic vectors
module tb_idma_backend #(
    parameter int unsigned BufferDepth           = 3,
    parameter int unsigned NumAxInFlight         = 3,
    parameter int unsigned DataWidth             = 32,
    parameter int unsigned AddrWidth             = 32,
    parameter int unsigned UserWidth             = 1,
    // ID is currently used to differentiate transfers in testbench. We need to fix this
    // eventually.
    parameter int unsigned AxiIdWidth            = 12,
    parameter int unsigned TFLenWidth            = 32,
    parameter int unsigned MemSysDepth           = 0,
    parameter bit          AXI_IdealMemory       = 1,
    parameter int unsigned AXI_MemNumReqOutst    = 1,
    parameter int unsigned AXI_MemLatency        = 0,
    parameter bit          OBI_IdealMemory       = 1,
    parameter int unsigned OBI_MemNumReqOutst    = 1,
    parameter int unsigned OBI_MemLatency        = 0,
    parameter bit          CombinedShifter       = 1'b0,
    parameter int unsigned WatchDogNumCycles     = 100,
    parameter bit          MaskInvalidData       = 1,
    parameter bit          RAWCouplingAvail      = 0,
    parameter bit          HardwareLegalizer     = 1,
    parameter bit          RejectZeroTransfers   = 1,
    parameter bit          ErrorHandling         = 0,
    parameter bit          DmaTracing            = 1
)(
    output idma_pkg::idma_busy_t   idma_busy_o
);

    // timing parameters
    localparam time TA  =  1ns;
    localparam time TT  =  9ns;
    localparam time TCK = 10ns;

    /// Define the error handling capability
    localparam idma_pkg::error_cap_e ErrorCap = ErrorHandling ? idma_pkg::ERROR_HANDLING :
                                                                idma_pkg::NO_ERROR_HANDLING;

    // TB parameters
    // dependent parameters
    localparam int unsigned StrbWidth       = DataWidth / 8;
    localparam int unsigned OffsetWidth     = $clog2(StrbWidth);
    typedef logic [AddrWidth-1:0]   addr_t;
    typedef logic [DataWidth-1:0]   data_t;
    typedef logic [StrbWidth-1:0]   strb_t;
    typedef logic [UserWidth-1:0]   user_t;
    typedef logic [AxiIdWidth-1:0]  id_t;
    typedef logic [OffsetWidth-1:0] offset_t;
    typedef logic [TFLenWidth-1:0]  tf_len_t;
    
    // Clock reset signals
    logic clk;
    logic rst_n;

    // AXI4+ATOP typedefs
    `ifdef PORT_AXI4
`AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
`AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, data_t, strb_t, user_t)
`AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, id_t, user_t)

`AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)
`AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, data_t, id_t, user_t)

`AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
`AXI_TYPEDEF_RESP_T(axi_rsp_t, axi_b_chan_t, axi_r_chan_t)
    `endif


    // OBI typedefs
    `ifdef PORT_OBI
`OBI_TYPEDEF_MINIMAL_A_OPTIONAL(a_optional_t)
`OBI_TYPEDEF_MINIMAL_R_OPTIONAL(r_optional_t)

`OBI_TYPEDEF_TYPE_A_CHAN_T(obi_a_chan_t, addr_t, data_t, strb_t, id_t, a_optional_t)
`OBI_TYPEDEF_TYPE_R_CHAN_T(obi_r_chan_t, data_t, id_t, r_optional_t)

`OBI_TYPEDEF_REQ_T(obi_req_t, obi_a_chan_t)
`OBI_TYPEDEF_RSP_T(obi_rsp_t, obi_r_chan_t)
    `endif


    `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
    `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

    idma_req_t idma_req [$];
    idma_rsp_t idma_rsp [$];

    `ifdef PORT_R_AXI4
    typedef struct packed {
        axi_ar_chan_t ar_chan;
    } axi_read_meta_channel_t;
    typedef struct packed {
        axi_read_meta_channel_t axi;
    } read_meta_channel_t;
    
    axi_req_t axi_read_req;
    axi_rsp_t axi_read_rsp;
    `elsif PORT_R_OBI
    typedef struct packed {
        obi_a_chan_t a_chan;
    } obi_read_meta_channel_t;
    typedef struct packed {
        obi_read_meta_channel_t obi;
    } read_meta_channel_t;
    
    obi_req_t obi_read_req;
    obi_rsp_t obi_read_rsp;
    `endif

    `ifdef PORT_W_AXI4
    typedef struct packed {
        axi_aw_chan_t aw_chan;
    } axi_write_meta_channel_t;
    typedef struct packed {
        axi_write_meta_channel_t axi;
    } write_meta_channel_t;
    
    axi_req_t axi_write_req;
    axi_rsp_t axi_write_rsp;
    `elsif PORT_W_OBI
    typedef struct packed {
        obi_a_chan_t a_chan;
    } obi_write_meta_channel_t;
    typedef struct packed {
        obi_write_meta_channel_t obi;
    } write_meta_channel_t;

    obi_req_t obi_write_req;
    obi_rsp_t obi_write_rsp;
    `endif

    idma_req_t curr_idma_req;
    idma_rsp_t curr_idma_rsp;

    logic test = 0;
    logic req_valid;
    logic req_ready;
    logic rsp_valid;
    logic rsp_ready;
    logic                   eh_req_valid_i;
    logic                   eh_req_ready_o;
    idma_pkg::idma_eh_req_t eh_req_i;

    clk_rst_gen #(
        .ClkPeriod    ( TCK  ),
        .RstClkCycles ( 1    )
    ) i_clk_rst_gen (
        .clk_o        ( clk    ),
        .rst_no       ( rst_n  )
    );

    `BACKEND_NAME #(
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
        .NumAxInFlight        ( NumAxInFlight        ),
        .MemSysDepth          ( MemSysDepth          ),
        .idma_req_t           ( idma_req_t           ),
        .idma_rsp_t           ( idma_rsp_t           ),
        .idma_eh_req_t        ( idma_pkg::idma_eh_req_t),
        .idma_busy_t          ( idma_pkg::idma_busy_t  ),
        `ifdef PORT_AXI4
        .axi_req_t ( axi_req_t ),
        .axi_rsp_t ( axi_rsp_t ),
        `endif
        `ifdef PORT_OBI
        .obi_req_t ( obi_req_t ),
        .obi_rsp_t ( obi_rsp_t ),
        `endif
        .write_meta_channel_t ( write_meta_channel_t ),
        .read_meta_channel_t  ( read_meta_channel_t  )
    ) i_idma_backend  (
        .clk_i                ( clk             ),
        .rst_ni               ( rst_n           ),
        .testmode_i           ( 1'b0            ),
        .idma_req_i           ( curr_idma_req        ),
        .req_valid_i          ( req_valid       ),
        .req_ready_o          ( req_ready       ),
        .idma_rsp_o           ( curr_idma_rsp        ),
        .rsp_valid_o          ( rsp_valid       ),
        .rsp_ready_i          ( rsp_ready       ),
        .idma_eh_req_i        ( eh_req_i     ),
        .eh_req_valid_i       ( eh_req_valid_i    ),
        .eh_req_ready_o       ( eh_req_ready_o    ),
        `ifdef PORT_R_AXI4
        .axi_read_req_o       ( axi_read_req    ),
        .axi_read_rsp_i       ( axi_read_rsp    ),
        `elsif PORT_R_OBI
        .obi_read_req_o       ( obi_read_req    ),
        .obi_read_rsp_i       ( obi_read_rsp    ),
        `endif
        `ifdef PORT_W_AXI4
        .axi_write_req_o      ( axi_write_req   ),
        .axi_write_rsp_i      ( axi_write_rsp   ),
        `elsif PORT_W_OBI
        .obi_write_req_o      ( obi_write_req   ),
        .obi_write_rsp_i      ( obi_write_rsp   ),
        `endif
        .busy_o               ( idma_busy_o            )
    );

    import "DPI-C" function void idma_request_done();

    // Not using regular DPI-C export here because it makes working with the idma_req_t struct much less of a hassle
    function trigger_request;
        // verilator public
        input idma_req_t request;
        idma_req.push_back(request);
    endfunction

    initial begin
        $dumpfile("idma_trace.fst");
        $dumpvars(0);

        eh_req_i = '0;
        eh_req_valid_i = '0;

        wait (rst_n);
        
        #100ns;
        
        while (idma_req.size() > 0) begin
            curr_idma_req = idma_req[0];
            idma_req.pop_front();

            $display("Sending request...");
            #TA;
            req_valid = '1;
            #(TT - TA);
            while (req_ready != '1) begin @(posedge clk); #TT; end
            @(posedge clk);
            $display("Sent request. Waiting for response...");

            #TA;
            req_valid = '0;
            rsp_ready = '1;
            #(TT - TA);
            while (rsp_valid != '1) begin @(posedge clk); #TT; end
            @(posedge clk);

            #TA;
            rsp_ready = '0;
            @(posedge clk);

            $display("Request complete.");

            idma_request_done();
        end

        #100ns;
        $finish;
    end

    `ifdef PORT_R_AXI4
    axi_read #(
        .axi_req_t(axi_req_t),
        .axi_rsp_t(axi_rsp_t),
        .DataWidth(DataWidth),
        .AddrWidth(AddrWidth),
        .UserWidth(UserWidth),
        .AxiIdWidth(AxiIdWidth),
        .TA(TA),
        .TT(TT)
    ) i_axi_read (
        .axi_read_req (axi_read_req),
        .axi_read_rsp (axi_read_rsp),
        .clk_i(clk)
    );
    `elsif PORT_R_OBI
    obi_read #(
        .obi_req_t(obi_req_t),
        .obi_rsp_t(obi_rsp_t),
        .TA(TA),
        .TT(TT)
    ) i_obi_read (
        .obi_read_req(obi_read_req),
        .obi_read_rsp(obi_read_rsp),
        .clk_i(clk),
        .rst_ni(rst_n)
    );
    `endif

    `ifdef PORT_W_AXI4
    axi_write #(
        .axi_req_t(axi_req_t),
        .axi_rsp_t(axi_rsp_t),
        .DataWidth(DataWidth),
        .AddrWidth(AddrWidth),
        .UserWidth(UserWidth),
        .AxiIdWidth(AxiIdWidth),
        .TA(TA),
        .TT(TT)
    ) i_axi_write (
        .axi_write_req(axi_write_req),
        .axi_write_rsp(axi_write_rsp),
        .clk_i(clk)
    );
    `elsif PORT_W_OBI
    obi_write #(
        .obi_req_t(obi_req_t),
        .obi_rsp_t(obi_rsp_t),
        .TA(TA),
        .TT(TT)
    ) i_obi_write (
        .obi_write_req(obi_write_req),
        .obi_write_rsp(obi_write_rsp),
        .clk_i(clk),
        .rst_ni(rst_n)
    );
    `endif
endmodule


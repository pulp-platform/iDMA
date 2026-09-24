// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "axi/typedef.svh"
`include "idma/typedef.svh"
`include "obi/typedef.svh"

package idma_inst64_tb_pkg;

    localparam int unsigned AxiDataWidth    = 32'd512;
    localparam int unsigned AxiAddrWidth    = 32'd64;
    localparam int unsigned AxiUserWidth    = 32'd1;
    localparam int unsigned AxiIdWidth      = 32'd3;
    localparam int unsigned NumAxInFlight   = 32'd3;
    localparam int unsigned DMAReqFifoDepth = 32'd3;
    localparam int unsigned NumChannels     = 32'd1;
    // Tracer off; the testbench does not consume trace files.
    localparam int unsigned DMATracing      = 32'd0;

    // TCDM (OBI) window of the harness; every address outside it decodes to AXI.
    localparam logic [63:0] TcdmStart       = 64'h0000_0000_1000_0000;
    localparam logic [63:0] TcdmEnd         = 64'h0000_0000_1001_0000;

    localparam time    Period      = 10ns;
    localparam time    ApplDelay   = Period / 4;
    localparam time    AcqDelay    = Period * 3 / 4;
    localparam integer ResetCycles = 10;

    typedef logic [AxiAddrWidth-1:0]   addr_t;
    typedef logic [31:0]               tf_id_t;

    typedef logic [AxiAddrWidth-1:0]   axi_addr_t;
    typedef logic [AxiDataWidth-1:0]   axi_data_t;
    typedef logic [AxiDataWidth/8-1:0] axi_strb_t;
    typedef logic [AxiUserWidth-1:0]   axi_user_t;
    typedef logic [AxiIdWidth-1:0]     axi_id_t;

    `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, axi_addr_t, axi_id_t, axi_user_t)
    `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, axi_data_t, axi_strb_t, axi_user_t)
    `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, axi_id_t, axi_user_t)
    `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, axi_addr_t, axi_id_t, axi_user_t)
    `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, axi_data_t, axi_id_t, axi_user_t)
    `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
    `AXI_TYPEDEF_RESP_T(axi_resp_t, axi_b_chan_t, axi_r_chan_t)

    typedef logic [AxiDataWidth/8-1:0] obi_strb_t;
    `OBI_TYPEDEF_MINIMAL_A_OPTIONAL(obi_a_optional_t)
    `OBI_TYPEDEF_MINIMAL_R_OPTIONAL(obi_r_optional_t)
    `OBI_TYPEDEF_TYPE_A_CHAN_T(obi_a_chan_t, axi_addr_t, axi_data_t, obi_strb_t, axi_id_t,
                               obi_a_optional_t)
    `OBI_TYPEDEF_TYPE_R_CHAN_T(obi_r_chan_t, axi_data_t, axi_id_t, obi_r_optional_t)
    `OBI_TYPEDEF_REQ_T(obi_req_t, obi_a_chan_t)
    `OBI_TYPEDEF_RSP_T(obi_res_t, obi_r_chan_t)

    // OBI sim-mem cfg; UseRReady=1 so the mem honors the backend's rready
    function automatic obi_pkg::obi_cfg_t tb_obi_cfg();
        tb_obi_cfg = obi_pkg::obi_default_cfg(AxiAddrWidth, AxiDataWidth, AxiIdWidth,
                                              obi_pkg::ObiMinimalOptionalConfig);
        tb_obi_cfg.UseRReady = 1'b1;
    endfunction
    localparam obi_pkg::obi_cfg_t ObiCfg = tb_obi_cfg();

    // INIT meta-channel types
    `IDMA_TYPEDEF_INIT_ALL(init, AxiAddrWidth, AxiDataWidth, AxiDataWidth/8, AxiIdWidth)

    typedef axi_pkg::xbar_rule_64_t addr_rule_t;

    // Snitch accelerator bus (the inst64 frontend decodes data_op/argb)
    typedef struct packed {
        logic [31:0] id;
        logic [31:0] data_op;
        logic [63:0] data_arga;
        logic [63:0] data_argb;
    } acc_req_t;
    typedef struct packed {
        logic [31:0] id;
        logic [63:0] data;
        logic        error;
    } acc_res_t;

    // CV-X-IF subset as Snitch declares it (hw/snitch/include/cv_x_if/typedef.svh)
    localparam int unsigned XifIdWidth = 32'd4;
    typedef logic [XifIdWidth-1:0] xif_id_t;

    typedef struct packed {
        logic [31:0] instr;
        logic [31:0] hartid;
        xif_id_t     id;
    } x_issue_req_t;
    typedef struct packed {
        logic       accept;
        logic       writeback;
        logic [2:0] register_read;
    } x_issue_resp_t;
    typedef struct packed {
        logic [31:0]      hartid;
        xif_id_t          id;
        logic [2:0][31:0] rs;
        logic [2:0]       rs_valid;
    } x_register_t;
    typedef struct packed {
        logic [31:0] hartid;
        xif_id_t     id;
        logic        commit_kill;
    } x_commit_t;
    typedef struct packed {
        logic [31:0] hartid;
        xif_id_t     id;
        logic [31:0] data;
        logic [4:0]  rd;
        logic        we;
    } x_result_t;

    // The exported type, so the testbench cannot drift from the snitch_cluster contract
    `IDMA_TYPEDEF_EVENTS_T(dma_events_t, AxiDataWidth)

    // Captured accelerator response; the driver queues one entry per acc handshake
    typedef struct packed {
        logic [31:0] id;
        logic [63:0] data;
        logic        error;
    } acc_rsp_item_t;

    /// Strip the don't-care (z) bits out of an `idma_inst64_snitch_pkg` casez pattern.
    /// The localparams are match patterns, not drivable values; a zeroed encoding still
    /// matches its own casez item and no other (the funct7 fields are mutually exclusive).
    function automatic logic [31:0] inst_encoding(input logic [31:0] pattern);
        for (int unsigned i = 0; i < 32; i++) begin
            inst_encoding[i] = (pattern[i] === 1'b1) ? 1'b1 : 1'b0;
        end
    endfunction

endpackage

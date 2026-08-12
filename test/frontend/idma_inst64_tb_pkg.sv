// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

`include "axi/typedef.svh"
`include "obi/typedef.svh"

/// Concrete type binding for the `idma_inst64_top` testbenches. The types mirror
/// `test/idma_inst64_lint.sv`, the elaboration-proven binding of the frontend.
package idma_inst64_tb_pkg;

    localparam int unsigned AxiDataWidth    = 32'd512;
    localparam int unsigned AxiAddrWidth    = 32'd64;
    localparam int unsigned AxiUserWidth    = 32'd1;
    localparam int unsigned AxiIdWidth      = 32'd3;
    localparam int unsigned NumAxInFlight   = 32'd3;
    localparam int unsigned DMAReqFifoDepth = 32'd3;
    localparam int unsigned NumChannels     = 32'd1;
    // Tracer off; idma_inst64_top applies the rw_axi tracer macro to a
    // rw_axi_rw_init_rw_obi backend instance, which is a separate open issue.
    localparam int unsigned DMATracing      = 32'd0;

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

    // INIT meta-channel types (mirror src/db/idma_init.yml)
    typedef struct packed {
        logic [AxiAddrWidth-1:0]   cfg;
        logic [AxiDataWidth-1:0]   term;
        logic [AxiDataWidth/8-1:0] strb;
        logic [AxiIdWidth-1:0]     id;
    } init_req_chan_t;
    typedef struct packed {
        init_req_chan_t req_chan;
        logic           req_valid;
        logic           rsp_ready;
    } init_req_t;
    typedef struct packed {
        logic [AxiDataWidth-1:0] init;
    } init_rsp_chan_t;
    typedef struct packed {
        init_rsp_chan_t rsp_chan;
        logic           rsp_valid;
        logic           req_ready;
    } init_rsp_t;

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

    // obi_wr_req/obi_rd_req are required: idma_inst64_events drives them unconditionally
    typedef struct packed {
        logic           aw_valid, aw_ready, aw_done, aw_stall;
        axi_pkg::len_t  aw_len;
        axi_pkg::size_t aw_size;
        logic           ar_valid, ar_ready, ar_done, ar_stall;
        axi_pkg::len_t  ar_len;
        axi_pkg::size_t ar_size;
        logic           r_valid, r_ready, r_done, r_bw, r_stall;
        logic           w_valid, w_ready, w_done, w_stall;
        logic [31:0]    num_bytes_written;
        logic           b_valid, b_ready, b_done;
        logic           obi_wr_req, obi_rd_req;
        logic           dma_busy;
    } dma_events_t;

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

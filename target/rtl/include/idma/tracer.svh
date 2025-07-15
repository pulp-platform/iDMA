// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

// Macro holding all the resources for the iDMA backend tracer
`ifndef IDMA_TRACER_SVH_
`define IDMA_TRACER_SVH_

// largest type to trace
`define IDMA_TRACER_MAX_TYPE_WIDTH 1024
`define IDMA_TRACER_MAX_TYPE logic [`IDMA_TRACER_MAX_TYPE_WIDTH-1:0]

// string assembly function
`define IDMA_TRACER_STR_ASSEMBLY(__dict, __cond) \
    if(__cond) begin \
        trace = $sformatf("%s'%s':{", trace, `"__dict`"); \
        foreach(__dict``[key]) trace = $sformatf("%s'%s': 0x%0x,", trace, key, __dict``[key]); \
        trace = $sformatf("%s},", trace); \
    end

// helper to clear a condition
`define IDMA_TRACER_CLEAR_COND(__cond) \
    if(__cond) begin \
        __cond = ~__cond; \
    end

// The tracer for the rw_axi iDMA
`define IDMA_TRACER_RW_AXI(__backend_inst, __out_f) \
`ifndef SYNTHESIS \
    initial begin : inital_tracer_rw_axi \
        automatic bit first_iter = 1; \
        automatic integer tf; \
        automatic `IDMA_TRACER_MAX_TYPE cnst [string]; \
        automatic `IDMA_TRACER_MAX_TYPE meta [string]; \
        automatic `IDMA_TRACER_MAX_TYPE backend [string]; \
        automatic `IDMA_TRACER_MAX_TYPE busy [string]; \
        automatic `IDMA_TRACER_MAX_TYPE bus [string]; \
        automatic string trace; \
`ifndef VERILATOR \
        #0; \
`endif \
        tf = $fopen(__out_f, "w"); \
        $display("[iDMA Tracer] Logging %s to %s", `"__backend_inst`", __out_f); \
        forever begin \
            @(posedge __backend_inst``.clk_i); \
            if(__backend_inst``.rst_ni & (|__backend_inst``.busy_o | \
                                          __backend_inst``.req_valid_i | \
                                          __backend_inst``.rsp_valid_o)) begin \
                /* Trace */ \
                trace = "{"; \
                /* Constants */ \
                cnst = '{ \
                    "inst"               : `"__backend_inst`", \
                    "identifier"         : "rw_axi", \
                    "data_width"         : __backend_inst``.DataWidth, \
                    "addr_width"         : __backend_inst``.AddrWidth, \
                    "user_width"         : __backend_inst``.UserWidth, \
                    "axi_id_width"       : __backend_inst``.AxiIdWidth, \
                    "num_ax_in_flight"   : __backend_inst``.NumAxInFlight, \
                    "buffer_depth"       : __backend_inst``.BufferDepth, \
                    "tf_len_width"       : __backend_inst``.TFLenWidth, \
                    "mem_sys_depth"      : __backend_inst``.MemSysDepth, \
                    "combined_shifter"   : __backend_inst``.CombinedShifter, \
                    "rw_coupling_avail"  : __backend_inst``.RAWCouplingAvail, \
                    "mask_invalid_data"  : __backend_inst``.MaskInvalidData, \
                    "hardware_legalizer" : __backend_inst``.HardwareLegalizer, \
                    "reject_zero_tfs"    : __backend_inst``.RejectZeroTransfers, \
                    "error_cap"          : __backend_inst``.ErrorCap, \
                    "print_fifo_info"    : __backend_inst``.PrintFifoInfo \
                }; \
                meta = '{ \
                    "time" : $time() \
                }; \
                backend = '{ \
                    "req_valid"  : __backend_inst``.req_valid_i, \
                    "req_ready"  : __backend_inst``.req_ready_o, \
                    "rsp_valid"  : __backend_inst``.rsp_valid_o, \
                    "rsp_ready"  : __backend_inst``.rsp_ready_i, \
                    "req_length" : __backend_inst``.idma_req_i.length \
                }; \
                busy = '{ \
                    "buffer"      : __backend_inst``.busy_o.buffer_busy, \
                    "r_dp"        : __backend_inst``.busy_o.r_dp_busy, \
                    "w_dp"        : __backend_inst``.busy_o.w_dp_busy, \
                    "r_leg"       : __backend_inst``.busy_o.r_leg_busy, \
                    "w_leg"       : __backend_inst``.busy_o.w_leg_busy, \
                    "eh_fsm"      : __backend_inst``.busy_o.eh_fsm_busy, \
                    "eh_cnt"      : __backend_inst``.busy_o.eh_cnt_busy, \
                    "raw_coupler" : __backend_inst``.busy_o.raw_coupler_busy \
                }; \
                bus = '{ \
                    "axi_rsp_valid": __backend_inst``.axi_read_rsp_i.r_valid, \
                    "axi_rsp_ready": __backend_inst``.axi_read_req_o.r_ready, \
                    "axi_req_valid": __backend_inst``.axi_write_req_o.w_valid, \
                    "axi_req_ready": __backend_inst``.axi_write_rsp_i.w_ready, \
                    "axi_req_strobe": __backend_inst``.axi_write_req_o.w.strb \
                }; \
                /* Assembly */ \
                `IDMA_TRACER_STR_ASSEMBLY(cnst, first_iter); \
                `IDMA_TRACER_STR_ASSEMBLY(meta, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(backend, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(busy, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(bus, 1); \
                `IDMA_TRACER_CLEAR_COND(first_iter); \
                /* Commit */ \
                $fwrite(tf, $sformatf("%s}\n", trace)); \
            end \
        end \
    end \
`endif

// The tracer for the r_obi_w_axi iDMA
`define IDMA_TRACER_R_OBI_W_AXI(__backend_inst, __out_f) \
`ifndef SYNTHESIS \
    initial begin : inital_tracer_r_obi_w_axi \
        automatic bit first_iter = 1; \
        automatic integer tf; \
        automatic `IDMA_TRACER_MAX_TYPE cnst [string]; \
        automatic `IDMA_TRACER_MAX_TYPE meta [string]; \
        automatic `IDMA_TRACER_MAX_TYPE backend [string]; \
        automatic `IDMA_TRACER_MAX_TYPE busy [string]; \
        automatic `IDMA_TRACER_MAX_TYPE bus [string]; \
        automatic string trace; \
`ifndef VERILATOR \
        #0; \
`endif \
        tf = $fopen(__out_f, "w"); \
        $display("[iDMA Tracer] Logging %s to %s", `"__backend_inst`", __out_f); \
        forever begin \
            @(posedge __backend_inst``.clk_i); \
            if(__backend_inst``.rst_ni & (|__backend_inst``.busy_o | \
                                          __backend_inst``.req_valid_i | \
                                          __backend_inst``.rsp_valid_o)) begin \
                /* Trace */ \
                trace = "{"; \
                /* Constants */ \
                cnst = '{ \
                    "inst"               : `"__backend_inst`", \
                    "identifier"         : "r_obi_w_axi", \
                    "data_width"         : __backend_inst``.DataWidth, \
                    "addr_width"         : __backend_inst``.AddrWidth, \
                    "user_width"         : __backend_inst``.UserWidth, \
                    "axi_id_width"       : __backend_inst``.AxiIdWidth, \
                    "num_ax_in_flight"   : __backend_inst``.NumAxInFlight, \
                    "buffer_depth"       : __backend_inst``.BufferDepth, \
                    "tf_len_width"       : __backend_inst``.TFLenWidth, \
                    "mem_sys_depth"      : __backend_inst``.MemSysDepth, \
                    "combined_shifter"   : __backend_inst``.CombinedShifter, \
                    "rw_coupling_avail"  : __backend_inst``.RAWCouplingAvail, \
                    "mask_invalid_data"  : __backend_inst``.MaskInvalidData, \
                    "hardware_legalizer" : __backend_inst``.HardwareLegalizer, \
                    "reject_zero_tfs"    : __backend_inst``.RejectZeroTransfers, \
                    "error_cap"          : __backend_inst``.ErrorCap, \
                    "print_fifo_info"    : __backend_inst``.PrintFifoInfo \
                }; \
                meta = '{ \
                    "time" : $time() \
                }; \
                backend = '{ \
                    "req_valid"  : __backend_inst``.req_valid_i, \
                    "req_ready"  : __backend_inst``.req_ready_o, \
                    "rsp_valid"  : __backend_inst``.rsp_valid_o, \
                    "rsp_ready"  : __backend_inst``.rsp_ready_i, \
                    "req_length" : __backend_inst``.idma_req_i.length \
                }; \
                busy = '{ \
                    "buffer"      : __backend_inst``.busy_o.buffer_busy, \
                    "r_dp"        : __backend_inst``.busy_o.r_dp_busy, \
                    "w_dp"        : __backend_inst``.busy_o.w_dp_busy, \
                    "r_leg"       : __backend_inst``.busy_o.r_leg_busy, \
                    "w_leg"       : __backend_inst``.busy_o.w_leg_busy, \
                    "eh_fsm"      : __backend_inst``.busy_o.eh_fsm_busy, \
                    "eh_cnt"      : __backend_inst``.busy_o.eh_cnt_busy, \
                    "raw_coupler" : __backend_inst``.busy_o.raw_coupler_busy \
                }; \
                bus = '{ \
                    "obi_rsp_valid": __backend_inst``.obi_read_req_o.req, \
                    "obi_rsp_ready": __backend_inst``.obi_read_rsp_i.gnt, \
                    "obi_rsp_write_en": __backend_inst``.obi_read_req_o.a.we, \
                    "axi_req_valid": __backend_inst``.axi_write_req_o.w_valid, \
                    "axi_req_ready": __backend_inst``.axi_write_rsp_i.w_ready, \
                    "axi_req_strobe": __backend_inst``.axi_write_req_o.w.strb \
                }; \
                /* Assembly */ \
                `IDMA_TRACER_STR_ASSEMBLY(cnst, first_iter); \
                `IDMA_TRACER_STR_ASSEMBLY(meta, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(backend, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(busy, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(bus, 1); \
                `IDMA_TRACER_CLEAR_COND(first_iter); \
                /* Commit */ \
                $fwrite(tf, $sformatf("%s}\n", trace)); \
            end \
        end \
    end \
`endif

// The tracer for the r_axi_w_obi iDMA
`define IDMA_TRACER_R_AXI_W_OBI(__backend_inst, __out_f) \
`ifndef SYNTHESIS \
    initial begin : inital_tracer_r_axi_w_obi \
        automatic bit first_iter = 1; \
        automatic integer tf; \
        automatic `IDMA_TRACER_MAX_TYPE cnst [string]; \
        automatic `IDMA_TRACER_MAX_TYPE meta [string]; \
        automatic `IDMA_TRACER_MAX_TYPE backend [string]; \
        automatic `IDMA_TRACER_MAX_TYPE busy [string]; \
        automatic `IDMA_TRACER_MAX_TYPE bus [string]; \
        automatic string trace; \
`ifndef VERILATOR \
        #0; \
`endif \
        tf = $fopen(__out_f, "w"); \
        $display("[iDMA Tracer] Logging %s to %s", `"__backend_inst`", __out_f); \
        forever begin \
            @(posedge __backend_inst``.clk_i); \
            if(__backend_inst``.rst_ni & (|__backend_inst``.busy_o | \
                                          __backend_inst``.req_valid_i | \
                                          __backend_inst``.rsp_valid_o)) begin \
                /* Trace */ \
                trace = "{"; \
                /* Constants */ \
                cnst = '{ \
                    "inst"               : `"__backend_inst`", \
                    "identifier"         : "r_axi_w_obi", \
                    "data_width"         : __backend_inst``.DataWidth, \
                    "addr_width"         : __backend_inst``.AddrWidth, \
                    "user_width"         : __backend_inst``.UserWidth, \
                    "axi_id_width"       : __backend_inst``.AxiIdWidth, \
                    "num_ax_in_flight"   : __backend_inst``.NumAxInFlight, \
                    "buffer_depth"       : __backend_inst``.BufferDepth, \
                    "tf_len_width"       : __backend_inst``.TFLenWidth, \
                    "mem_sys_depth"      : __backend_inst``.MemSysDepth, \
                    "combined_shifter"   : __backend_inst``.CombinedShifter, \
                    "rw_coupling_avail"  : __backend_inst``.RAWCouplingAvail, \
                    "mask_invalid_data"  : __backend_inst``.MaskInvalidData, \
                    "hardware_legalizer" : __backend_inst``.HardwareLegalizer, \
                    "reject_zero_tfs"    : __backend_inst``.RejectZeroTransfers, \
                    "error_cap"          : __backend_inst``.ErrorCap, \
                    "print_fifo_info"    : __backend_inst``.PrintFifoInfo \
                }; \
                meta = '{ \
                    "time" : $time() \
                }; \
                backend = '{ \
                    "req_valid"  : __backend_inst``.req_valid_i, \
                    "req_ready"  : __backend_inst``.req_ready_o, \
                    "rsp_valid"  : __backend_inst``.rsp_valid_o, \
                    "rsp_ready"  : __backend_inst``.rsp_ready_i, \
                    "req_length" : __backend_inst``.idma_req_i.length \
                }; \
                busy = '{ \
                    "buffer"      : __backend_inst``.busy_o.buffer_busy, \
                    "r_dp"        : __backend_inst``.busy_o.r_dp_busy, \
                    "w_dp"        : __backend_inst``.busy_o.w_dp_busy, \
                    "r_leg"       : __backend_inst``.busy_o.r_leg_busy, \
                    "w_leg"       : __backend_inst``.busy_o.w_leg_busy, \
                    "eh_fsm"      : __backend_inst``.busy_o.eh_fsm_busy, \
                    "eh_cnt"      : __backend_inst``.busy_o.eh_cnt_busy, \
                    "raw_coupler" : __backend_inst``.busy_o.raw_coupler_busy \
                }; \
                bus = '{ \
                    "axi_rsp_valid": __backend_inst``.axi_read_rsp_i.r_valid, \
                    "axi_rsp_ready": __backend_inst``.axi_read_req_o.r_ready, \
                    "obi_req_valid": __backend_inst``.obi_write_req_o.req, \
                    "obi_req_ready": __backend_inst``.obi_write_rsp_i.gnt, \
                    "obi_req_strobe": __backend_inst``.obi_write_req_o.a.be, \
                    "obi_req_write_en": __backend_inst``.obi_write_req_o.a.we \
                }; \
                /* Assembly */ \
                `IDMA_TRACER_STR_ASSEMBLY(cnst, first_iter); \
                `IDMA_TRACER_STR_ASSEMBLY(meta, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(backend, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(busy, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(bus, 1); \
                `IDMA_TRACER_CLEAR_COND(first_iter); \
                /* Commit */ \
                $fwrite(tf, $sformatf("%s}\n", trace)); \
            end \
        end \
    end \
`endif

// The tracer for the rw_axi_rw_axis iDMA
`define IDMA_TRACER_RW_AXI_RW_AXIS(__backend_inst, __out_f) \
`ifndef SYNTHESIS \
    initial begin : inital_tracer_rw_axi_rw_axis \
        automatic bit first_iter = 1; \
        automatic integer tf; \
        automatic `IDMA_TRACER_MAX_TYPE cnst [string]; \
        automatic `IDMA_TRACER_MAX_TYPE meta [string]; \
        automatic `IDMA_TRACER_MAX_TYPE backend [string]; \
        automatic `IDMA_TRACER_MAX_TYPE busy [string]; \
        automatic `IDMA_TRACER_MAX_TYPE bus [string]; \
        automatic string trace; \
`ifndef VERILATOR \
        #0; \
`endif \
        tf = $fopen(__out_f, "w"); \
        $display("[iDMA Tracer] Logging %s to %s", `"__backend_inst`", __out_f); \
        forever begin \
            @(posedge __backend_inst``.clk_i); \
            if(__backend_inst``.rst_ni & (|__backend_inst``.busy_o | \
                                          __backend_inst``.req_valid_i | \
                                          __backend_inst``.rsp_valid_o)) begin \
                /* Trace */ \
                trace = "{"; \
                /* Constants */ \
                cnst = '{ \
                    "inst"               : `"__backend_inst`", \
                    "identifier"         : "rw_axi_rw_axis", \
                    "data_width"         : __backend_inst``.DataWidth, \
                    "addr_width"         : __backend_inst``.AddrWidth, \
                    "user_width"         : __backend_inst``.UserWidth, \
                    "axi_id_width"       : __backend_inst``.AxiIdWidth, \
                    "num_ax_in_flight"   : __backend_inst``.NumAxInFlight, \
                    "buffer_depth"       : __backend_inst``.BufferDepth, \
                    "tf_len_width"       : __backend_inst``.TFLenWidth, \
                    "mem_sys_depth"      : __backend_inst``.MemSysDepth, \
                    "combined_shifter"   : __backend_inst``.CombinedShifter, \
                    "rw_coupling_avail"  : __backend_inst``.RAWCouplingAvail, \
                    "mask_invalid_data"  : __backend_inst``.MaskInvalidData, \
                    "hardware_legalizer" : __backend_inst``.HardwareLegalizer, \
                    "reject_zero_tfs"    : __backend_inst``.RejectZeroTransfers, \
                    "error_cap"          : __backend_inst``.ErrorCap, \
                    "print_fifo_info"    : __backend_inst``.PrintFifoInfo \
                }; \
                meta = '{ \
                    "time" : $time() \
                }; \
                backend = '{ \
                    "req_valid"  : __backend_inst``.req_valid_i, \
                    "req_ready"  : __backend_inst``.req_ready_o, \
                    "rsp_valid"  : __backend_inst``.rsp_valid_o, \
                    "rsp_ready"  : __backend_inst``.rsp_ready_i, \
                    "req_length" : __backend_inst``.idma_req_i.length \
                }; \
                busy = '{ \
                    "buffer"      : __backend_inst``.busy_o.buffer_busy, \
                    "r_dp"        : __backend_inst``.busy_o.r_dp_busy, \
                    "w_dp"        : __backend_inst``.busy_o.w_dp_busy, \
                    "r_leg"       : __backend_inst``.busy_o.r_leg_busy, \
                    "w_leg"       : __backend_inst``.busy_o.w_leg_busy, \
                    "eh_fsm"      : __backend_inst``.busy_o.eh_fsm_busy, \
                    "eh_cnt"      : __backend_inst``.busy_o.eh_cnt_busy, \
                    "raw_coupler" : __backend_inst``.busy_o.raw_coupler_busy \
                }; \
                bus = '{ \
                    "axi_rsp_valid": __backend_inst``.axi_read_rsp_i.r_valid, \
                    "axi_rsp_ready": __backend_inst``.axi_read_req_o.r_ready, \
                    "axis_rsp_valid": __backend_inst``.axis_read_req_i.tvalid, \
                    "axis_rsp_ready": __backend_inst``.axis_read_rsp_o.tready, \
                    "axis_rsp_strobe": __backend_inst``.axis_read_req_i.t.strb, \
                    "axi_req_valid": __backend_inst``.axi_write_req_o.w_valid, \
                    "axi_req_ready": __backend_inst``.axi_write_rsp_i.w_ready, \
                    "axi_req_strobe": __backend_inst``.axi_write_req_o.w.strb, \
                    "axis_req_valid": __backend_inst``.axis_write_req_o.tvalid, \
                    "axis_req_ready": __backend_inst``.axis_write_rsp_i.tready, \
                    "axis_req_strobe": __backend_inst``.axis_write_req_o.t.strb \
                }; \
                /* Assembly */ \
                `IDMA_TRACER_STR_ASSEMBLY(cnst, first_iter); \
                `IDMA_TRACER_STR_ASSEMBLY(meta, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(backend, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(busy, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(bus, 1); \
                `IDMA_TRACER_CLEAR_COND(first_iter); \
                /* Commit */ \
                $fwrite(tf, $sformatf("%s}\n", trace)); \
            end \
        end \
    end \
`endif

// The tracer for the r_obi_rw_init_w_axi iDMA
`define IDMA_TRACER_R_OBI_RW_INIT_W_AXI(__backend_inst, __out_f) \
`ifndef SYNTHESIS \
    initial begin : inital_tracer_r_obi_rw_init_w_axi \
        automatic bit first_iter = 1; \
        automatic integer tf; \
        automatic `IDMA_TRACER_MAX_TYPE cnst [string]; \
        automatic `IDMA_TRACER_MAX_TYPE meta [string]; \
        automatic `IDMA_TRACER_MAX_TYPE backend [string]; \
        automatic `IDMA_TRACER_MAX_TYPE busy [string]; \
        automatic `IDMA_TRACER_MAX_TYPE bus [string]; \
        automatic string trace; \
`ifndef VERILATOR \
        #0; \
`endif \
        tf = $fopen(__out_f, "w"); \
        $display("[iDMA Tracer] Logging %s to %s", `"__backend_inst`", __out_f); \
        forever begin \
            @(posedge __backend_inst``.clk_i); \
            if(__backend_inst``.rst_ni & (|__backend_inst``.busy_o | \
                                          __backend_inst``.req_valid_i | \
                                          __backend_inst``.rsp_valid_o)) begin \
                /* Trace */ \
                trace = "{"; \
                /* Constants */ \
                cnst = '{ \
                    "inst"               : `"__backend_inst`", \
                    "identifier"         : "r_obi_rw_init_w_axi", \
                    "data_width"         : __backend_inst``.DataWidth, \
                    "addr_width"         : __backend_inst``.AddrWidth, \
                    "user_width"         : __backend_inst``.UserWidth, \
                    "axi_id_width"       : __backend_inst``.AxiIdWidth, \
                    "num_ax_in_flight"   : __backend_inst``.NumAxInFlight, \
                    "buffer_depth"       : __backend_inst``.BufferDepth, \
                    "tf_len_width"       : __backend_inst``.TFLenWidth, \
                    "mem_sys_depth"      : __backend_inst``.MemSysDepth, \
                    "combined_shifter"   : __backend_inst``.CombinedShifter, \
                    "rw_coupling_avail"  : __backend_inst``.RAWCouplingAvail, \
                    "mask_invalid_data"  : __backend_inst``.MaskInvalidData, \
                    "hardware_legalizer" : __backend_inst``.HardwareLegalizer, \
                    "reject_zero_tfs"    : __backend_inst``.RejectZeroTransfers, \
                    "error_cap"          : __backend_inst``.ErrorCap, \
                    "print_fifo_info"    : __backend_inst``.PrintFifoInfo \
                }; \
                meta = '{ \
                    "time" : $time() \
                }; \
                backend = '{ \
                    "req_valid"  : __backend_inst``.req_valid_i, \
                    "req_ready"  : __backend_inst``.req_ready_o, \
                    "rsp_valid"  : __backend_inst``.rsp_valid_o, \
                    "rsp_ready"  : __backend_inst``.rsp_ready_i, \
                    "req_length" : __backend_inst``.idma_req_i.length \
                }; \
                busy = '{ \
                    "buffer"      : __backend_inst``.busy_o.buffer_busy, \
                    "r_dp"        : __backend_inst``.busy_o.r_dp_busy, \
                    "w_dp"        : __backend_inst``.busy_o.w_dp_busy, \
                    "r_leg"       : __backend_inst``.busy_o.r_leg_busy, \
                    "w_leg"       : __backend_inst``.busy_o.w_leg_busy, \
                    "eh_fsm"      : __backend_inst``.busy_o.eh_fsm_busy, \
                    "eh_cnt"      : __backend_inst``.busy_o.eh_cnt_busy, \
                    "raw_coupler" : __backend_inst``.busy_o.raw_coupler_busy \
                }; \
                bus = '{ \
                    "init_req_valid": __backend_inst``.init_read_req_o.req_valid, \
                    "init_req_config": __backend_inst``.init_read_req_o.req_chan.cfg, \
                    "init_req_ready": __backend_inst``.init_read_rsp_i.req_ready, \
                    "init_rsp_valid": __backend_inst``.init_read_rsp_i.rsp_valid, \
                    "init_rsp_ready": __backend_inst``.init_read_req_o.rsp_ready, \
                    "obi_rsp_valid": __backend_inst``.obi_read_req_o.req, \
                    "obi_rsp_ready": __backend_inst``.obi_read_rsp_i.gnt, \
                    "obi_rsp_write_en": __backend_inst``.obi_read_req_o.a.we, \
                    "axi_req_valid": __backend_inst``.axi_write_req_o.w_valid, \
                    "axi_req_ready": __backend_inst``.axi_write_rsp_i.w_ready, \
                    "axi_req_strobe": __backend_inst``.axi_write_req_o.w.strb, \
                    "init_req_valid": __backend_inst``.init_write_req_o.req_valid, \
                    "init_req_config": __backend_inst``.init_write_req_o.req_chan.cfg, \
                    "init_req_data": __backend_inst``.init_write_req_o.req_chan.term, \
                    "init_req_ready": __backend_inst``.init_write_rsp_i.req_ready, \
                    "init_rsp_valid": __backend_inst``.init_write_rsp_i.rsp_valid, \
                    "init_rsp_ready": __backend_inst``.init_write_req_o.rsp_ready \
                }; \
                /* Assembly */ \
                `IDMA_TRACER_STR_ASSEMBLY(cnst, first_iter); \
                `IDMA_TRACER_STR_ASSEMBLY(meta, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(backend, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(busy, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(bus, 1); \
                `IDMA_TRACER_CLEAR_COND(first_iter); \
                /* Commit */ \
                $fwrite(tf, $sformatf("%s}\n", trace)); \
            end \
        end \
    end \
`endif

// The tracer for the r_axi_rw_init_rw_obi iDMA
`define IDMA_TRACER_R_AXI_RW_INIT_RW_OBI(__backend_inst, __out_f) \
`ifndef SYNTHESIS \
    initial begin : inital_tracer_r_axi_rw_init_rw_obi \
        automatic bit first_iter = 1; \
        automatic integer tf; \
        automatic `IDMA_TRACER_MAX_TYPE cnst [string]; \
        automatic `IDMA_TRACER_MAX_TYPE meta [string]; \
        automatic `IDMA_TRACER_MAX_TYPE backend [string]; \
        automatic `IDMA_TRACER_MAX_TYPE busy [string]; \
        automatic `IDMA_TRACER_MAX_TYPE bus [string]; \
        automatic string trace; \
`ifndef VERILATOR \
        #0; \
`endif \
        tf = $fopen(__out_f, "w"); \
        $display("[iDMA Tracer] Logging %s to %s", `"__backend_inst`", __out_f); \
        forever begin \
            @(posedge __backend_inst``.clk_i); \
            if(__backend_inst``.rst_ni & (|__backend_inst``.busy_o | \
                                          __backend_inst``.req_valid_i | \
                                          __backend_inst``.rsp_valid_o)) begin \
                /* Trace */ \
                trace = "{"; \
                /* Constants */ \
                cnst = '{ \
                    "inst"               : `"__backend_inst`", \
                    "identifier"         : "r_axi_rw_init_rw_obi", \
                    "data_width"         : __backend_inst``.DataWidth, \
                    "addr_width"         : __backend_inst``.AddrWidth, \
                    "user_width"         : __backend_inst``.UserWidth, \
                    "axi_id_width"       : __backend_inst``.AxiIdWidth, \
                    "num_ax_in_flight"   : __backend_inst``.NumAxInFlight, \
                    "buffer_depth"       : __backend_inst``.BufferDepth, \
                    "tf_len_width"       : __backend_inst``.TFLenWidth, \
                    "mem_sys_depth"      : __backend_inst``.MemSysDepth, \
                    "combined_shifter"   : __backend_inst``.CombinedShifter, \
                    "rw_coupling_avail"  : __backend_inst``.RAWCouplingAvail, \
                    "mask_invalid_data"  : __backend_inst``.MaskInvalidData, \
                    "hardware_legalizer" : __backend_inst``.HardwareLegalizer, \
                    "reject_zero_tfs"    : __backend_inst``.RejectZeroTransfers, \
                    "error_cap"          : __backend_inst``.ErrorCap, \
                    "print_fifo_info"    : __backend_inst``.PrintFifoInfo \
                }; \
                meta = '{ \
                    "time" : $time() \
                }; \
                backend = '{ \
                    "req_valid"  : __backend_inst``.req_valid_i, \
                    "req_ready"  : __backend_inst``.req_ready_o, \
                    "rsp_valid"  : __backend_inst``.rsp_valid_o, \
                    "rsp_ready"  : __backend_inst``.rsp_ready_i, \
                    "req_length" : __backend_inst``.idma_req_i.length \
                }; \
                busy = '{ \
                    "buffer"      : __backend_inst``.busy_o.buffer_busy, \
                    "r_dp"        : __backend_inst``.busy_o.r_dp_busy, \
                    "w_dp"        : __backend_inst``.busy_o.w_dp_busy, \
                    "r_leg"       : __backend_inst``.busy_o.r_leg_busy, \
                    "w_leg"       : __backend_inst``.busy_o.w_leg_busy, \
                    "eh_fsm"      : __backend_inst``.busy_o.eh_fsm_busy, \
                    "eh_cnt"      : __backend_inst``.busy_o.eh_cnt_busy, \
                    "raw_coupler" : __backend_inst``.busy_o.raw_coupler_busy \
                }; \
                bus = '{ \
                    "axi_rsp_valid": __backend_inst``.axi_read_rsp_i.r_valid, \
                    "axi_rsp_ready": __backend_inst``.axi_read_req_o.r_ready, \
                    "init_req_valid": __backend_inst``.init_read_req_o.req_valid, \
                    "init_req_config": __backend_inst``.init_read_req_o.req_chan.cfg, \
                    "init_req_ready": __backend_inst``.init_read_rsp_i.req_ready, \
                    "init_rsp_valid": __backend_inst``.init_read_rsp_i.rsp_valid, \
                    "init_rsp_ready": __backend_inst``.init_read_req_o.rsp_ready, \
                    "obi_rsp_valid": __backend_inst``.obi_read_req_o.req, \
                    "obi_rsp_ready": __backend_inst``.obi_read_rsp_i.gnt, \
                    "obi_rsp_write_en": __backend_inst``.obi_read_req_o.a.we, \
                    "init_req_valid": __backend_inst``.init_write_req_o.req_valid, \
                    "init_req_config": __backend_inst``.init_write_req_o.req_chan.cfg, \
                    "init_req_data": __backend_inst``.init_write_req_o.req_chan.term, \
                    "init_req_ready": __backend_inst``.init_write_rsp_i.req_ready, \
                    "init_rsp_valid": __backend_inst``.init_write_rsp_i.rsp_valid, \
                    "init_rsp_ready": __backend_inst``.init_write_req_o.rsp_ready, \
                    "obi_req_valid": __backend_inst``.obi_write_req_o.req, \
                    "obi_req_ready": __backend_inst``.obi_write_rsp_i.gnt, \
                    "obi_req_strobe": __backend_inst``.obi_write_req_o.a.be, \
                    "obi_req_write_en": __backend_inst``.obi_write_req_o.a.we \
                }; \
                /* Assembly */ \
                `IDMA_TRACER_STR_ASSEMBLY(cnst, first_iter); \
                `IDMA_TRACER_STR_ASSEMBLY(meta, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(backend, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(busy, 1); \
                `IDMA_TRACER_STR_ASSEMBLY(bus, 1); \
                `IDMA_TRACER_CLEAR_COND(first_iter); \
                /* Commit */ \
                $fwrite(tf, $sformatf("%s}\n", trace)); \
            end \
        end \
    end \
`endif

`endif


#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO tracer interaction"""
import flatdict
from mako.template import Template

TRACER_BODY = '''
// The tracer for the ${identifier} iDMA
`define IDMA_TRACER_${identifier_cap}(__backend_inst, __out_f) <%text>\\</%text>
`ifndef SYNTHESIS <%text>\\</%text>
    initial begin : inital_tracer_${identifier} <%text>\\</%text>
        automatic bit first_iter = 1; <%text>\\</%text>
        automatic integer tf; <%text>\\</%text>
        automatic `IDMA_TRACER_MAX_TYPE cnst [string]; <%text>\\</%text>
        automatic `IDMA_TRACER_MAX_TYPE meta [string]; <%text>\\</%text>
        automatic `IDMA_TRACER_MAX_TYPE backend [string]; <%text>\\</%text>
        automatic `IDMA_TRACER_MAX_TYPE busy [string]; <%text>\\</%text>
        automatic `IDMA_TRACER_MAX_TYPE bus [string]; <%text>\\</%text>
        automatic string trace; <%text>\\</%text>
`ifndef VERILATOR <%text>\\</%text>
        #0; <%text>\\</%text>
`endif <%text>\\</%text>
        tf = $fopen(__out_f, "w"); <%text>\\</%text>
        $display("[iDMA Tracer] Logging %s to %s", `"__backend_inst`", __out_f); <%text>\\</%text>
        forever begin <%text>\\</%text>
            @(posedge __backend_inst``.clk_i); <%text>\\</%text>
            if(__backend_inst``.rst_ni & (|__backend_inst``.busy_o | <%text>\\</%text>
                                          __backend_inst``.req_valid_i | <%text>\\</%text>
                                          __backend_inst``.rsp_valid_o)) begin <%text>\\</%text>
                /* Trace */ <%text>\\</%text>
                trace = "{"; <%text>\\</%text>
                /* Constants */ <%text>\\</%text>
                cnst = '{ <%text>\\</%text>
                    "inst"               : `"__backend_inst`", <%text>\\</%text>
                    "identifier"         : "${identifier}", <%text>\\</%text>
                    "data_width"         : __backend_inst``.DataWidth, <%text>\\</%text>
                    "addr_width"         : __backend_inst``.AddrWidth, <%text>\\</%text>
                    "user_width"         : __backend_inst``.UserWidth, <%text>\\</%text>
                    "axi_id_width"       : __backend_inst``.AxiIdWidth, <%text>\\</%text>
                    "num_ax_in_flight"   : __backend_inst``.NumAxInFlight, <%text>\\</%text>
                    "buffer_depth"       : __backend_inst``.BufferDepth, <%text>\\</%text>
                    "tf_len_width"       : __backend_inst``.TFLenWidth, <%text>\\</%text>
                    "mem_sys_depth"      : __backend_inst``.MemSysDepth, <%text>\\</%text>
                    "combined_shifter"   : __backend_inst``.CombinedShifter, <%text>\\</%text>
                    "rw_coupling_avail"  : __backend_inst``.RAWCouplingAvail, <%text>\\</%text>
                    "mask_invalid_data"  : __backend_inst``.MaskInvalidData, <%text>\\</%text>
                    "hardware_legalizer" : __backend_inst``.HardwareLegalizer, <%text>\\</%text>
                    "reject_zero_tfs"    : __backend_inst``.RejectZeroTransfers, <%text>\\</%text>
                    "error_cap"          : __backend_inst``.ErrorCap, <%text>\\</%text>
                    "print_fifo_info"    : __backend_inst``.PrintFifoInfo <%text>\\</%text>
                }; <%text>\\</%text>
                meta = '{ <%text>\\</%text>
                    "time" : $time() <%text>\\</%text>
                }; <%text>\\</%text>
                backend = '{ <%text>\\</%text>
                    "req_valid"  : __backend_inst``.req_valid_i, <%text>\\</%text>
                    "req_ready"  : __backend_inst``.req_ready_o, <%text>\\</%text>
                    "rsp_valid"  : __backend_inst``.rsp_valid_o, <%text>\\</%text>
                    "rsp_ready"  : __backend_inst``.rsp_ready_i, <%text>\\</%text>
                    "req_length" : __backend_inst``.idma_req_i.length <%text>\\</%text>
                }; <%text>\\</%text>
                busy = '{ <%text>\\</%text>
                    "buffer"      : __backend_inst``.busy_o.buffer_busy, <%text>\\</%text>
                    "r_dp"        : __backend_inst``.busy_o.r_dp_busy, <%text>\\</%text>
                    "w_dp"        : __backend_inst``.busy_o.w_dp_busy, <%text>\\</%text>
                    "r_leg"       : __backend_inst``.busy_o.r_leg_busy, <%text>\\</%text>
                    "w_leg"       : __backend_inst``.busy_o.w_leg_busy, <%text>\\</%text>
                    "eh_fsm"      : __backend_inst``.busy_o.eh_fsm_busy, <%text>\\</%text>
                    "eh_cnt"      : __backend_inst``.busy_o.eh_cnt_busy, <%text>\\</%text>
                    "raw_coupler" : __backend_inst``.busy_o.raw_coupler_busy <%text>\\</%text>
                }; <%text>\\</%text>
                bus = '{ <%text>\\</%text>
${signals}
                }; <%text>\\</%text>
                /* Assembly */ <%text>\\</%text>
                `IDMA_TRACER_STR_ASSEMBLY(cnst, first_iter); <%text>\\</%text>
                `IDMA_TRACER_STR_ASSEMBLY(meta, 1); <%text>\\</%text>
                `IDMA_TRACER_STR_ASSEMBLY(backend, 1); <%text>\\</%text>
                `IDMA_TRACER_STR_ASSEMBLY(busy, 1); <%text>\\</%text>
                `IDMA_TRACER_STR_ASSEMBLY(bus, 1); <%text>\\</%text>
                `IDMA_TRACER_CLEAR_COND(first_iter); <%text>\\</%text>
                /* Commit */ <%text>\\</%text>
                $fwrite(tf, $sformatf("%s}<%text>\\</%text>n", trace)); <%text>\\</%text>
            end <%text>\\</%text>
        end <%text>\\</%text>
    end <%text>\\</%text>
`endif
'''


def render_tracer(prot_ids: dict, db: dict, tpl_file: str) -> str:
    """Generate racer"""
    tracer_body = ''

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        tracer_tpl = templ_file.read()

    # render for every is
    for prot_id in prot_ids:

        # signals
        signals = ''

        # handle read ports
        for read_prot in prot_ids[prot_id]['ar']:
            sig_dict = flatdict.FlatDict(db[read_prot]['trace_signals']['read'], delimiter='_')
            for signal in sig_dict:
                signals += '                    '
                signals += f'"{read_prot}_{signal}": __backend_inst``.{sig_dict[signal]}'
                signals += ', \\\n'

        for write_prot in prot_ids[prot_id]['aw']:
            sig_dict = flatdict.FlatDict(db[write_prot]['trace_signals']['write'], delimiter='_')
            for signal in sig_dict:
                signals += '                    '
                signals += f'"{write_prot}_{signal}": __backend_inst``.{sig_dict[signal]}'
                signals += ', \\\n'

        # post-processing
        signals = signals[:-4] + ' \\'

        context_body = {
            'identifier': prot_id,
            'identifier_cap': prot_id.upper(),
            'signals': signals
        }

        # render
        tracer_body += Template(TRACER_BODY).render(**context_body)

    # render tracer context
    context = {
        'body': tracer_body
    }

    return Template(tracer_tpl).render(**context)

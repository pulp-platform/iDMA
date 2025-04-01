#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO transport layer interaction"""
from mako.template import Template


def render_read_mgr_inst(prot_id: str, prot_ids: dict, db: dict) -> dict:
    """Renders the port instantiations of the read managers"""

    res = {}

    # single read port
    srp = len(prot_ids[prot_id]['ar']) == 1

    # Render read ports
    for rp in prot_ids[prot_id]['ar']:

        res[rp] = ''

        # prepare multihead snippets
        num_heads = prot_ids[prot_id]['multihead']['r'][rp]

        # treat multi head config as multi protocol config
        srp &= num_heads == 1

        # template cleanup
        db[rp]['read_template'] = '    ' + db[rp]['read_template'].replace('\n', '\n    ')
        db[rp]['read_template'] = db[rp]['read_template'][:-5]

        # iterate over heads
        for curr_head in range(0, num_heads):

            if num_heads == 1:
                mh = ''
                mh_bus = ''
            else:
                mh = f'_{curr_head}'
                mh_bus = f' [{curr_head}]'

            if db[rp]['read_slave'] == 'true':
                read_req_str = f'{rp}_read_req_t'
                read_rsp_str = f'{rp}_read_rsp_t'
            else:
                read_req_str = f'{rp}_req_t'
                read_rsp_str = f'{rp}_rsp_t'

            if db[rp]['passive_req'] == 'true':
                read_port_dir_req_str = 'i'
                read_port_dir_rsp_str = 'o'
            else:
                read_port_dir_req_str = 'o'
                read_port_dir_rsp_str = 'i'

            if srp:
                read_dp_valid_in = 'r_dp_valid_i'
                read_dp_ready_out = 'r_dp_ready_o'
                read_dp_response = 'r_dp_rsp_o'
                read_dp_valid_out = 'r_dp_valid_o'
                read_dp_ready_in = 'r_dp_ready_i'
                read_meta_request = 'ar_req_i'
                read_meta_valid = 'ar_valid_i'
                read_meta_ready = 'ar_ready_o'
                r_chan_valid = 'r_chan_valid_o'
                r_chan_ready = 'r_chan_ready_o'
                buffer_in = 'buffer_in'
                buffer_in_valid = 'buffer_in_valid'
            else:
                if num_heads == 1:
                    read_dp_valid_in = f'''\
(r_dp_req_i.src_protocol == idma_pkg::{db[rp]["protocol_enum"]}) & \
r_dp_valid_i\
'''
                else:
                    read_dp_valid_in = f'''\
(r_dp_req_i.src_protocol == idma_pkg::{db[rp]["protocol_enum"]}) & \
(r_dp_req_i.src_head == {curr_head}) & \
r_dp_valid_i\
'''
                read_dp_ready_out = f'{rp}_r_dp_ready{mh_bus}'
                read_dp_response = f'{rp}_r_dp_rsp{mh_bus}'
                read_dp_valid_out = f'{rp}_r_dp_valid{mh_bus}'
                if num_heads == 1:
                    read_dp_ready_in = f'''\
(r_dp_req_i.src_protocol == idma_pkg::{db[rp]["protocol_enum"]}) & \
r_dp_ready_i\
'''
                else:
                    read_dp_ready_in = f'''\
(r_dp_req_i.src_protocol == idma_pkg::{db[rp]["protocol_enum"]}) & \
(r_dp_req_i.src_head == {curr_head}) & \
r_dp_ready_i\
'''
                read_meta_request = 'ar_req_i.ar_req'
                if num_heads == 1:
                    read_meta_valid = f'''\
(ar_req_i.src_protocol == idma_pkg::{db[rp]["protocol_enum"]}) & \
ar_valid_i\
'''
                else:
                    read_meta_valid = f'''\
(ar_req_i.src_protocol == idma_pkg::{db[rp]["protocol_enum"]}) & \
(r_dp_req_i.src_head == {curr_head}) & \
ar_valid_i\
'''
                read_meta_ready = f'{rp}_ar_ready{mh_bus}'
                r_chan_valid = f'{rp}_r_chan_valid{mh_bus}'
                r_chan_ready = f'{rp}_r_chan_ready{mh_bus}'
                buffer_in = f'{rp}_buffer_in{mh_bus}'
                buffer_in_valid = f'{rp}_buffer_in_valid{mh_bus}'

            read_port_context = {
                'database': db,
                'req_t': read_req_str,
                'rsp_t': read_rsp_str,
                'r_dp_valid_i': read_dp_valid_in,
                'r_dp_ready_o': read_dp_ready_out,
                'r_dp_rsp_o': read_dp_response,
                'r_dp_valid_o': read_dp_valid_out,
                'r_dp_ready_i': read_dp_ready_in,
                'read_meta_request': read_meta_request,
                'read_meta_valid': read_meta_valid,
                'read_meta_ready': read_meta_ready,
                'read_request': f'{rp}_read_req_{read_port_dir_req_str}',
                'read_response': f'{rp}_read_rsp_{read_port_dir_rsp_str}',
                'r_chan_valid': r_chan_valid,
                'r_chan_ready': r_chan_ready,
                'buffer_in': buffer_in,
                'buffer_in_valid': buffer_in_valid,
                'mh': mh
            }

            if curr_head > 0:
                res[rp] += '\n\n'

            # render
            res[rp] += Template(db[rp]['read_template']).render(**read_port_context)

    return res


def render_write_mgr_inst(prot_id: str, prot_ids: dict, db: dict) -> dict:
    """Renders the port instantiations of the write managers"""

    res = {}

    # single read port
    swp = len(prot_ids[prot_id]['aw']) == 1

    # Render read ports
    for wp in prot_ids[prot_id]['aw']:

        res[wp] = ''

        # prepare multihead snippets
        num_heads = prot_ids[prot_id]['multihead']['w'][wp]

        # treat multi head config as multi protocol config
        swp &= num_heads == 1

        # template cleanup
        db[wp]['write_template'] = '    ' + db[wp]['write_template'].replace('\n', '\n    ')
        db[wp]['write_template'] = db[wp]['write_template'][:-5]

        # iterate over heads
        for curr_head in range(0, num_heads):

            if num_heads == 1:
                mh = ''
                mh_bus = ''
            else:
                mh = f'_{curr_head}'
                mh_bus = f' [{curr_head}]'

            if db[wp]['read_slave'] == 'true':
                write_req_str = f'{wp}_write_req_t'
                write_rsp_str = f'{wp}_write_rsp_t'
            else:
                write_req_str = f'{wp}_req_t'
                write_rsp_str = f'{wp}_rsp_t'

            if swp:
                write_dp_valid_in = 'w_dp_valid_i'
                write_dp_ready_out = 'w_dp_ready_o'
                write_dp_response = 'w_dp_rsp_o'
                write_dp_valid_out = 'w_dp_valid_o'
                write_dp_ready_in = 'w_dp_ready_i'
                write_meta_request = 'aw_req_i'
                write_meta_valid = 'aw_valid_i'
                write_meta_ready = 'aw_ready_o'
                buffer_out_ready = 'buffer_out_ready'
            else:
                if num_heads == 1:
                    write_dp_valid_in = f'''\
(w_dp_req_i.dst_protocol == idma_pkg::{db[wp]["protocol_enum"]}) & \
w_dp_req_valid\
'''
                else:
                    write_dp_valid_in = f'''\
(w_dp_req_i.dst_protocol == idma_pkg::{db[wp]["protocol_enum"]}) & \
(r_dp_req_i.dst_head == {curr_head}) & \
w_dp_req_valid\
'''
                write_dp_ready_out = f'{wp}_w_dp_ready{mh_bus}'
                write_dp_response = f'{wp}_w_dp_rsp{mh_bus}'
                write_dp_valid_out = f'{wp}_w_dp_rsp_valid{mh_bus}'
                write_dp_ready_in = f'{wp}_w_dp_rsp_ready{mh_bus}'
                write_meta_request = 'aw_req_i.aw_req'
                if num_heads == 1:
                    write_meta_valid = f'''\
(aw_req_i.dst_protocol == idma_pkg::{db[wp]["protocol_enum"]}) & \
aw_valid_i\
'''
                else:
                    write_meta_valid = f'''\
(aw_req_i.dst_protocol == idma_pkg::{db[wp]["protocol_enum"]}) & \
(r_dp_req_i.dst_head == {curr_head}) & \
aw_valid_i\
'''
                write_meta_ready = f'{wp}_aw_ready{mh_bus}'
                buffer_out_ready = f'{wp}_buffer_out_ready{mh_bus}'

            write_port_context = {
                'database': db,
                'req_t': write_req_str,
                'rsp_t': write_rsp_str,
                'w_dp_valid_i': write_dp_valid_in,
                'w_dp_ready_o': write_dp_ready_out,
                'w_dp_rsp_o': write_dp_response,
                'w_dp_valid_o': write_dp_valid_out,
                'w_dp_ready_i': write_dp_ready_in,
                'write_meta_request': write_meta_request,
                'write_meta_valid': write_meta_valid,
                'write_meta_ready': write_meta_ready,
                'write_request': f'{wp}_write_req_o',
                'write_response': f'{wp}_write_rsp_i',
                'buffer_out_ready': buffer_out_ready,
                'mh': mh
            }

            if curr_head > 0:
                res[wp] += '\n\n'

            # render
            res[wp] += Template(db[wp]['write_template']).render(**write_port_context)

    return res


def render_transport_layer(prot_ids: dict, db: dict, tpl_file: str) -> str:
    """Generate Transport Layer"""
    transport_rendered = ''

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        transport_tpl = templ_file.read()

    # render for every is
    for prot_id in prot_ids:

        # format multi head bus
        any_mh = {'ar': False, 'aw': False}
        mh_format = {'ar': {}, 'aw': {}}
        for dir in ['r', 'w']:
            for mhp in prot_ids[prot_id]['multihead'][dir]:
                num_heads = prot_ids[prot_id]['multihead'][dir][mhp]
                if (num_heads == 1):
                    mh_format['a' + dir][mhp] = ''
                else:
                    any_mh['a' + dir] |= True
                    mh_format['a' + dir][mhp] = f'[{num_heads-1}:0] '

        # Render Transport Layer
        context = {
            'name_uniqueifier': prot_id,
            'database': db,
            'used_read_protocols': prot_ids[prot_id]['ar'],
            'used_write_protocols': prot_ids[prot_id]['aw'],
            'used_protocols': prot_ids[prot_id]['used'],
            'one_read_port': len(prot_ids[prot_id]['ar']) == 1 and not any_mh['ar'],
            'one_write_port': len(prot_ids[prot_id]['aw']) == 1 and not any_mh['aw'],
            'mh_format': mh_format,
            'any_mh': any_mh,
            'rendered_read_ports': render_read_mgr_inst(prot_id, prot_ids, db),
            'rendered_write_ports': render_write_mgr_inst(prot_id, prot_ids, db)
        }

        # render
        transport_rendered += Template(transport_tpl).render(**context)

        return transport_rendered

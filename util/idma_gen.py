#!/usr/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Tobias Senti <tsenti@student.ethz.ch>

"""Responsible for code generation"""
import argparse
import os
from functools import reduce
import yaml
from yaml.loader import SafeLoader
from mako.template import Template

database_directory='src/backend/database/'
template_directory='src/backend/src/'

def indent_block(block, indentation):
    indented_block = ''
    split_block = block.split('\n')

    for line in split_block:
        if indented_block != '':
            indented_block += '\n'
        for i in range(indentation):
            indented_block += "    "
        indented_block += line

    return indented_block

# Parse Databases
# yaml=YAML()
database={}
available_protocols=[]
available_read_protocols=[]
available_write_protocols=[]
for filename in os.listdir(database_directory):
    if filename.endswith('.yaml'):
        # Load Database File
        print('Found database: ', filename)
        with open(database_directory + filename, 'r', encoding='utf-8') as f:
            file = yaml.load(f, Loader=SafeLoader)

            # Check if required fields are available
            if 'prefix' not in file:
                raise Exception(filename, ': "prefix" not found!')
            prefix = file['prefix']

            if 'protocol_enum' not in file:
                raise Exception(filename, ': "protocol_enum" not found!')

            if 'full_name' not in file:
                raise Exception(filename, ': "full_name" not found!')

            if 'bursts' not in file:
                raise Exception(filename, ': "bursts" not found!')

            if (file['bursts'] != 'not_supported') and (file['bursts'] != 'split_at_page_boundary') and (file['bursts'] != 'only_pow2'):
                raise Exception(filename, '"bursts" must either be "not_supported"\
 "split_at_page_boundary" or "only_pow2"')

            if (file['bursts'] == 'split_at_page_boundary') and ('max_beats_per_burst' not in file):
                raise Exception(filename, 'if "bursts" != "not_supported",\
 then the "max_beats_per_burst" is needed!')

            if (file['bursts'] != 'not_supported') and ('page_size' not in file):
                raise Exception(filename, '"page_size" not found!')

            if 'typedefs' not in file:
                raise Exception(filename, ': "typedefs" not found!')

            if ('read_template' not in file) and ('write_template' not in file):
                raise Exception(filename, 'Database must atleast include a\
 "read_template" or a "write_template"')

            if ('read_template' in file):
                if ('read_meta_channel' not in file):
                    raise Exception(filename, ': "read_meta_channel" not found!')

                if ('meta_channel_width' not in file) and ('read_meta_channel_width' not in file):
                    raise Exception(filename, ': "read_meta_channel_width" not found!')

                if ('synth_wrapper_ports_read' not in file):
                    raise Exception(filename, ': "synth_wrapper_ports_read" not found!')

                if ('synth_wrapper_assign_read' not in file):
                    raise Exception(filename, ': "synth_wrapper_assign_read" not found!')

                if ('legalizer_read_meta_channel' not in file):
                    raise Exception(filename, ': "legalizer_read_meta_channel" not found!')

                read_manager_path = 'src/backend/src/protocol_managers/' + prefix + '/idma_' + prefix + '_read.sv'
                if not os.path.isfile(read_manager_path):
                    raise Exception(filename, ': Read manager file "' + read_manager_path + '" cannot be found!')

            if ('write_template' in file):
                if ('write_meta_channel' not in file):
                    raise Exception(filename, ': "write_meta_channel" not found!')

                if ('meta_channel_width' not in file) and ('write_meta_channel_width' not in file):
                    raise Exception(filename, ': "write_meta_channel_width" not found!')

                if ('synth_wrapper_ports_write' not in file):
                    raise Exception(filename, ': "synth_wrapper_ports_write" not found!')

                if ('synth_wrapper_assign_write' not in file):
                    raise Exception(filename, ': "synth_wrapper_assign_write" not found!')

                if ('legalizer_write_meta_channel' not in file):
                    raise Exception(filename, ': "legalizer_write_meta_channel" not found!')

                write_manager_path = 'src/backend/src/protocol_managers/' + prefix + '/idma_' + prefix + '_write.sv'
                if not os.path.isfile(write_manager_path):
                    raise Exception(filename, ': Write manager file "' + write_manager_path + '" cannot be found!')


            if (prefix != 'axi') and ('write_template' in file) and ('bridge_template' not in file) and ('write_bridge_template' not in file):
                raise Exception(filename, ': "write_bridge_template" or "bridge_template" not found!')

            if (prefix != 'axi') and ('read_template' in file) and ('bridge_template' not in file) and ('read_bridge_template' not in file):
                raise Exception(filename, ': "read_bridge_template" or "bridge_template" not found!')

            database[prefix] = file
            if 'read_slave' not in file:
                database[prefix]['read_slave'] = "false";
            database[prefix]['typedefs'] = '    '\
                 + database[prefix]['typedefs'].replace('\n', '\n    ')
            if 'read_template' in file:
                available_read_protocols.append(prefix)
            if 'write_template' in file:
                available_write_protocols.append(prefix)

            available_protocols.append(prefix)

def generate_transport_layer():
    """Generate Transport Layer"""
    # Render Read Ports
    print('Generating Read Ports...')
    rendered_read_ports={}
    for rp in used_read_protocols:
        read_port_context={
            'database':     database,
            'req_t':        rp + '_read_req_t' if database[rp]['read_slave'] == 'true' else rp + '_req_t',
            'rsp_t':        rp + '_read_rsp_t' if database[rp]['read_slave'] == 'true' else rp + '_rsp_t',
            'r_dp_valid_i': 'r_dp_valid_i' if one_read_port else '(r_dp_req_i.src_protocol\
 == idma_pkg::' + database[rp]['protocol_enum'] + ') && r_dp_valid_i',
            'r_dp_ready_o': 'r_dp_ready_o' if one_read_port else rp + '_r_dp_ready',
            'r_dp_rsp_o':   'r_dp_rsp_o' if one_read_port else rp + '_r_dp_rsp',
            'r_dp_valid_o': 'r_dp_valid_o' if one_read_port else rp + '_r_dp_valid',
            'r_dp_ready_i': 'r_dp_ready_i' if one_read_port else '(r_dp_req_i.src_protocol\
 == idma_pkg::' + database[rp]['protocol_enum'] + ') && r_dp_ready_i',
            'read_meta_request':    'ar_req_i' if one_read_port else 'ar_req_i.ar_req',
            'read_meta_valid':      'ar_valid_i' if one_read_port else '(ar_req_i.src_protocol\
 == idma_pkg::' + database[rp]['protocol_enum'] + ') && ar_valid_i',
            'read_meta_ready':      'ar_ready_o' if one_read_port else rp + '_ar_ready',
            'read_request':     rp + '_read_req_o',
            'read_response':    rp + '_read_rsp_i',
            'r_chan_valid':     'r_chan_valid_o' if one_read_port else rp + '_r_chan_valid',
            'r_chan_ready':     'r_chan_ready_o' if one_read_port else rp + '_r_chan_ready',
            'buffer_in':    'buffer_in' if one_read_port else rp + '_buffer_in',
            'buffer_in_valid':    'buffer_in_valid' if one_read_port else rp + '_buffer_in_valid',
        }
        database[rp]['read_template'] = '    '\
             + database[rp]['read_template'].replace('\n', '\n    ')
        database[rp]['read_template'] = database[rp]['read_template'][:-5]
        rp_template = Template(database[rp]['read_template'])
        rendered_read_ports[rp] = rp_template.render(**read_port_context)

    # Render Write Ports
    print('Generating Write Ports...')
    rendered_write_ports={}
    for wp in used_write_protocols:
        write_port_context={
            'database':     database,
            'req_t':        wp + '_write_req_t' if database[wp]['read_slave'] == 'true' else wp + '_req_t',
            'rsp_t':        wp + '_write_rsp_t' if database[wp]['read_slave'] == 'true' else wp + '_rsp_t',
            'w_dp_valid_i': 'w_dp_valid_i' if one_write_port else 'w_dp_req_valid &&\n      \
      (w_dp_req_i.dst_protocol == idma_pkg::' + database[wp]['protocol_enum'] + ')',
            'w_dp_ready_o': 'w_dp_ready_o' if one_write_port else wp + '_w_dp_ready',
            'w_dp_rsp_o':   'w_dp_rsp_o' if one_write_port else wp + '_w_dp_rsp',
            'w_dp_valid_o': 'w_dp_valid_o' if one_write_port else wp + '_w_dp_rsp_valid',
            'w_dp_ready_i': 'w_dp_ready_i' if one_write_port else wp + '_w_dp_rsp_ready',
            'write_meta_request':    'aw_req_i' if one_write_port else 'aw_req_i.aw_req',
            'write_meta_valid':      'aw_valid_i' if one_write_port else '(aw_req_i.dst_protocol\
 == idma_pkg::' + database[wp]['protocol_enum'] + ') && aw_valid_i',
            'write_meta_ready':      'aw_ready_o' if one_write_port else wp + '_aw_ready',
            'write_request':     wp + '_write_req_o',
            'write_response':    wp + '_write_rsp_i',
            'buffer_out_ready':    'buffer_out_ready' if one_write_port
                else wp + '_buffer_out_ready'
        }
        database[wp]['write_template'] = '    '\
             + database[wp]['write_template'].replace('\n', '\n    ')
        database[wp]['write_template'] = database[wp]['write_template'][:-5]
        wp_template = Template(database[wp]['write_template'])
        rendered_write_ports[wp] = wp_template.render(**write_port_context)

    # Render Transport Layer
    print('Generating Transport Layer...')
    tl_context={
        'name_uniqueifier':     name_uniqueifier,
        'database':             database,
        'used_read_protocols':  used_read_protocols,
        'used_write_protocols': used_write_protocols,
        'used_protocols':       used_protocols,
        'one_read_port':        one_read_port,
        'one_write_port':       one_write_port,
        'rendered_read_ports':  rendered_read_ports,
        'rendered_write_ports': rendered_write_ports
    }
    tl_template = Template(filename=template_directory + 'idma_transport_layer.sv.tpl')
    rendered_tl = tl_template.render(**tl_context)

    tl_filename = 'src/backend/backend' + name_uniqueifier
    tl_filename += '/idma_transport_layer' + name_uniqueifier + '.sv'

    with open(tl_filename, 'w', encoding='utf-8') as tl_file:
        tl_file.write(rendered_tl)

    print('Generated ' + tl_filename + '!')

def generate_legalizer():
    """Generate Legalizer"""
    # Indent read meta channel
    for protocol in used_read_protocols:
        database[protocol]['legalizer_read_meta_channel'] = indent_block(database[protocol]['legalizer_read_meta_channel'], 2 if one_read_port else 3)
    # Indent write meta channel and data path
    for protocol in used_write_protocols:
        database[protocol]['legalizer_write_meta_channel'] = indent_block(database[protocol]['legalizer_write_meta_channel'], 2 if one_write_port else 3)
        if 'legalizer_write_data_path' in database[protocol]:
            database[protocol]['legalizer_write_data_path'] = indent_block(database[protocol]['legalizer_write_data_path'], 2 if one_write_port else 3)
    # Render Legalizer
    print('Generating Legalizer...')
    le_context={
        'name_uniqueifier':     name_uniqueifier,
        'database':             database,
        'used_read_protocols':  used_read_protocols,
        'used_write_protocols': used_write_protocols,
        'used_protocols':       used_protocols,
        'one_read_port':        one_read_port,
        'one_write_port':       one_write_port,

        'no_read_bursting':     reduce(lambda a, b: a and b,
            map(lambda p: database[p]['bursts'] == 'not_supported', used_read_protocols)),
        'has_page_read_bursting':   reduce(lambda a, b: a or b,
            map(lambda p: database[p]['bursts'] == 'split_at_page_boundary', used_read_protocols)),
        'has_pow2_read_bursting':   reduce(lambda a, b: a or b,
            map(lambda p: database[p]['bursts'] == 'only_pow2', used_read_protocols)),

        'no_write_bursting':    reduce(lambda a, b: a and b,
            map(lambda p: database[p]['bursts'] == 'not_supported', used_write_protocols)),
        'has_page_write_bursting':   reduce(lambda a, b: a or b,
            map(lambda p: database[p]['bursts'] == 'split_at_page_boundary', used_write_protocols)),
        'has_pow2_write_bursting':   reduce(lambda a, b: a or b,
            map(lambda p: database[p]['bursts'] == 'only_pow2', used_write_protocols)),

        'used_non_bursting_write_protocols' : list(filter(
            lambda a: database[a]['bursts'] == 'not_supported', used_write_protocols)),
        'used_non_bursting_read_protocols'  : list(filter(
            lambda a: database[a]['bursts'] == 'not_supported', used_read_protocols)),
        'used_non_bursting_or_force_decouple_write_protocols' : list(filter(
            lambda a: database[a]['bursts'] == 'not_supported' or ('legalizer_force_decouple' in database[a] and database[a]['legalizer_force_decouple']), used_write_protocols)),
        'used_non_bursting_or_force_decouple_read_protocols'  : list(filter(
            lambda a: database[a]['bursts'] == 'not_supported' or ('legalizer_force_decouple' in database[a] and database[a]['legalizer_force_decouple']), used_read_protocols))
    }
    le_template = Template(filename=template_directory + 'idma_legalizer.sv.tpl')
    rendered_le = le_template.render(**le_context)

    le_filename = 'src/backend/backend' + name_uniqueifier
    le_filename += '/idma_legalizer' + name_uniqueifier + '.sv'

    with open(le_filename, 'w', encoding='utf-8') as le_file:
        le_file.write(rendered_le)

    print('Generated ' + le_filename + '!')

def generate_backend():
    """Generate Backend"""
    # Render Backend
    print('Generating Backend...')
    be_context={
        'name_uniqueifier':     name_uniqueifier,
        'database':             database,
        'used_read_protocols':  used_read_protocols,
        'used_write_protocols': used_write_protocols,
        'used_protocols':       used_protocols,
        'one_read_port':        one_read_port,
        'one_write_port':       one_write_port,
        'no_write_bursting':    reduce(lambda a, b: a and b,
            map(lambda p: database[p]['bursts'] == 'not_supported', used_write_protocols)),
        'used_non_bursting_write_protocols' : list(filter(
            lambda a: database[a]['bursts'] == 'not_supported', used_write_protocols)),
        'combined_aw_and_w':    len(list(filter(
            lambda a: ('combined_aw_and_w' in database[a])
                and (database[a]['combined_aw_and_w'] == 'true'), used_write_protocols))) == 1
    }
    be_template = Template(filename=template_directory + 'idma_backend.sv.tpl')
    rendered_be = be_template.render(**be_context)

    be_filename ='src/backend/backend' + name_uniqueifier
    be_filename += '/idma_backend' + name_uniqueifier + '.sv'

    with open(be_filename, 'w', encoding='utf-8') as be_file:
        be_file.write(rendered_be)

    print('Generated ' + be_filename + '!')

def generate_wave_file():
    """Generate Wave File"""
    # Render Wave File
    print('Generating Wave File...')
    wf_context={
        'name_uniqueifier':     name_uniqueifier,
        'database':             database,
        'used_read_protocols':  used_read_protocols,
        'used_write_protocols': used_write_protocols,
        'used_protocols':       used_protocols,
        'one_read_port':        one_read_port,
        'one_write_port':       one_write_port
    }
    wf_template = Template(filename='./scripts/waves/vsim_backend.do.tpl')
    rendered_wf = wf_template.render(**wf_context)

    wf_filename = './scripts/waves/vsim_backend' + name_uniqueifier + '.do'

    with open(wf_filename, 'w', encoding='utf-8') as wf_file:
        wf_file.write(rendered_wf)

    print('Generated ' + wf_filename + '!')

def generate_testbench():
    """Generate Testbench"""
    # Render Bridges
    for protocol in used_protocols:
        if protocol != 'axi':
            if 'bridge_template' in database[protocol]:
                database[protocol]['bridge_template'] = '    '\
                + database[protocol]['bridge_template'].replace('\n', '\n    ')
            if 'write_bridge_template' in database[protocol]:
                database[protocol]['write_bridge_template'] = '    '\
                + database[protocol]['write_bridge_template'].replace('\n', '\n    ')
            if 'read_bridge_template' in database[protocol]:
                database[protocol]['read_bridge_template'] = '    '\
                + database[protocol]['read_bridge_template'].replace('\n', '\n    ')

    print('Generating read bridges...')
    rendered_read_bridges={}
    for protocol in used_read_protocols:
        if protocol != 'axi':
            bridge_context={
                'port': 'read',
                'database': database,
                'used_read_protocols': used_read_protocols
            }
            if 'read_bridge_template' in database[protocol]:
                bridge_template=Template(database[protocol]['read_bridge_template'])
            else:
                bridge_template=Template(database[protocol]['bridge_template'])
            rendered_read_bridges[protocol]=bridge_template.render(**bridge_context)

    print('Generating write bridges...')
    rendered_write_bridges={}
    for protocol in used_write_protocols:
        if protocol != 'axi':
            bridge_context={
                'port': 'write',
                'database': database,
                'used_write_protocols': used_write_protocols
            }
            if 'write_bridge_template' in database[protocol]:
                bridge_template=Template(database[protocol]['write_bridge_template'])
            else:
                bridge_template=Template(database[protocol]['bridge_template'])
            rendered_write_bridges[protocol]=bridge_template.render(**bridge_context)

    # Render Testbench

    print('Generating Testbench...')
    tb_context={
        'name_uniqueifier':     name_uniqueifier,
        'database':             database,
        'used_read_protocols':  used_read_protocols,
        'used_write_protocols': used_write_protocols,
        'used_protocols':       used_protocols,
        'unused_protocols':     list(set(available_protocols) - set(used_protocols)),
        'one_read_port':        one_read_port,
        'one_write_port':       one_write_port,
        'rendered_read_bridges':    rendered_read_bridges,
        'rendered_write_bridges':   rendered_write_bridges,
        'combined_shifter':     combined_shifter
    }
    tb_template = Template(filename='test/tb_idma_backend.sv.tpl')
    rendered_tb = tb_template.render(**tb_context)

    tb_filename = 'src/backend/backend' + name_uniqueifier
    tb_filename += '/tb_idma_backend' + name_uniqueifier + '.sv'

    with open(tb_filename, 'w', encoding='utf-8') as tb_file:
        tb_file.write(rendered_tb)

    print('Generated ' + tb_filename + '!')

def generate_synth_wrapper():
    """Generate Synth Wrapper"""
    # Render Wave File
    print('Generating Synth Wrapper...')
    sw_context={
        'name_uniqueifier':     name_uniqueifier,
        'database':             database,
        'used_read_protocols':  used_read_protocols,
        'used_write_protocols': used_write_protocols,
        'used_protocols':       used_protocols,
        'one_read_port':        one_read_port,
        'one_write_port':       one_write_port,
        'combined_shifter':     combined_shifter
    }
    for protocol in used_protocols:
        if protocol in used_read_protocols:
            database[protocol]['synth_wrapper_ports_read']   = '    '\
            + database[protocol]['synth_wrapper_ports_read'].replace('\n', '\n    ')
            database[protocol]['synth_wrapper_assign_read']  = '    '\
            + database[protocol]['synth_wrapper_assign_read'].replace('\n', '\n    ')
        if protocol in used_write_protocols:
            database[protocol]['synth_wrapper_ports_write']  = '    '\
            + database[protocol]['synth_wrapper_ports_write'].replace('\n', '\n    ')
            database[protocol]['synth_wrapper_assign_write'] = '    '\
            + database[protocol]['synth_wrapper_assign_write'].replace('\n', '\n    ')
    sw_template = Template(filename='src/backend/src/idma_backend_synth.sv.tpl')
    rendered_sw = sw_template.render(**sw_context)

    sw_filename = 'src/backend/backend' + name_uniqueifier
    sw_filename += '/idma_backend_synth' + name_uniqueifier + '.sv'

    with open(sw_filename, 'w', encoding='utf-8') as sw_file:
        sw_file.write(rendered_sw)

    print('Generated ' + sw_filename + '!')

def generate_folder():
    """Generates the folder where all generated files will live"""
    try:
        os.mkdir('src/backend/backend' + name_uniqueifier)
    except FileExistsError:
        pass

def generate_bender():
    """Generates src/backend/Bender.yml"""
    # Check if file exists
    if not os.path.isfile('src/backend/Bender.yml'):
        # If not -> Write template into it
        with open('src/backend/Bender.yml.tpl', 'r', encoding='utf-8') as template_file:
            content = template_file.read()

        content += '\n  # Protocol Managers\n'
        for protocol in available_protocols:
            content += '\n  # ' + database[protocol]['full_name'] + '\n'
            if protocol in available_read_protocols:
                content += '  - src/protocol_managers/' + protocol + '/idma_' + protocol + '_read.sv\n'
            if protocol in available_write_protocols:
                content += '  - src/protocol_managers/' + protocol + '/idma_' + protocol + '_write.sv\n'
        
        content += '\n  # Backends\n'
    else:
        # Read contents of bender file
        with open('src/backend/Bender.yml', 'r', encoding='utf-8') as bender_file:
            content = bender_file.read()

    # Check if backend is already in bender file
    if name_uniqueifier not in content:
        # Add new backend
        content += '\n  # backend' + name_uniqueifier + '\n'
        content += '  - files:\n'
        content += '    - backend' + name_uniqueifier
        content += '/idma_transport_layer' + name_uniqueifier + '.sv\n'
        content += '    - backend' + name_uniqueifier + '/idma_legalizer' + name_uniqueifier + '.sv\n'
        content += '    - backend' + name_uniqueifier + '/idma_backend' + name_uniqueifier + '.sv\n'
        content += '  - target: test\n'
        content += '    defines:\n'
        content += '      TARGET_SIMULATION: ~\n'
        content += '    include_dirs:\n'
        content += '      - ../../test\n'
        content += '    files:\n'
        content += '    - backend' + name_uniqueifier + '/tb_idma_backend' + name_uniqueifier + '.sv\n'
        content += '  - target: synthesis\n'
        content += '    files:\n'
        content += '    - backend' + name_uniqueifier + '/idma_backend_synth'
        content += name_uniqueifier + '.sv\n'

        # Write bender file
        with open('src/backend/Bender.yml', 'w', encoding='utf-8') as bender_file:
            bender_file.write(content)

# Parse Arguments
parser = argparse.ArgumentParser(
    prog='idma_gen',
    description='Generates a wanted iDMA configuration'
)
subparser = parser.add_subparsers(dest='command')

gen_tl = subparser.add_parser('transportlayer', description='Generates the transport layer')
gen_tl.add_argument('-r', '--read-protocols', choices=available_read_protocols,
    type=str, required=True, nargs='+', dest='read_protocols')
gen_tl.add_argument('-w', '--write-protocols', choices=available_write_protocols,
    type=str, required=True, nargs='+', dest='write_protocols')

gen_le = subparser.add_parser('legalizer', description='Generates the legalizer')
gen_le.add_argument('-r', '--read-protocols', choices=available_read_protocols,
    type=str, required=True, nargs='+', dest='read_protocols')
gen_le.add_argument('-w', '--write-protocols', choices=available_write_protocols,
    type=str, required=True, nargs='+', dest='write_protocols')

gen_be = subparser.add_parser('backend', description='Generates the backend')
gen_be.add_argument('-r', '--read-protocols', choices=available_read_protocols,
    type=str, required=True, nargs='+', dest='read_protocols')
gen_be.add_argument('-w', '--write-protocols', choices=available_write_protocols,
    type=str, required=True, nargs='+', dest='write_protocols')

gen_wf = subparser.add_parser('wavefile', description='Generates a .do wavefile for debugging in vsim')
gen_wf.add_argument('-r', '--read-protocols', choices=available_read_protocols,
    type=str, required=True, nargs='+', dest='read_protocols')
gen_wf.add_argument('-w', '--write-protocols', choices=available_write_protocols,
    type=str, required=True, nargs='+', dest='write_protocols')

gen_tb = subparser.add_parser('testbench', description='Generates the testbench')
gen_tb.add_argument('-r', '--read-protocols', choices=available_read_protocols,
    type=str, required=True, nargs='+', dest='read_protocols')
gen_tb.add_argument('-w', '--write-protocols', choices=available_write_protocols,
    type=str, required=True, nargs='+', dest='write_protocols')
gen_tb.add_argument('-s', '--shifter', choices=['combined', 'split'],
    type=str, required=False, default='split', dest='shifter')

gen_sw = subparser.add_parser('synth_wrapper', description='Generates the synthesis wrapper')
gen_sw.add_argument('-r', '--read-protocols', choices=available_read_protocols,
    type=str, required=True, nargs='+', dest='read_protocols')
gen_sw.add_argument('-w', '--write-protocols', choices=available_write_protocols,
    type=str, required=True, nargs='+', dest='write_protocols')
gen_sw.add_argument('-s', '--shifter', choices=['combined', 'split'],
    type=str, required=False, default='split', dest='shifter')

gen_bd = subparser.add_parser('bender', description='Generates the bender file')
gen_bd.add_argument('-r', '--read-protocols', choices=available_read_protocols,
    type=str, required=True, nargs='+', dest='read_protocols')
gen_bd.add_argument('-w', '--write-protocols', choices=available_write_protocols,
    type=str, required=True, nargs='+', dest='write_protocols')

gen_all = subparser.add_parser('debug', description='Generates all required files for debugging: TransportLayer, Legalizer, Backend, Testbench, Bender, Wavefile')
gen_all.add_argument('-r', '--read-protocols', choices=available_read_protocols,
    type=str, required=True, nargs='+', dest='read_protocols')
gen_all.add_argument('-w', '--write-protocols', choices=available_write_protocols,
    type=str, required=True, nargs='+', dest='write_protocols')
gen_all.add_argument('-s', '--shifter', choices=['combined', 'split'],
    type=str, required=False, default='split', dest='shifter')


args = parser.parse_args()

used_read_protocols=[]
used_write_protocols=[]
if 'read_protocols' in args:
    args.read_protocols.sort()
    used_read_protocols=list(set(args.read_protocols))
if 'write_protocols' in args:
    args.write_protocols.sort()
    used_write_protocols=list(set(args.write_protocols))

used_protocols=list(set(used_read_protocols + used_write_protocols))

used_read_protocols.sort()
used_write_protocols.sort()
used_protocols.sort()

print('Read Protocols: ', used_read_protocols)
print('Write Protocols:', used_write_protocols)
print('Used Protocols: ', used_protocols)

one_read_port = len(used_read_protocols) == 1
one_write_port = len(used_write_protocols) == 1

# Create Unique name
name_uniqueifier=''
for up in used_protocols:
    name_uniqueifier += '_'
    if up in used_read_protocols:
        name_uniqueifier += 'r'
    if up in used_write_protocols:
        name_uniqueifier += 'w'
    name_uniqueifier += '_' + up
combined_shifter = False
if ('shifter' in args) and ('combined' in args.shifter):
    combined_shifter = True

if args.command == 'transportlayer':
    generate_folder()
    generate_transport_layer()

if args.command == 'legalizer':
    generate_folder()
    generate_legalizer()

if args.command == 'backend':
    generate_folder()
    generate_backend()

if args.command == 'wavefile':
    generate_wave_file()

if args.command == 'testbench':
    generate_folder()
    generate_testbench()

if args.command == 'synth_wrapper':
    generate_folder()
    generate_synth_wrapper()

if args.command == 'bender':
    generate_bender()

if args.command == 'debug':
    generate_bender()
    generate_folder()
    generate_transport_layer()
    generate_legalizer()
    generate_backend()
    generate_testbench()
    generate_wave_file()
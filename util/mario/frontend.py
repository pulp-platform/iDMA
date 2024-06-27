#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO frontend interaction"""
import sys
import math
from mako.template import Template

NUM_PROT_BITS = 3

def render_register(content: dict):
    """Render a register"""
    return '''    {{ name: "{name:}"
      desc: "{desc:}",
      swaccess: "rw",
      hwaccess: "hro",
      fields: [
        {{ bits: "31:0",
          name: "{name:}",
          desc: "{desc:}",
          resval: "0"
        }}
      ]
    }},
'''.format(**content)


def render_param(content: dict):
    """Render a parameter"""
    return '''    {{ name: "{name:}",
      desc: "{desc:}",
      type: "int",
      default: "{value:}"
    }}'''.format(**content)


def render_reg_hjson(fe_ids: dict, tpl_file: str) -> str:
    """Generate register hjson"""
    reg_hjson_rendered = ''

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        reg_hjson_tpl = templ_file.read()

    # render for every is
    for fe_id in fe_ids:

        low_regs = []
        high_regs = []
        align_regs = []

        # lower registers are always present
        low_regs.append(render_register({'name': 'dst_addr_low',
            'desc': 'Low destination address'}))
        low_regs.append(render_register({'name': 'src_addr_low',
            'desc': 'Low source address'}))
        low_regs.append(render_register({'name': 'length_low',
            'desc': 'Low transfer length in byte'}))

        # lower ND register
        for d in range(2, int(fe_ids[fe_id][1]) + 1):
            low_regs.append(render_register({'name': f'dst_stride_{d}_low',
                'desc': f'Low destination stride dimension {d}'}))
            low_regs.append(render_register({'name': f'src_stride_{d}_low',
                'desc': f'Low source stride dimension {d}'}))
            low_regs.append(render_register({'name': f'reps_{d}_low',
                'desc': f'Low number of repetitions dimension {d}'}))

        # higher register depends on the bit-width: 32-bit-case just add alignment marks
        if fe_ids[fe_id][0] == '32':
            for i in range(0, 3 * int(fe_ids[fe_id][1])):
                align_regs.append(f'    {{ skipto: "{hex(8*i + 0xD0)}" }},\n')

            # assemble regs
            regs = low_regs + align_regs
            regs[1::2] = low_regs
            regs[::2] = align_regs

            # render
            regs = ''.join(regs)[:-2]

        # render upper registers for 64-bit case
        elif fe_ids[fe_id][0] == '64':
            # upper registers are always present
            high_regs.append(render_register({'name': 'dst_addr_high',
                'desc': 'High destination address'}))
            high_regs.append(render_register({'name': 'src_addr_high',
                'desc': 'High source address'}))
            high_regs.append(render_register({'name': 'length_high',
                'desc': 'High transfer length in byte'}))

            # upper ND register
            for d in range(2, int(fe_ids[fe_id][1]) + 1):
                high_regs.append(render_register({'name': f'dst_stride_{d}_high',
                    'desc': f'High destination stride dimension {d}'}))
                high_regs.append(render_register({'name': f'src_stride_{d}_high',
                    'desc': f'High source stride dimension {d}'}))
                high_regs.append(render_register({'name': f'reps_{d}_high',
                    'desc': f'High number of repetitions dimension {d}'}))

            # assemble regs
            regs = low_regs + high_regs
            regs[::2] = low_regs
            regs[1::2] = high_regs

            # render
            regs = '    { skipto: "0xD0" },\n' + ''.join(regs)[:-2]

        # unsupported bit width
        else:
            print(f'Unsupported bit width: {fe_ids[fe_id][0]}', file=sys.stderr)
            sys.exit(-1)

        # render params
        params = render_param({'name': 'num_dims', 'desc': 'Number of dimensions available',
            'value': fe_ids[fe_id][1]})

        # number of bits required to characterize dimension
        if int(fe_ids[fe_id][1]) > 1:
            num_dim_bits = int(math.log2(int(fe_ids[fe_id][1]) - 1))
        else:
            num_dim_bits = 0

        # assemble context
        context = {
            'identifier': fe_id,
            'params': params,
            'registers': regs,
            'dim_range': f'{10+num_dim_bits}:10',
            'src_prot_range': f'{10+num_dim_bits+NUM_PROT_BITS}:{10+num_dim_bits+1}',
            'dst_prot_range': f'{10+num_dim_bits+2*NUM_PROT_BITS}:{10+num_dim_bits+NUM_PROT_BITS+1}'
        }

        # render
        reg_hjson_rendered += Template(reg_hjson_tpl).render(**context)

    return reg_hjson_rendered


def render_reg_top(fe_ids: dict, tpl_file: str) -> str:
    """Generate register top"""
    reg_top_rendered = ''

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        reg_top_tpl = templ_file.read()

    # render for every is
    for fe_id in fe_ids:

        if fe_ids[fe_id][1] == '1':
            sep = '.'
        else:
            sep = '.burst_req.'

        # assemble context
        context = {
            'identifier': fe_id,
            'num_dim': int(fe_ids[fe_id][1]),
            'sep': sep,
            'bit_width': fe_ids[fe_id][0]
        }

        # render
        reg_top_rendered += Template(reg_top_tpl).render(**context)

    return reg_top_rendered

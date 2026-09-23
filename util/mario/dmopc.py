#!/usr/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

""" MARIO DMOPC contract interaction"""
from mako.template import Template


def _camel(name: str) -> str:
    """snake_case to CamelCase; the SystemVerilog identifier style"""
    return ''.join(part.capitalize() for part in name.split('_'))


def _unique(names: list, what: str) -> None:
    """Reject a duplicate key; two entries of the same name silently shadow each other"""
    seen = set()
    for name in names:
        if name in seen:
            raise ValueError(f'duplicate {what}: {name}')
        seen.add(name)


def _context(db: dict) -> dict:
    """Turn the DMOPC database into the template context shared by both renderings"""
    opcode_width = int(db['opcode_width'])
    operands = db['operands']

    operand_width = int(db['operand_width'])

    # fields: the SystemVerilog and C names are derived, the layout comes from the database
    fields = []
    for field in db['fields']:
        operand = field['operand']
        if operand not in operands:
            raise ValueError(f'field {field["name"]}: unknown operand {operand}')
        lsb, width = int(field['lsb']), int(field['width'])
        if width <= 0:
            raise ValueError(f'field {field["name"]}: width {width} is not positive')
        if lsb + width > operand_width:
            raise ValueError(f'field {field["name"]}: runs past the {operand_width} b operand')
        fields.append({
            'key': field['name'],
            'sv': _camel(operand) + _camel(field['name']),
            'c': f'{operand.upper()}_{field["name"].upper()}',
            'operand': operand,
            'signal': operands[operand],
            'lsb': lsb,
            'width': width,
            'sv_width': field.get('sv_width'),
            'mask': format((1 << width) - 1, 'x')
        })
    _unique([f['key'] for f in fields], 'field')
    by_key = {f['key']: f for f in fields}

    # opcodes: `enable` false decodes to a plain copy, so it carries no compute op
    opcodes = []
    for opcode in db['opcodes']:
        params = []
        for target, key in (opcode.get('params') or {}).items():
            if key not in by_key:
                raise ValueError(f'opcode {opcode["name"]}: unknown field {key}')
            params.append({'target': target, 'field': by_key[key]})
        if params and not opcode.get('enable', True):
            raise ValueError(f'opcode {opcode["name"]}: params need enable')
        byte = int(opcode['byte'])
        if not 0 <= byte < (1 << opcode_width):
            raise ValueError(f'opcode {opcode["name"]}: byte {byte:#x} outside the opcode width')
        opcodes.append({
            'sv': 'Opc' + _camel(opcode['name']),
            'c': opcode['name'].upper(),
            'byte': byte,
            'hex': format(byte, f'0{(opcode_width + 3) // 4}x'),
            'op': opcode['op'].upper(),
            'enable': opcode.get('enable', True),
            'params': params
        })
    _unique([o['sv'] for o in opcodes], 'opcode')
    _unique([o['byte'] for o in opcodes], 'opcode byte')

    # per-operand fields in layout order; the disjointness guard compares neighbours
    operand_fields = {name: sorted([f for f in fields if f['operand'] == name],
                                   key=lambda f: f['lsb']) for name in operands}

    if db['opcode_field'] not in by_key:
        raise ValueError(f'unknown opcode field {db["opcode_field"]}')
    if by_key[db['opcode_field']]['width'] != opcode_width:
        raise ValueError(f'opcode field {db["opcode_field"]}: width is not {opcode_width}')

    return {
        'opcode_width': opcode_width,
        'operand_width': operand_width,
        'opcode_field': by_key[db['opcode_field']],
        'operands': operands,
        'fields': fields,
        'operand_fields': operand_fields,
        'opcodes': opcodes,
        'name_width': max(len(f['sv']) for f in fields) + len('Width')
    }


def render_dmopc(db: dict, tpl_file: str) -> str:
    """Generate one rendering of the DMOPC contract"""
    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        return Template(templ_file.read()).render(**_context(db))

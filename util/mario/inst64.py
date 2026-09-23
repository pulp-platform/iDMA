#!/usr/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

""" MARIO inst64 instruction-set interaction"""
from mako.template import Template

# R-type slots: name, lsb, width
SLOTS = {'rd': (7, 5), 'rs1': (15, 5), 'rs2': (20, 5)}
KINDS = ('config', 'launch', 'status')
REQUIRES = ('compute', 'init')


def _camel(name: str) -> str:
    """snake_case to CamelCase; the SystemVerilog identifier style"""
    return ''.join(part.capitalize() for part in name.split('_'))


def _field(value: int, lsb: int, width: int, what: str) -> int:
    """Place `value` in a `width`-bit field at `lsb`, rejecting one that does not fit"""
    if not 0 <= value < (1 << width):
        raise ValueError(f'{what}: {value:#x} does not fit {width} b')
    return value << lsb


def _slot_mask(slot: str) -> int:
    lsb, width = SLOTS[slot]
    return ((1 << width) - 1) << lsb


def _dmopc_operands(dmopc: dict) -> dict:
    """The DMOPC operands and what they carry, from the DMOPC contract itself"""
    operands = {}
    for operand in dmopc['operands']:
        if operand not in ('rs1', 'rs2'):
            raise ValueError(f'dmopc: operand {operand} is not an R-type source')
        names = [f['name'] for f in dmopc['fields'] if f['operand'] == operand]
        operands[operand] = 'DMOPC ' + ', '.join(names)
    return operands


def _context(db: dict, dmopc: dict) -> dict:
    """Turn the inst64 database into the template context shared by every rendering"""
    opcode = int(db['opcode'])
    funct3 = int(db['funct3'])
    base = _field(opcode, 0, 7, 'opcode') | _field(funct3, 12, 3, 'funct3')
    base_mask = 0x7f | (0x7 << 12) | (0x7f << 25)

    imm_lsb = int(db['imm5']['lsb'])
    if imm_lsb != SLOTS['rs2'][0]:
        raise ValueError('imm5 must ride the rs2 slot')
    imm_fields = []
    used = 0
    for fld in db['imm5']['fields']:
        lsb, width = int(fld['lsb']), int(fld['width'])
        mask = ((1 << width) - 1) << lsb
        if width <= 0 or lsb + width > 5 or used & mask:
            raise ValueError(f'imm5 field {fld["name"]}: bad or overlapping layout')
        used |= mask
        imm_fields.append({'name': fld['name'], 'sv': 'Imm' + _camel(fld['name']),
                           'c': fld['name'].upper(), 'lsb': lsb, 'width': width,
                           'mask': (1 << width) - 1})

    insts = []
    for inst in db['instructions']:
        name = inst['name']
        kind = inst['kind']
        if kind not in KINDS:
            raise ValueError(f'{name}: unknown kind {kind}')
        requires = inst.get('requires')
        if requires is not None and requires not in REQUIRES:
            raise ValueError(f'{name}: unknown requirement {requires}')
        if 'operands' in inst:
            if inst['operands'] != 'dmopc':
                raise ValueError(f'{name}: unknown operand contract {inst["operands"]}')
            if any(slot in inst for slot in ('rs1', 'rs2', 'imm5')):
                raise ValueError(f'{name}: operands are taken from the dmopc database')
            sources = _dmopc_operands(dmopc)
        else:
            sources = {slot: inst[slot] for slot in ('rs1', 'rs2') if slot in inst}
        if 'rs2' in sources and 'imm5' in inst:
            raise ValueError(f'{name}: rs2 and imm5 share a slot')
        writeback = 'rd' in inst
        if writeback != (kind != 'config'):
            raise ValueError(f'{name}: only launch and status instructions write rd')

        funct7 = int(inst['funct7'])
        match = base | _field(funct7, 25, 7, f'{name} funct7')
        mask = base_mask
        used_slots = set(sources) | ({'rd'} if writeback else set())
        used_slots |= {'rs2'} if 'imm5' in inst else set()
        for slot in ('rd', 'rs1', 'rs2'):
            if slot not in used_slots:
                mask |= _slot_mask(slot)
        pattern = ''.join('?' if not (mask >> b) & 1 else str((match >> b) & 1)
                          for b in range(31, -1, -1))

        # riscv-opcodes line: variable arguments, then the zero slots, then the fixed fields
        args = (['rd'] if writeback else []) + [s for s in ('rs1', 'rs2') if s in sources]
        args += ['imm5'] if 'imm5' in inst else []
        zeros = []
        for slot, rng in (('rs2', '24..20'), ('rs1', '19..15'), ('rd', '11..7')):
            if mask & _slot_mask(slot):
                zeros.append(f'{rng}=0')
        insts.append({
            'name': name,
            'upper': name.upper(),
            'sv': _camel(name),
            'kind': kind,
            'funct7': funct7,
            'match': match,
            'mask': mask,
            'pattern': pattern,
            'read': (1 if 'rs1' in sources else 0) | (2 if 'rs2' in sources else 0),
            'writeback': writeback,
            'imm': 'imm5' in inst,
            'requires': requires,
            'rd': inst.get('rd'),
            'sources': sources,
            'imm_desc': inst.get('imm5'),
            'args': args,
            'zeros': zeros
        })

    for key in ('name', 'funct7'):
        seen = set()
        for inst in insts:
            if inst[key] in seen:
                raise ValueError(f'duplicate {key}: {inst[key]}')
            seen.add(inst[key])
    for i, a in enumerate(insts):
        for b in insts[i + 1:]:
            both = a['mask'] & b['mask']
            if (a['match'] & both) == (b['match'] & both):
                raise ValueError(f'{a["name"]} and {b["name"]} overlap')

    return {
        'description': db['description'],
        'note': db.get('note'),
        'opcode': opcode,
        'funct3': funct3,
        'imm_lsb': imm_lsb,
        'imm_fields': imm_fields,
        'insts': insts
    }


def render_inst64(db: dict, tpl_file: str) -> str:
    """Generate one rendering of the inst64 instruction set"""
    if 'inst64' not in db or 'dmopc' not in db:
        raise ValueError('the inst64 rendering needs the inst64 and dmopc databases')
    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        return Template(templ_file.read()).render(**_context(db['inst64'], db['dmopc']))

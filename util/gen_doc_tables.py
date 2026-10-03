#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

"""Docs register-map and DMOPC tables from the RDL and the DMOPC database (--check: compare)"""
import argparse
import difflib
import os
import re
import sys

import yaml
from systemrdl import RDLCompiler
from systemrdl.node import AddrmapNode, FieldNode, RegNode

# register frontend variants: name -> (SysAddrWidth, NumDims, Log2NumDims), as in idma.mk
REG_VARIANTS = {
    'reg32_3d': (32, 3, 2),
    'reg64_1d': (64, 1, 0),
    'reg64_2d': (64, 2, 1),
}
FIELD_TABLES = ['conf', 'compute_cfg', 'mx_cfg']


def compile_rdl(rdl: str, params: tuple) -> AddrmapNode:
    """Elaborate the register description for one frontend variant"""
    rdlc = RDLCompiler()
    rdlc.compile_file(rdl)
    names = ['SysAddrWidth', 'NumDims', 'Log2NumDims']
    return rdlc.elaborate(parameters=dict(zip(names, params))).top


def bits(field: FieldNode) -> str:
    """Bit range of a field as the docs write it"""
    if field.msb == field.lsb:
        return str(field.lsb)
    return f'{field.msb}:{field.lsb}'


def desc(node) -> str:
    """One-line description of an RDL node"""
    text = node.get_property('desc') or ''
    return ' '.join(text.split()).replace('|', '\\|')


def regs(top: AddrmapNode) -> list:
    """Every register instance of the map in address order: (name, address, node)"""
    out = []
    for node in top.descendants(unroll=True):
        if isinstance(node, RegNode):
            path = node.get_path(empty_array_suffix='')
            out.append((path.split('.', 1)[1], node.absolute_address, node))
    return sorted(out, key=lambda r: r[1])


def field_table(name: str, tops: dict) -> list:
    """Field table of a register: one Bits column, or one per variant where they differ"""
    per_var = {}
    for var, top in tops.items():
        reg = next(n for (_, _, n) in regs(top) if n.inst_name == name)
        per_var[var] = {f.inst_name: f for f in reg.fields()}
    first = next(iter(per_var.values()))
    same = all({k: bits(f) for k, f in fs.items()} == {k: bits(f) for k, f in first.items()}
               for fs in per_var.values())
    order = sorted(first.values(), key=lambda f: f.lsb)
    if same:
        lines = ['| Bits | Field | Description |', '|------|-------|-------------|']
        used = 0
        for f in order:
            lines.append(f'| {bits(f)} | `{f.inst_name}` | {desc(f)} |')
            used = max(used, f.msb + 1)
        if used < 32:
            rng = str(used) if used == 31 else f'31:{used}'
            lines.append(f'| {rng} | - | Reserved |')
        return lines
    vars_ = list(per_var)
    lines = ['| ' + ' | '.join(f'Bits `{v}`' for v in vars_) + ' | Field | Description |',
             '|' + '---|' * (len(vars_) + 2)]
    for f in order:
        cols = [bits(per_var[v][f.inst_name]) for v in vars_]
        lines.append('| ' + ' | '.join(cols) + f' | `{f.inst_name}` | {desc(f)} |')
    return lines


def map_table(tops: dict) -> list:
    """Byte offset of every register in every frontend variant; arrays of more than two collapse"""
    offs = {}
    for var, top in tops.items():
        groups = {}
        for name, addr, _ in regs(top):
            groups.setdefault(re.sub(r'\[\d+\]$', '', name), []).append((name, addr))
        for base, items in groups.items():
            if len(items) > 2:
                items = [(f'{base}[0..{len(items) - 1}]', items[0][1])]
            for name, addr in items:
                offs.setdefault(name, {})[var] = addr
    vars_ = list(tops)
    order = sorted(offs, key=lambda n: [offs[n].get(v, 1 << 32) for v in reversed(vars_)])
    lines = ['| Register | ' + ' | '.join(f'`{v}`' for v in vars_) + ' |',
             '|' + '---|' * (len(vars_) + 1)]
    for name in order:
        cols = [f'`0x{offs[name][v]:03X}`' if v in offs[name] else '-' for v in vars_]
        lines.append(f'| `{name}` | ' + ' | '.join(cols) + ' |')
    return lines


def dmopc_table(db: dict) -> list:
    """Opcode bytes, the op they latch and the operand fields they read"""
    fields = {f['name']: f for f in db['fields']}

    def pos(name):
        f = fields[name]
        lsb, msb = int(f['lsb']), int(f['lsb']) + int(f['width']) - 1
        rng = str(lsb) if lsb == msb else f'{msb}:{lsb}'
        return f'`{f["operand"]}[{rng}]`'

    rows = []
    for opc in db['opcodes']:
        eff = f'latch `{opc["op"]}`' if opc.get('enable', True) else 'latch a plain copy'
        par = ', '.join(f'{pos(v)} `{k}`' for k, v in opc.get('params', {}).items()) or '-'
        rows.append((int(opc['byte']), opc['name'], eff, par))
    for st in db.get('setters', []):
        cat = ', '.join(pos(n) for n in st['fields'])
        sgn = 'sign-extended ' if st.get('signed') else ''
        rows.append((int(st['byte']), st['name'],
                     f'set the frontend register to {sgn}{{{cat}}} << {st["shift"]}', '-'))
    lines = ['| Byte | Name | Effect | Operand fields |',
             '|------|------|--------|----------------|']
    for byte, name, eff, par in sorted(rows):
        lines.append(f'| `0x{byte:02X}` | `{name}` | {eff} | {par} |')
    return lines


def render(root: str) -> dict:
    """All generated tables, by block name"""
    rdl = os.path.join(root, 'src/frontend/reg/idma_reg.rdl')
    tops = {v: compile_rdl(rdl, p) for v, p in REG_VARIANTS.items()}
    with open(os.path.join(root, 'src/db/idma_dmopc.yml'), 'r', encoding='utf-8') as fh:
        dmopc = yaml.safe_load(fh)
    out = {f'reg_{name}': field_table(name, tops) for name in FIELD_TABLES}
    out['reg_map'] = map_table(tops)
    out['dmopc'] = dmopc_table(dmopc)
    return out


def main() -> int:
    par = argparse.ArgumentParser(description=__doc__)
    par.add_argument('--root', default=os.path.join(os.path.dirname(__file__), '..'))
    par.add_argument('--check', action='store_true', help='fail if a page differs')
    par.add_argument('pages', nargs='+', help='docs pages holding generated blocks')
    args = par.parse_args()
    tables = render(args.root)
    seen, bad = set(), 0
    pat = re.compile(r'(<!-- BEGIN GENERATED (\w+) -->\n)(.*?)(<!-- END GENERATED \2 -->)', re.S)
    for page in args.pages:
        with open(page, 'r', encoding='utf-8') as fh:
            text = fh.read()

        def sub(m):
            if m.group(2) not in tables:
                raise KeyError(f'{page}: unknown generated block {m.group(2)}')
            seen.add(m.group(2))
            return m.group(1) + '\n'.join(tables[m.group(2)]) + '\n' + m.group(4)

        new = pat.sub(sub, text)
        if new != text:
            if args.check:
                bad += 1
                sys.stdout.writelines(difflib.unified_diff(
                    text.splitlines(True), new.splitlines(True), page, page + ' (generated)'))
            else:
                with open(page, 'w', encoding='utf-8') as fh:
                    fh.write(new)
    for name in sorted(set(tables) - seen):
        print(f'error: generated block {name} is in no page')
        bad += 1
    if bad:
        print(f'gen_doc_tables: {bad} page(s) or block(s) out of date')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())

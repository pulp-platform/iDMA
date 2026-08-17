# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

"""Emit the elaboration configurations of one top, straight from jobs.json.

Prints one line per configuration:

    <config-name> -GName=Value -GName=Value ...

Both slang and verilator take those flags verbatim. slang silently ignores a
``-G`` whose parameter does not exist, so every name is checked against the
module header here; an unknown or misspelled parameter is a hard error rather
than a configuration that quietly does not apply.
"""

import argparse
import glob
import json
import os
import re
import sys

# Parameters a compute-enabled configuration sets
COMPUTE_PARAMS = ('EnableCompute', 'ComputeOps', 'ComputeTuning')


def packed_struct_fields(typename, sources):
    """Return the field names of packed struct *typename*, MSB field first."""
    decl = re.compile(r'typedef\s+struct\s+packed\s*\{([^{}]*)\}\s*' +
                      re.escape(typename) + r'\s*;', re.S)
    for path in sources:
        try:
            with open(path, 'r', errors='replace') as handle:
                text = handle.read()
        except OSError:
            continue
        match = decl.search(text)
        if not match:
            continue
        fields = []
        for line in match.group(1).splitlines():
            line = re.sub(r'//.*', '', line).strip()
            if not line.startswith('logic'):
                continue
            for name in line[len('logic'):].rstrip(';').split(','):
                name = name.strip()
                if name:
                    fields.append(name)
        return fields
    return []


def module_parameters(top, sources):
    """Return the parameter names declared in the header of module *top*."""
    decl = re.compile(r'\bmodule\s+' + re.escape(top) + r'\b')
    for path in sources:
        try:
            with open(path, 'r', errors='replace') as handle:
                text = handle.read()
        except OSError:
            continue
        match = decl.search(text)
        if not match:
            continue
        start = text.find('#(', match.end())
        if start < 0:
            return set()
        depth = 0
        for pos in range(start + 1, len(text)):
            if text[pos] == '(':
                depth += 1
            elif text[pos] == ')':
                depth -= 1
                if depth == 0:
                    header = text[start:pos]
                    break
        else:
            raise SystemExit('error: unterminated parameter list of {}'.format(top))
        names = re.findall(r'\bparameter\b[^,;()]*?\b([A-Za-z_]\w*)\s*=', header)
        return set(names)
    raise SystemExit('error: module {} not found in the given sources'.format(top))


def entries_for(jobs, top):
    """jobs.json entries whose synth_top or testbench is *top*."""
    return [(name, body) for name, body in jobs.items()
            if body.get('synth_top') == top or body.get('testbench') == top]


def main():
    par = argparse.ArgumentParser(description=__doc__)
    par.add_argument('--verify-db', default=None,
                     help='src/db/verify.yml; supplies the width and compute sweeps')
    par.add_argument('--top', required=True)
    par.add_argument('--jobs', default='jobs/jobs.json')
    par.add_argument('--source', action='append', default=[], metavar='GLOB',
                     help='glob of SystemVerilog sources to search for the module header')
    par.add_argument('--widths', default='',
                     help='space-separated DataWidth sweep; empty disables the sweep')
    par.add_argument('--compute', default='', metavar='WIDTH:OPS:TUNING',
                     help='space-separated compute-enabled configurations; empty '
                          'disables the sweep. Skipped for tops without the parameters')
    args = par.parse_args()

    # The database is the source when supplied; the flags stay for one-off runs.
    if args.verify_db:
        import yaml
        with open(args.verify_db, 'r') as handle:
            db = yaml.safe_load(handle) or {}
        if db.get('elab_widths'):
            args.widths = ' '.join(str(w) for w in db['elab_widths'])
        if db.get('elab_compute'):
            args.compute = ' '.join('{}:{}:{}'.format(c['width'], c['ops'], c['tuning'])
                                    for c in db['elab_compute'])

    patterns = args.source or ['target/rtl/*.sv', 'src/**/*.sv', 'test/**/*.sv']
    sources = []
    for pattern in patterns:
        sources += sorted(glob.glob(pattern, recursive=True))
    if not sources:
        raise SystemExit('error: no sources matched {}'.format(patterns))

    with open(args.jobs, 'r') as handle:
        jobs = json.load(handle)

    declared = module_parameters(args.top, sources)
    matches = entries_for(jobs, args.top)
    if not matches:
        raise SystemExit('error: no {} entry names {} as a synth_top or testbench'.format(
            os.path.basename(args.jobs), args.top))

    lines = []
    seen = set()
    base = {}
    for name, body in matches:
        params = body.get('params', {})
        unknown = sorted(set(params) - declared)
        if unknown:
            raise SystemExit('error: {} names parameter(s) {} that module {} does not '
                             'declare'.format(name, ', '.join(unknown), args.top))
        if not base:
            base = dict(params)
        flags = ' '.join('-G{}={}'.format(k, v) for k, v in params.items())
        seen.add(flags)
        lines.append('{} {}'.format(name, flags).rstrip())

    widths = [w for w in args.widths.split() if w]
    if widths:
        if 'DataWidth' not in declared:
            print('note: {} has no DataWidth parameter; width sweep not applicable'.format(
                args.top), file=sys.stderr)
        else:
            for width in widths:
                cfg = dict(base)
                cfg['DataWidth'] = width
                flags = ' '.join('-G{}={}'.format(k, v) for k, v in cfg.items())
                if flags in seen:  # identical to a jobs.json configuration
                    continue
                seen.add(flags)
                lines.append('dw{} {}'.format(width, flags))

    computes = [c for c in args.compute.split() if c]
    if computes:
        have = [p for p in COMPUTE_PARAMS if p in declared]
        if have and len(have) != len(COMPUTE_PARAMS):
            raise SystemExit('error: module {} declares {} but not {}; the compute sweep '
                             'would silently not apply'.format(
                                 args.top, ', '.join(have),
                                 ', '.join(p for p in COMPUTE_PARAMS if p not in declared)))
        if not have:
            print('note: {} has no compute parameters; compute sweep not applicable'.format(
                args.top), file=sys.stderr)
        else:
            ops_fields = packed_struct_fields('compute_enable_t', sources)
            tuning_fields = packed_struct_fields('compute_tuning_t', sources)
            if not ops_fields or not tuning_fields:
                raise SystemExit('error: cannot read compute_enable_t/compute_tuning_t; '
                                 'the compute sweep cannot be validated')
            # MSB first; mxfp16 gates FP16 paths only, so it enables no datapath alone
            real_ops = [f for f in ops_fields if f != 'mxfp16']
            real_mask = 0
            for pos, name in enumerate(reversed(ops_fields)):
                if name in real_ops:
                    real_mask |= 1 << pos
            for spec in computes:
                fields = spec.split(':')
                if len(fields) != 3:
                    raise SystemExit('error: --compute entry {} is not '
                                     'WIDTH:OPS:TUNING'.format(spec))
                width, ops, tuning = fields
                for name, value in (('WIDTH', width), ('OPS', ops), ('TUNING', tuning)):
                    if not value.isdigit():
                        raise SystemExit('error: --compute entry {}: {} is not a '
                                         'non-negative integer'.format(spec, name))
                if int(width) <= 0:
                    raise SystemExit('error: --compute entry {}: WIDTH must be '
                                     'positive'.format(spec))
                if int(ops) >= 1 << len(ops_fields):
                    raise SystemExit('error: --compute entry {}: OPS {} does not fit '
                                     'compute_enable_t ({} bits: {})'.format(
                                         spec, ops, len(ops_fields), ', '.join(ops_fields)))
                if int(tuning) >= 1 << len(tuning_fields):
                    raise SystemExit('error: --compute entry {}: TUNING {} does not fit '
                                     'compute_tuning_t ({} bits: {})'.format(
                                         spec, tuning, len(tuning_fields),
                                         ', '.join(tuning_fields)))
                if not int(ops) & real_mask:
                    raise SystemExit('error: --compute entry {}: OPS {} enables no compute '
                                     'op ({}), so the datapath is never instantiated and '
                                     'the configuration elaborates nothing'.format(
                                         spec, ops, ', '.join(real_ops)))
                cfg = dict(base)
                if 'DataWidth' in declared:
                    cfg['DataWidth'] = width
                cfg['EnableCompute'] = 1
                cfg['ComputeOps'] = ops
                cfg['ComputeTuning'] = tuning
                flags = ' '.join('-G{}={}'.format(k, v) for k, v in cfg.items())
                if flags in seen:
                    continue
                seen.add(flags)
                lines.append('compute{}_ops{}_t{} {}'.format(width, ops, tuning, flags))

    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(main())

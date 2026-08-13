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

# Configurations that sweep the bus width on top of the jobs.json parameters.
# Every jobs.json entry pins DataWidth=32, so nothing wider is elaborated by
# the directed matrix.
DEFAULT_WIDTHS = [32, 64, 512, 1024]


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
    par.add_argument('--top', required=True)
    par.add_argument('--jobs', default='jobs/jobs.json')
    par.add_argument('--source', action='append', default=[], metavar='GLOB',
                     help='glob of SystemVerilog sources to search for the module header')
    par.add_argument('--widths', default=' '.join(str(w) for w in DEFAULT_WIDTHS),
                     help='space-separated DataWidth sweep; empty disables the sweep')
    args = par.parse_args()

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

    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(main())

# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

"""Run a verification suite, or emit the CI matrix, from src/db/verify.yml.

Both come from the same entries, so a leg cannot exist in CI and not locally, or
the reverse. The old form kept the run set in make variables and the fan-out in
the workflow, and needed a drift checker to notice when they disagreed.

  run_verify.py --suite mxneg           run every leg of one suite
  run_verify.py --emit-matrix suites    print the suite names as a CI matrix
  run_verify.py --list                  print every leg, one per line
  run_verify.py --tb-tops               print the testbench tops bender knows of
  run_verify.py --prereqs mxneg         print the files that suite needs built
  run_verify.py --emit reg_variants     print a list the make recipes loop over

Testbench tops are asked of bender rather than listed by hand: it already owns
the file set, so a testbench added to Bender.yml is elaborated without touching
this file, and one that is not in Bender.yml cannot hide behind a stale list.
"""

import argparse
import json
import os
import re
import subprocess
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DB = os.path.join(ROOT, 'src', 'db', 'verify.yml')


def load(path=None):
    with open(path or DB, 'r') as handle:
        return yaml.safe_load(handle)


def legs(suite_name, suite):
    """Expand one suite into its runs: an explicit list, or a swept parameter."""
    if 'runs' in suite:
        for run in suite['runs']:
            yield {
                'tag': run['tag'],
                'params': dict(run.get('params', {})),
                'token': run.get('token', suite.get('token')),
                'plusargs': run.get('plusargs', []),
            }
        return
    if 'sweep' not in suite:
        raise KeyError('suite {} has neither runs nor sweep'.format(suite_name))
    sweep = suite['sweep']
    for value in sweep['values']:
        yield {
            'tag': '{}_{}'.format(suite_name, value),
            'params': {sweep['param']: value},
            'token': suite.get('token'),
            'plusargs': [],
        }


def bender_sources(bender, targets):
    """The .sv files bender selects for *targets*, in compile order."""
    cmd = [bender, 'script', 'flist'] + targets
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit('bender failed: ' + out.stderr.strip())
    files = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if line and not line.startswith(('+incdir+', '-', '+define+')):
            files.append(line)
    return files


def tb_tops(db, bender, targets):
    """Every testbench module bender knows about, for the elaboration tier.

    `tops_untested` is deliberately not subtracted: those tops elaborate fine and
    only their simulation is excluded, so dropping them here would quietly lose
    the elaboration coverage that still works.
    """
    covered = set(db.get('elab_covered_elsewhere', []))
    found = []
    decl = re.compile(r'^\s*module\s+(tb_\w+)', re.M)
    for path in bender_sources(bender, targets):
        # relative: an absolute match on deps/ would filter out the whole repo
        rel = os.path.relpath(path, ROOT)
        if rel.startswith('..') or rel.startswith(('.bender/', 'deps/')):
            continue
        try:
            with open(path, 'r', errors='replace') as handle:
                text = handle.read()
        except OSError:
            continue
        for name in decl.findall(text):
            if name.startswith('tb_idma_backend_'):
                continue          # covered by the matching per-backend leg
            if name in covered or name in found:
                continue
            found.append(name)
    return sorted(found)


def run_suite(name, db, args):
    suite = db['suites'][name]
    vlt_dir = args.vlt_dir
    flist = os.path.join(vlt_dir, suite['top'] + '.f')
    failures = []
    planned = list(legs(name, suite))
    if not planned:
        print('error: suite {} has no legs'.format(name))
        return 1
    for leg in planned:
        if not leg['token']:
            print('error: leg {} has no token'.format(leg['tag']), file=sys.stderr)
            return 1
        cmd = [sys.executable, os.path.join(HERE, 'run_vlt_sim.py'),
               '--dir', vlt_dir, '--top', suite['top'], '--flist', flist,
               '--tag', leg['tag'], '--token', leg['token']]
        for key, value in leg['params'].items():
            cmd += ['--param', '{}={}'.format(key, value)]
        for define in suite.get('defines', []):
            cmd += ['--define', define]
        for plusarg in leg['plusargs']:
            cmd += ['--plusarg', plusarg]
        if suite.get('dpi'):
            cmd += ['--dpi', os.path.join(vlt_dir, suite['dpi'] + '.o')]
        if suite.get('expect') == 'fail':
            cmd += ['--expect', 'fail']
        if args.verilator:
            cmd += ['--verilator', args.verilator]
        if args.makeflags:
            cmd += ['--makeflags', args.makeflags]
        if subprocess.call(cmd) != 0:
            failures.append(leg['tag'])
    # A suite that silently ran nothing is a pass under any per-leg check alone
    print('{}: ran {} leg(s), {} failed'.format(name, len(planned), len(failures)))
    return 1 if failures else 0


def main():
    par = argparse.ArgumentParser(description=__doc__)
    par.add_argument('--db', default=DB)
    par.add_argument('--suite')
    par.add_argument('--emit-matrix', choices=['suites'])
    par.add_argument('--list', action='store_true')
    par.add_argument('--emit', metavar='KEY',
                     choices=['elab_shared_tops', 'multihead_ids', 'reg_variants', 'suites'],
                     help='print a database list for a make recipe to loop over')
    par.add_argument('--prereqs', metavar='SUITE',
                     help='files the suite needs built, so make needs no per-suite rule')
    par.add_argument('--tb-tops', action='store_true',
                     help='testbench tops, from bender rather than a hand-kept list')
    par.add_argument('--bender', default=os.environ.get('BENDER', 'bender'))
    par.add_argument('--target', action='append', default=[],
                     help='bender target; repeat, e.g. --target rtl --target idma_test')
    par.add_argument('--vlt-dir', default=os.path.join(ROOT, 'target/sim/verilator'))
    par.add_argument('--verilator', default=os.environ.get('VERILATOR'))
    par.add_argument('--makeflags', default=os.environ.get('IDMA_VLT_MAKEFLAGS'))
    args = par.parse_args()
    db = load(args.db)

    if args.emit_matrix == 'suites':
        if not db.get('suites'):
            print('error: the database lists no suites', file=sys.stderr)
            return 1
        print(json.dumps({'suite': sorted(db['suites'])}))
        return 0
    if args.emit:
        entries = sorted(db['suites']) if args.emit == 'suites' else (db.get(args.emit) or [])
        if not entries:
            print('error: {} is empty'.format(args.emit), file=sys.stderr)
            return 1
        if args.emit == 'reg_variants':
            for entry in entries:
                print('{} {}'.format(entry['variant'], entry['module']))
        else:
            print(' '.join(str(e) for e in entries))
        return 0
    if args.prereqs:
        if args.prereqs not in db['suites']:
            print('error: no suite named {}'.format(args.prereqs), file=sys.stderr)
            return 1
        suite = db['suites'][args.prereqs]
        needed = [os.path.join(args.vlt_dir, suite['top'] + '.f')]
        if suite.get('dpi'):
            needed.append(os.path.join(args.vlt_dir, suite['dpi'] + '.o'))
        print(' '.join(needed))
        return 0
    if args.tb_tops:
        targets = []
        for target in args.target:
            targets += ['-t', target]
        tops = tb_tops(db, args.bender, targets)
        if not tops:
            print('error: bender returned no testbench tops', file=sys.stderr)
            return 1
        print(' '.join(tops))
        return 0
    if args.list:
        for name in sorted(db['suites']):
            for leg in legs(name, db['suites'][name]):
                print('{}\t{}\t{}'.format(name, leg['tag'], leg['token']))
        return 0
    if args.suite:
        if args.suite not in db['suites']:
            print('error: no suite named {}'.format(args.suite))
            return 1
        return run_suite(args.suite, db, args)
    par.error('pass --suite, --emit-matrix or --list')


if __name__ == '__main__':
    sys.exit(main())

# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

"""Codegen hygiene checks over jobs.json and the generated RTL.

This is not verification. It checks that the run list and the generated output
still describe the same design:

  a) every backend id has a jobs.json entry,
  b) every job path referenced by jobs.json exists,
  c) every testbench and synth_top named by jobs.json exists in the sources,
  d) the workflow fans out over every backend id,
  e) every negative-test case the testbench defines is either run or named as
     skipped, and every legalizer compute guard is either proven to fire by some
     case or named as untested. Without (e) a new case or a new guard is added to
     the design and silently exercised by nothing.

The simulation matrix is not checked: CI fans it out over jobs/jobs.json, the
same file that drives the local runs. The backend-id matrix is a literal list in
the workflow, so (e) still compares it against the ids.

The run list is always taken from jobs.json, never from `ls jobs/*`: four
error_*.txt files exist on disk for variants built with ErrorHandling=0 and
must not be run. They are listed in UNWIRED_JOBS so the reverse check (a file
on disk that nothing references) stays meaningful.
"""

import argparse
import glob
import json
import os
import re
import sys


# On disk but deliberately unwired: these backends elaborate with ErrorHandling=0
UNWIRED_JOBS = {
    'backend_r_axi_w_obi/error_simple.txt',
    'backend_r_axi_w_obi/error_mixed.txt',
    'backend_r_obi_w_axi/error_simple.txt',
    'backend_r_obi_w_axi/error_mixed.txt',
}


def load_sources(patterns):
    text = []
    for pattern in patterns:
        for path in sorted(glob.glob(pattern, recursive=True)):
            with open(path, 'r', errors='replace') as handle:
                text.append(handle.read())
    return '\n'.join(text)


def main():
    par = argparse.ArgumentParser(description=__doc__)
    par.add_argument('--jobs', default='jobs/jobs.json')
    par.add_argument('--jobs-dir', default='jobs')
    par.add_argument('--ids', required=True, help='space-separated IDMA_BACKEND_IDS')
    par.add_argument('--source', action='append', default=[], metavar='GLOB')
    par.add_argument('--matrix-file', default=None,
                     help='CI workflow that must fan out over every backend id')
    par.add_argument('--verify-db', default=None,
                     help='jobs/jobs.json; the run set and its named exclusions')
    par.add_argument('--mxneg-tb', default=None,
                     help='negative-test testbench; its case labels must all be accounted for')
    par.add_argument('--mxneg-guard-src', default=None,
                     help='source declaring the compute guards, e.g. the legalizer template')
    args = par.parse_args()

    patterns = args.source or ['target/rtl/*.sv', 'src/**/*.sv', 'test/**/*.sv']
    with open(args.jobs, 'r') as handle:
        jobs = json.load(handle)
    # _verify holds the globals; entries with a verify key are simulation suites
    # rather than backend variants, so they carry no synth_top and no job files
    suites = {k: v for k, v in jobs.items() if 'verify' in v}
    jobs = {k: v for k, v in jobs.items() if k != '_verify' and 'verify' not in v}
    sources = load_sources(patterns)
    errors = []

    # (a) every backend id is represented by a jobs.json entry
    synth_tops = {body.get('synth_top') for body in jobs.values()}
    for backend_id in args.ids.split():
        expected = 'idma_backend_synth_' + backend_id
        if expected not in synth_tops:
            errors.append('backend id {} has no {} entry (expected synth_top {})'.format(
                backend_id, os.path.basename(args.jobs), expected))

    # (b) every referenced job path exists
    referenced = set()
    for name, body in jobs.items():
        for job, rel in body.get('jobs', {}).items():
            referenced.add(rel)
            if not os.path.isfile(os.path.join(args.jobs_dir, rel)):
                errors.append('{}: job "{}" references missing file {}/{}'.format(
                    name, job, args.jobs_dir, rel))

    # (b, inverse) an unreferenced job file on disk is dead or a forgotten entry
    on_disk = set()
    for path in glob.glob(os.path.join(args.jobs_dir, '**', '*.txt'), recursive=True):
        on_disk.add(os.path.relpath(path, args.jobs_dir))
    for rel in sorted(on_disk - referenced - UNWIRED_JOBS):
        errors.append('{}/{} is referenced by no {} entry'.format(
            args.jobs_dir, rel, os.path.basename(args.jobs)))
    for rel in sorted(UNWIRED_JOBS - on_disk):
        errors.append('{} is listed as deliberately unwired but does not exist'.format(rel))

    # (c) named testbenches and synth wrappers exist in the sources
    for name, body in jobs.items():
        for field in ('testbench', 'synth_top'):
            module = body.get(field)
            if not module:
                errors.append('{}: no {} named'.format(name, field))
                continue
            if not re.search(r'\bmodule\s+' + re.escape(module) + r'\b', sources):
                errors.append('{}: {} "{}" is not defined in the sources'.format(
                    name, field, module))

    # a suite entry names no synth_top, but its testbench must still exist
    for name, body in sorted(suites.items()):
        module = body.get('testbench')
        if not module:
            errors.append('{}: no testbench named'.format(name))
        elif not re.search(r'\bmodule\s+' + re.escape(module) + r'\b', sources):
            errors.append('{}: testbench "{}" is not defined in the sources'.format(
                name, module))

    # (d) the backend-id matrix is a literal list in the workflow, so it can drift
    if args.matrix_file:
        with open(args.matrix_file, 'r') as handle:
            matrix = handle.read()
        for backend_id in args.ids.split():
            if not re.search(r'^\s*-\s*' + re.escape(backend_id) + r'\s*$', matrix, re.M):
                errors.append('{} has no matrix leg for backend id {}'.format(
                    args.matrix_file, backend_id))

    # (e) compares the run set against the design, not against a copy of itself
    db = {}
    if args.verify_db:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import run_verify
        db = run_verify.load(args.verify_db)

    mxneg = db.get('suites', {}).get('mxneg', {})
    run_cases = {str(r['params']['NegCase']) for r in mxneg.get('runs', [])}
    skipped = {str(e['case']): e['why'] for e in mxneg.get('exclude', [])}

    if args.mxneg_tb and db:
        with open(args.mxneg_tb, 'r', errors='replace') as handle:
            tb_text = handle.read()
        body = re.search(r'\bcase\s*\(\s*NegCase\s*\)(.*?)\bendcase', tb_text, re.S)
        if not body:
            errors.append('{}: no case (NegCase) block found'.format(args.mxneg_tb))
        else:
            defined = set(re.findall(r'^\s*(\d+)\s*:', body.group(1), re.M))
            for case in sorted(defined - run_cases - set(skipped), key=int):
                errors.append('{}: case {} is defined but neither run nor excluded in '
                              '{}'.format(args.mxneg_tb, case, os.path.basename(args.verify_db)))
            for case in sorted(set(skipped) - defined, key=int):
                errors.append('case {} is excluded but the testbench does not define '
                              'it'.format(case))
            for case in sorted(run_cases - defined, key=int):
                errors.append('case {} is run but the testbench does not define it'.format(case))

    # An exclude entry must name a value the sweep does not run
    for name, suite in sorted(db.get('suites', {}).items()):
        sweep = suite.get('sweep')
        for entry in suite.get('exclude', []):
            for value in entry.get('values', []):
                if sweep and value in sweep.get('values', []):
                    errors.append('suite {}: {} is both run and excluded'.format(name, value))
            if not entry.get('values') and not entry.get('case'):
                errors.append('suite {}: an exclude entry names neither values nor a '
                              'case'.format(name))

    if args.mxneg_guard_src and db:
        with open(args.mxneg_guard_src, 'r', errors='replace') as handle:
            guard_text = handle.read()
        declared = set(re.findall(r'`ASSERT_NEVER\(\s*(Compute\w+)', guard_text))
        tested = {r['token'] for r in mxneg.get('runs', []) if r.get('token')}
        waived = {e['guard'] for e in db.get('guards_untested', [])}
        for guard in sorted(declared - tested - waived):
            errors.append('{}: guard {} has no negative test and is not named in '
                          'guards_untested'.format(args.mxneg_guard_src, guard))
        for guard in sorted(waived - declared):
            errors.append('guard {} is named in guards_untested but is not declared in '
                          '{}'.format(guard, args.mxneg_guard_src))
        for guard in sorted(tested - declared):
            errors.append('guard {} is claimed by a mxneg run but is not declared in '
                          '{}'.format(guard, args.mxneg_guard_src))

    for message in errors:
        print('error: ' + message)
    if errors:
        print('check_jobs: {} problem(s)'.format(len(errors)))
        return 1
    print('check_jobs: {} entries, {} job paths, all consistent'.format(
        len(jobs), len(referenced)))
    return 0


if __name__ == '__main__':
    sys.exit(main())

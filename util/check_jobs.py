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
  c) every testbench and synth_top named by jobs.json exists in the sources.

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

# Directed job files that exist on disk and are deliberately not wired into
# jobs.json: the r_axi_w_obi and r_obi_w_axi backends elaborate with
# ErrorHandling=0, so the error tests do not apply to them.
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
    par.add_argument('--matrix-file', required=True,
                     help='CI workflow that must fan out over every backend id')
    par.add_argument('--mxneg-cases', default='',
                     help='negative-test cases the workflow legs must request between them')
    args = par.parse_args()

    patterns = args.source or ['target/rtl/*.sv', 'src/**/*.sv', 'test/**/*.sv']
    with open(args.jobs, 'r') as handle:
        jobs = json.load(handle)
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

    # (b, inverse) a job file on disk that nothing references, and is not a
    # known-unwired file, is either dead or a forgotten entry
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

    # (d) the CI matrix must name every backend id and request every negative
    # test case; a leg that silently does not exist is worse than no leg
    with open(args.matrix_file, 'r') as handle:
        matrix = handle.read()
    for backend_id in args.ids.split():
        if not re.search(r'^\s*-\s*' + re.escape(backend_id) + r'\s*$', matrix, re.M):
            errors.append('{} has no matrix leg for backend id {}'.format(
                args.matrix_file, backend_id))
    if args.mxneg_cases:
        requested = set()
        for line in re.findall(r'^\s*cases:\s*(.+?)\s*$', matrix, re.M):
            requested.update(line.split())
        for case in args.mxneg_cases.split():
            if case not in requested:
                errors.append('{} requests no negative-test case {}'.format(
                    args.matrix_file, case))

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

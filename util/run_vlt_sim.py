# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

"""Build and run one Verilator simulation, then check it three ways.

A simulation leg only passes when all three hold:
  1. the run exited with the expected status (0 for a positive test, non-zero
     for a negative test, whose guard is supposed to fire),
  2. the log exists and is non-empty,
  3. the log contains the expected positive token.

A negated grep for "Error:" is deliberately not used: it passes when the log is
missing, when the simulator died before writing anything, and when the token
was never printed. Every condition here is stated positively.
"""

import argparse
import os
import shlex
import subprocess
import sys
import time


def run(cmd, log_path, cwd):
    """Run cmd, tee to log_path, return (rc, wall_seconds)."""
    start = time.monotonic()
    with open(log_path, 'wb') as log:
        proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        for chunk in iter(lambda: proc.stdout.read(4096), b''):
            log.write(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.flush()
        proc.stdout.close()
        rc = proc.wait()
    return rc, time.monotonic() - start


def parse_args():
    par = argparse.ArgumentParser(description=__doc__)
    par.add_argument('--top', required=True)
    par.add_argument('--flist', required=True)
    par.add_argument('--dir', required=True, help='build/run scratch directory')
    par.add_argument('--tag', default=None, help='unique name for this configuration')
    par.add_argument('--token', required=True, help='string the log must contain')
    par.add_argument('--expect', choices=['pass', 'fail'], default='pass',
                     help='pass: run must exit 0; fail: run must exit non-zero')
    par.add_argument('--param', action='append', default=[], metavar='NAME=VALUE',
                     help='top-level parameter override (-G)')
    par.add_argument('--plusarg', action='append', default=[], metavar='+ARG')
    par.add_argument('--dpi', action='append', default=[], metavar='OBJ',
                     help='precompiled DPI object to link')
    par.add_argument('--verilator', default=os.environ.get('VERILATOR', 'verilator'))
    par.add_argument('--makeflags', default=os.environ.get('IDMA_VLT_MAKEFLAGS', ''))
    par.add_argument('--define', action='append', default=[], metavar='NAME',
                     help='preprocessor define passed to verilator (-D)')
    par.add_argument('--vlt-arg', action='append', default=[], metavar='ARG',
                     help='extra verilator argument; use --vlt-arg=-X for dashed values')
    return par.parse_args()


def main():
    args = parse_args()
    tag = args.tag or args.top
    workdir = os.path.abspath(args.dir)
    os.makedirs(workdir, exist_ok=True)
    objdir = os.path.join(workdir, 'obj_' + tag)
    binary = os.path.join(objdir, 'simv')
    build_log = os.path.join(workdir, tag + '_build.log')
    run_log = os.path.join(workdir, tag + '_run.log')

    build = shlex.split(args.verilator) + [
        '--binary', '--timing', '--assert', '-Wno-fatal', '--error-limit', '1000',
        '-CFLAGS', '-O2',
        '--unroll-count', '4096', '--unroll-stmts', '200000',
        '-Mdir', objdir, '-o', 'simv',
        '-f', os.path.abspath(args.flist), '--top-module', args.top,
    ]
    if args.makeflags:
        build += ['-MAKEFLAGS', args.makeflags]
    build += ['-G' + p for p in args.param]
    build += ['-D' + d for d in args.define]
    if args.dpi:
        build += ['-LDFLAGS', ' '.join(os.path.abspath(d) for d in args.dpi)]
    build += args.vlt_arg

    print('--- building {} [{}] ---'.format(args.top, tag), flush=True)
    rc, secs = run(build, build_log, workdir)
    print('--- build {} rc={} ({:.1f} s) ---'.format(tag, rc, secs), flush=True)
    if rc != 0:
        print('FAIL {}: verilator build failed (see {})'.format(tag, build_log))
        return 1
    if not os.path.isfile(binary):
        print('FAIL {}: no simulation binary at {}'.format(tag, binary))
        return 1

    print('--- running {} [{}] ---'.format(args.top, tag), flush=True)
    rc, secs = run([binary] + args.plusarg, run_log, workdir)
    print('--- run {} rc={} ({:.2f} s) ---'.format(tag, rc, secs), flush=True)

    # 1. exit status
    if args.expect == 'pass' and rc != 0:
        print('FAIL {}: expected exit 0, got {}'.format(tag, rc))
        return 1
    if args.expect == 'fail' and rc == 0:
        print('FAIL {}: negative test exited 0; the guard never fired'.format(tag))
        return 1
    # 2. log present and non-empty
    if not os.path.isfile(run_log) or os.path.getsize(run_log) == 0:
        print('FAIL {}: run log {} is missing or empty'.format(tag, run_log))
        return 1
    # 3. positive token
    with open(run_log, 'r', errors='replace') as handle:
        text = handle.read()
    if args.token not in text:
        print('FAIL {}: token "{}" absent from {}'.format(tag, args.token, run_log))
        return 1

    print('PASS {}: rc={} token="{}"'.format(tag, rc, args.token))
    return 0


if __name__ == '__main__':
    sys.exit(main())

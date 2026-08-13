# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

"""Run a slang elaboration through pyslang.

pyslang ships the same driver as the ``slang`` binary, so every argument is
forwarded verbatim and a red CI leg reproduces locally with the same flags.
A wrapper script is deliberately avoided: some site wrappers swallow a crash
and return 0, which would turn this gate vacuous.

Exit codes mirror the slang driver: 0 clean, 1 bad command line, 5 compilation
or elaboration error. Any unexpected exception is also a non-zero exit.
"""

import shlex
import sys

import pyslang


def main(argv):
    driver = pyslang.driver.Driver()
    driver.addStandardArgs()

    # The string overload parses a full command line; token 0 is the program name.
    cmdline = ' '.join(shlex.quote(a) for a in ['slang'] + list(argv))
    if not driver.parseCommandLine(cmdline):
        return 1
    if not driver.processOptions():
        return 1

    # Both stages must run; `&` rather than `and` so parse failures are reported
    # together with the elaboration diagnostics instead of masking them.
    ok = driver.parseAllSources()
    ok = driver.runFullCompilation() & ok
    return 0 if ok else 5


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Functions used to parse and evaluate iDMA trace files."""
import ast
import sys
from pprint import pprint as pp


def trace_file (fn : str) -> list:
    """Reads a trace file and returns it as a list of dict objects"""

    # resulting list of trace events
    trace = []

    # read and parse file
    with open(fn, 'r', encoding='utf8') as tf:
        for line in tf:
            trace_dict = ast.literal_eval(line)
            trace.append(trace_dict)

    return trace


if __name__ == '__main__':
    _, filename = sys.argv
    pp(trace_file(filename))

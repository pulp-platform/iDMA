#!/usr/bin/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Functions used to parse and evaluate iDMA trace files."""
import ast
import sys
from pprint import pprint as pp


def strb_to_bytes(strobe: int) -> int:
    """Returns the amount of valid bytes in a strobe value"""

    res = 0

    # iterate over strobe
    for byte_en in str(bin(strobe))[2:]:
        if byte_en == '1':
            res += 1

    return res


def read_trace(fn: str) -> list:
    """Reads a trace file and returns it as a list of dict objects"""

    # resulting list of trace events
    trace = []

    # read and parse file
    with open(fn, 'r', encoding='utf8') as tf:
        for line in tf:
            trace_dict = ast.literal_eval(line)
            trace.append(trace_dict)

    return trace


def extract_parameter(trace: list) -> dict:
    """Extracts the parameter of the DMA backend the run resulted from"""

    return trace[0]['cnst']


def get_global_utilization(trace: list, data_width: int) -> list:
    """Calculates the global utilization [read, write] of the DMA"""

    read_data = 0  # in bytes
    write_data = 0  # in bytes

    for ele in trace:
        # add read contribution
        if ele['axib']['r_ready'] and ele['axib']['r_valid']:
            read_data += data_width // 8

        # add write contribution
        if ele['axib']['w_ready'] and ele['axib']['w_valid']:
            write_data += strb_to_bytes(ele['axib']['w_strb'])

    # calculate maximum possible amount of data
    max_data = len(trace) * data_width // 8

    return [read_data / max_data, write_data / max_data]


if __name__ == '__main__':
    _, filename = sys.argv
    idma_trace = read_trace(filename)
    idma_data_width = extract_parameter(idma_trace)['data_width']
    pp(get_global_utilization(idma_trace, idma_data_width))

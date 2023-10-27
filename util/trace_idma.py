#!/usr/bin/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Functions used to parse and evaluate iDMA trace files."""
import argparse
import ast
import sys
from pprint import pprint as pp
from mario.database import read_database
from mario.util import prepare_ids


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

    if len(trace) > 0 and 'cnst' in trace[0]:
        return trace[0]['cnst']
    else:
        print('Trace file is empty or constant header is malformed')
        sys.exit(0)


def get_global_utilization(trace: list, params: dict, be_info: dict) -> list:
    """Calculates the global utilization [read, write] of the DMA"""

    read_data = 0  # in bytes
    write_data = 0  # in bytes

    for ele in trace:
        # add read contribution
        for read_prot in be_info['read_prots']:
            if ele['bus'][f'{read_prot}_rsp_ready'] and ele['bus'][f'{read_prot}_rsp_valid']:
                read_data += params['data_width'] // 8

        # add write contribution
        for write_prot in be_info['write_prots']:
            if ele['bus'][f'{write_prot}_req_ready'] and ele['bus'][f'{write_prot}_req_valid']:
                write_data += strb_to_bytes(ele['bus'][f'{write_prot}_req_strobe'])

    # calculate maximum possible amount of data
    max_data = len(trace) * params['data_width'] // 8

    return [read_data / max_data, write_data / max_data]


def main():
    # Parse Arguments
    parser = argparse.ArgumentParser(
        prog='trace_idma',
        description='Trace iDMA files to analyze them.'
    )
    parser.add_argument('--db', dest='db', nargs='*', required=True, help='Database files')
    parser.add_argument('--trace', dest='trace_file', required=True, help='Trace file')
    args = parser.parse_args()

    # get database to fetch interface names
    database = read_database(args.db)

    # read trace, fetch parameters
    idma_trace = read_trace(args.trace_file)
    params = extract_parameter(idma_trace)

    # fetch and parse identifier
    id = bytes.fromhex(hex(params['identifier'])[2:]).decode("ASCII")
    read_prots = prepare_ids([id])[id]['ar']
    write_prots = prepare_ids([id])[id]['aw']
    read_sigs = [database[r]['trace_signals']['read'] for r in read_prots]
    write_sigs = [database[w]['trace_signals']['write'] for w in write_prots]

    # pack data
    be_info = {
        'read_prots': read_prots,
        'write_prots': write_prots,
        'read_sigs': read_sigs,
        'write_sigs': write_sigs
    }

    # get utilization
    pp(get_global_utilization(idma_trace, params, be_info))

    # no issues
    return 0


if __name__ == '__main__':
    sys.exit(main())

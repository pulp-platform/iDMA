#!/usr/bin/env python3
# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Allows to re-customize job files to use different protocols. For now, only support job files
Without errors enabled"""
import argparse
import random
import sys

SUPP_PROTOCOLS = ['0', '1', '2', '3', '4', '5']

# Parse Arguments
parser = argparse.ArgumentParser(
    prog='reprotocol',
    description='Allows to re-customize job files to use different protocols'
)
parser.add_argument('--seed', dest='seed', default=1773)
parser.add_argument('--r_prots', dest='rps', nargs='*', required=True, choices=SUPP_PROTOCOLS)
parser.add_argument('--w_prots', dest='wps', nargs='*', required=True, choices=SUPP_PROTOCOLS)
parser.add_argument('--infile', dest='infile', required=True)
parser.add_argument('--outfile', dest='outfile', required=True)
args = parser.parse_args()

random.seed(args.seed)

content = ''
with open(args.infile) as f:
    content = f.read().split('\n')[:-1]
    f.close()

if len(content) % 10 != 0:
    print(len(content))
    print('File error, only non-error files supported', file=sys.stderr)
    sys.exit(-1)

for i in range(0, len(content), 10):
    content[i + 3] = args.rps[random.randrange(len(args.rps))]
    content[i + 4] = args.wps[random.randrange(len(args.wps))]

content = '\n'.join(content) + '\n'

with open(args.outfile, 'w') as f:
    content = f.write(content)
    f.close()

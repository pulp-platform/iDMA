#!/usr/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@.ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>


"""Responsible for code generation"""
import argparse
import sys

from mario.util import prepare_ids
from mario.database import read_database
from mario.bender import render_bender
from mario.transport_layer import render_transport_layer
from mario.legalizer import render_legalizer
from mario.backend import render_backend
from mario.wave import render_vsim_wave
from mario.synth import render_synth_wrapper
from mario.testbench import render_testbench

GENABLE_ENTITIES = ['transport', 'legalizer', 'backend', 'vsim_wave', 'testbench', 'synth_wrapper',
    'bender']

EPILOG = '''
The iDMA configuration ID is composed of a underscore-separated list of specifiers and protocols.
Valid specifiers are 'r', 'w', and 'rw' indicating read, write, and bidirectional protocol
capabilities. The specifiers need to be alphabetically ordered, 'rw' is exclusive to 'r' or 'w'.
Protocols follow the specifiers and must be alphabetically ordered within the specifier class.
'''


def main():
    # Parse Arguments
    parser = argparse.ArgumentParser(
        prog='gen_idma',
        description='Mario, our trusty plumber: creates parts of the iDMA given a configuration ID',
        epilog=EPILOG
    )
    parser.add_argument('--entity', choices=sorted(GENABLE_ENTITIES), dest='entity', required=True,
        help='The entity to generate from a given configuration.')
    parser.add_argument('--ids', dest='ids', nargs='*', help='configuration IDs')
    parser.add_argument('--db', dest='db', nargs='*', required=True, help='Database files')
    parser.add_argument('--tpl', dest='tpl', required=True, help='Template file')
    args = parser.parse_args()

    # prepare database and ids
    protocol_ids = prepare_ids(args.ids)
    protocol_db = read_database(args.db)

    # decide what to render
    if args.entity == 'bender':
        print(render_bender(protocol_ids, protocol_db, args.tpl))
    elif args.entity == 'transport':
        print(render_transport_layer(protocol_ids, protocol_db, args.tpl))
    elif args.entity == 'legalizer':
        print(render_legalizer(protocol_ids, protocol_db, args.tpl))
    elif args.entity == 'backend':
        print(render_backend(protocol_ids, protocol_db, args.tpl))
    elif args.entity == 'vsim_wave':
        print(render_vsim_wave(protocol_ids, protocol_db, args.tpl))
    elif args.entity == 'synth_wrapper':
        print(render_synth_wrapper(protocol_ids, protocol_db, args.tpl))
    elif args.entity == 'testbench':
        print(render_testbench(protocol_ids, protocol_db, args.tpl))
    else:
        return 1

    # done
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO database interaction"""
import yaml


def read_database(db_files: list) -> dict:
    """ Read the protocol database"""

    # if no db is specified, escape
    if not db_files:
        return {}

    prot_db = {}

    # get database entries
    for prot_file in sorted(db_files):
        with open(prot_file, 'r', encoding='utf-8') as content:
            # read yml content
            prot = yaml.load(content, Loader=yaml.SafeLoader)
            # print(f'[MARIO] Found protocol: {prot["full_name"]}', file=sys.stderr)
            prot_db[prot['prefix']] = prot
    return prot_db

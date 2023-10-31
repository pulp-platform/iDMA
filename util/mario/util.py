#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Util functions for MARIO"""
import re
import sys


def indent_block(block: str, level: int, num_spaces: int) -> str:
    """Indents a block """
    indented_block = ''
    split_block = block.split('\n')

    for line in split_block:
        if indented_block != '':
            indented_block += '\n'
        indented_block += level * num_spaces * " " + line

    return indented_block


def eval_key(used_prots: list, key: str, feature: str, db: dict) -> bool:
    """Determine if one prot supports a feature"""
    res = False
    for prot in used_prots:
        res |= db[prot][key] == feature
    return res


def prot_key(used_prots: list, key: str, feature: str, db: dict) -> list:
    """Determine the prots supports a feature"""
    res = []
    for prot in used_prots:
        if db[prot][key] == feature:
            res.append(prot)
    return res


def prepare_ids(id_strs: list) -> dict:
    """Parses and validates the IDs """

    # check if empty list
    if not id_strs:
        return {}

    # resulting dict
    res = {}
    # go over all IDs
    for id_str in id_strs:
        # decompose ID
        id = id_str.split('_')

        # check specifier ordering
        specifiers = id[::2]
        if not specifiers == sorted(specifiers):
            print(f'[MARIO] Specifier order not corrected in {id_str}', file=sys.stderr)
            sys.exit(1)

        # get protocols
        r_prots = []
        w_prots = []
        rw_prots = []
        for idx in range(0, len(id), 2):
            if id[idx] == 'r':
                r_prots.append(id[idx + 1])
            elif id[idx] == 'w':
                w_prots.append(id[idx + 1])
            elif id[idx] == 'rw':
                rw_prots.append(id[idx + 1])
            else:
                print(f'[MARIO] {id[idx]} is non-supported specifier', file=sys.stderr)
                sys.exit(1)

        # check protocol ordering
        specifiers = id[::2]
        if not r_prots == sorted(r_prots):
            print('[MARIO] Read protocols order not correct', file=sys.stderr)
            sys.exit(1)

        if not w_prots == sorted(w_prots):
            print('[MARIO] Write protocols order not correct', file=sys.stderr)
            sys.exit(1)

        if not rw_prots == sorted(rw_prots):
            print('[MARIO] Bidir protocols order not correct', file=sys.stderr)
            sys.exit(1)

        # create all_read and all_write
        ar_prots = []
        [ar_prots.append(rp) for rp in r_prots]
        [ar_prots.append(rwp) for rwp in rw_prots]

        aw_prots = []
        [aw_prots.append(wp) for wp in w_prots]
        [aw_prots.append(rwp) for rwp in rw_prots]

        # for now: check if a port only appears once
        if not sorted(ar_prots) == sorted(list(set(ar_prots))):
            print('[MARIO] Protocol can only appear once', file=sys.stderr)
            sys.exit(1)

        if not sorted(aw_prots) == sorted(list(set(aw_prots))):
            print('[MARIO] Protocol can only appear once', file=sys.stderr)
            sys.exit(1)

        # used protocols
        used_prots = []
        [used_prots.append(arps) for arps in ar_prots]
        [used_prots.append(awps) for awps in aw_prots]

        # append protocols
        res[id_str] = {'r': r_prots, 'w': w_prots, 'rw': rw_prots, 'ar': sorted(ar_prots),
            'aw': sorted(aw_prots), 'used': sorted(list(set(used_prots)))}

    return res


def prepare_fids(fe_strs: list) -> dict:
    """Parses and validates the frontend IDs """

    # check if empty list
    if not fe_strs:
        return {}

    # resulting dict
    res = {}
    # assemble info
    for reg in re.findall(r'reg([0-9]+)_([0-9]+)d', ' '.join(fe_strs)):
        res[f'reg{reg[0]}_{reg[1]}d'] = reg

    return res

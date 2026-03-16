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
        specifiers = [''.join(i for i in s if not i.isdigit()) for s in specifiers]

        if not specifiers == sorted(specifiers):
            print(f'[MARIO] Specifier order not correct in {id_str}', file=sys.stderr)
            sys.exit(1)

        # get protocols
        r_prots = []
        w_prots = []
        rw_prots = []
        multihead = {'r': {}, 'w': {}}
        for idx in range(0, len(id), 2):
            # check if we have a multi head config
            num_char_idx = 0
            for c in id[idx]:
                if c.isdigit():
                    num_char_idx += 1

            current_id = id[idx][num_char_idx:]
            num_channels = id[idx][:num_char_idx]
            if num_channels != '':
                num_channels = int(num_channels)
                if num_channels < 2:
                    print(f'[MARIO] Multi head specifier not correct in {id_str}', file=sys.stderr)
                    sys.exit(1)
            else:
                num_channels = 1

            if current_id == 'r':
                r_prots.append(id[idx + 1])
                multihead['r'][id[idx + 1]] = num_channels
            elif current_id == 'w':
                w_prots.append(id[idx + 1])
                multihead['w'][id[idx + 1]] = num_channels
            elif current_id == 'rw':
                rw_prots.append(id[idx + 1])
                multihead['r'][id[idx + 1]] = num_channels
                multihead['w'][id[idx + 1]] = num_channels
            else:
                print(f'[MARIO] {id[idx]} is non-supported specifier', file=sys.stderr)
                sys.exit(1)

        # check protocol ordering
        if not r_prots == sorted(r_prots):
            print('[MARIO] Read protocols order not correct', file=sys.stderr)
            sys.exit(1)

        if not w_prots == sorted(w_prots):
            print('[MARIO] Write protocols order not correct', file=sys.stderr)
            sys.exit(1)

        if not rw_prots == sorted(rw_prots):
            print('[MARIO] Bidir protocols order not correct', file=sys.stderr)
            sys.exit(1)

        # check if a rw_prot is declared as one read and write prot
        for rp in r_prots:
            if rp in w_prots:
                if multihead['r'][rp] == multihead['w'][rp]:
                    print('[MARIO] Use rw specifier instead of r and w separately', file=sys.stderr)
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
            'aw': sorted(aw_prots), 'used': sorted(list(set(used_prots))), 'multihead': multihead}

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

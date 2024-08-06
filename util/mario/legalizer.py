#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO legalizer interaction"""
from mako.template import Template
from mario.util import indent_block, eval_key, prot_key


def prot_force_decouple(used_prots: list, db: dict) -> list:
    """Determine the prots supports a feature"""
    res = []
    for prot in used_prots:
        if db[prot]['bursts'] == 'not_supported' or db[prot]['legalizer_force_decouple'] == 'true':
            res.append(prot)
    return res


def render_legalizer(prot_ids: dict, db: dict, tpl_file: str) -> str:
    """Generate legalizer"""
    legalizer_rendered = ''

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        legalizer_tpl = templ_file.read()

    # render for every is
    for prot_id in prot_ids:

        # get ports used
        used_read_prots = prot_ids[prot_id]['ar']
        used_write_prots = prot_ids[prot_id]['aw']

        # single port IPs?
        srp = len(used_read_prots) == 1
        swp = len(used_write_prots) == 1

        # Indent read meta channel
        for rp in used_read_prots:
            # format DB entry
            read_meta = indent_block(db[rp]['legalizer_read_meta_channel'], 3 - srp, 4)
            db[rp]['legalizer_read_meta_channel'] = read_meta[:read_meta.rfind('\n')]

        # Indent write meta channel and data path
        for wp in used_write_prots:
            # format DB entry
            write_meta = indent_block(db[wp]['legalizer_write_meta_channel'], 3 - swp, 4)
            db[wp]['legalizer_write_meta_channel'] = write_meta[:write_meta.rfind('\n')]
            # if datapath exists
            if 'legalizer_write_data_path' in db[wp]:
                # format DB entry
                data_path = indent_block(db[wp]['legalizer_write_data_path'], 3 - swp, 4)
                db[wp]['legalizer_write_data_path'] = data_path

        has_page_read_bursting = eval_key(used_read_prots, 'bursts', 'split_at_page_boundary', db)
        has_pow2_read_bursting = eval_key(used_read_prots, 'bursts', 'only_pow2', db)
        has_read_bursting = has_page_read_bursting or has_pow2_read_bursting
        has_page_write_bursting = eval_key(used_write_prots, 'bursts', 'split_at_page_boundary', db)
        has_pow2_write_bursting = eval_key(used_write_prots, 'bursts', 'only_pow2', db)
        has_write_bursting = has_page_write_bursting or has_pow2_write_bursting
        # assemble context
        context = {
            'name_uniqueifier': prot_id,
            'database': db,
            'used_read_protocols': used_read_prots,
            'used_write_protocols': used_write_prots,
            'used_protocols': prot_ids[prot_id]['used'],
            'one_read_port': srp,
            'one_write_port': swp,
            'no_read_bursting':
                not has_read_bursting,
            'has_page_read_bursting':
                has_page_read_bursting,
            'has_pow2_read_bursting':
                has_pow2_read_bursting,
            'no_write_bursting':
                not has_write_bursting,
            'has_page_write_bursting':
                has_page_write_bursting,
            'has_pow2_write_bursting':
                has_pow2_write_bursting,
            'used_non_bursting_write_protocols':
                prot_key(used_read_prots, 'bursts', 'not_supported', db),
            'used_non_bursting_read_protocols':
                prot_key(used_write_prots, 'bursts', 'not_supported', db),
            'used_non_bursting_or_force_decouple_read_protocols':
                prot_force_decouple(used_read_prots, db),
            'used_non_bursting_or_force_decouple_write_protocols':
                prot_force_decouple(used_write_prots, db)
        }

        # render
        legalizer_rendered += Template(legalizer_tpl).render(**context)

    return legalizer_rendered

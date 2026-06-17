#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO backend interaction"""
from mako.template import Template
from mario.util import eval_key, prot_key


def render_backend(prot_ids: dict, db: dict, tpl_file: str, compute_cfg: dict = None) -> str:
    """Generate backend"""
    backend_rendered = ''

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        backend_tpl = templ_file.read()

    # render for every is
    for prot_id in prot_ids:

        # format multi head bus
        mh_format = {'ar': {}, 'aw': {}}
        for dir in ['r', 'w']:
            for mhp in prot_ids[prot_id]['multihead'][dir]:
                num_heads = prot_ids[prot_id]['multihead'][dir][mhp]
                if (num_heads == 1):
                    mh_format['a' + dir][mhp] = ''
                else:
                    mh_format['a' + dir][mhp] = f'[{num_heads-1}:0] '

        # get ports used
        used_read_prots = prot_ids[prot_id]['ar']
        used_write_prots = prot_ids[prot_id]['aw']

        # single port IPs? a multi-head protocol still needs the tagged (per-head) path
        any_mh_r = any(n > 1 for n in prot_ids[prot_id]['multihead']['r'].values())
        any_mh_w = any(n > 1 for n in prot_ids[prot_id]['multihead']['w'].values())
        srp = len(used_read_prots) == 1 and not any_mh_r
        swp = len(used_write_prots) == 1 and not any_mh_w

        # on-the-fly compute requires a single AXI write port
        enable_compute = prot_id in (compute_cfg or {})
        if enable_compute and not (swp and used_write_prots[0] == 'axi'):
            raise ValueError(
                f'compute (IDMA_VIDMA_IDS) requires a single AXI write port: {prot_id}')

        # create context
        context = {
            'name_uniqueifier': prot_id,
            'database': db,
            'used_read_protocols': used_read_prots,
            'used_write_protocols': used_write_prots,
            'used_protocols': prot_ids[prot_id]['used'],
            'one_read_port': srp,
            'one_write_port': swp,
            'enable_compute': enable_compute,
            'compute_ops': compute_cfg[prot_id]['ops'] if enable_compute else [],
            'used_non_bursting_write_protocols':
                prot_key(used_write_prots, 'bursts', 'not_supported', db),
            'combined_aw_and_w':
                eval_key(used_write_prots, 'combined_aw_and_w', 'true', db),
            'mh_format': mh_format
        }

        # render
        backend_rendered += Template(backend_tpl).render(**context)

    return backend_rendered

#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO wave interaction"""
from mako.template import Template


def render_vsim_wave(prot_ids: dict, db: dict, tpl_file: str) -> str:
    """Generate questa wave"""
    wave_rendered = ''

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        wave_tpl = templ_file.read()

    # render for every is
    for prot_id in prot_ids:

        # get ports used
        used_read_prots = prot_ids[prot_id]['ar']
        used_write_prots = prot_ids[prot_id]['aw']

        # single port IPs?
        srp = len(used_read_prots) == 1
        swp = len(used_write_prots) == 1

        context = {
            'name_uniqueifier': prot_id,
            'database': db,
            'used_read_protocols': used_read_prots,
            'used_write_protocols': used_write_prots,
            'used_protocols': prot_ids[prot_id]['used'],
            'one_read_port': srp,
            'one_write_port': swp
        }

        # render
        wave_rendered += Template(wave_tpl).render(**context)

    return wave_rendered

#!/usr/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@.ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Bender utils for MARIO"""
from mako.template import Template


def render_bender(prot_ids: dict, prot_db: dict, tpl_file: str) -> str:
    """Generates and returns the Bender.yml file"""

    # assemble all sources
    rtl_sources = ''
    test_sources = ''
    synth_sources = ''

    # assemble sources
    for id in prot_ids:
        rtl_sources += f'      - idma_legalizer_{id}.sv\n'
        rtl_sources += f'      - idma_transport_layer_{id}.sv\n'
        rtl_sources += f'      - idma_backend_{id}.sv\n'
        # test and synth sources
        test_sources += f'      - tb_idma_backend_{id}.sv\n'
        synth_sources += f'      - idma_backend_synth_{id}.sv\n'

    # create context and render
    bender_context = {
        'rtl_sources': rtl_sources, 'test_sources': test_sources, 'synth_sources': synth_sources}

    with open(tpl_file, 'r', encoding='utf-8') as bender_template_content:
        return Template(bender_template_content.read()).render(**bender_context)

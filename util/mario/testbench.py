#!/usr/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti <tsenti@ethz.ch>
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

""" MARIO backend interaction"""
from mako.template import Template


def render_testbench(prot_ids: dict, db: dict, tpl_file: str) -> str:
    """Generate testbench"""
    testbench_rendered = ''

    with open(tpl_file, 'r', encoding='utf-8') as templ_file:
        testbench_tpl = templ_file.read()

    # render for every is
    for prot_id in prot_ids:

        read_bridges = {}
        write_bridges = {}
        tb_defines = ''

        # iterate over the protocols in use
        for up in prot_ids[prot_id]['used']:

            # format bridge instantiation
            if up != 'axi':
                if 'bridge_template' in db[up]:
                    db[up]['bridge_template'] =\
                        '    ' + db[up]['bridge_template'].replace('\n', '\n    ')
                if 'write_bridge_template' in db[up]:
                    db[up]['write_bridge_template'] =\
                        '    ' + db[up]['write_bridge_template'].replace('\n', '\n    ')
                if 'read_bridge_template' in db[up]:
                    db[up]['read_bridge_template'] =\
                        '    ' + db[up]['read_bridge_template'].replace('\n', '\n    ')

            # assemble tb_defines
            tb_defines += f'`define {db[up]["tb_define"]}\n'

        # iterate over the protocols in use
        for rp in prot_ids[prot_id]['ar']:

            # format bridge instantiation
            if rp != 'axi':
                context = {
                    'port': 'read',
                    'database': db,
                    'used_read_protocols': prot_ids[prot_id]['ar']
                }

                # render
                if 'read_bridge_template' in db[rp]:
                    bridge_template = Template(db[rp]['read_bridge_template'])
                else:
                    bridge_template = Template(db[rp]['bridge_template'])
                read_bridges[rp] = bridge_template.render(**context)

        # iterate over the protocols in use
        for wp in prot_ids[prot_id]['aw']:

            # format bridge instantiation
            if wp != 'axi':
                context = {
                    'port': 'write',
                    'database': db,
                    'used_write_protocols': prot_ids[prot_id]['aw']
                }

                # render
                if 'write_bridge_template' in db[wp]:
                    bridge_template = Template(db[wp]['write_bridge_template'])
                else:
                    bridge_template = Template(db[wp]['bridge_template'])
                write_bridges[wp] = bridge_template.render(**context)

        # render
        context = {
            'name_uniqueifier': prot_id,
            'database': db,
            'used_read_protocols': prot_ids[prot_id]['ar'],
            'used_write_protocols': prot_ids[prot_id]['aw'],
            'used_protocols': prot_ids[prot_id]['used'],
            'unused_protocols': set(list(db.keys())) - set(prot_ids[prot_id]['used']),
            'one_read_port': len(prot_ids[prot_id]['ar']) == 1,
            'one_write_port': len(prot_ids[prot_id]['aw']) == 1,
            'rendered_read_bridges': read_bridges,
            'rendered_write_bridges': write_bridges,
            'tb_defines': tb_defines
        }

        # render
        testbench_rendered += Template(testbench_tpl).render(**context)

    return testbench_rendered

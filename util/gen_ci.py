#!/usr/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Generates the main CI pipeline."""
import sys
import json


MAIN_TMPLT = '''
{0:}-run:
  stage: iDMA
  needs:
    - prepare-non-free
  trigger:
    include:
      - artifact: idma-non-free/ci/gitlab-{0:}-ci.yml
        job: prepare-non-free
    strategy: depend
'''


# argparse
_, json_fn, ci_tpl_file = sys.argv

# read json
with open(json_fn, 'r', encoding='utf8') as json_file:
    transfers = json.load(json_file)

# main ci
with open(ci_tpl_file, 'r', encoding='utf8') as ci_header_file:
    main_ci_string = ci_header_file.read()

# iterate over all design variants
for variant in list(transfers.keys()):

    # append to CI body
    main_ci_string += MAIN_TMPLT.format(variant)

print(main_ci_string)

#!/usr/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Tobias Senti <tsenti@student.ethz.ch>

"""Makes a legacy job file multiprotocol\
 by adding random read and write protocol"""

import sys
import random

filename = 'Bender.yml'

_, input_filename = sys.argv

with open(input_filename, 'r', encoding='utf-8') as file:
    lines = file.readlines()

output = []

index = 0
while index < len(lines):
    # Read protocol
    output.append(str(random.randrange(0, 6)) + '\n')
    # Write protocol
    output.append(str(random.randrange(0, 6)) + '\n')
    index += 2

    for i in range(0,8):
        if index >= len(lines):
            break
        output.append(lines[index])
        index += 1

with open(input_filename, 'w', encoding='utf-8') as file:
    file.writelines(output)

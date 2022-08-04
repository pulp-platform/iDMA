#!/usr/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Author: Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Randomly generates job files."""
import sys
import json
import math
import random

# error handle options
HANDLES = ['c', 'a']

# argparse
_, json_fn, out_dir = sys.argv

# read json
with open(json_fn, encoding='utf-8') as json_string:
    transfers = json.load(json_string)

    # iterate over all design variants
    for variant in list(transfers.keys()):

        # get data
        seed = transfers[variant]['seed']
        jobs = transfers[variant]['gen_jobs']

        # init random
        random.seed(seed)

        for job in jobs:
            print(f'Emitting Job Package: {job}')
            job_str = ""
            # generate given number of jobs
            for j in range(0, jobs[job]['num_jobs']):

                # generate a valid length
                length = random.randrange(jobs[job]['min_len'], jobs[job]['max_len'] + 1)

                # generate max transfer sizes
                src_tf_size = 2**random.randrange(
                    math.log(jobs[job]['min_src_tf_len'], 2),
                    math.log(jobs[job]['max_src_tf_len'], 2) + 1
                    )

                dst_tf_size = 2**random.randrange(
                    math.log(jobs[job]['min_dst_tf_len'], 2),
                    math.log(jobs[job]['max_dst_tf_len'], 2) + 1
                    )

                # generate decoupled
                rw_decoupled = random.randrange(0, jobs[job]['ena_rw_decoupled'] + 1)
                aw_decoupled = random.randrange(0, jobs[job]['ena_aw_decoupled'] + 1)

                # parse addresses
                min_src_addr = int(jobs[job]['min_src_addr'], 16)
                max_src_addr = int(jobs[job]['max_src_addr'], 16)
                min_dst_addr = int(jobs[job]['min_dst_addr'], 16)
                max_dst_addr = int(jobs[job]['max_dst_addr'], 16)

                # generate valid address ranges
                src_addr = random.randrange(min_src_addr, max_src_addr + 1)
                dst_addr = random.randrange(min_dst_addr, max_dst_addr + 1)

                # exclusive errors activated: decide between read or write errors
                read_erros_only = random.randrange(0, 2)

                src_errs = []
                dst_errs = []

                if jobs[job]['r_w_err_excl'] == 1:
                    if read_erros_only:
                        # generate valid errors
                        num_src_err = random.randrange(jobs[job]['min_num_rerr'],
                            jobs[job]['max_num_rerr'] + 1)
                        src_errs = sorted(random.sample(range(src_addr,
                            src_addr + length + 1), k=num_src_err))
                    else:
                        num_dst_err = random.randrange(jobs[job]['min_num_werr'],
                            jobs[job]['max_num_werr'] + 1)
                        dst_errs = sorted(random.sample(range(dst_addr,
                            dst_addr + length + 1), k=num_dst_err))
                else:
                    # generate valid errors
                    num_src_err = random.randrange(jobs[job]['min_num_rerr'],
                        jobs[job]['max_num_rerr'] + 1)
                    src_errs = sorted(random.sample(range(src_addr,
                        src_addr + length + 1), k=num_src_err))

                    num_dst_err = random.randrange(jobs[job]['min_num_werr'],
                        jobs[job]['max_num_werr'] + 1)
                    dst_errs = sorted(random.sample(range(dst_addr,
                        dst_addr + length + 1), k=num_dst_err))


                # assemble job file
                job_str += str(length) + '\n'
                job_str += str(hex(src_addr)) + '\n'
                job_str += str(hex(dst_addr)) + '\n'
                job_str += str(src_tf_size) + '\n'
                job_str += str(dst_tf_size) + '\n'
                job_str += str(aw_decoupled) + '\n'
                job_str += str(aw_decoupled and rw_decoupled and False) + '\n'
                job_str += str(len(src_errs) + len(dst_errs)) + '\n'
                for rerr in src_errs:
                    handle = random.choice(HANDLES)
                    job_str += str('r' + handle + hex(rerr)) + '\n'
                for werr in dst_errs:
                    handle = random.choice(HANDLES)
                    job_str += str('w' + handle + hex(werr)) + '\n'

            # writing job files
            with open(f'{out_dir}/{variant}/gen_{job}.txt', 'w', encoding='utf-8') as job_file:
                job_file.write(job_str)
                job_file.close()

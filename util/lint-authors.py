# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Lints the header ensuring consistent file headers"""
import glob
import os
import sys
import re
import yaml


def lint_authors(file: str, config: dict) -> int:
    """Lint headers"""
    # filter paths
    if not os.path.isfile(file):
        print(f'Path ignore:      {file}')
        return 0

    # filter binary files
    try:
        with open(file, 'r', encoding='utf-8') as fh:
            content = fh.read()
    except UnicodeDecodeError:
        print(f'Binary ignore:    {file}')
        return 0

    # filter certain dirs
    for path in config['exclude-paths']:
        if file.startswith(path):
            print(f'Path ignore:      {file}')
            return 0

    # filter extension
    ext = file.split('.')[-1]
    if ext in config['exclude-ext']:
        print(f'Extension ignore: {ext} - {file}')
        return 0

    # filter file
    if file in config['excludes']:
        print(f'Ignore:           {file}')
        return 0

    # parse header
    print(f'Checking file:    {file}')
    header_info = re.findall(config['header-regex'], content)

    # check if there is no match at all -> error
    if len(header_info) == 0:
        print(' -> Header unreadable or no header present')
        return 1

    # check year
    if not int(header_info[0][0]) in config['allowed-years']:
        print(f' -> Copyright outdated {header_info[0][0]}')
        return 1

    # parse authors
    authors = re.findall(config['author-regex'], header_info[0][1])

    # check for authors
    for author in authors:
        if not author[0].strip() in config['allowed-authors']:
            print(f' -> Unknown author {author[0].strip()}')
            return 1
        # check email
        else:
            if author[1].strip() != config['allowed-authors'][author[0].strip()]:
                print(f' -> Wrong email address {author[1].strip()}')
                return 1

    # all checks pass
    return 0


def main():
    errors = 0
    error_files = []

    # get arguments
    _, cfg_file = sys.argv

    # read cfg file
    with open(cfg_file, 'r') as cfh:
        config = yaml.safe_load(cfh)

    # fetch file list
    all_files = glob.glob('**/*', recursive=True)

    # check all files
    for file in all_files:
        if lint_authors(file, config):
            error_files.append(file)
            errors += 1

    # Print error files
    if len(error_files) > 0:
        print('\nErrors in:')
        for ef in error_files:
            print(f'  {ef}')

    # return the accumulated errors
    return errors


if __name__ == '__main__':
    sys.exit(main())

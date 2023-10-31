#!/usr/bin/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

"""List the amount of lines every contributor adds, and their files"""
import sys
import glob
import re
import git

_, extensions, excludes = sys.argv

# current repo
repo = git.Repo()

# remove surplus whitespaces
extensions = re.sub(r' +', ' ', extensions)
excludes = re.sub(r' +', ' ', excludes)

# list of all files to analyze
flist = []

# find files
for ext in extensions.split(' '):
    flist.extend(glob.glob(f'**/*{ext}', recursive=True))

# contribution (in lines for all authors)
lines_total = {}
files = {}

for file in flist:
    excluded = False
    # check if file should be excluded
    for excl in excludes.split(' '):
        if excl != '':
            excluded |= file.endswith(excl)

    # analyze contribution
    if not excluded:
        try:
            for commit, lines in repo.blame('HEAD', file):
                author = commit.author.name

                if author not in lines_total:
                    lines_total[author] = len(lines)
                    files[author] = [file]
                else:
                    lines_total[author] += len(lines)
                    files[author].append(file)
        except git.GitCommandError:
            pass

for contributor, lines in sorted(lines_total.items(), reverse=True, key=lambda item: item[1]):
    touched_files = '\n -  '.join(sorted(list(set(files[contributor]))))
    print(f'{contributor}: {lines} Lines in\n -  {touched_files}\n')

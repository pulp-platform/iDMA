#!/usr/bin/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

"""List the amount of lines every contributor adds, and their files"""
import sys
import glob
import re
import git

TODO_STRINGS = ['todo', 'fixme', 'fix me']

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
    if ext != '':
        flist.extend(glob.glob(f'**/*{ext}', recursive=True))

global_todo_present = False

todo_files = {}
for file in flist:
    excluded = False
    todo_present = False
    num_todos = {}
    # check if file should be excluded
    for excl in excludes.split(' '):
        if excl != '':
            excluded |= file.endswith(excl)

    # analyze file
    if not excluded:
        try:
            for commit, lines in repo.blame('HEAD', file):
                author = commit.author.name
                for line in lines:
                    # check if line has a TODO
                    for to_check in TODO_STRINGS:
                        if re.search(to_check, line, re.IGNORECASE):
                            todo_present |= True
                            global_todo_present |= True
                            if not author in num_todos:
                                num_todos[author] = 1
                            else:
                                num_todos[author] += 1
        except git.GitCommandError:
            pass

    # add file if TODO is present
    if todo_present:
        todo_files[file] = num_todos

# print output
for file in todo_files.items():
    for author in file[1].items():
        print(f'{author[0]}: {author[1]} TODOs in {file[0]}')

sys.exit(global_todo_present)

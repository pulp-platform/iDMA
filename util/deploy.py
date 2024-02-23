#!/usr/env python3
# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Deploy script run by ci. Creates a deploy branch which includes generated files."""
import os
import time

# Git command fragments
GET_BRANCH_CMD = '''git for-each-ref --format='%(objectname) %(refname:short)' refs/heads |\
                    awk "/^$(git rev-parse HEAD)/ {print \\$2}"'''
GET_COMMIT_ID_CMD = 'git rev-parse HEAD'
GET_COMMIT_MSG_CMD = 'git log -1 --pretty=%B'
GIT_ADD_ALL_CMD = 'git add .'
GIT_CHECKOUT_TAG_CMD = 'git checkout -b'
GIT_COMMIT_CMD = 'git commit -m'
GIT_PUSH_CMD = 'git push'

# Repo configuration
ORIGIN = 'origin'

# Comment added to gitignore
GITIGNORE_COMMENT = '# Deactivated by deploy.py'

# get current branch info
current_branch = os.popen(GET_BRANCH_CMD).read().split('\n')[0]
print(f'Current branch: {current_branch}')
current_hash = os.popen(GET_COMMIT_ID_CMD).read().split('\n')[0]
print(f'Current hash: {current_hash}')
current_msg = '\n'.join(os.popen(GET_COMMIT_MSG_CMD).read().split('\n')[:-1])
print(f'Current commit message: \n{current_msg}')

# create target branch
deploy_branch = f'__deploy__{current_hash[0:7]}__{current_branch}'
print(f'Deploy branch: {deploy_branch}\n\n')
deploy_msg = f'{current_msg}\n-----\n\nDeployed from {current_hash}'
print(f'Deploy commit message:\n{deploy_msg}')

# create new deploy branch
os.popen(f'{GIT_CHECKOUT_TAG_CMD} {deploy_branch} {current_branch}')
time.sleep(2)

# selectively deactivate gitignore to check in generated files
with open('target/rtl/.gitignore', 'r', encoding='utf-8') as f:
    content = f.read().split('\n')[:-1]

if content[0] != GITIGNORE_COMMENT:
    with open('target/rtl/.gitignore', 'w', encoding='utf-8') as f:
        f.write(f'{GITIGNORE_COMMENT}\n')
        for line in content:
            f.write(f'# {line}\n')

# add and commit files
os.popen(GIT_ADD_ALL_CMD)
time.sleep(0.5)
os.popen(f'{GIT_COMMIT_CMD} "{deploy_msg}"')
time.sleep(0.5)

# push state to origin
os.popen(f'{GIT_PUSH_CMD} {ORIGIN} {deploy_branch}')

#!/usr/env python3
# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Thomas Benz <tbenz@iis.ee.ethz.ch>

"""Deploy script run by ci. Creates a deploy branch which includes generated files."""
import subprocess


# Repo configuration
ORIGIN = 'origin'

# Comment added to gitignore
GITIGNORE_COMMENT = '# Deactivated by deploy.py'


def git_output(*args):
    """Run a git command and return its stdout without invoking a shell."""
    return subprocess.check_output(['git', *args], text=True).strip()


def git_run(*args):
    """Run a git command without invoking a shell."""
    subprocess.run(['git', *args], check=True)


def get_current_branch():
    """Return the local branch pointing at HEAD, matching the previous shell pipeline."""
    current_hash = git_output('rev-parse', 'HEAD')
    refs = git_output('for-each-ref', '--format=%(objectname) %(refname:short)', 'refs/heads')

    for ref in refs.splitlines():
        object_name, branch_name = ref.split(maxsplit=1)
        if object_name == current_hash:
            return branch_name

    raise RuntimeError(f'Could not find a local branch pointing at {current_hash}')


# get current branch info
current_branch = get_current_branch()
print(f'Current branch: {current_branch}')
current_hash = git_output('rev-parse', 'HEAD')
print(f'Current hash: {current_hash}')
current_msg = git_output('log', '-1', '--pretty=%B')
print(f'Current commit message: \n{current_msg}')

# create target branch
deploy_branch = f'__deploy__{current_hash[0:7]}__{current_branch}'
print(f'Deploy branch: {deploy_branch}\n\n')
deploy_msg = f'{current_msg}\n-----\n\nDeployed from {current_hash}'
print(f'Deploy commit message:\n{deploy_msg}')

# create new deploy branch
git_run('checkout', '-b', deploy_branch, current_branch)

# selectively deactivate gitignore to check in generated files
with open('target/rtl/.gitignore', 'r', encoding='utf-8') as f:
    content = f.read().split('\n')[:-1]

if content[0] != GITIGNORE_COMMENT:
    with open('target/rtl/.gitignore', 'w', encoding='utf-8') as f:
        f.write(f'{GITIGNORE_COMMENT}\n')
        for line in content:
            f.write(f'# {line}\n')

# add and commit files
git_run('add', '.')
git_run('commit', '-m', deploy_msg)

# push state to origin
git_run('push', ORIGIN, deploy_branch)

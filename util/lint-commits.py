#!/usr/bin/env python3
# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import re
import sys

from git import Repo

error_msg_prefix = 'ERROR: '
warning_msg_prefix = 'WARNING: '

# Maximum length of the summary line in the commit message (the first line)
# There is no hard limit, but a typical convention is to keep this line at or
# below 50 characters, with occasional outliers.
COMMIT_MSG_MAX_SUMMARY_LEN = 100


def error(msg, commit=None):
    full_msg = msg
    if commit:
        full_msg = "Commit %s: %s" % (commit.hexsha, msg)
    print(error_msg_prefix + full_msg, file=sys.stderr)


def warning(msg, commit=None):
    full_msg = msg
    if commit:
        full_msg = "Commit %s: %s" % (commit.hexsha, msg)
    print(warning_msg_prefix + full_msg, file=sys.stderr)


def lint_commit_author(commit):
    """
    Checks that the author is properly set.
    """
    success = True
    if commit.author.email.endswith('users.noreply.github.com'):
        error(
            'Commit author has no valid email address set: %s. '
            'Use "git config user.email user@example.com" to '
            'set a valid email address, then update the commit '
            'with "git rebase -i" and/or '
            '"git commit --amend --reset-author". '
            'Also check your GitHub settings at '
            'https://github.com/settings/emails: your email address '
            'must be verified, and the option "Keep my email address '
            'private" must be disabled.' % (commit.author.email, ), commit)
        success = False

    if ' ' not in commit.author.name:
        warning(
            'The commit author name "%s" contains no space. '
            'Use "git config user.name \'Johnny English\'" to '
            'set your real name, and update the commit with "git rebase -i " '
            'and/or "git commit --amend --reset-author".' %
            (commit.author.name, ), commit)
        # A warning doesn't fail lint.

    return success


def lint_commit_message(commit):
    """
    Checks the commit messages to conform to our standards.
    """
    success = True
    lines = commit.message.splitlines()

    # Check length of summary line.
    summary_line_len = len(lines[0])
    if summary_line_len > COMMIT_MSG_MAX_SUMMARY_LEN:
        error(
            "The summary line in the commit message is %d characters long; "
            "only %d characters are allowed." %
            (summary_line_len, COMMIT_MSG_MAX_SUMMARY_LEN), commit)
        success = False

    # Check that summary line does not end with a period
    if lines[0].endswith('.'):
        error("The summary line must not end with a period.", commit)
        success = False

    # Check that we don't have any fixups.
    if lines[0].startswith('fixup!'):
        error("Fixup commits are not allowed. Please resolve by rebasing.",
              commit)
        success = False

    # Try to determine whether we got an area prefix in the commit message:
    summary_line_split = lines[0].split(':')
    summary_line_split_len = len(summary_line_split)

    # We didn't get an area prefix, so just make sure the message started with a
    # capital letter.
    if summary_line_split_len == 1:
        if not re.match(r'[A-Z]', lines[0]):
            error("The summary line must start with a capital letter.", commit)
            success = False
    # The user specified an area on which she worked.
    elif summary_line_split_len == 2:
        if not re.match(r'[a-z_A-Z\-]*(/[a-z_A-Z\-]+)*', summary_line_split[0]):
            error(
                'The area specifier is mal-formed. Only letters,'
                'underscores and hyphens are allowed. Different areas must be'
                'separated by a slash.', commit)
            success = False
        # Check the second part of the commit message.
        if not summary_line_split[1].startswith(' '):
            error("The area must be separated by a single space.", commit)
            success = False
        if not re.match(r'\s[A-Z]', summary_line_split[1]):
            error(
                "The summary line after the colon must start with a capital letter.",
                commit)
            success = False
    # We do not allow more than one area i.e., colon.
    else:
        error("Only one colon is allowed to specify the area of changes.",
              commit)
        success = False

    # Check for an empty line separating the summary line from the long
    # description.
    if len(lines) > 1 and lines[1] != "":
        error(
            "The second line of a commit message must be empty, as it "
            "separates the summary from the long description.", commit)
        success = False

    return success


def lint_commit_base(commit):
    """
    Checks that the commit is properly based and has a single, defined parent.
    """
    success = True
    # Merge commits have two parents, we maintain a linear history.
    if len(commit.parents) > 1:
        error(
            "Please resolve merges by re-basing. Merge commits are not allowed.",
            commit)
        success = False

    return success


def lint_commit(commit):
    success = True
    if not lint_commit_author(commit):
        success = False
    if not lint_commit_message(commit):
        success = False
    if not lint_commit_base(commit):
        success = False
    return success


def main():
    global error_msg_prefix
    global warning_msg_prefix

    parser = argparse.ArgumentParser(
        description='Check commit metadata for common mistakes')
    parser.add_argument('--error-msg-prefix',
                        default=error_msg_prefix,
                        required=False,
                        help='string to prepend to all error messages')
    parser.add_argument('--warning-msg-prefix',
                        default=warning_msg_prefix,
                        required=False,
                        help='string to prepend to all warning messages')
    parser.add_argument('--no-merges',
                        required=False,
                        action="store_true",
                        help='do not check commits with more than one parent')
    parser.add_argument('commit_range',
                        metavar='commit-range',
                        help=('commit range to check '
                              '(must be understood by git log)'))
    args = parser.parse_args()

    error_msg_prefix = args.error_msg_prefix
    warning_msg_prefix = args.warning_msg_prefix

    lint_successful = True

    repo = Repo()
    commits = repo.iter_commits(args.commit_range)
    for commit in commits:
        print("Checking commit %s" % commit.hexsha)
        is_merge = len(commit.parents) > 1
        if is_merge and args.no_merges:
            print("Skipping merge commit.")
            continue

        if not lint_commit(commit):
            lint_successful = False

    if not lint_successful:
        error('Commit lint failed.')
        sys.exit(1)


if __name__ == '__main__':
    main()

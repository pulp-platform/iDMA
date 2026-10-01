#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

# Usage: ci-internal-needed.sh <base> <head>
# Prints false iff every file changed in <base>...<head> is irrelevant to the internal CI.
# Any error prints true.

set -o pipefail

files=$(git diff --name-only --no-renames "$1...$2") || { echo true; exit 0; }
[ -n "$files" ] || { echo true; exit 0; }

while IFS= read -r f; do
    case "$f" in
        doc/* | *.md | CODEOWNERS | LICENSE | LICENSE.* | .github/ISSUE_TEMPLATE/* | \
        util/lint-*.py | scripts/list-* | \
        .github/workflows/docs.yml | .github/workflows/promote-to-master.yml | \
        .github/workflows/prune-deploy-branches.yml | .github/workflows/retarget-to-devel.yml) ;;
        *) echo true; exit 0 ;;
    esac
done <<< "$files"

echo false

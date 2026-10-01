#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

# Usage: ci-internal-needed.sh <base> <head>; prints false iff no change matters, else true

set -o pipefail

files=$(git diff --name-only --no-renames "$1...$2") || { echo true; exit 0; }
[ -n "$files" ] || { echo true; exit 0; }

while IFS= read -r f; do
    case "$f" in
        .github/workflows/gitlab-ci.yml) echo true; exit 0 ;;
        doc/* | *.md | CODEOWNERS | LICENSE | LICENSE.* | .github/* | .gitlint | \
        .pre-commit-config.yaml | util/lint-*.py | util/list-*.py | scripts/list-*) ;;
        *) echo true; exit 0 ;;
    esac
done <<< "$files"

echo false

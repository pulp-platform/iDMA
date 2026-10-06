#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

# Copies Verilator out of the official image; the install is relocatable
set -euo pipefail
digest=sha256:a5b73e2fce0b2c483396f3800940f33b6faa802331a061c21694dd27b7352120
image=verilator/verilator:v5.052@$digest
prefix=$HOME/.cache/verilator
docker pull -q "$image"
id=$(docker create "$image")
trap 'docker rm "$id" > /dev/null' EXIT
mkdir -p "$prefix/bin" "$prefix/share"
for f in verilator verilator_bin; do
  docker cp "$id:/usr/local/bin/$f" "$prefix/bin/"
done
docker cp "$id:/usr/local/share/verilator" "$prefix/share/"
"$prefix/bin/verilator" --version

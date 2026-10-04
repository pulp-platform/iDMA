#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

# Copies Verilator out of the OSEDA image into its install prefix, where its paths point
set -euo pipefail
image=${OSEDA_IMAGE:-hpretl/iic-osic-tools:2026.09}
docker pull -q "$image"
id=$(docker create "$image")
trap 'docker rm "$id" > /dev/null' EXIT
mkdir -p /foss/tools
docker cp "$id:/foss/tools/verilator" /foss/tools/
/foss/tools/verilator/bin/verilator --version

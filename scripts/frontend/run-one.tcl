# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Axel Vanoni <axvanoni@student.ethz.ch>

# run frontend tests with one transfer
source scripts/compile_vsim.tcl
vsim tb_idma_desc64_top -t 1ps -GNumberOfTests=1 \
    -GSimulationTimeoutCycles=200 \
    -GMaxChainedDescriptors=1 \
    -voptargs=+acc
#-voptargs=-pedantic

set StdArithNoWarnings 1
set NumericStdNoWarnings 1
log -r /*

source scripts/waves/vsim_fe_desc64.do

run -all

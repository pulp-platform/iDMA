# Copyright 2022 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Axel Vanoni <axvanoni@student.ethz.ch>

source scripts/compile_vsim.tcl
vsim tb_idma_desc64_bench -t 1ps \
    -GNumberOfTests=150 \
    -GChainedDescriptors=20 \
    -GSimulationTimeoutCycles=300000 \
    -GTransferLength=24 \
    -GDoIRQ=0 \
    +trace_file=trace-test.log \
    -voptargs=+acc
#-voptargs=-pedantic

set StdArithNoWarnings 1
set NumericStdNoWarnings 1
log -r /*

source scripts/waves/vsim_fe_desc64.do

run -all

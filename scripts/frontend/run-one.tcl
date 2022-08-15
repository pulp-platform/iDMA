source scripts/compile_vsim.tcl
vsim tb_idma_desc64_top -t 1ps -GNumberOfTests=1 -GSimulationTimeoutCycles=200 -voptargs=+acc
#-voptargs=-pedantic

set StdArithNoWarnings 1
set NumericStdNoWarnings 1
log -r /*

source scripts/waves/vsim_fe_desc64.do

run -all

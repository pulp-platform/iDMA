source scripts/compile_vsim.tcl

vsim tb_idma_desc64_top -t 1ps -voptargs=+acc
#-voptargs=-pedantic

source scripts/waves/vsim_fe_desc64.do

set StdArithNoWarnings 1
set NumericStdNoWarnings 1
log -r /*
run -all

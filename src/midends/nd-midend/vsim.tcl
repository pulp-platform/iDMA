vlog -sv ../../../.bender/git/checkouts/common_cells-a0d7576c20f2838a/src/popcount.sv
vlog -sv idma_nd_midend_pkg.sv
vlog -sv idma_nd_midend.sv
vlog -sv tb_idma_nd_midend.sv

vsim tb_idma_nd_midend -t 1ps -voptargs=+acc

set StdArithNoWarnings 1
set NumericStdNoWarnings 1
log -r /*

do wave.do

run 1000us

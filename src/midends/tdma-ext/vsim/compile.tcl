# This script was generated automatically by bender.
set ROOT "/home/tbenz/git/bslk/tdma-fe"

if {[catch {vlog -incr -sv \
    +define+TARGET_DEFAULT \
    +define+TARGET_SIMULATION \
    +define+TARGET_VSIM \
    "$ROOT/src/fifo.sv" \
    "$ROOT/src/reg_intf.sv" \
    "$ROOT/src/axi_dma_pkg.sv" \
    "$ROOT/src/tdma_addr_calc.sv" \
    "$ROOT/src/tdma_conf_intf.sv" \
    "$ROOT/src/tdma_frontend.sv" \
    "$ROOT/src/tdma_top.sv" \
    "$ROOT/src/tdma_fix.sv" \
    "$ROOT/test/tdma_fe_tb.sv"
}]} {return 1}

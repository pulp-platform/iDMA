onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/clk_i
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/rst_ni
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/nd_req_i
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/nd_valid_i
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/nd_ready_o
add wave -noupdate -expand /tb_idma_nd_midend/i_idma_nd_midend/burst_req_o
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/burst_valid_o
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/burst_ready_i
add wave -noupdate -divider Internals
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/stage_en
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/stage_clear
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/stage_zero
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/stage_done
add wave -noupdate {/tb_idma_nd_midend/i_idma_nd_midend/gen_dim_counters[6]/i_num_rep_counter/counter_q}
add wave -noupdate {/tb_idma_nd_midend/i_idma_nd_midend/gen_dim_counters[5]/i_num_rep_counter/counter_q}
add wave -noupdate {/tb_idma_nd_midend/i_idma_nd_midend/gen_dim_counters[4]/i_num_rep_counter/counter_q}
add wave -noupdate {/tb_idma_nd_midend/i_idma_nd_midend/gen_dim_counters[3]/i_num_rep_counter/counter_q}
add wave -noupdate {/tb_idma_nd_midend/i_idma_nd_midend/gen_dim_counters[2]/i_num_rep_counter/counter_q}
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/stride_sel_q
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/src_addr_d
add wave -noupdate /tb_idma_nd_midend/i_idma_nd_midend/dst_addr_d
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {61915 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 152
configure wave -valuecolwidth 68
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ps
update
WaveRestoreZoom {15936 ps} {258544 ps}

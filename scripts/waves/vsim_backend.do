onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/clk_i
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/rst_ni
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/testmode_i
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/idma_req_i
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/req_valid_i
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/req_ready_o
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/idma_rsp_o
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/rsp_valid_o
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/rsp_ready_i
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/idma_eh_req_i
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/eh_req_valid_i
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/eh_req_ready_o
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/axi_req_o
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/axi_rsp_i
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/busy_o
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/dp_busy
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/dp_poison
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_req
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_req
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_valid
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_valid
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_last_burst
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_last_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_super_last
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_dp_req_in_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_dp_req_in_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_dp_req_out_valid
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_dp_req_out_valid
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_dp_req_out_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_dp_req_out_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_dp_req_out
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_dp_req_out
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_dp_rsp
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_dp_rsp
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_dp_rsp_valid
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_dp_rsp_valid
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/r_dp_rsp_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/w_dp_rsp_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/ar_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/aw_ready
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/aw_ready_dp
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/aw_valid_dp
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/aw_req_dp
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/legalizer_flush
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/legalizer_kill
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/is_length_zero
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/req_valid
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/idma_rsp
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/rsp_valid
add wave -noupdate -expand -group Backend /tb_idma_backend/i_idma_backend/rsp_ready
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/clk_i
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/rst_ni
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/req_i
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/valid_i
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/ready_o
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_req_o
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_valid_o
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_ready_i
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_req_o
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_valid_o
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_ready_i
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/flush_i
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/kill_i
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_busy_o
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_busy_o
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_tf_q
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_tf_q
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/opt_tf_q
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_tf_ena
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_tf_ena
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_page_offset
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_num_bytes_to_pb
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_page_offset
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_num_bytes_to_pb
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/c_num_bytes_to_pb
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_page_addr_width
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_page_addr_width
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_page_size
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_page_size
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_num_bytes_possible
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_num_bytes
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_addr_offset
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_done
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_num_bytes_possible
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_num_bytes
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_addr_offset
add wave -noupdate -group Legalizer /tb_idma_backend/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_done
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/clk_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/rst_ni
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/testmode_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/axi_req_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/axi_rsp_i
add wave -noupdate -group {Transport Layer} -expand /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_dp_req_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_dp_valid_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_dp_ready_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_dp_rsp_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_dp_valid_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_dp_ready_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_dp_req_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_dp_valid_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_dp_ready_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_dp_rsp_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_dp_valid_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_dp_ready_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/ar_req_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/ar_valid_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/ar_ready_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/aw_req_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/aw_valid_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/aw_ready_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/dp_poison_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_dp_busy_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_dp_busy_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/buffer_busy_o
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_first_mask
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/r_last_mask
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_first_mask
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_last_mask
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/first_r_q
add wave -noupdate -group {Transport Layer} -expand /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/buffer_in
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/read_aligned_in_mask
add wave -noupdate -group {Transport Layer} -expand /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/mask_in
add wave -noupdate -group {Transport Layer} -expand /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/buffer_in_valid
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/buffer_in_ready
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/in_valid
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/in_ready
add wave -noupdate -group {Transport Layer} -expand /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/mask_out
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/first_w
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/last_w
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/buffer_out
add wave -noupdate -group {Transport Layer} -expand /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/buffer_out_valid
add wave -noupdate -group {Transport Layer} -expand /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/buffer_out_ready
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/write_happening
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/ready_to_write
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/first_possible
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/buffer_clean
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_num_beats_q
add wave -noupdate -group {Transport Layer} /tb_idma_backend/i_idma_backend/i_idma_axi_transport_layer/w_cnt_valid_q
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/clk_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/rst_ni
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/testmode_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/rsp_o
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/rsp_valid_o
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/rsp_ready_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/eh_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/eh_valid_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/eh_ready_o
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/r_addr_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/r_consume_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/w_addr_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/w_consume_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/legalizer_flush_o
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/legalizer_kill_o
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/dp_busy_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/dp_poison_o
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/r_dp_rsp_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/r_dp_valid_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/r_dp_ready_o
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/w_dp_rsp_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/w_dp_valid_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/w_dp_ready_o
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/w_last_burst_i
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/state_q
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/r_addr_head
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/w_addr_head
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/r_store_pop
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/w_store_pop
add wave -noupdate -group {Error Handler} /tb_idma_backend/i_idma_backend/gen_error_handler/i_idma_error_handler/num_outst_q
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/clk_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/rst_ni
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/testmode_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/r_rsp_valid_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/r_rsp_ready_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/r_rsp_first_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/r_decouple_aw_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_decouple_aw_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_req_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_valid_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_ready_o
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_req_o
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_valid_o
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_ready_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_req_in
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_req_out
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_ready
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_valid
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/first
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_sent
add wave -noupdate -group R-AW-Coupler /tb_idma_backend/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_to_send_q
add wave -noupdate -divider BUS
add wave -noupdate -group {AXI IF} -label AW /tb_idma_backend/i_aw_hl/in_wave
add wave -noupdate -group {AXI IF} -label AR /tb_idma_backend/i_ar_hl/in_wave
add wave -noupdate -group {AXI IF} -label W /tb_idma_backend/i_w_hl/in_wave
add wave -noupdate -group {AXI IF} -label R /tb_idma_backend/i_r_hl/in_wave
add wave -noupdate -group {AXI IF} -label B /tb_idma_backend/i_b_hl/in_wave
add wave -noupdate -group {iDMA IF} -label {iDMA REQ} /tb_idma_backend/i_req_hl/in_wave
add wave -noupdate -group {iDMA IF} -label {iDMA RSP} -expand -subitemconfig {/tb_idma_backend/i_rsp_hl/in_wave.pld -expand} /tb_idma_backend/i_rsp_hl/in_wave
add wave -noupdate -group {iDMA IF} -label {iDMA EH} /tb_idma_backend/i_eh_hl/in_wave
add wave -noupdate -group Busy -expand /tb_idma_backend/i_idma_backend/busy_o
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {210998 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 150
configure wave -valuecolwidth 427
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
configure wave -timelineunits ns
update
WaveRestoreZoom {1121282 ps} {1235722 ps}

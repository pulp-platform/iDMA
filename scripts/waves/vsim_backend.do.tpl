onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/clk_i
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/rst_ni
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/testmode_i
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/idma_req_i
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/req_valid_i
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/req_ready_o
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/idma_rsp_o
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/rsp_valid_o
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/rsp_ready_i
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/idma_eh_req_i
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/eh_req_valid_i
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/eh_req_ready_o
% for protocol in used_read_protocols:
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/${protocol}_read_req_o
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/${protocol}_read_rsp_i
% endfor
% for protocol in used_write_protocols:
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/${protocol}_write_req_o
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/${protocol}_write_rsp_i
% endfor
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/busy_o
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/dp_busy
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/dp_poison
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_req
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_req
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_valid
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_valid
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_last_burst
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_last_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_super_last
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_dp_req_in_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_dp_req_in_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_dp_req_out_valid
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_dp_req_out_valid
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_dp_req_out_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_dp_req_out_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_dp_req_out
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_dp_req_out
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_dp_rsp
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_dp_rsp
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_dp_rsp_valid
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_dp_rsp_valid
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/r_dp_rsp_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/w_dp_rsp_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/ar_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/aw_ready
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/aw_ready_dp
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/aw_valid_dp
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/aw_req_dp
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/legalizer_flush
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/legalizer_kill
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/is_length_zero
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/req_valid
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/idma_rsp
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/rsp_valid
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/rsp_ready
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/clk_i
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/rst_ni
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/req_i
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/valid_i
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/ready_o
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_req_o
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_valid_o
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_ready_i
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_req_o
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_valid_o
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_ready_i
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/flush_i
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/kill_i
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_busy_o
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_busy_o
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_tf_q
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_tf_q
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/opt_tf_q
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_tf_ena
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_tf_ena
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_num_bytes_to_pb
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_num_bytes_to_pb
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/c_num_bytes_to_pb
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_num_bytes_possible
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_num_bytes
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_addr_offset
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/r_done
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_num_bytes_possible
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_num_bytes
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_addr_offset
add wave -noupdate -group Legalizer /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_hw_legalizer/i_idma_legalizer/w_done
add wave -noupdate -group {Transport Layer} /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/clk_i
add wave -noupdate -group {Transport Layer} /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/rst_ni
add wave -noupdate -group {Transport Layer} /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/testmode_i
% for protocol in used_read_protocols:
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/${protocol}_read_req_o
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/${protocol}_read_rsp_i
% endfor
% for protocol in used_write_protocols:
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/${protocol}_write_req_o
add wave -noupdate -expand -group Backend /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/${protocol}_write_rsp_i
% endfor
add wave -noupdate -group {Transport Layer} /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/*
% for protocol in used_read_protocols:
add wave -noupdate -group {${database[protocol]['full_name']} Read} -expand /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/i_idma_${protocol}_read/*
% endfor
% for protocol in used_write_protocols:
add wave -noupdate -group {${database[protocol]['full_name']} Write} -expand /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/i_idma_${protocol}_write/*
% endfor
% if not one_write_port:
add wave -noupdate -group {Write Response FIFO} -expand /tb_idma_backend${name_uniqueifier}/i_idma_backend/i_idma_transport_layer/i_write_response_fifo/*
% endif
% if one_read_port and one_write_port and ('axi' in used_read_protocols) and ('axi' in used_write_protocols):
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/clk_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/rst_ni
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/testmode_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/r_rsp_valid_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/r_rsp_ready_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/r_rsp_first_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/r_decouple_aw_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_decouple_aw_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_req_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_valid_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_ready_o
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_req_o
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_valid_o
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_ready_i
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_req_in
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_req_out
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_ready
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_valid
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/first
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_sent
add wave -noupdate -group R-AW-Coupler /tb_idma_backend${name_uniqueifier}/i_idma_backend/gen_r_aw_coupler/i_idma_channel_coupler/aw_to_send_q
% endif
add wave -noupdate -divider BUS
% for protocol in used_protocols:
    % if protocol == 'axi':
add wave -noupdate -group {${database[protocol]['full_name']} IF} -label AW /tb_idma_backend${name_uniqueifier}/i_aw_hl/in_wave
add wave -noupdate -group {${database[protocol]['full_name']} IF} -label AR /tb_idma_backend${name_uniqueifier}/i_ar_hl/in_wave
add wave -noupdate -group {${database[protocol]['full_name']} IF} -label W /tb_idma_backend${name_uniqueifier}/i_w_hl/in_wave
add wave -noupdate -group {${database[protocol]['full_name']} IF} -label R /tb_idma_backend${name_uniqueifier}/i_r_hl/in_wave
add wave -noupdate -group {${database[protocol]['full_name']} IF} -label B /tb_idma_backend${name_uniqueifier}/i_b_hl/in_wave
    % else:
add wave -noupdate -group {${database[protocol]['full_name']} ${database['axi']['full_name']} IF} -label AW /tb_idma_backend${name_uniqueifier}/i_${protocol}_aw_hl/in_wave
add wave -noupdate -group {${database[protocol]['full_name']} ${database['axi']['full_name']} IF} -label AR /tb_idma_backend${name_uniqueifier}/i_${protocol}_ar_hl/in_wave
add wave -noupdate -group {${database[protocol]['full_name']} ${database['axi']['full_name']} IF} -label W /tb_idma_backend${name_uniqueifier}/i_${protocol}_w_hl/in_wave
add wave -noupdate -group {${database[protocol]['full_name']} ${database['axi']['full_name']} IF} -label R /tb_idma_backend${name_uniqueifier}/i_${protocol}_r_hl/in_wave
add wave -noupdate -group {${database[protocol]['full_name']} ${database['axi']['full_name']} IF} -label B /tb_idma_backend${name_uniqueifier}/i_${protocol}_b_hl/in_wave
    % endif
% endfor
add wave -noupdate -group {iDMA IF} -label {iDMA REQ} /tb_idma_backend${name_uniqueifier}/i_req_hl/in_wave
add wave -noupdate -group {iDMA IF} -label {iDMA RSP} -expand -subitemconfig {/tb_idma_backend${name_uniqueifier}/i_rsp_hl/in_wave.pld -expand} /tb_idma_backend${name_uniqueifier}/i_rsp_hl/in_wave
add wave -noupdate -group {iDMA IF} -label {iDMA EH} /tb_idma_backend${name_uniqueifier}/i_eh_hl/in_wave
add wave -noupdate -group Busy -expand /tb_idma_backend${name_uniqueifier}/i_idma_backend/busy_o
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {0 ps} 0}
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

onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -position end i_dut/clk_i
add wave -position end i_dut/rst_ni
add wave -position end i_dut/master_req_o
add wave -position end i_dut/master_rsp_i
add wave -position end i_dut/slave_req_i
add wave -position end i_dut/slave_rsp_o
add wave -position end i_dut/dma_be_req_o
add wave -position end i_dut/dma_be_req_ready_i
add wave -position end i_dut/dma_be_req_valid_o
add wave -position end i_dut/dma_be_rsp_ready_o
add wave -position end i_dut/dma_be_rsp_valid_i
add wave -position end i_dut/dma_be_idle_i
add wave -position end i_dut/irq_o

add wave -position end i_dut/submitter_q
add wave -position end i_dut/feedback_fsm_q
quietly wave cursor active 1

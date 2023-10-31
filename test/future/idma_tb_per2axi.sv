// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Commit: 892fcad60b6374fe558cbde76f4a529d473ba5ca
// Compiled by morty-0.8.0 / 2022-10-25 10:05:33.986890469 +02:00
module idma_tb_fifo_v3 #(
    parameter bit          FALL_THROUGH = 1'b0,
    parameter int unsigned DATA_WIDTH   = 32,
    parameter int unsigned DEPTH        = 8,
    parameter type         dtype        = logic [DATA_WIDTH-1:0],
    parameter int unsigned ADDR_DEPTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,
    input logic testmode_i,
    output logic full_o,
    output logic empty_o,
    output logic [ADDR_DEPTH-1:0] usage_o,
    input dtype data_i,
    input logic push_i,
    output dtype data_o,
    input  logic pop_i
);
  localparam int unsigned FifoDepth = (DEPTH > 0) ? DEPTH : 1;
  logic gate_clock;
  logic [ADDR_DEPTH - 1:0] read_pointer_n, read_pointer_q, write_pointer_n, write_pointer_q;
  logic [ADDR_DEPTH:0] status_cnt_n, status_cnt_q;
  dtype [FifoDepth - 1:0] mem_n, mem_q;
  assign usage_o = status_cnt_q[ADDR_DEPTH-1:0];
  if (DEPTH == 0) begin : gen_pass_through
    assign empty_o = ~push_i;
    assign full_o  = ~pop_i;
  end else begin : gen_fifo
    assign full_o  = (status_cnt_q == FifoDepth[ADDR_DEPTH:0]);
    assign empty_o = (status_cnt_q == 0) & ~(FALL_THROUGH & push_i);
  end
  always_comb begin : read_write_comb
    read_pointer_n  = read_pointer_q;
    write_pointer_n = write_pointer_q;
    status_cnt_n    = status_cnt_q;
    data_o          = (DEPTH == 0) ? data_i : mem_q[read_pointer_q];
    mem_n           = mem_q;
    gate_clock      = 1'b1;
    if (push_i && ~full_o) begin
      mem_n[write_pointer_q] = data_i;
      gate_clock = 1'b0;
      if (write_pointer_q == FifoDepth[ADDR_DEPTH-1:0] - 1) write_pointer_n = '0;
      else write_pointer_n = write_pointer_q + 1;
      status_cnt_n = status_cnt_q + 1;
    end
    if (pop_i && ~empty_o) begin
      if (read_pointer_n == FifoDepth[ADDR_DEPTH-1:0] - 1) read_pointer_n = '0;
      else read_pointer_n = read_pointer_q + 1;
      status_cnt_n = status_cnt_q - 1;
    end
    if (push_i && pop_i && ~full_o && ~empty_o) status_cnt_n = status_cnt_q;
    if (FALL_THROUGH && (status_cnt_q == 0) && push_i) begin
      data_o = data_i;
      if (pop_i) begin
        status_cnt_n = status_cnt_q;
        read_pointer_n = read_pointer_q;
        write_pointer_n = write_pointer_q;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      read_pointer_q  <= '0;
      write_pointer_q <= '0;
      status_cnt_q    <= '0;
    end else begin
      if (flush_i) begin
        read_pointer_q  <= '0;
        write_pointer_q <= '0;
        status_cnt_q    <= '0;
      end else begin
        read_pointer_q  <= read_pointer_n;
        write_pointer_q <= write_pointer_n;
        status_cnt_q    <= status_cnt_n;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mem_q <= '0;
    end else if (!gate_clock) begin
      mem_q <= mem_n;
    end
  end
  initial begin
    assert (DEPTH > 0)
    else $error("DEPTH must be greater than 0.");
  end
  full_write :
  assert property (@(posedge clk_i) disable iff (~rst_ni) (full_o |-> ~push_i))
  else $fatal(1, "Trying to push new data although the FIFO is full.");
  empty_read :
  assert property (@(posedge clk_i) disable iff (~rst_ni) (empty_o |-> ~pop_i))
  else $fatal(1, "Trying to pop data although the FIFO is empty.");
endmodule
module idma_tb_fifo_v2 #(
    parameter bit          FALL_THROUGH = 1'b0,
    parameter int unsigned DATA_WIDTH   = 32,
    parameter int unsigned DEPTH        = 8,
    parameter int unsigned ALM_EMPTY_TH = 1,
    parameter int unsigned ALM_FULL_TH  = 1,
    parameter type         dtype        = logic [DATA_WIDTH-1:0],
    parameter int unsigned ADDR_DEPTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,
    input logic testmode_i,
    output logic full_o,
    output logic empty_o,
    output logic alm_full_o,
    output logic alm_empty_o,
    input dtype data_i,
    input logic push_i,
    output dtype data_o,
    input  logic pop_i
);
  logic [ADDR_DEPTH-1:0] usage;
  if (DEPTH == 0) begin : proc_depth_zero
    assign alm_full_o  = 1'b0;
    assign alm_empty_o = 1'b0;
  end else begin : proc_depth_larger_zero
    assign alm_full_o  = (usage >= ALM_FULL_TH[ADDR_DEPTH-1:0]);
    assign alm_empty_o = (usage <= ALM_EMPTY_TH[ADDR_DEPTH-1:0]);
  end
  idma_tb_fifo_v3 #(
      .FALL_THROUGH(FALL_THROUGH),
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .dtype       (dtype)
  ) i_fifo_v3 (
      .clk_i,
      .rst_ni,
      .flush_i,
      .testmode_i,
      .full_o,
      .empty_o,
      .usage_o(usage),
      .data_i,
      .push_i,
      .data_o,
      .pop_i
  );
  initial begin
    assert (ALM_FULL_TH <= DEPTH)
    else $error("ALM_FULL_TH can't be larger than the DEPTH.");
    assert (ALM_EMPTY_TH <= DEPTH)
    else $error("ALM_EMPTY_TH can't be larger than the DEPTH.");
  end
endmodule
module idma_tb_fifo #(
    parameter bit          FALL_THROUGH = 1'b0,
    parameter int unsigned DATA_WIDTH   = 32,
    parameter int unsigned DEPTH        = 8,
    parameter int unsigned THRESHOLD    = 1,
    parameter type         dtype        = logic [DATA_WIDTH-1:0]
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,
    input logic testmode_i,
    output logic full_o,
    output logic empty_o,
    output logic threshold_o,
    input dtype data_i,
    input logic push_i,
    output dtype data_o,
    input  logic pop_i
);
  idma_tb_fifo_v2 #(
      .FALL_THROUGH(FALL_THROUGH),
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .ALM_FULL_TH (THRESHOLD),
      .dtype       (dtype)
  ) impl (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .flush_i    (flush_i),
      .testmode_i (testmode_i),
      .full_o     (full_o),
      .empty_o    (empty_o),
      .alm_full_o (threshold_o),
      .alm_empty_o(),
      .data_i     (data_i),
      .push_i     (push_i),
      .data_o     (data_o),
      .pop_i      (pop_i)
  );
endmodule
module idma_tb_axi_single_slice #(
    parameter int BUFFER_DEPTH = -1,
    parameter int DATA_WIDTH   = -1
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  testmode_i,
    input  logic                  valid_i,
    output logic                  ready_o,
    input  logic [DATA_WIDTH-1:0] data_i,
    input  logic                  ready_i,
    output logic                  valid_o,
    output logic [DATA_WIDTH-1:0] data_o
);
  logic full, empty;
  assign ready_o = ~full;
  assign valid_o = ~empty;
  idma_tb_fifo #(
      .FALL_THROUGH(1'b1),
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (BUFFER_DEPTH)
  ) i_fifo (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .flush_i    (1'b0),
      .threshold_o(),
      .testmode_i (testmode_i),
      .full_o     (full),
      .empty_o    (empty),
      .data_i     (data_i),
      .push_i     (valid_i & ready_o),
      .data_o     (data_o),
      .pop_i      (ready_i & valid_o)
  );
endmodule
module idma_tb_axi_ar_buffer #(
    parameter int ID_WIDTH     = -1,
    parameter int ADDR_WIDTH   = -1,
    parameter int USER_WIDTH   = -1,
    parameter int BUFFER_DEPTH = -1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic test_en_i,
    input  logic                  slave_valid_i,
    input  logic [ADDR_WIDTH-1:0] slave_addr_i,
    input  logic [           2:0] slave_prot_i,
    input  logic [           3:0] slave_region_i,
    input  logic [           7:0] slave_len_i,
    input  logic [           2:0] slave_size_i,
    input  logic [           1:0] slave_burst_i,
    input  logic                  slave_lock_i,
    input  logic [           3:0] slave_cache_i,
    input  logic [           3:0] slave_qos_i,
    input  logic [  ID_WIDTH-1:0] slave_id_i,
    input  logic [USER_WIDTH-1:0] slave_user_i,
    output logic                  slave_ready_o,
    output logic                  master_valid_o,
    output logic [ADDR_WIDTH-1:0] master_addr_o,
    output logic [           2:0] master_prot_o,
    output logic [           3:0] master_region_o,
    output logic [           7:0] master_len_o,
    output logic [           2:0] master_size_o,
    output logic [           1:0] master_burst_o,
    output logic                  master_lock_o,
    output logic [           3:0] master_cache_o,
    output logic [           3:0] master_qos_o,
    output logic [  ID_WIDTH-1:0] master_id_o,
    output logic [USER_WIDTH-1:0] master_user_o,
    input  logic                  master_ready_i
);
  logic [29+ADDR_WIDTH+USER_WIDTH+ID_WIDTH-1:0] s_data_in;
  logic [29+ADDR_WIDTH+USER_WIDTH+ID_WIDTH-1:0] s_data_out;
  assign s_data_in = {
    slave_cache_i,
    slave_prot_i,
    slave_lock_i,
    slave_burst_i,
    slave_size_i,
    slave_len_i,
    slave_qos_i,
    slave_region_i,
    slave_addr_i,
    slave_user_i,
    slave_id_i
  };
  assign             {master_cache_o, master_prot_o, master_lock_o, master_burst_o, master_size_o, master_len_o, master_qos_o, master_region_o, master_addr_o, master_user_o, master_id_o} =  s_data_out;
  idma_tb_axi_single_slice #(
      .BUFFER_DEPTH(BUFFER_DEPTH),
      .DATA_WIDTH  (29 + ADDR_WIDTH + USER_WIDTH + ID_WIDTH)
  ) i_axi_single_slice (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .testmode_i(test_en_i),
      .valid_i   (slave_valid_i),
      .ready_o   (slave_ready_o),
      .data_i    (s_data_in),
      .ready_i   (master_ready_i),
      .valid_o   (master_valid_o),
      .data_o    (s_data_out)
  );
endmodule
module idma_tb_axi_aw_buffer #(
    parameter int ID_WIDTH     = -1,
    parameter int ADDR_WIDTH   = -1,
    parameter int USER_WIDTH   = -1,
    parameter int BUFFER_DEPTH = -1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic test_en_i,
    input  logic                  slave_valid_i,
    input  logic [ADDR_WIDTH-1:0] slave_addr_i,
    input  logic [           2:0] slave_prot_i,
    input  logic [           3:0] slave_region_i,
    input  logic [           7:0] slave_len_i,
    input  logic [           2:0] slave_size_i,
    input  logic [           1:0] slave_burst_i,
    input  logic                  slave_lock_i,
    input  logic [           3:0] slave_cache_i,
    input  logic [           3:0] slave_qos_i,
    input  logic [  ID_WIDTH-1:0] slave_id_i,
    input  logic [USER_WIDTH-1:0] slave_user_i,
    output logic                  slave_ready_o,
    output logic                  master_valid_o,
    output logic [ADDR_WIDTH-1:0] master_addr_o,
    output logic [           2:0] master_prot_o,
    output logic [           3:0] master_region_o,
    output logic [           7:0] master_len_o,
    output logic [           2:0] master_size_o,
    output logic [           1:0] master_burst_o,
    output logic                  master_lock_o,
    output logic [           3:0] master_cache_o,
    output logic [           3:0] master_qos_o,
    output logic [  ID_WIDTH-1:0] master_id_o,
    output logic [USER_WIDTH-1:0] master_user_o,
    input  logic                  master_ready_i
);
  logic [29+ADDR_WIDTH+USER_WIDTH+ID_WIDTH-1:0] s_data_in;
  logic [29+ADDR_WIDTH+USER_WIDTH+ID_WIDTH-1:0] s_data_out;
  assign s_data_in = {
    slave_cache_i,
    slave_prot_i,
    slave_lock_i,
    slave_burst_i,
    slave_size_i,
    slave_len_i,
    slave_qos_i,
    slave_region_i,
    slave_addr_i,
    slave_user_i,
    slave_id_i
  };
  assign             {master_cache_o, master_prot_o, master_lock_o, master_burst_o, master_size_o, master_len_o, master_qos_o, master_region_o, master_addr_o, master_user_o, master_id_o} = s_data_out;
  idma_tb_axi_single_slice #(
      .BUFFER_DEPTH(BUFFER_DEPTH),
      .DATA_WIDTH  (29 + ADDR_WIDTH + USER_WIDTH + ID_WIDTH)
  ) i_axi_single_slice (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .testmode_i(test_en_i),
      .valid_i   (slave_valid_i),
      .ready_o   (slave_ready_o),
      .data_i    (s_data_in),
      .ready_i   (master_ready_i),
      .valid_o   (master_valid_o),
      .data_o    (s_data_out)
  );
endmodule
module idma_tb_axi_b_buffer #(
    parameter int ID_WIDTH     = -1,
    parameter int USER_WIDTH   = -1,
    parameter int BUFFER_DEPTH = -1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic test_en_i,
    input  logic                  slave_valid_i,
    input  logic [           1:0] slave_resp_i,
    input  logic [  ID_WIDTH-1:0] slave_id_i,
    input  logic [USER_WIDTH-1:0] slave_user_i,
    output logic                  slave_ready_o,
    output logic                  master_valid_o,
    output logic [           1:0] master_resp_o,
    output logic [  ID_WIDTH-1:0] master_id_o,
    output logic [USER_WIDTH-1:0] master_user_o,
    input  logic                  master_ready_i
);
  logic [2+USER_WIDTH+ID_WIDTH-1:0] s_data_in;
  logic [2+USER_WIDTH+ID_WIDTH-1:0] s_data_out;
  assign s_data_in                                   = {slave_id_i, slave_user_i, slave_resp_i};
  assign {master_id_o, master_user_o, master_resp_o} = s_data_out;
  idma_tb_axi_single_slice #(
      .BUFFER_DEPTH(BUFFER_DEPTH),
      .DATA_WIDTH  (2 + USER_WIDTH + ID_WIDTH)
  ) i_axi_single_slice (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .testmode_i(test_en_i),
      .valid_i   (slave_valid_i),
      .ready_o   (slave_ready_o),
      .data_i    (s_data_in),
      .ready_i   (master_ready_i),
      .valid_o   (master_valid_o),
      .data_o    (s_data_out)
  );
endmodule
module idma_tb_axi_r_buffer #(
    parameter ID_WIDTH     = 4,
    parameter DATA_WIDTH   = 64,
    parameter USER_WIDTH   = 6,
    parameter BUFFER_DEPTH = 8,
    parameter STRB_WIDTH   = DATA_WIDTH / 8
) (
    input logic clk_i,
    input logic rst_ni,
    input logic test_en_i,
    input  logic                  slave_valid_i,
    input  logic [DATA_WIDTH-1:0] slave_data_i,
    input  logic [           1:0] slave_resp_i,
    input  logic [USER_WIDTH-1:0] slave_user_i,
    input  logic [  ID_WIDTH-1:0] slave_id_i,
    input  logic                  slave_last_i,
    output logic                  slave_ready_o,
    output logic                  master_valid_o,
    output logic [DATA_WIDTH-1:0] master_data_o,
    output logic [           1:0] master_resp_o,
    output logic [USER_WIDTH-1:0] master_user_o,
    output logic [  ID_WIDTH-1:0] master_id_o,
    output logic                  master_last_o,
    input  logic                  master_ready_i
);
  logic [2+DATA_WIDTH+USER_WIDTH+ID_WIDTH:0] s_data_in;
  logic [2+DATA_WIDTH+USER_WIDTH+ID_WIDTH:0] s_data_out;
  assign s_data_in = {slave_id_i, slave_user_i, slave_data_i, slave_resp_i, slave_last_i};
  assign {master_id_o, master_user_o, master_data_o, master_resp_o, master_last_o} = s_data_out;
  idma_tb_axi_single_slice #(
      .BUFFER_DEPTH(BUFFER_DEPTH),
      .DATA_WIDTH  (3 + DATA_WIDTH + USER_WIDTH + ID_WIDTH)
  ) i_axi_single_slice (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .testmode_i(test_en_i),
      .valid_i   (slave_valid_i),
      .ready_o   (slave_ready_o),
      .data_i    (s_data_in),
      .ready_i   (master_ready_i),
      .valid_o   (master_valid_o),
      .data_o    (s_data_out)
  );
endmodule
module idma_tb_axi_w_buffer #(
    parameter int DATA_WIDTH   = -1,
    parameter int USER_WIDTH   = -1,
    parameter int BUFFER_DEPTH = -1,
    parameter int STRB_WIDTH   = DATA_WIDTH / 8
) (
    input logic clk_i,
    input logic rst_ni,
    input logic test_en_i,
    input  logic                  slave_valid_i,
    input  logic [DATA_WIDTH-1:0] slave_data_i,
    input  logic [STRB_WIDTH-1:0] slave_strb_i,
    input  logic [USER_WIDTH-1:0] slave_user_i,
    input  logic                  slave_last_i,
    output logic                  slave_ready_o,
    output logic                  master_valid_o,
    output logic [DATA_WIDTH-1:0] master_data_o,
    output logic [STRB_WIDTH-1:0] master_strb_o,
    output logic [USER_WIDTH-1:0] master_user_o,
    output logic                  master_last_o,
    input  logic                  master_ready_i
);
  logic [DATA_WIDTH+STRB_WIDTH+USER_WIDTH:0] s_data_in;
  logic [DATA_WIDTH+STRB_WIDTH+USER_WIDTH:0] s_data_out;
  assign s_data_in = {slave_user_i, slave_strb_i, slave_data_i, slave_last_i};
  assign {master_user_o, master_strb_o, master_data_o, master_last_o} = s_data_out;
  idma_tb_axi_single_slice #(
      .BUFFER_DEPTH(BUFFER_DEPTH),
      .DATA_WIDTH  (1 + DATA_WIDTH + STRB_WIDTH + USER_WIDTH)
  ) i_axi_single_slice (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .testmode_i(test_en_i),
      .valid_i   (slave_valid_i),
      .ready_o   (slave_ready_o),
      .data_i    (s_data_in),
      .ready_i   (master_ready_i),
      .valid_o   (master_valid_o),
      .data_o    (s_data_out)
  );
endmodule
module idma_tb_per2axi_busy_unit (
    input logic clk_i,
    input logic rst_ni,
    input logic aw_sync_i,
    input logic b_sync_i,
    input logic ar_sync_i,
    input logic r_sync_i,
    output logic busy_o
);
  logic [3:0] s_aw_trans_count;
  logic [3:0] s_ar_trans_count;
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (rst_ni == 1'b0) s_aw_trans_count <= '0;
    else if (aw_sync_i == 1'b1 && b_sync_i == 1'b0) s_aw_trans_count <= s_aw_trans_count + 1;
    else if (aw_sync_i == 1'b0 && b_sync_i == 1'b1) s_aw_trans_count <= s_aw_trans_count - 1;
    else s_aw_trans_count <= s_aw_trans_count;
  end
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (rst_ni == 1'b0) s_ar_trans_count <= '0;
    else if (ar_sync_i == 1'b1 && r_sync_i == 1'b0) s_ar_trans_count <= s_ar_trans_count + 1;
    else if (ar_sync_i == 1'b0 && r_sync_i == 1'b1) s_ar_trans_count <= s_ar_trans_count - 1;
    else s_ar_trans_count <= s_ar_trans_count;
  end
  always_comb begin
    if (s_ar_trans_count == 0 && s_aw_trans_count == 0) busy_o = 1'b0;
    else busy_o = 1'b1;
  end
endmodule
module idma_tb_per2axi_req_channel #(
    parameter PER_ADDR_WIDTH = 32,
    parameter PER_ID_WIDTH   = 5,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 64,
    parameter AXI_USER_WIDTH = 6,
    parameter AXI_ID_WIDTH   = 3,
    parameter AXI_STRB_WIDTH = AXI_DATA_WIDTH / 8
) (
    input  logic                      per_slave_req_i,
    input  logic [PER_ADDR_WIDTH-1:0] per_slave_add_i,
    input  logic                      per_slave_we_i,
    input  logic [AXI_DATA_WIDTH-1:0] per_slave_wdata_i,
    input  logic [AXI_STRB_WIDTH-1:0] per_slave_be_i,
    input  logic [  PER_ID_WIDTH-1:0] per_slave_id_i,
    output logic                      per_slave_gnt_o,
    output logic                      axi_master_aw_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0] axi_master_aw_addr_o,
    output logic [               2:0] axi_master_aw_prot_o,
    output logic [               3:0] axi_master_aw_region_o,
    output logic [               7:0] axi_master_aw_len_o,
    output logic [               2:0] axi_master_aw_size_o,
    output logic [               1:0] axi_master_aw_burst_o,
    output logic                      axi_master_aw_lock_o,
    output logic [               3:0] axi_master_aw_cache_o,
    output logic [               3:0] axi_master_aw_qos_o,
    output logic [  AXI_ID_WIDTH-1:0] axi_master_aw_id_o,
    output logic [AXI_USER_WIDTH-1:0] axi_master_aw_user_o,
    input  logic                      axi_master_aw_ready_i,
    output logic                      axi_master_ar_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0] axi_master_ar_addr_o,
    output logic [               2:0] axi_master_ar_prot_o,
    output logic [               3:0] axi_master_ar_region_o,
    output logic [               7:0] axi_master_ar_len_o,
    output logic [               2:0] axi_master_ar_size_o,
    output logic [               1:0] axi_master_ar_burst_o,
    output logic                      axi_master_ar_lock_o,
    output logic [               3:0] axi_master_ar_cache_o,
    output logic [               3:0] axi_master_ar_qos_o,
    output logic [  AXI_ID_WIDTH-1:0] axi_master_ar_id_o,
    output logic [AXI_USER_WIDTH-1:0] axi_master_ar_user_o,
    input  logic                      axi_master_ar_ready_i,
    output logic                      axi_master_w_valid_o,
    output logic [AXI_DATA_WIDTH-1:0] axi_master_w_data_o,
    output logic [AXI_STRB_WIDTH-1:0] axi_master_w_strb_o,
    output logic [AXI_USER_WIDTH-1:0] axi_master_w_user_o,
    output logic                      axi_master_w_last_o,
    input  logic                      axi_master_w_ready_i,
    output logic                      trans_req_o,
    output logic [  AXI_ID_WIDTH-1:0] trans_id_o,
    output logic [AXI_ADDR_WIDTH-1:0] trans_add_o
);
  integer i;
  always_comb begin
    axi_master_ar_valid_o = 1'b0;
    axi_master_aw_valid_o = 1'b0;
    axi_master_w_valid_o  = 1'b0;
    axi_master_w_last_o   = 1'b0;
    if (per_slave_req_i == 1'b1 &&                                              
            per_slave_we_i == 1'b0 &&                          
            axi_master_aw_ready_i == 1'b1 &&                                       
            axi_master_w_ready_i == 1'b1 )                                      
          begin
      axi_master_aw_valid_o = 1'b1;
      axi_master_w_valid_o  = 1'b1;
      axi_master_w_last_o   = 1'b1;
    end
        else
          if (per_slave_req_i == 1'b1 &&                                            
              per_slave_we_i == 1'b1 &&                       
              axi_master_ar_ready_i == 1'b1)                                       
            begin
      axi_master_ar_valid_o = 1'b1;
    end
  end
  assign axi_master_aw_addr_o   = per_slave_add_i;
  assign axi_master_ar_addr_o   = per_slave_add_i;
  assign axi_master_aw_id_o     = per_slave_id_i;
  assign axi_master_ar_id_o     = per_slave_id_i;
  assign axi_master_w_data_o    = per_slave_wdata_i;
  assign axi_master_w_strb_o    = per_slave_be_i;
  assign per_slave_gnt_o        = axi_master_aw_ready_i && axi_master_ar_ready_i && axi_master_w_ready_i;
  assign axi_master_ar_size_o   = $clog2(AXI_STRB_WIDTH);
  assign axi_master_aw_size_o   = $clog2(AXI_STRB_WIDTH);
  assign axi_master_aw_burst_o  = 2'b01;
  assign axi_master_ar_burst_o  = 2'b01;
  assign trans_req_o            = axi_master_ar_valid_o;
  assign trans_id_o             = axi_master_ar_id_o;
  assign trans_add_o            = axi_master_ar_addr_o;
  assign axi_master_aw_prot_o   = '0;
  assign axi_master_aw_region_o = '0;
  assign axi_master_aw_len_o    = '0;
  assign axi_master_aw_lock_o   = '0;
  assign axi_master_aw_cache_o  = '0;
  assign axi_master_aw_qos_o    = '0;
  assign axi_master_aw_user_o   = '0;
  assign axi_master_ar_prot_o   = '0;
  assign axi_master_ar_region_o = '0;
  assign axi_master_ar_len_o    = '0;
  assign axi_master_ar_lock_o   = '0;
  assign axi_master_ar_cache_o  = '0;
  assign axi_master_ar_qos_o    = '0;
  assign axi_master_ar_user_o   = '0;
  assign axi_master_w_user_o    = '0;
endmodule
module idma_tb_per2axi_res_channel #(
    parameter PER_ADDR_WIDTH = 32,
    parameter PER_ID_WIDTH   = 5,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 64,
    parameter AXI_USER_WIDTH = 6,
    parameter AXI_ID_WIDTH   = 3
) (
    input  logic clk_i,
    input  logic rst_ni,
    output logic                      per_slave_r_valid_o,
    output logic                      per_slave_r_opc_o,
    output logic [  PER_ID_WIDTH-1:0] per_slave_r_id_o,
    output logic [AXI_DATA_WIDTH-1:0] per_slave_r_rdata_o,
    input  logic                      per_slave_r_ready_i,
    input  logic                      axi_master_r_valid_i,
    input  logic [AXI_DATA_WIDTH-1:0] axi_master_r_data_i,
    input  logic [               1:0] axi_master_r_resp_i,
    input  logic                      axi_master_r_last_i,
    input  logic [  AXI_ID_WIDTH-1:0] axi_master_r_id_i,
    input  logic [AXI_USER_WIDTH-1:0] axi_master_r_user_i,
    output logic                      axi_master_r_ready_o,
    input  logic                      axi_master_b_valid_i,
    input  logic [               1:0] axi_master_b_resp_i,
    input  logic [  AXI_ID_WIDTH-1:0] axi_master_b_id_i,
    input  logic [AXI_USER_WIDTH-1:0] axi_master_b_user_i,
    output logic                      axi_master_b_ready_o,
    input  logic                      trans_req_i,
    input  logic [  AXI_ID_WIDTH-1:0] trans_id_i,
    input  logic [AXI_ADDR_WIDTH-1:0] trans_add_i
);
  always_comb begin
    per_slave_r_valid_o  = '0;
    per_slave_r_opc_o    = '0;
    per_slave_r_id_o     = '0;
    per_slave_r_rdata_o  = '0;
    axi_master_r_ready_o = per_slave_r_ready_i;
    axi_master_b_ready_o = per_slave_r_ready_i;
    if (axi_master_r_valid_i && per_slave_r_ready_i) begin
      per_slave_r_valid_o = 1'b1;
      per_slave_r_id_o = axi_master_r_id_i;
      per_slave_r_rdata_o = axi_master_r_data_i;
      axi_master_b_ready_o = 1'b0;
    end else if (axi_master_b_valid_i && per_slave_r_ready_i) begin
      per_slave_r_valid_o                 = 1'b1;
      per_slave_r_id_o                    = axi_master_b_id_i;
      axi_master_r_ready_o                = 1'b0;
    end
  end
endmodule
module idma_tb_per2axi #(
    parameter NB_CORES       = 4,
    parameter PER_ADDR_WIDTH = 32,
    parameter PER_ID_WIDTH   = 5,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 64,
    parameter AXI_USER_WIDTH = 6,
    parameter AXI_ID_WIDTH   = 3,
    parameter AXI_STRB_WIDTH = AXI_DATA_WIDTH / 8
) (
    input logic clk_i,
    input logic rst_ni,
    input logic test_en_i,
    input  logic                      per_slave_req_i,
    input  logic [PER_ADDR_WIDTH-1:0] per_slave_add_i,
    input  logic                      per_slave_we_i,
    input  logic [AXI_DATA_WIDTH-1:0] per_slave_wdata_i,
    input  logic [AXI_STRB_WIDTH-1:0] per_slave_be_i,
    input  logic [  PER_ID_WIDTH-1:0] per_slave_id_i,
    output logic                      per_slave_gnt_o,
    output logic                      per_slave_r_valid_o,
    output logic                      per_slave_r_opc_o,
    output logic [  PER_ID_WIDTH-1:0] per_slave_r_id_o,
    output logic [AXI_DATA_WIDTH-1:0] per_slave_r_rdata_o,
    input  logic                      per_slave_r_ready_i,
    output logic                      axi_master_aw_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0] axi_master_aw_addr_o,
    output logic [               2:0] axi_master_aw_prot_o,
    output logic [               3:0] axi_master_aw_region_o,
    output logic [               7:0] axi_master_aw_len_o,
    output logic [               2:0] axi_master_aw_size_o,
    output logic [               1:0] axi_master_aw_burst_o,
    output logic                      axi_master_aw_lock_o,
    output logic [               3:0] axi_master_aw_cache_o,
    output logic [               3:0] axi_master_aw_qos_o,
    output logic [  AXI_ID_WIDTH-1:0] axi_master_aw_id_o,
    output logic [AXI_USER_WIDTH-1:0] axi_master_aw_user_o,
    input  logic                      axi_master_aw_ready_i,
    output logic                      axi_master_ar_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0] axi_master_ar_addr_o,
    output logic [               2:0] axi_master_ar_prot_o,
    output logic [               3:0] axi_master_ar_region_o,
    output logic [               7:0] axi_master_ar_len_o,
    output logic [               2:0] axi_master_ar_size_o,
    output logic [               1:0] axi_master_ar_burst_o,
    output logic                      axi_master_ar_lock_o,
    output logic [               3:0] axi_master_ar_cache_o,
    output logic [               3:0] axi_master_ar_qos_o,
    output logic [  AXI_ID_WIDTH-1:0] axi_master_ar_id_o,
    output logic [AXI_USER_WIDTH-1:0] axi_master_ar_user_o,
    input  logic                      axi_master_ar_ready_i,
    output logic                      axi_master_w_valid_o,
    output logic [AXI_DATA_WIDTH-1:0] axi_master_w_data_o,
    output logic [AXI_STRB_WIDTH-1:0] axi_master_w_strb_o,
    output logic [AXI_USER_WIDTH-1:0] axi_master_w_user_o,
    output logic                      axi_master_w_last_o,
    input  logic                      axi_master_w_ready_i,
    input  logic                      axi_master_r_valid_i,
    input  logic [AXI_DATA_WIDTH-1:0] axi_master_r_data_i,
    input  logic [               1:0] axi_master_r_resp_i,
    input  logic                      axi_master_r_last_i,
    input  logic [  AXI_ID_WIDTH-1:0] axi_master_r_id_i,
    input  logic [AXI_USER_WIDTH-1:0] axi_master_r_user_i,
    output logic                      axi_master_r_ready_o,
    input  logic                      axi_master_b_valid_i,
    input  logic [               1:0] axi_master_b_resp_i,
    input  logic [  AXI_ID_WIDTH-1:0] axi_master_b_id_i,
    input  logic [AXI_USER_WIDTH-1:0] axi_master_b_user_i,
    output logic                      axi_master_b_ready_o,
    output logic busy_o
);
  logic                      s_aw_valid;
  logic [AXI_ADDR_WIDTH-1:0] s_aw_addr;
  logic [               2:0] s_aw_prot;
  logic [               3:0] s_aw_region;
  logic [               7:0] s_aw_len;
  logic [               2:0] s_aw_size;
  logic [               1:0] s_aw_burst;
  logic                      s_aw_lock;
  logic [               3:0] s_aw_cache;
  logic [               3:0] s_aw_qos;
  logic [  AXI_ID_WIDTH-1:0] s_aw_id;
  logic [AXI_USER_WIDTH-1:0] s_aw_user;
  logic                      s_aw_ready;
  logic                      s_ar_valid;
  logic [AXI_ADDR_WIDTH-1:0] s_ar_addr;
  logic [               2:0] s_ar_prot;
  logic [               3:0] s_ar_region;
  logic [               7:0] s_ar_len;
  logic [               2:0] s_ar_size;
  logic [               1:0] s_ar_burst;
  logic                      s_ar_lock;
  logic [               3:0] s_ar_cache;
  logic [               3:0] s_ar_qos;
  logic [  AXI_ID_WIDTH-1:0] s_ar_id;
  logic [AXI_USER_WIDTH-1:0] s_ar_user;
  logic                      s_ar_ready;
  logic                      s_w_valid;
  logic [AXI_DATA_WIDTH-1:0] s_w_data;
  logic [AXI_STRB_WIDTH-1:0] s_w_strb;
  logic [AXI_USER_WIDTH-1:0] s_w_user;
  logic                      s_w_last;
  logic                      s_w_ready;
  logic                      s_r_valid;
  logic [AXI_DATA_WIDTH-1:0] s_r_data;
  logic [               1:0] s_r_resp;
  logic                      s_r_last;
  logic [  AXI_ID_WIDTH-1:0] s_r_id;
  logic [AXI_USER_WIDTH-1:0] s_r_user;
  logic                      s_r_ready;
  logic                      s_b_valid;
  logic [               1:0] s_b_resp;
  logic [  AXI_ID_WIDTH-1:0] s_b_id;
  logic [AXI_USER_WIDTH-1:0] s_b_user;
  logic                      s_b_ready;
  logic                      s_trans_req;
  logic [  AXI_ID_WIDTH-1:0] s_trans_id;
  logic [AXI_ADDR_WIDTH-1:0] s_trans_add;
  idma_tb_per2axi_req_channel #(
      .PER_ID_WIDTH  (PER_ID_WIDTH),
      .PER_ADDR_WIDTH(PER_ADDR_WIDTH),
      .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
      .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
      .AXI_USER_WIDTH(AXI_USER_WIDTH),
      .AXI_ID_WIDTH  (AXI_ID_WIDTH)
  ) req_channel_i (
      .per_slave_req_i  (per_slave_req_i),
      .per_slave_add_i  (per_slave_add_i),
      .per_slave_we_i   (per_slave_we_i),
      .per_slave_wdata_i(per_slave_wdata_i),
      .per_slave_be_i   (per_slave_be_i),
      .per_slave_id_i   (per_slave_id_i),
      .per_slave_gnt_o  (per_slave_gnt_o),
      .axi_master_aw_valid_o (s_aw_valid),
      .axi_master_aw_addr_o  (s_aw_addr),
      .axi_master_aw_prot_o  (s_aw_prot),
      .axi_master_aw_region_o(s_aw_region),
      .axi_master_aw_len_o   (s_aw_len),
      .axi_master_aw_size_o  (s_aw_size),
      .axi_master_aw_burst_o (s_aw_burst),
      .axi_master_aw_lock_o  (s_aw_lock),
      .axi_master_aw_cache_o (s_aw_cache),
      .axi_master_aw_qos_o   (s_aw_qos),
      .axi_master_aw_id_o    (s_aw_id),
      .axi_master_aw_user_o  (s_aw_user),
      .axi_master_aw_ready_i (s_aw_ready),
      .axi_master_ar_valid_o (s_ar_valid),
      .axi_master_ar_addr_o  (s_ar_addr),
      .axi_master_ar_prot_o  (s_ar_prot),
      .axi_master_ar_region_o(s_ar_region),
      .axi_master_ar_len_o   (s_ar_len),
      .axi_master_ar_size_o  (s_ar_size),
      .axi_master_ar_burst_o (s_ar_burst),
      .axi_master_ar_lock_o  (s_ar_lock),
      .axi_master_ar_cache_o (s_ar_cache),
      .axi_master_ar_qos_o   (s_ar_qos),
      .axi_master_ar_id_o    (s_ar_id),
      .axi_master_ar_user_o  (s_ar_user),
      .axi_master_ar_ready_i (s_ar_ready),
      .axi_master_w_valid_o(s_w_valid),
      .axi_master_w_data_o (s_w_data),
      .axi_master_w_strb_o (s_w_strb),
      .axi_master_w_user_o (s_w_user),
      .axi_master_w_last_o (s_w_last),
      .axi_master_w_ready_i(s_w_ready),
      .trans_req_o(s_trans_req),
      .trans_id_o (s_trans_id),
      .trans_add_o(s_trans_add)
  );
  idma_tb_per2axi_res_channel #(
      .PER_ID_WIDTH  (PER_ID_WIDTH),
      .PER_ADDR_WIDTH(PER_ADDR_WIDTH),
      .AXI_ID_WIDTH  (AXI_ID_WIDTH),
      .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
      .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
      .AXI_USER_WIDTH(AXI_USER_WIDTH)
  ) res_channel_i (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .per_slave_r_valid_o(per_slave_r_valid_o),
      .per_slave_r_opc_o  (per_slave_r_opc_o),
      .per_slave_r_id_o   (per_slave_r_id_o),
      .per_slave_r_rdata_o(per_slave_r_rdata_o),
      .per_slave_r_ready_i(per_slave_r_ready_i),
      .axi_master_r_valid_i(s_r_valid),
      .axi_master_r_data_i (s_r_data),
      .axi_master_r_resp_i (s_r_resp),
      .axi_master_r_last_i (s_r_last),
      .axi_master_r_id_i   (s_r_id),
      .axi_master_r_user_i (s_r_user),
      .axi_master_r_ready_o(s_r_ready),
      .axi_master_b_valid_i(s_b_valid),
      .axi_master_b_resp_i (s_b_resp),
      .axi_master_b_id_i   (s_b_id),
      .axi_master_b_user_i (s_b_user),
      .axi_master_b_ready_o(s_b_ready),
      .trans_req_i(s_trans_req),
      .trans_id_i (s_trans_id),
      .trans_add_i(s_trans_add)
  );
  idma_tb_per2axi_busy_unit busy_unit_i (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .aw_sync_i(s_aw_valid & s_aw_ready),
      .b_sync_i (s_b_valid & s_b_ready),
      .ar_sync_i(s_ar_valid & s_ar_ready),
      .r_sync_i (s_r_valid & s_r_ready & s_r_last),
      .busy_o(busy_o)
  );
  idma_tb_axi_aw_buffer #(
      .ID_WIDTH    (AXI_ID_WIDTH),
      .ADDR_WIDTH  (AXI_ADDR_WIDTH),
      .USER_WIDTH  (AXI_USER_WIDTH),
      .BUFFER_DEPTH(NB_CORES)
  ) aw_buffer_i (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .test_en_i(test_en_i),
      .slave_valid_i (s_aw_valid),
      .slave_addr_i  (s_aw_addr),
      .slave_prot_i  (s_aw_prot),
      .slave_region_i(s_aw_region),
      .slave_len_i   (s_aw_len),
      .slave_size_i  (s_aw_size),
      .slave_burst_i (s_aw_burst),
      .slave_lock_i  (s_aw_lock),
      .slave_cache_i (s_aw_cache),
      .slave_qos_i   (s_aw_qos),
      .slave_id_i    (s_aw_id),
      .slave_user_i  (s_aw_user),
      .slave_ready_o (s_aw_ready),
      .master_valid_o (axi_master_aw_valid_o),
      .master_addr_o  (axi_master_aw_addr_o),
      .master_prot_o  (axi_master_aw_prot_o),
      .master_region_o(axi_master_aw_region_o),
      .master_len_o   (axi_master_aw_len_o),
      .master_size_o  (axi_master_aw_size_o),
      .master_burst_o (axi_master_aw_burst_o),
      .master_lock_o  (axi_master_aw_lock_o),
      .master_cache_o (axi_master_aw_cache_o),
      .master_qos_o   (axi_master_aw_qos_o),
      .master_id_o    (axi_master_aw_id_o),
      .master_user_o  (axi_master_aw_user_o),
      .master_ready_i (axi_master_aw_ready_i)
  );
  idma_tb_axi_ar_buffer #(
      .ID_WIDTH    (AXI_ID_WIDTH),
      .ADDR_WIDTH  (AXI_ADDR_WIDTH),
      .USER_WIDTH  (AXI_USER_WIDTH),
      .BUFFER_DEPTH(NB_CORES)
  ) ar_buffer_i (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .test_en_i(test_en_i),
      .slave_valid_i (s_ar_valid),
      .slave_addr_i  (s_ar_addr),
      .slave_prot_i  (s_ar_prot),
      .slave_region_i(s_ar_region),
      .slave_len_i   (s_ar_len),
      .slave_size_i  (s_ar_size),
      .slave_burst_i (s_ar_burst),
      .slave_lock_i  (s_ar_lock),
      .slave_cache_i (s_ar_cache),
      .slave_qos_i   (s_ar_qos),
      .slave_id_i    (s_ar_id),
      .slave_user_i  (s_ar_user),
      .slave_ready_o (s_ar_ready),
      .master_valid_o (axi_master_ar_valid_o),
      .master_addr_o  (axi_master_ar_addr_o),
      .master_prot_o  (axi_master_ar_prot_o),
      .master_region_o(axi_master_ar_region_o),
      .master_len_o   (axi_master_ar_len_o),
      .master_size_o  (axi_master_ar_size_o),
      .master_burst_o (axi_master_ar_burst_o),
      .master_lock_o  (axi_master_ar_lock_o),
      .master_cache_o (axi_master_ar_cache_o),
      .master_qos_o   (axi_master_ar_qos_o),
      .master_id_o    (axi_master_ar_id_o),
      .master_user_o  (axi_master_ar_user_o),
      .master_ready_i (axi_master_ar_ready_i)
  );
  idma_tb_axi_w_buffer #(
      .DATA_WIDTH  (AXI_DATA_WIDTH),
      .USER_WIDTH  (AXI_USER_WIDTH),
      .BUFFER_DEPTH(NB_CORES)
  ) w_buffer_i (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .test_en_i(test_en_i),
      .slave_valid_i(s_w_valid),
      .slave_data_i (s_w_data),
      .slave_strb_i (s_w_strb),
      .slave_user_i (s_w_user),
      .slave_last_i (s_w_last),
      .slave_ready_o(s_w_ready),
      .master_valid_o(axi_master_w_valid_o),
      .master_data_o (axi_master_w_data_o),
      .master_strb_o (axi_master_w_strb_o),
      .master_user_o (axi_master_w_user_o),
      .master_last_o (axi_master_w_last_o),
      .master_ready_i(axi_master_w_ready_i)
  );
  idma_tb_axi_r_buffer #(
      .ID_WIDTH    (AXI_ID_WIDTH),
      .DATA_WIDTH  (AXI_DATA_WIDTH),
      .USER_WIDTH  (AXI_USER_WIDTH),
      .BUFFER_DEPTH(2)
  ) r_buffer_i (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .test_en_i(test_en_i),
      .slave_valid_i(axi_master_r_valid_i),
      .slave_data_i (axi_master_r_data_i),
      .slave_resp_i (axi_master_r_resp_i),
      .slave_user_i (axi_master_r_user_i),
      .slave_id_i   (axi_master_r_id_i),
      .slave_last_i (axi_master_r_last_i),
      .slave_ready_o(axi_master_r_ready_o),
      .master_valid_o(s_r_valid),
      .master_data_o (s_r_data),
      .master_resp_o (s_r_resp),
      .master_user_o (s_r_user),
      .master_id_o   (s_r_id),
      .master_last_o (s_r_last),
      .master_ready_i(s_r_ready)
  );
  idma_tb_axi_b_buffer #(
      .ID_WIDTH    (AXI_ID_WIDTH),
      .USER_WIDTH  (AXI_USER_WIDTH),
      .BUFFER_DEPTH(2)
  ) b_buffer_i (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .test_en_i(test_en_i),
      .slave_valid_i(axi_master_b_valid_i),
      .slave_resp_i (axi_master_b_resp_i),
      .slave_id_i   (axi_master_b_id_i),
      .slave_user_i (axi_master_b_user_i),
      .slave_ready_o(axi_master_b_ready_o),
      .master_valid_o(s_b_valid),
      .master_resp_o (s_b_resp),
      .master_id_o   (s_b_id),
      .master_user_o (s_b_user),
      .master_ready_i(s_b_ready)
  );
endmodule

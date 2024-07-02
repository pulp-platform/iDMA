// This file contains code from https://github.com/pulp-platform/axi.
// This had to be made separate because Verilator does not support
// all features used in the original file.

// See copyright notices in
// https://github.com/pulp-platform/axi/blob/master/src/axi_test.sv.

`ifndef AXI_DRIVER_COMMON_SV
`define AXI_DRIVER_COMMON_SV

/// The data transferred on a beat on the AW/AR channels.
class axi_ax_beat #(
parameter AW = 32,
parameter IW = 8 ,
parameter UW = 1
);
rand logic [IW-1:0] ax_id     = '0;
rand logic [AW-1:0] ax_addr   = '0;
logic [7:0]         ax_len    = '0;
logic [2:0]         ax_size   = '0;
logic [1:0]         ax_burst  = '0;
logic               ax_lock   = '0;
logic [3:0]         ax_cache  = '0;
logic [2:0]         ax_prot   = '0;
rand logic [3:0]    ax_qos    = '0;
logic [3:0]         ax_region = '0;
logic [5:0]         ax_atop   = '0; // Only defined on the AW channel.
rand logic [UW-1:0] ax_user   = '0;
endclass

/// The data transferred on a beat on the W channel.
class axi_w_beat #(
parameter DW = 32,
parameter UW = 1
);
rand logic [DW-1:0]   w_data = '0;
rand logic [DW/8-1:0] w_strb = '0;
logic                 w_last = '0;
rand logic [UW-1:0]   w_user = '0;
endclass

/// The data transferred on a beat on the B channel.
class axi_b_beat #(
parameter IW = 8,
parameter UW = 1
);
rand logic [IW-1:0] b_id   = '0;
axi_pkg::resp_t     b_resp = '0;
rand logic [UW-1:0] b_user = '0;
endclass

/// The data transferred on a beat on the R channel.
class axi_r_beat #(
parameter DW = 32,
parameter IW = 8 ,
parameter UW = 1
);
rand logic [IW-1:0] r_id   = '0;
rand logic [DW-1:0] r_data = '0;
axi_pkg::resp_t     r_resp = '0;
logic               r_last = '0;
rand logic [UW-1:0] r_user = '0;
endclass

`endif
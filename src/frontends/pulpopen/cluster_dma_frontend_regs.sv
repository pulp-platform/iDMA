// Copyright (c) 2020 ETH Zurich and University of Bologna
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Authors:
// - Thomas Benz <tbenz@ethz.ch>
// - Andreas Kurth <akurth@iis.ee.ethz.ch>

// register file for one pe in the pulp_cluster_frontend
// strictly 32 bit on TCDM side.

module cluster_dma_frontend_regs #(
    parameter type transf_descr_t     = logic,
    parameter int unsigned AddrWidth  = 32,
    parameter int unsigned NumStreams = 1,
    parameter int unsigned IdxWidth   = (NumStreams > 32'd1) ? unsigned'($clog2(NumStreams)) : 32'd1,
    parameter type         idx_t      = logic [IdxWidth-1:0]
)(
    input  logic                        clk_i,
    input  logic                        rst_ni,
    // tcdm forwards channel
    input  logic                        ctrl_req_i,
    input  logic                        ctrl_type_i,
    input  logic [3:0]                  ctrl_be_i,
    input  logic [31:0]                 ctrl_add_i,
    input  logic [31:0]                 ctrl_data_i,
    output logic                        ctrl_gnt_o,
    // return channel
    output logic                        ctrl_valid_o,
    output logic [31:0]                 ctrl_data_o,
    // transfer ids
    input  logic [NumStreams-1:0][27:0] next_id_i,
    input  logic [NumStreams-1:0][27:0] done_id_i,
    input  idx_t                        be_sel_i,
    // backend handshake
    input  logic                        be_ready_i,
    output logic                        be_valid_o,
    input  logic                        be_busy_i,
    output transf_descr_t               transf_descr_o
);

    // DMA transfer descriptor
    typedef struct packed {
        logic          [31:0] num_bytes;
        logic [AddrWidth-1:0] dst_addr;
        logic [AddrWidth-1:0] src_addr;
    } transf_descr_regular_t;

    // have up to 256 registers per PE
    logic [7:0] reg_addr;
    // 6 registers are r/w so we need to keep a state
    transf_descr_regular_t data_store_d, data_store_q;
    logic [2:0]            conf_store_d, conf_store_q;
    // data is delayed one cycle
    logic [31:0] rdata_d, rdata_q;
    logic        valid_d, valid_q;

    // assign address to register address
    assign reg_addr = ctrl_add_i[7:0];

    // determine if an access on the control interface is a read or a write
    logic ctrl_read, ctrl_write;
    assign ctrl_read = ctrl_req_i & ctrl_type_i;
    assign ctrl_write = ctrl_req_i & ~ctrl_type_i;

    // compute data to write from previous value and write enable mask
    logic [31:0] write_data;
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            write_data[8 * i +: 8] = rdata_d[8 * i +: 8];
            if (ctrl_req_i && !ctrl_type_i && ctrl_be_i[i]) begin
                write_data[8 * i +: 8] = ctrl_data_i[8 * i +: 8];
            end
        end
    end

    // address decode
    always_comb begin : proc_address_decode

        // defaults
        ctrl_gnt_o   = 1'b0;
        rdata_d      =   '0;
        be_valid_o   = 1'b0;
        data_store_d = data_store_q;
        conf_store_d = conf_store_q;

        // if we have access
        if (ctrl_req_i) begin

            // only grant if a request is here
            ctrl_gnt_o = 1'b1;

            // address decoding
            unique casez ({reg_addr, AddrWidth >= 64})
                // source address (lower 32 bit)
                {8'h00, 1'b?}: begin
                    rdata_d = data_store_q.src_addr[31:0];
                    if (ctrl_write) begin
                        data_store_d.src_addr[31:0] = write_data;
                    end
                end
                // source address (upper 32 bit)
                {8'h04, 1'b1}: begin
                    rdata_d = data_store_q.src_addr[63:32];
                    if (ctrl_write) begin
                        data_store_d.src_addr[63:32] = write_data;
                    end
                end
                // destination address (lower 32 bit)
                {8'h08, 1'b?}: begin
                    rdata_d = data_store_q.dst_addr[31:0];
                    if (ctrl_write) begin
                        data_store_d.dst_addr[31:0] = write_data;
                    end
                end
                // destination address (upper 32 bit)
                {8'h0C, 1'b1}: begin
                    rdata_d = data_store_q.dst_addr[63:32];
                    if (ctrl_write) begin
                        data_store_d.dst_addr[63:32] = write_data;
                    end
                end
                // num bytes
                {8'h10, 1'b?}: begin
                    rdata_d = data_store_q.num_bytes;
                    if (ctrl_write) begin
                        data_store_d.num_bytes = write_data;
                    end
                end
                // status / conf
                {8'h18, 1'b?}: begin
                    rdata_d = {15'h0000, be_busy_i, 13'h0000, conf_store_q};
                    if (ctrl_write) begin
                        conf_store_d = ctrl_data_i[2:0];
                    end
                end
                // next_id
                {8'h20, 1'b?}: begin
                    if (ctrl_read) begin
                        if (data_store_q.num_bytes == '0) begin
                            rdata_d = '0;
                        end else begin
                            ctrl_gnt_o = be_ready_i;
                            rdata_d    = {4'h0 + be_sel_i, next_id_i[be_sel_i]};
                            be_valid_o = 1'b1;
                        end
                    end
                end
                // default case
                default : begin
                    // complete ids
                    if (reg_addr >= 8'h28 && reg_addr < 8'h28 + NumStreams * 8) begin
                        if (ctrl_read) begin
                            rdata_d = {4'h0, done_id_i[(reg_addr - 8'h28) >> 3]};
                        end
                    // invalid access
                    end else begin
                        rdata_d = '0;
                    end
                end
            endcase
        end
    end
    assign valid_d = ctrl_req_i & ctrl_gnt_o;

    // data store
    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_data_store
        if(~rst_ni) begin
            data_store_q <= '0;
            conf_store_q <= 3'b101;
            rdata_q      <= '0;
            valid_q      <= '0;
        end else begin
            data_store_q <= data_store_d;
            conf_store_q <= conf_store_d;
            rdata_q      <= rdata_d;
            valid_q      <= valid_d;
        end
    end

    assign ctrl_valid_o = valid_q;
    assign ctrl_data_o  = rdata_q;

    assign transf_descr_o.num_bytes = data_store_q.num_bytes;
    assign transf_descr_o.dst_addr  = data_store_q.dst_addr;
    assign transf_descr_o.src_addr  = data_store_q.src_addr;
    assign transf_descr_o.decouple  = conf_store_q[0];
    assign transf_descr_o.deburst   = conf_store_q[1];
    assign transf_descr_o.serialize = conf_store_q[2];

// pragma translate_off
`ifndef VERILATOR
    initial begin : p_assertions
        assert (AddrWidth == 32 || AddrWidth == 64)
            else $fatal(1, "Only 32 or 64 bit wide addresses are supported!");
    end
`endif
// pragma translate_on

endmodule : cluster_dma_frontend_regs

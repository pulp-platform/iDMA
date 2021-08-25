module tdma_frontend #(
    parameter type dma_axi_req_t  = logic,
    parameter type dma_axi_resp_t = logic
) (
    input  logic            clk_i,                      //the clock signal
    input  logic            rst_ni,


    input logic             start_new_transaction_i,
    input logic[63:0]       source_address_i,
    input logic[31:0]       source_stride_i[4:1],       //the "innerst stride is one byte"
    input logic[63:0]       destination_address_i,
    input logic[31:0]       destination_stride_i[4:1],
    input logic[31:0]       shape_i[4:0],

    output logic            transaction_finished_o,

    output dma_axi_req_t   dma_axi_req_o,
    input  dma_axi_resp_t  dma_axi_resp_i

);

    logic[63:0] current_source_addr;
    logic[63:0] current_destination_addr;
    logic       src_addr_valid;
    logic       dst_addr_valid;
    logic       src_tx_finished;
    logic       dst_tx_finished;
    logic       update_addresses;
    logic[31:0] byte_length_d;
    logic[31:0] byte_length_q;
    logic[63:0] burst_src_addr;
    logic[63:0] burst_dst_addr;
    logic[14:0] burst_num_bytes;
    logic       burst_finished;
    logic       burst_valid;


    always_comb begin : proc_comb
        if (start_new_transaction_i==1) begin
            byte_length_d = shape_i[0];
        end else begin
            byte_length_d = byte_length_q;
        end

        if (src_tx_finished & dst_tx_finished) begin
            byte_length_d = 0;
        end

    end
    assign transaction_finished_o = src_tx_finished & dst_tx_finished;

    tdma_addr_calc src_addr_generator (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        .start_address_i        (source_address_i),
        .shape_i                (shape_i[4:1]),
        .stride_i               (source_stride_i),
        .start_new_transaction_i(start_new_transaction_i),
        .update_address_i       (update_addresses & byte_length_q != '0),

        .current_address_o      (current_source_addr),
        .valid_o                (src_addr_valid),
        .transaction_finished_o (src_tx_finished)
        );

    tdma_addr_calc dst_addr_generator (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        .start_address_i        (destination_address_i),
        .shape_i                (shape_i[4:1]),
        .stride_i               (destination_stride_i),
        .start_new_transaction_i(start_new_transaction_i),
        .update_address_i       (update_addresses & byte_length_q != '0),

        .current_address_o      (current_destination_addr),
        .valid_o                (dst_addr_valid),
        .transaction_finished_o (dst_tx_finished)
        );

    // display transfers
    always_comb begin : proc_mock_output
        if (src_addr_valid & dst_addr_valid & update_addresses & byte_length_q != 0) begin
            $display("Transfer - src: 0x%h - dst: 0x%h - num_bytes: %d", current_source_addr, current_destination_addr, byte_length_q);
        end
        // we are always ready :P
        update_addresses = 1'b1;
    end

    // implementation of dated backend... needs to be updated :/
    /*
    axi_pkg::burst_req_t burst_req;

    assign burst_req.id          =  'b0;
    assign burst_req.src         = current_source_addr;
    assign burst_req.dst         = current_destination_addr;
    assign burst_req.num_bytes   = byte_length_q;
    assign burst_req.cache_src   =  'b0;
    assign burst_req.cache_dst   =  'b0;
    assign burst_req.burst_src   = 2'b01;
    assign burst_req.burst_dst   = 2'b01;
    assign burst_req.decouple_rw = 1'b0;

    axi_dma_backend #(
        .DATA_WIDTH        (512),
        .ADDR_WIDTH        (64),
        .AXI_REQ_FIFO_DEPTH(1),
        .REQ_FIFO_DEPTH    (1),
        .BUFFER_DEPTH      (3),
        .axi_req_t         (dma_axi_req_t),
        .axi_res_t         (dma_axi_resp_t)
    ) i_axi_dma_backend (
        .clk_i           ( clk_i                            ),
        .rst_ni          ( rst_ni                           ),
        .axi_dma_req_o   ( dma_axi_req_o                    ),
        .axi_dma_res_i   ( dma_axi_resp_i                   ),
        .burst_req_i     ( burst_req                        ),
        .valid_i         ( src_addr_valid & dst_addr_valid & update_addresses  ),
        .ready_o         ( update_addresses                 ),
        .backend_idle_o  ( )
    );
    */


    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_update_reg
        if(~rst_ni) begin
            byte_length_q <= 0;
        end else begin
            byte_length_q <= byte_length_d;
        end
    end

endmodule // axi_dma_tdma_frontend
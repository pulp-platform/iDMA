//-------------------------------------------------------------------------------
//-- Title      : Tensor DMA
//-- Project    : Kerbin SOC
//-------------------------------------------------------------------------------
//-- File       : dma_config_interface.sv
//-- Author     : Gian Marti      <gimarti.student.ethz.ch>
//-- Author     : Thomas Kramer   <tkramer.student.ethz.ch>
//-- Author     : Thomas E. Benz  <tbenz.student.ethz.ch>
//-- Company    : Integrated Systems Laboratory, ETH Zurich
//-- Created    : 2018-04-03
//-- Last update: 2018-04-24
//-- Platform   : ModelSim (simulation), Synopsys (synthesis)
//-- Standard   : SystemVerilog IEEE 1800-2012
//-------------------------------------------------------------------------------
//-- Description: The toplevel of the tensor DMA
//-------------------------------------------------------------------------------
//-- Copyright (c) 2018 Integrated Systems Laboratory, ETH Zurich
//-------------------------------------------------------------------------------
//-- Revisions  :
//-- Date        Version  Author  Description
//-- 2018-04-03  1.0      tbenz   Created
//-- 2019-11-24  2.0      tbenz   Adapt to boggart
//-------------------------------------------------------------------------------

module tdma_top #(
    parameter int  FIFO_DEPTH     = -1,
    parameter type dma_axi_req_t  = axi_dma_pkg::req_t,
    parameter type dma_axi_resp_t = axi_dma_pkg::res_t
    ) (
    input   logic clk_i,                 //the clock signal
    input   logic rst_ni,                //asynchronous reset active low
    input   logic test_en_i,             //test enable

    output  logic irq_o,
    output  logic debug_dma_running_o,
    output  logic push_o,                //DEBUG PORT -> keep track of work status
    output  logic pop_o,                 //DEBUG PORT -> keep track of work status

    REG_BUS       dma_config_reg_bus,     //configuration bus

    output dma_axi_req_t   dma_axi_req_o,
    input  dma_axi_resp_t  dma_axi_resp_i
    );


    //parameter check
    `ifndef SYNTHESIS
    initial begin
        assert(FIFO_DEPTH > 0   )                       else $error("FIFO Depth has to be larger than 0");
        assert(FIFO_DEPTH < 128 )                       else $error("FIFO Depth has to be smaller than 128");
    end
    `endif


    //local parameters
    // hardcoded for 64 bit addresses
    localparam FIFO_WIDTH = 2*32*4 + 32*5 + 2*64;


    //fifo signals
    logic                  fifo_full;
    logic                  fifo_empty;
    logic                  fifo_threshold;
    logic                  fifo_push;
    logic                  fifo_pop;
    logic                  start_transaction_d;
    logic                  start_transaction_q;
    logic                  transaction_finished;
    logic                  busy_with_transaction_d;
    logic                  busy_with_transaction_q;
    logic [FIFO_WIDTH-1:0] fifo_data_i;
    logic [FIFO_WIDTH-1:0] fifo_data_o;
    logic [          63:0] source_address;
    logic [          63:0] destination_address;
    logic [          31:0] source_stride        [3:0];
    logic [          31:0] destination_stride   [3:0];
    logic [          31:0] shape                [4:0];
    logic [          31:0] finished_tx_id_d;
    logic [          31:0] finished_tx_id_q;


    // debug ports
    assign push_o  = fifo_push;
    assign pop_o   = fifo_pop;


    assign debug_dma_running_o = busy_with_transaction_q;


    //instances
    tdma_conf_intf #(
        .ADDR_WIDTH         (32                  ),
        .NUM_DIM            (4                   ),
        .COMMAND_WIDTH      (FIFO_WIDTH          )

        ) conf_intf_i (
        .clk_i              (clk_i                   ),
        .rst_ni             (rst_ni                  ),
        .fifo_empty_i       (fifo_empty              ),
        .fifo_full_i        (fifo_full               ),
        .dma_core_running_i (busy_with_transaction_q ),
        .finished_tx_id_i   (finished_tx_id_q        ),
        .enqueu_o           (fifo_push               ),
        .command_o          (fifo_data_i             ),
        .dma_config_reg_bus (dma_config_reg_bus      )

        );

    fifo #(
        .FALL_THROUGH       (0                   ),
        .DATA_WIDTH         (FIFO_WIDTH          ),
        .DEPTH              (FIFO_DEPTH          ),
        .THRESHOLD          (0                   )

        ) dma_fifo_i  (
        .clk_i              (clk_i               ),
        .rst_ni             (rst_ni              ),
        .flush_i            (1'b0                ),
        .testmode_i         (test_en_i           ),
        .full_o             (fifo_full           ),
        .empty_o            (fifo_empty          ),
        .threshold_o        (fifo_threshold      ),
        .data_i             (fifo_data_i         ),
        .push_i             (fifo_push           ),
        .data_o             (fifo_data_o         ),
        .pop_i              (fifo_pop            )

        );

    tdma_frontend  #(
        .dma_axi_req_t              (dma_axi_req_t ),
        .dma_axi_resp_t             (dma_axi_resp_t)

    ) tdma_frontend_i (
        .clk_i                      (clk_i),
        .rst_ni                     (rst_ni),

        .start_new_transaction_i    (start_transaction_q),
        .source_address_i           (source_address),
        .source_stride_i            (source_stride),
        .destination_address_i      (destination_address),
        .destination_stride_i       (destination_stride),
        .shape_i                    (shape),
        .transaction_finished_o     (transaction_finished),
        .dma_axi_req_o              (dma_axi_req_o),
        .dma_axi_resp_i             (dma_axi_resp_i)

    );


    assign source_address               = fifo_data_o[ 63:0];
    assign destination_address          = fifo_data_o[127:64];
    for (genvar dim = 0; dim < 4; dim++) begin
        assign source_stride[dim]       = fifo_data_o[159+32*dim:128+32*dim];
        assign destination_stride[dim]  = fifo_data_o[287+32*dim:256+32*dim];
        assign shape[dim]               = fifo_data_o[415+32*dim:384+32*dim];
    end
    assign shape[4]                     = fifo_data_o[543:512];
    // assign transaction_id               = fifo_data_o[547:544];
    assign irq_o                        = transaction_finished;


    always_comb begin : proc_comb
        //default assignments
        start_transaction_d     = 0;
        fifo_pop                = 0;
        busy_with_transaction_d = busy_with_transaction_q;
        finished_tx_id_d        = finished_tx_id_q;

        //start a new transaction if possible
        if((fifo_empty==0) & (busy_with_transaction_q==0)) begin
            start_transaction_d     = 1;
            busy_with_transaction_d = 1;
        end

        //pop the last element off the queue in the cycle afterwards
        if(start_transaction_q==1) begin
            fifo_pop = 1;
        end

        //if a transaction has been finished, allow new transactions and increase id counter
        if(transaction_finished==1) begin
            busy_with_transaction_d = 0;
            finished_tx_id_d        = finished_tx_id_q + 1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_mem
        if(~rst_ni) begin
            start_transaction_q     <= '0;
            busy_with_transaction_q <= '0;
            finished_tx_id_q        <= '0;
        end else begin
            start_transaction_q     <= start_transaction_d;
            busy_with_transaction_q <= busy_with_transaction_d;
            finished_tx_id_q        <= finished_tx_id_d;
        end
    end

endmodule // axi_dma_tdma_top

module tdma_fix(
    input   logic clk_i,                 //the clock signal
    input   logic rst_ni,                //asynchronous reset active low
    // input   logic test_en_i,             //test enable

    output  logic irq_o,
    output  logic debug_dma_running_o,
    output  logic push_o,                //DEBUG PORT -> keep track of work status
    output  logic pop_o,                 //DEBUG PORT -> keep track of work status

    output  logic        ready,
    output  logic        error,
    input   logic        valid,
    input   logic        write,
    input   logic [7:0 ] wstrb,
    input   logic [63:0] addr,
    output  logic [63:0] rdata,
    input   logic [63:0] wdata,

    output  axi_dma_pkg::req_t  dma_axi_req_o,
    input   axi_dma_pkg::res_t  dma_axi_resp_i
);


    // pack a reg bus
    REG_BUS #(.ADDR_WIDTH(64), .DATA_WIDTH(64)) the_bus(.clk_i(clk_i));

    assign ready = the_bus.ready;
    assign error = the_bus.error;
    assign rdata = the_bus.rdata;

    assign the_bus.addr  = addr;
    assign the_bus.valid = valid;
    assign the_bus.write = write;
    assign the_bus.wstrb = wstrb;
    assign the_bus.wdata = wdata;


    tdma_top #(.FIFO_DEPTH(4)) i_axi_dma_tdma_top (
        .clk_i              (clk_i              ),
        .rst_ni             (rst_ni             ),
        .test_en_i          (1'b0               ),
        .irq_o              (irq_o ),
        .debug_dma_running_o(debug_dma_running_o ),
        .push_o             (push_o ),
        .pop_o              (pop_o ),
        .dma_config_reg_bus (the_bus.in         ),
        .dma_axi_req_o      (dma_axi_req_o      ),
        .dma_axi_resp_i     (dma_axi_resp_i     )
    );

endmodule : tdma_fix
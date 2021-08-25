`timescale 1ns/1ns
module tdma_fe_tb();

    localparam HALF_PERIOD = 50;
    localparam RESET       = 75;

    localparam DATA_WIDTH  = axi_dma_pkg::DataWidth;

    logic clk;
    initial begin
        forever begin
            clk = 0;
            #HALF_PERIOD;
            clk = 1;
            #HALF_PERIOD;
        end
    end

    logic rst_n;
    initial begin
        rst_n = 0;
        #RESET;
        rst_n = 1;
    end

    logic        ready;
    logic        error;
    logic        valid;
    logic        write;
    logic [7:0 ] wstrb;
    logic [63:0] addr;
    logic [63:0] rdata;
    logic [63:0] wdata;

    logic running;

    //bus write
    task bus_write (
        input logic [63:0] addr_i,
        input logic [63:0] wdata_i
    );

        @(posedge clk)
            valid = 'b1;
            write = 'b1;
            wstrb = '1;
            addr  = addr_i;
            wdata = wdata_i;

        @(posedge clk)
            valid = 'b0;
            write = 'b0;
            wstrb = 'h0;
            addr  = 'h0;
            wdata = 'x;

    endtask

     //bus write
    task bus_read (
        input logic [63:0] addr_i
    );

        @(posedge clk)
            valid = 'b1;
            write = 'b0;
            addr  = addr_i;
        @(posedge clk)
            valid = 'b0;
            addr  = 'h0;

    endtask

    // pack a reg bus
    REG_BUS #(.ADDR_WIDTH(64), .DATA_WIDTH(64)) the_bus(.clk_i(clk));

    assign ready = the_bus.ready;
    assign error = the_bus.error;
    assign rdata = the_bus.rdata;

    assign the_bus.addr  = addr;
    assign the_bus.valid = valid;
    assign the_bus.write = write;
    assign the_bus.wstrb = wstrb;
    assign the_bus.wdata = wdata;

    //--------------------------------------
    // TDMA FE test
    //--------------------------------------
    axi_dma_pkg::req_t dma_axi_req_o;
    axi_dma_pkg::res_t axi_dma_res_i;

    tdma_top #(.FIFO_DEPTH(4)) i_tdma_top (
        .clk_i              (clk                ),
        .rst_ni             (rst_n              ),
        .test_en_i          (1'b0               ),
        .irq_o              ( ),
        .debug_dma_running_o(running            ),
        .push_o             ( ),
        .pop_o              ( ),
        .dma_config_reg_bus (the_bus.in         ),
        .dma_axi_req_o      ( ),
        .dma_axi_resp_i     ( )
    );

    initial begin

        #5000;
        @(posedge clk);

        $display("Go!");

        // source address
        bus_write ('h0010, 'h0000 );

        // destination address
        bus_write ('h0018, 'h0000 );

        // shape / "word size" 1 for byte
        bus_write ('h0400, 'd1   );

        // size dim 1
        bus_write ('h0408, 1);
        // size dim 2
        bus_write ('h0410, 0);
        // size dim 3
        bus_write ('h0418, 0);
        // size dim 4
        bus_write ('h0420, 0);

        // source stride 1
        bus_write ('h0800, 1);
        // source stride 2
        bus_write ('h0808, 0);
        // source stride 3
        bus_write ('h0810, 0);
        // source stride 4
        bus_write ('h0818, 0);

        // destination stride 1
        bus_write ('h0c00, 1);
        // destination stride 2
        bus_write ('h0c08, 0);
        // destination stride 3
        bus_write ('h0c10, 0);
        // destination stride 4
        bus_write ('h0c18, 0);

        // launch a transfer
        bus_read  ('h0000);

        // stop once transfer completes
        @(negedge running);
        #10000;
        $stop();
    end

endmodule : tdma_fe_tb

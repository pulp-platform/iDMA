//-------------------------------------------------------------------------------
//-- Title      : Config Interface for a Tensor DMA
//-- Project    : Kerbin SOC
//-------------------------------------------------------------------------------
//-- File       : dma_config_interface.sv
//-- Author     : Gian Marti      <gimarti.student.ethz.ch>
//-- Author     : Thomas Kramer   <tkramer.student.ethz.ch>
//-- Author     : Thomas E. Benz  <tbenz.student.ethz.ch>
//-- Company    : Integrated Systems Laboratory, ETH Zurich
//-- Created    : 2018-03-30
//-- Last update: 2018-04-24
//-- Platform   : ModelSim (simulation), Synopsys (synthesis)
//-- Standard   : SystemVerilog IEEE 1800-2012
//-------------------------------------------------------------------------------
//-- Description: Configuration Interface for a Tensor DMA
//-------------------------------------------------------------------------------
//-- Copyright (c) 2018 Integrated Systems Laboratory, ETH Zurich
//-------------------------------------------------------------------------------
//-- Revisions  :
//-- Date        Version  Author  Description
//-- 2018-03-30  1.0      tbenz   Created
//-- 2018-04-24  1.1      gmarti  Rework to support id
//-------------------------------------------------------------------------------

//the configuration interface of the DMA is connected via a register interface
//internally it will only consider 1 page (4kiB) to decode the addresses
//to place the interface into the global address space, t has to be configured
//in the axi crossbar it is connected to.

//an additional dimension is used to communicate the size of a transfer

//the command will have the following structure:
//[src_addr(64bit) src_addr(64bit) src_stride_1(32bit) ... src_stride_n(32bit) dest_stride_1(32bit) ... dest_stride_n(32bit) shape_1(32bit) ... shape_n+1(32bit)]


//Address map
//address [11:0]        description
//0x000                 config_reg
//0x008                 status_reg
//0x010                 source address
//0x018                 destination address
//0x040                 ID of finished DMA transfers
//0x400                 dimension 0
//0x408                 dimension 1
//...
//0x800                 source stride 0
//0x808                 source stride 1
//...
//0xc00                 destination stride 0
//0xc08                 destination stride 1

//any not described addresses will be invalid

module tdma_conf_intf #(

    parameter int ADDR_WIDTH    = -1,     //either 32 or 64 bit
    parameter int NUM_DIM       = -1,     //number of supported dimensions
    parameter int COMMAND_WIDTH = -1      //width of the resulting command
    )(

    input  logic                     clk_i,                 //the clock signal
    input  logic                     rst_ni,                //asynchronous reset active low

    input  logic                     fifo_empty_i,
    input  logic                     fifo_full_i,
    input  logic                     dma_core_running_i,
    input  logic [31:0]              finished_tx_id_i,

    output logic                     enqueu_o,
    output logic [COMMAND_WIDTH-1:0] command_o,

    REG_BUS                          dma_config_reg_bus     //the bus
    );


    //parameter check
    `ifndef SYNTHESIS
    initial begin
        assert((ADDR_WIDTH  == 32 ) | (ADDR_WIDTH == 64)) else $error("Address width has to bei either 32 or 64 bit");
        assert(NUM_DIM       > 0  )                       else $error("Number of Dimensions has to be larger than 0");
        assert(NUM_DIM       < 128)                       else $error("Number of Dimensions has to be smaller than 128");
        assert(COMMAND_WIDTH > 0  )                       else $error("Invalid Command size");
    end
    `endif

    //local parameters
    localparam SUB_AR_WIDTH = NUM_DIM * 32;     //length of a subarray


    //define ennumerated types
    enum logic [3:0] {INV, DIM, SSTR, DSTR, SADR, DADR, STAT, CONF, GETID} funct;
    //INV:   invalid                        SADR:  source address
    //DIM:   dimensions                     DADR:  destination address
    //SSTR:  source strides                 STAT:  status
    //DDST:  destionation strides           CONF:  config
    //GETID: get id of finished dma txs


    //internal signals
    logic[ADDR_WIDTH-13:0]    page_address;       //the upper part of the address
    logic[11:0]               page_offset;        //the lowest 12 bit describes the page offset
    logic[8:0 ]               page_word_offset;   //the word address of each page offset
    logic[2:0 ]               word_offset;        //the byte in the word

    logic[6:0 ]               dimension;          //the decoded dimension

    logic[7:0 ]               write_active;       //0 if inactive, else which byte has to be written
    logic                     read_active;        //0 if inactive, 1 when reading the word

    logic                     dma_ready;          //signals the register interface, that the cammand reg is writable
    logic[31:0]               transaction_id_d;   //an id is received for each transaction
    logic[31:0]               transaction_id_q;


    //registers
    logic[7:0 ]               dimensions_d          [NUM_DIM:0  ][3:0];  //32 bit
    logic[7:0 ]               dimensions_q          [NUM_DIM:0  ][3:0];  //32 bit
    logic[7:0 ]               source_strides_d      [NUM_DIM-1:0][3:0];  //32 bit
    logic[7:0 ]               source_strides_q      [NUM_DIM-1:0][3:0];  //32 bit
    logic[7:0 ]               destination_strides_d [NUM_DIM-1:0][3:0];  //32 bit
    logic[7:0 ]               destination_strides_q [NUM_DIM-1:0][3:0];  //32 bit
    logic[7:0 ]               source_address_d      [7:0        ];       //64 bit
    logic[7:0 ]               source_address_q      [7:0        ];       //64 bit
    logic[7:0 ]               destination_address_d [7:0        ];       //64 bit
    logic[7:0 ]               destination_address_q [7:0        ];       //64 bit
    logic[2:0 ]               status_reg_d;
    logic[2:0 ]               status_reg_q;


    //debug signals (only used in the wave...)
    logic[31:0] current_dim;

    //assign addresses
    assign page_address     = dma_config_reg_bus.addr[ADDR_WIDTH-1:12];
    assign page_offset      = dma_config_reg_bus.addr[11:0           ];
    assign page_word_offset = dma_config_reg_bus.addr[11:3           ];
    assign word_offset      = dma_config_reg_bus.addr[2:0            ];

    assign dimension        = page_word_offset       [6:0            ];

    //assignments
    assign write_active     = (dma_config_reg_bus.valid & dma_config_reg_bus.write) ? dma_config_reg_bus.wstrb : '0;
    assign read_active      = dma_config_reg_bus.valid & !dma_config_reg_bus.write;

    assign dma_ready        = ~fifo_full_i;



    //write src address in command
    for(genvar biw = 0; biw       < 8; biw++) begin
        assign command_o[ 0 + 8*(biw) +: 8] = source_address_q[biw];
    end

    //write dest address in command
    for(genvar biw = 0; biw       < 8; biw++) begin
        assign command_o[64 + 8*(biw) +: 8] = destination_address_q[biw];
    end

    //write strides in command
    for(genvar dim = 0; dim < NUM_DIM; dim++) begin
        for(genvar biw = 0; biw       < 4; biw++) begin
            assign command_o[128 + 0*SUB_AR_WIDTH + 32*dim + 8*(biw) +: 8] = source_strides_q     [dim][biw];
            assign command_o[128 + 1*SUB_AR_WIDTH + 32*dim + 8*(biw) +: 8] = destination_strides_q[dim][biw];
        end
    end

    //write shape in command
    for(genvar dim = 0; dim < NUM_DIM+1; dim++) begin
        for(genvar biw = 0; biw       < 4; biw++) begin
            assign command_o[128 + 2*SUB_AR_WIDTH + 32*dim + 8*(biw) +: 8] = dimensions_q         [dim][biw];
        end
    end

    //add id to command
    // assign command_o[COMMAND_WIDTH-1:COMMAND_WIDTH-8] = transaction_id_q;


    //determine the function to be performed
    always_comb begin : proc_address_map

        //default values
        funct       = INV;
        current_dim = 'z;

        //only alligned access is allowed:
        if(word_offset == '0) begin

            //$display("%d, %d, %d", page_word_offset[8:7], page_word_offset[6:0], $time);

            if         (page_word_offset[8:7] == 'h0 && page_word_offset[6:0] == 'h0 )     begin
                funct       = CONF;

            end else if(page_word_offset[8:7] == 'h0 && page_word_offset[6:0] == 'h1 )     begin
                funct       = STAT;

            end else if(page_word_offset[8:7] == 'h0 && page_word_offset[6:0] == 'h2 )     begin
                funct       = SADR;

            end else if(page_word_offset[8:7] == 'h0 && page_word_offset[6:0] == 'h3 )     begin
                funct       = DADR;

            end else if(page_word_offset[8:7] == 'h0 && page_word_offset[6:0] == 'h8)     begin
                funct       = GETID;

            end else if(page_word_offset[8:7] == 'h1 && page_word_offset[6:0] < NUM_DIM+1) begin
                funct       = DIM;
                current_dim = page_word_offset[6:0];

            end else if(page_word_offset[8:7] == 'h2 && page_word_offset[6:0] < NUM_DIM)   begin
                funct       = SSTR;
                current_dim = page_word_offset[6:0];

            end else if(page_word_offset[8:7] == 'h3 && page_word_offset[6:0] < NUM_DIM)   begin
                funct       = DSTR;
                current_dim = page_word_offset[6:0];

            end
        end
    end // proc_address_map


    //calculate the next state
    always_comb begin : proc_next_state

        //default values
        dma_config_reg_bus.ready = dma_ready;
        dma_config_reg_bus.error =  1'b0;
        dma_config_reg_bus.rdata = 64'h0;

        enqueu_o                 = 1'b0;


        //if nothing changes -> keep last values
        dimensions_d          = dimensions_q;
        source_strides_d      = source_strides_q;
        destination_strides_d = destination_strides_q;
        source_address_d      = source_address_q;
        destination_address_d = destination_address_q;
        transaction_id_d      = transaction_id_q;


        //assign next state of the status register
        status_reg_d[0]       = dma_core_running_i;
        status_reg_d[1]       = fifo_full_i;
        status_reg_d[2]       = fifo_empty_i;


        case(funct)

            CONF : begin
                //read only register
                if(write_active != '0) begin
                     dma_config_reg_bus.error = 1'b1;
                end

                if(read_active == 1'b1 && dma_ready==1) begin
                    dma_config_reg_bus.rdata[31:0] = transaction_id_q;
                    transaction_id_d = transaction_id_q + 1;
                    enqueu_o = 1'b1;
                end
            end

            STAT : begin
                //read only register
                if(write_active != '0) begin
                    dma_config_reg_bus.error = 1'b1;
                end

                if(read_active == 1'b1) begin
                    dma_config_reg_bus.rdata[2:0] = status_reg_q;
                end
            end

            SADR : begin
                if(write_active != '0) begin
                    for(integer biw = 0; biw < 8; biw++) begin
                        if(write_active[biw] == 1'b1) begin
                            source_address_d[biw] = dma_config_reg_bus.wdata[8*(biw) +: 8];
                        end
                    end
                end

                if(read_active == 1'b1) begin
                    for(integer biw = 0; biw < 8; biw++) begin
                        dma_config_reg_bus.rdata[8*(biw) +: 8] = source_address_q[biw];
                    end
                end
            end

            DADR : begin
                if(write_active != '0) begin
                    for(integer biw = 0; biw < 8; biw++) begin
                        if(write_active[biw] == 1'b1) begin
                            destination_address_d[biw] = dma_config_reg_bus.wdata[8*(biw) +: 8];
                        end
                    end
                end

                if(read_active == 1'b1) begin
                    for(integer biw = 0; biw < 8; biw++) begin
                        dma_config_reg_bus.rdata[8*(biw) +: 8] = destination_address_q[biw];
                    end
                end
            end

            GETID : begin
                //read only register
                if(write_active != '0) begin
                     dma_config_reg_bus.error = 1'b1;
                end

                if(read_active == 1'b1) begin
                    dma_config_reg_bus.rdata[31:0] = finished_tx_id_i;
                end
            end

            DIM  : begin
                if(write_active != '0) begin
                    for(integer biw = 0; biw < 4; biw++) begin
                        if(write_active[biw] == 1'b1) begin
                            dimensions_d[dimension][biw] = dma_config_reg_bus.wdata[8*(biw) +: 8];
                        end
                    end
                end

                if(read_active == 1'b1) begin
                    for(integer biw = 0; biw < 4; biw++) begin
                        dma_config_reg_bus.rdata[8*(biw) +: 8] = dimensions_q[dimension][biw];
                    end
                end
            end

            SSTR : begin
                if(write_active != '0) begin
                    for(integer biw = 0; biw < 4; biw++) begin
                        if(write_active[biw] == 1'b1) begin
                            source_strides_d[dimension][biw] = dma_config_reg_bus.wdata[8*(biw) +: 8];
                        end
                    end
                end

                if(read_active == 1'b1) begin
                    for(integer biw = 0; biw < 4; biw++) begin
                        dma_config_reg_bus.rdata[8*(biw) +: 8] = source_strides_q[dimension][biw];
                    end
                end
            end

            DSTR : begin
                if(write_active != '0) begin
                    for(integer biw = 0; biw < 4; biw++) begin
                        if(write_active[biw] == 1'b1) begin
                            destination_strides_d[dimension][biw] = dma_config_reg_bus.wdata[8*(biw) +: 8];
                        end
                    end
                end

                if(read_active == 1'b1) begin
                    for(integer biw = 0; biw < 4; biw++) begin
                        dma_config_reg_bus.rdata[8*(biw) +: 8] = destination_strides_q[dimension][biw];
                    end
                end
            end

            INV : begin
                dma_config_reg_bus.error = 1'b1;
            end
        endcase // funct
    end // proc_next_state


    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_update_registers
        if(~rst_ni) begin
            for(integer biw = 0; biw < 4; biw++) begin
                for(integer dim = 0; dim < NUM_DIM; dim++) begin
                    source_strides_q[dim][biw]      <= '0;
                    destination_strides_q[dim][biw] <= '0;
                end
            end

            for(integer biw = 0; biw < 4; biw++) begin
                for(integer dim = 0; dim < NUM_DIM+1; dim++) begin
                    dimensions_q[dim][biw]          <= '0;

                end
            end

            for(integer biw = 0; biw < 8; biw++) begin
                source_address_q[biw]               <= '0;
                destination_address_q[biw]          <= '0;
            end

            status_reg_q                            <= '0;
            transaction_id_q                        <= '0;

        end else begin
        dimensions_q          <= dimensions_d;
        source_strides_q      <= source_strides_d;
        destination_strides_q <= destination_strides_d;
        source_address_q      <= source_address_d;
        destination_address_q <= destination_address_d;
        status_reg_q          <= status_reg_d;
        transaction_id_q      <= transaction_id_d;

        end
    end // proc_update_registers

endmodule // tdma_conf_intf
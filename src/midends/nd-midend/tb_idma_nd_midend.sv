module tb_idma_nd_midend; import idma_nd_midend_pkg::*;

    logic clk_i   = 0;
    logic rst_ni  = 0;
    logic valid_i = 0;
    logic ready_o;
    logic valid_o;

    initial begin
        #10ns;
        rst_ni = 1;
    end

    initial begin
        forever begin
            #5ns;
            clk_i = !clk_i;
        end
    end

    initial begin
        repeat (5) begin
            @(posedge clk_i);
        end
        valid_i = 1;
        @(posedge clk_i);
        while (ready_o == '0) begin
            @(posedge clk_i);
        end
        valid_i = 0;
        repeat (5) begin
            @(posedge clk_i);
        end
        $stop();
    end


    nd_req_t    nd_req;
    burst_req_t burst_req;

    initial begin
        nd_req = '{
            burst_req: '{src: 'h1000000, dst: 'h2000000},
            d_req:     '{
                '{reps: 'd5,  src_strides: 'h100,    dst_strides: 'h200    }, // Dim 3
                '{reps: 'd2,  src_strides: 'h10,     dst_strides: 'h20     }  // Dim 2
            }
        };
    end

    idma_nd_midend /*#(
        .NumDims        ( NumDims         ),
        .addr_t         ( addr_t          ),
        .burst_req_t    ( burst_req_t     ),
        .nd_req_t       ( nd_req_t        ),
        .d_cfg_t        ( d_cfg_t         ),
        .nd_cfg_t       ( nd_cfg_t        ),
        .nd_cfg         ( nd_cfg          )
    ) */i_idma_nd_midend (
        .clk_i          ( clk_i      ),
        .rst_ni         ( rst_ni     ),
        .nd_req_i       ( nd_req     ),
        .nd_valid_i     ( valid_i    ),
        .nd_ready_o     ( ready_o    ),
        .burst_req_o    ( burst_req  ),
        .burst_valid_o  ( valid_o    ),
        .burst_ready_i  ( '1         )
    );

    initial begin
        forever begin
            @(posedge clk_i);
            if (valid_o) begin
                #0;
                $display("%p", burst_req);
            end
        end
    end

endmodule : tb_idma_nd_midend

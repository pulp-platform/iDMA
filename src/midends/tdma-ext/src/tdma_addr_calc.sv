module tdma_addr_calc (
    input  logic            clk_i,                      //the clock signal
    input  logic            rst_ni,

    //inputs from dma top
    input logic[63:0]       start_address_i,
    input logic[31:0]       shape_i[4:1],
    input logic[31:0]       stride_i[4:1],   //the "innerst stride is one byte"
    input logic             start_new_transaction_i,

    //input from lower level
    input logic             update_address_i,

    //outputs for lower level
    output logic[63:0]      current_address_o,
    output logic            valid_o,

    //output for dma top
    output logic            transaction_finished_o //if there are no more items
);

    logic       valid_q;
    logic       valid_d;
    logic       transaction_finished_q;
    logic       transaction_finished_d;
    logic[63:0] current_address_q;
    logic[63:0] current_address_d;
    logic[31:0] length_bytes_q;
    logic[31:0] length_bytes_d;
    logic[31:0] shape_q[4:1];
    logic[31:0] shape_d[4:1];
    logic[31:0] stride_q[4:1];
    logic[31:0] stride_d[4:1];
    logic[31:0] dim4_ctr_d;
    logic[31:0] dim4_ctr_q;
    logic[31:0] dim3_ctr_d;
    logic[31:0] dim3_ctr_q;
    logic[31:0] dim2_ctr_d;
    logic[31:0] dim2_ctr_q;
    logic[31:0] dim1_ctr_d;
    logic[31:0] dim1_ctr_q;


    assign current_address_o      = current_address_q;
    assign valid_o                = valid_q;
    assign transaction_finished_o = transaction_finished_q;


    always_comb begin : proc_calc_next_addr

        //default assignments
        current_address_d = current_address_q;
        shape_d = shape_q;
        stride_d = stride_q;
        valid_d = 0;
        dim1_ctr_d = dim1_ctr_q;
        dim2_ctr_d = dim2_ctr_q;
        dim3_ctr_d = dim3_ctr_q;
        dim4_ctr_d = dim4_ctr_q;
        transaction_finished_d = 0;


        if (start_new_transaction_i==1) begin
            transaction_finished_d = 0;
            current_address_d = start_address_i;
            shape_d = shape_i;
            stride_d = stride_i;
            dim1_ctr_d = 0;
            dim2_ctr_d = 0;
            dim3_ctr_d = 0;
            dim4_ctr_d = 0;
            valid_d = 1;

            // Terminate immediately if shape = (0, 0, 0, 0)
            if(shape_i[1] == 0 && shape_i[2] == 0 && shape_i[3] == 0 && shape_i[4] == 0) begin
                transaction_finished_d = 1;
            end

        end else if (update_address_i==1 && transaction_finished_q == 0) begin

            // the innerst shape shape_q[0] is always the number of consecutive bytes

            dim1_ctr_d = dim1_ctr_q + 1;

            if (dim1_ctr_d==shape_q[1] || shape_q[1] == 0) begin
                dim1_ctr_d = 0;
                dim2_ctr_d = dim2_ctr_q + 1;
                if (dim2_ctr_d==shape_q[2] || shape_q[2] == 0) begin
                    dim2_ctr_d = 0;
                    dim3_ctr_d = dim3_ctr_q + 1;
                    if (dim3_ctr_d==shape_q[3] || shape_q[3] == 0) begin
                        dim3_ctr_d = 0;
                        dim4_ctr_d = dim4_ctr_q + 1;
                        if (dim4_ctr_d==shape_q[4] || shape_q[4] == 0) begin
                            transaction_finished_d = 1;
                            dim4_ctr_d = 0;
                        end else begin
                            current_address_d = current_address_q + stride_q[4];
                        end
                    end else begin
                        current_address_d = current_address_q + stride_q[3];
                    end
                end else begin
                    current_address_d = current_address_q + stride_q[2];
                end
            end else begin
                current_address_d = current_address_q + stride_q[1];
            end
        end

        if(update_address_i==1 && transaction_finished_d==0) begin
            valid_d = 1;
        end

    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_update_state
        if(~rst_ni) begin
             valid_q                <= '0;
             transaction_finished_q <= '0;
             current_address_q      <= '0;
             shape_q[0]             <= '0;
             shape_q[1]             <= '0;
             shape_q[2]             <= '0;
             shape_q[3]             <= '0;
             shape_q[4]             <= '0;
             stride_q[1]            <= '0;
             stride_q[2]            <= '0;
             stride_q[3]            <= '0;
             stride_q[4]            <= '0;
             dim1_ctr_q             <= '0;
             dim2_ctr_q             <= '0;
             dim3_ctr_q             <= '0;
             dim4_ctr_q             <= '0;
        end else begin
             valid_q                <= valid_d;
             transaction_finished_q <= transaction_finished_d;
             current_address_q      <= current_address_d;
             shape_q[0]             <= shape_d[0];
             shape_q[1]             <= shape_d[1];
             shape_q[2]             <= shape_d[2];
             shape_q[3]             <= shape_d[3];
             shape_q[4]             <= shape_d[4];
             stride_q[1]            <= stride_d[1];
             stride_q[2]            <= stride_d[2];
             stride_q[3]            <= stride_d[3];
             stride_q[4]            <= stride_d[4];
             dim1_ctr_q             <= dim1_ctr_d;
             dim2_ctr_q             <= dim2_ctr_d;
             dim3_ctr_q             <= dim3_ctr_d;
             dim4_ctr_q             <= dim4_ctr_d;
        end
    end

endmodule // tdma_addr_calc
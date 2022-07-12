module idma_nd_midend #(
    parameter int unsigned NumDims = idma_nd_midend_pkg::NumDims,
    parameter type addr_t = idma_nd_midend_pkg::addr_t,
    parameter type burst_req_t = idma_nd_midend_pkg::burst_req_t,
    parameter type nd_req_t = idma_nd_midend_pkg::nd_req_t,
    parameter type d_cfg_t  = idma_nd_midend_pkg::d_cfg_t,
    parameter type nd_cfg_t = idma_nd_midend_pkg::nd_cfg_t,
    parameter nd_cfg_t nd_cfg = idma_nd_midend_pkg::nd_cfg
) (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  nd_req_t    nd_req_i,
    input  logic       nd_valid_i,
    output logic       nd_ready_o,
    output burst_req_t burst_req_o,
    output logic       burst_valid_o,
    input  logic       burst_ready_i
);

    // stride select
    localparam StrideSelWidth = $clog2(NumDims-1) + 1;

    logic [StrideSelWidth-1:0] stride_sel_d, stride_sel_q;

    // signal connecting the stages
    logic [NumDims-1:0] stage_done;
    logic [NumDims-2:0] stage_zero;
    logic [NumDims-2:0] stage_en;
    logic [NumDims-2:0] stage_clear;

    // signal signaling all zeros
    logic zero;

    // the current address pointers
    addr_t src_addr_d, src_addr_q;
    addr_t dst_addr_d, dst_addr_q;

    // assign the handshaking signals on the input
    assign stage_done[0] = nd_valid_i;
    assign nd_ready_o    = &(stage_done[NumDims-1:0]) & nd_valid_i;

    // all stages are zero
    assign zero = &(stage_zero);

    // assign handshake on the output
    assign burst_valid_o = nd_valid_i & !zero;

    // generate the counters
    for (genvar d = 2; d <= NumDims; d++) begin : gen_dim_counters

        // local copy of the dimensional configuration of the counters
        localparam d_cfg_t dim_cfg = nd_cfg[d-2];

        // local signals
        logic [dim_cfg.RepWidth-1:0] local_rep;
        logic local_overflow;

        // dataflow: stage needs to be enabled and target ready
        assign stage_en   [d-2] = &(stage_done[d-2:0]) & burst_ready_i;
        assign stage_clear[d-2] = &(stage_done[d-1:0]);

        // size conversion
        assign local_rep = nd_req_i.d_req[d-2].reps[dim_cfg.RepWidth-1:0];

        // bypass if num iterations is 0, mark stage as 0 stage:
        always_comb begin : proc_zero_bypass
            if (local_rep == '0) begin
                stage_done[d-1] = &(stage_done[d-2:0]);
                stage_zero[d-2] = 1'b1;
            end else begin
                stage_done[d-1] = local_overflow;
                stage_zero[d-2] = 1'b0;
            end
        end

        // number of repetitions counter
        idma_nd_counter #(
            .Width           ( dim_cfg.RepWidth ),
            .ResetVal        ( 'd1              )
        ) i_num_rep_counter (
            .clk_i,
            .rst_ni,
            .en_i    ( stage_en[d-2]       ),
            .clear_i ( stage_clear[d-2]    ),
            .limit_i ( local_rep           ),
            .cnt_o   ( /* NOT CONNECTED */ ),
            .done_o  ( local_overflow      )
        );
    end

    // stride select
    popcount #(
        .INPUT_WIDTH(NumDims-1)
    ) i_popcount (
        .data_i     ( stage_clear  ),
        .popcount_o ( stride_sel_d )
    );

    // address calculation
    always_comb begin : src_addr_calc
        if (stride_sel_q == NumDims - 1) begin
            src_addr_d = nd_req_i.burst_req.src;
        end else begin
            src_addr_d = src_addr_q + nd_req_i.d_req[stride_sel_q].src_strides;
        end
    end

    always_comb begin : dst_addr_calc
        if (stride_sel_q == NumDims - 1) begin
            dst_addr_d = nd_req_i.burst_req.dst;
        end else begin
            dst_addr_d = dst_addr_q + nd_req_i.d_req[stride_sel_q].dst_strides;
        end
    end

    // modify burst request
    assign burst_req_o.src = src_addr_d;
    assign burst_req_o.dst = dst_addr_d;

    // state
    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_stride_select_delay
        if(~rst_ni) begin
            stride_sel_q <= NumDims - 'd1;
            src_addr_q   <= '0;
            dst_addr_q   <= '0;
        end else begin
            if (nd_valid_i)
                stride_sel_q <= stride_sel_d;
                src_addr_q   <= src_addr_d;
                dst_addr_q   <= dst_addr_d;
        end
    end

endmodule : idma_nd_midend

module idma_nd_counter #(
    parameter int unsigned Width = 0,
    parameter logic [Width-1:0] ResetVal = 0
)(
    input  logic             clk_i,
    input  logic             rst_ni,
    input  logic             en_i,
    input  logic             clear_i,
    input  logic [Width-1:0] limit_i,
    output logic [Width-1:0] cnt_o,
    output logic             done_o
);

    logic [Width-1:0] counter_q, counter_d;

    always_comb begin
        counter_d = counter_q;
        if (clear_i) begin
            counter_d = ResetVal;
        end else if (en_i) begin
            counter_d = counter_q + 'd1;
        end
    end

    assign done_o = counter_q == limit_i;
    assign cnt_o  = counter_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
           counter_q <= ResetVal;
        end else begin
           counter_q <= counter_d;
        end
    end

endmodule : idma_nd_counter

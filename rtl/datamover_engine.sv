/*
 * Copyright (C) 2025-2026 ETH Zurich and University of Bologna
 *
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the "License"); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 */

/*
 * Authors:  Francesco Conti <f.conti@unibo.it>
 *           Sergio Mazzola <smazzola@iis.ee.ethz.ch>
 *           Cyrill Durrer <cdurrer@iis.ee.ethz.ch>
 */

module datamover_engine
  import hwpe_stream_package::*;
  import hci_package::*;
  import datamover_package::*;
#(
  parameter int unsigned FIFO_DEPTH = 2,
  parameter int unsigned BANDWIDTH_ALIGNED = 512,
  parameter int unsigned NUM_ELEM_WORD = 4, // number of elements in a bank word
  parameter int unsigned ELEM_WIDTH = 8,     // element width (in bits)
  // Dependent parameters: do not modify!
  localparam int unsigned WORD_WIDTH = NUM_ELEM_WORD * ELEM_WIDTH // should correspond to bank width
) (
  // global signals
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic                   test_mode_i,   // unused
  // local enable & clear
  input  logic                   enable_i,      // unused
  input  logic                   clear_i,
  // control registers
  input  ctrl_engine_t           ctrl_i,
  // input data stream + handshake
  hwpe_stream_intf_stream.sink   data_in,
  // output data stream + handshake
  hwpe_stream_intf_stream.source data_out
);

  // number of elements (in the full bandwidth, not a single bank word)
  localparam int unsigned NB_ELEMENTS = BANDWIDTH_ALIGNED / ELEM_WIDTH;
  localparam int unsigned NB_ELEM_LOG2 = $clog2(NB_ELEMENTS);

  // Type def and internal signals
  typedef enum logic { WRITE, READ } datamover_engine_fsm_t;
  datamover_engine_fsm_t                  fsm_d, fsm_q;
  logic                                   clear_elem_matrix;
  logic [NB_ELEM_LOG2-1:0]                cnt_q, cnt_d;
  logic [17:0]                            tot_cnt_q, tot_cnt_d;
  logic                                   cnt_en;
  logic [NB_ELEMENTS-1:0][ELEM_WIDTH-1:0] data_in_unrolled;
  logic                                   data_in_valid;
  logic                                   data_in_ready;
  logic [NB_ELEMENTS-1:0][ELEM_WIDTH-1:0] data_out_unrolled;
  logic                                   data_out_valid;
  logic                                   data_out_ready;
  logic [NB_ELEM_LOG2-1:0]                remaining_elems;
  logic [17:0]                            total_accesses_copy_mode, total_accesses;
  logic [15:0]                            y_elem_cnt, expanded_y_elems;
  logic [9:0]                             y_tiles, n_tiles, n_tile_cnt;
  logic [NB_ELEM_LOG2:0]                  leftover_rows, leftover_cols;
  logic                                   last_y_tile, last_n_tile;

  logic                                   execution_done;

  // FSM: WRITE -> READ on input handshake at end of write, READ -> WRITE on output handshake at end of read
  always_comb
  begin
    fsm_d = fsm_q;
    case (fsm_q)
      WRITE: begin
        if (((cnt_q == ctrl_i.transp_len-ctrl_i.transp_stride)) && (data_in_valid & data_in_ready)) begin
          fsm_d = READ;
        end
      end
      READ: begin
        if (((cnt_q == ctrl_i.transp_len-ctrl_i.transp_stride)) && (data_out_valid & data_out_ready)) begin
          fsm_d = WRITE;
        end
      end
      default: begin
        fsm_d = WRITE;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      fsm_q <= WRITE;
    end else if (clear_i || execution_done) begin
      fsm_q <= WRITE;
    end else begin
      fsm_q <= fsm_d;
    end
  end

  assign clear_elem_matrix = (fsm_q == READ && fsm_d == WRITE);

  // internal interfaces and unrolling
  hwpe_stream_intf_stream #(
    .DATA_WIDTH ( BANDWIDTH_ALIGNED ),
    .ELEMENT_WIDTH ( ELEM_WIDTH ),
    .STRB_WIDTH ( NB_ELEMENTS )
  ) data_in_postfifo (
    .clk ( clk_i )
  );
  hwpe_stream_intf_stream #(
    .DATA_WIDTH ( BANDWIDTH_ALIGNED ),
    .ELEMENT_WIDTH ( ELEM_WIDTH ),
    .STRB_WIDTH ( NB_ELEMENTS )
  ) data_out_prefifo (
    .clk ( clk_i )
  );

  // decouple in/out with FIFOs
  hwpe_stream_fifo #(
    .DATA_WIDTH ( BANDWIDTH_ALIGNED ),
    .ELEMENT_WIDTH ( ELEM_WIDTH ),
    .FIFO_DEPTH ( FIFO_DEPTH )
  ) i_fifo_in (
    .clk_i   ( clk_i            ),
    .rst_ni  ( rst_ni           ),
    .clear_i ( clear_i          ),
    .flags_o (                  ),
    .push_i  ( data_in          ),
    .pop_o   ( data_in_postfifo )
  );
  assign data_in_unrolled = data_in_postfifo.data;
  assign data_in_valid = data_in_postfifo.valid;
  assign data_in_postfifo.ready = data_in_ready;
  hwpe_stream_fifo #(
    .DATA_WIDTH ( BANDWIDTH_ALIGNED ),
    .ELEMENT_WIDTH ( ELEM_WIDTH ),
    .FIFO_DEPTH ( FIFO_DEPTH )
  ) i_fifo_out (
    .clk_i   ( clk_i            ),
    .rst_ni  ( rst_ni           ),
    .clear_i ( clear_i          ),
    .flags_o (                  ),
    .push_i  ( data_out_prefifo ),
    .pop_o   ( data_out         )
  );


  // Partial tile / leftover elements handling
  // Due to the streamer address generation, matrices need to be word-aligned in n-dimension for transposition
  localparam logic [NB_ELEMENTS-1:0] STRB_ONE = {{(NB_ELEMENTS-1){1'b0}}, 1'b1};    // Necessary to force the shifting operation to the correct bitwidth (default would be only 32b)
  assign remaining_elems = ctrl_i.total_elements & (NB_ELEMENTS - 1);         // modulo (NB_ELEMENTS: power of two) - this signal is only used in copy mode
  assign total_accesses_copy_mode = (ctrl_i.total_elements >> NB_ELEM_LOG2) + ((remaining_elems != 0) ? 1 : 0);

  // y_tiles represents the number of tiles in c-dimension for unfold/fold modes, and the number of tiles in m-dimension for all other modes
  assign y_tiles = (ctrl_i.datamover_mode == DATAMOVER_UNFOLD || ctrl_i.datamover_mode == DATAMOVER_FOLD) ?
                   (ctrl_i.num_channels + NB_ELEMENTS - 1) >> NB_ELEM_LOG2 :
                   (ctrl_i.tensor_size_m + NB_ELEMENTS - 1) >> NB_ELEM_LOG2;   // ceil division
  assign n_tiles = (ctrl_i.tensor_size_n + NB_ELEMENTS - 1) >> NB_ELEM_LOG2;   // ceil division
  assign total_accesses = (ctrl_i.datamover_mode == DATAMOVER_UNFOLD || ctrl_i.datamover_mode == DATAMOVER_FOLD) ? (y_tiles * ctrl_i.tensor_size_m * n_tiles) << NB_ELEM_LOG2 : (y_tiles * n_tiles) << NB_ELEM_LOG2;          // NB_ELEMENTS is a power of 2, so multiply by shifting; ToDo: remaining MUL overhead, could be pre-computed in HAL and configured in control register
  assign leftover_rows = (ctrl_i.datamover_mode == DATAMOVER_UNFOLD || ctrl_i.datamover_mode == DATAMOVER_FOLD) ? ctrl_i.num_channels & (NB_ELEMENTS - 1) : ctrl_i.tensor_size_m & (NB_ELEMENTS - 1);
  assign leftover_cols = ctrl_i.tensor_size_n & (NB_ELEMENTS - 1);
  assign expanded_y_elems = y_tiles << NB_ELEM_LOG2;    // taking into account partial tiles
  assign y_elem_cnt = (expanded_y_elems == 0) ? '0 : (tot_cnt_q % expanded_y_elems);    // ToDo: restructure without modulo (pre-compute in HAL?)
  assign n_tile_cnt = (expanded_y_elems == 0) ? '0 : (tot_cnt_q / expanded_y_elems);    // ToDo: restructure without division (pre-compute in HAL?)
  assign last_y_tile = (ctrl_i.datamover_mode == DATAMOVER_UNFOLD || ctrl_i.datamover_mode == DATAMOVER_FOLD) ?
                       ((y_elem_cnt >> NB_ELEM_LOG2) >= (ctrl_i.num_channels >> NB_ELEM_LOG2)) :
                       ((y_elem_cnt >> NB_ELEM_LOG2) >= (ctrl_i.tensor_size_m >> NB_ELEM_LOG2));
  assign last_n_tile = (n_tile_cnt >= (ctrl_i.tensor_size_n >> NB_ELEM_LOG2));

  always_comb begin
    data_out_prefifo.strb = '1;
    if(ctrl_i.total_elements != 0) begin
      if(ctrl_i.datamover_mode == DATAMOVER_COPY) begin            // Copy mode
        data_out_prefifo.strb = ((tot_cnt_q >= total_accesses_copy_mode-1) && (remaining_elems != 0)) ? ((STRB_ONE << remaining_elems) - 1) : '1;
      end else if(ctrl_i.datamover_mode == DATAMOVER_TRANSPOSE) begin   // Transpose mode
        if((last_y_tile && leftover_rows != 0) && (last_n_tile && leftover_cols != 0)) begin
          if((y_elem_cnt & (NB_ELEMENTS - 1)) < leftover_cols) begin
            data_out_prefifo.strb = ((STRB_ONE << leftover_rows) - 1);
          end else begin
            data_out_prefifo.strb = '0;
          end
        end else if(last_y_tile && leftover_rows != 0) begin
          data_out_prefifo.strb = ((STRB_ONE << leftover_rows) - 1);
        end else if(last_n_tile && leftover_cols != 0) begin
          if((y_elem_cnt & (NB_ELEMENTS - 1)) < leftover_cols) begin
            data_out_prefifo.strb = '1;
          end else begin
            data_out_prefifo.strb = '0;
          end
        end else begin
          data_out_prefifo.strb = '1;
        end
      end else if(ctrl_i.datamover_mode == DATAMOVER_CIM_CONVERSION) begin   // CIM layout conversion mode
        if((last_y_tile && leftover_rows != 0) && (last_n_tile && leftover_cols != 0)) begin
          if((y_elem_cnt & (NB_ELEMENTS - 1)) < leftover_rows) begin
            data_out_prefifo.strb = ((STRB_ONE << leftover_cols) - 1);
          end else begin
            data_out_prefifo.strb = '0;
          end
        end else if(last_y_tile && leftover_rows != 0) begin
          if((y_elem_cnt & (NB_ELEMENTS - 1)) < leftover_rows) begin
            data_out_prefifo.strb = '1;
          end else begin
            data_out_prefifo.strb = '0;
          end
        end else if(last_n_tile && leftover_cols != 0) begin
          data_out_prefifo.strb = ((STRB_ONE << leftover_cols) - 1);
        end else begin
          data_out_prefifo.strb = '1;
        end
      end else if(ctrl_i.datamover_mode == DATAMOVER_UNFOLD) begin   // Unfold mode
        if((last_y_tile && leftover_rows != 0) && (last_n_tile && leftover_cols != 0)) begin
          if((y_elem_cnt & (NB_ELEMENTS - 1)) < leftover_cols) begin
            data_out_prefifo.strb = ((STRB_ONE << leftover_rows) - 1);
          end else begin
            data_out_prefifo.strb = '0;
          end
        end else if(last_y_tile && leftover_rows != 0) begin
          data_out_prefifo.strb = ((STRB_ONE << leftover_rows) - 1);
        end else if(last_n_tile && leftover_cols != 0) begin
          if((y_elem_cnt & (NB_ELEMENTS - 1)) < leftover_cols) begin
            data_out_prefifo.strb = '1;
          end else begin
            data_out_prefifo.strb = '0;
          end
        end else begin
          data_out_prefifo.strb = '1;
        end
      end else if(ctrl_i.datamover_mode == DATAMOVER_FOLD) begin   // Fold mode (inverse of unfold: leftover_rows <-> leftover_cols roles swapped)
        if((last_y_tile && leftover_rows != 0) && (last_n_tile && leftover_cols != 0)) begin
          if((y_elem_cnt & (NB_ELEMENTS - 1)) < leftover_rows) begin
            data_out_prefifo.strb = ((STRB_ONE << leftover_cols) - 1);
          end else begin
            data_out_prefifo.strb = '0;
          end
        end else if(last_n_tile && leftover_cols != 0) begin
          data_out_prefifo.strb = ((STRB_ONE << leftover_cols) - 1);
        end else if(last_y_tile && leftover_rows != 0) begin
          if((y_elem_cnt & (NB_ELEMENTS - 1)) < leftover_rows) begin
            data_out_prefifo.strb = '1;
          end else begin
            data_out_prefifo.strb = '0;
          end
        end else begin
          data_out_prefifo.strb = '1;
        end
      end
    end
  end

  assign data_out_prefifo.data = data_out_unrolled;
  assign data_out_prefifo.valid = data_out_valid;
  assign data_out_ready = data_out_prefifo.ready;

  // Write counter
  always_ff @(posedge clk_i or negedge rst_ni)
  begin
    if (~rst_ni) begin
      cnt_q <= '0;
      tot_cnt_q <= '0;
    end
    else if(clear_i) begin
      cnt_q <= '0;
      tot_cnt_q <= '0;
    end
    else if(execution_done) begin
      cnt_q <= '0;
      tot_cnt_q <= '0;
    end
    else if(cnt_en) begin
      cnt_q <= cnt_d;
      tot_cnt_q <= tot_cnt_d;
    end
  end
  assign cnt_d = (cnt_q < (ctrl_i.transp_len-ctrl_i.transp_stride)) ? cnt_q+ctrl_i.transp_stride : '0;
  assign cnt_en = fsm_q == WRITE ? data_in_valid & data_in_ready : data_out_valid & data_out_ready;
  assign execution_done = (ctrl_i.datamover_mode == DATAMOVER_COPY) ? (total_accesses_copy_mode != 0) && (data_out_prefifo.valid & data_out_prefifo.ready) && (tot_cnt_q >= total_accesses_copy_mode - 1) :
                                                   (total_accesses != 0) && (data_out_prefifo.valid & data_out_prefifo.ready) && (tot_cnt_q >= total_accesses - 1);

  // count total number of write accesses
  assign tot_cnt_d = (data_out_prefifo.valid & data_out_prefifo.ready) ? tot_cnt_q + 1 : tot_cnt_q;

  // "Smart shifting": this set of combinational blocks shifts data_in_unrolled
  // appropriately, depending on the configuration.
  // E.g., if you have a classical configuration with
  // - NUM_ELEM_WORD = 8 and
  // - ELEM_WIDTH = 8 bits, i.e. total is 64 bits per word
  // the configurations are: 8b transpose, 16b transpose, 32b transpose. We assume
  // that transposes >= 64b can be done efficiently by Snitch processors through SSRs
  // and those < 8b are not interesting in our use case.
  localparam MAX_SHIFTING = (NUM_ELEM_WORD > 4) ? NUM_ELEM_WORD : 4;
  // e.g., in a classical configuration (ELEM_WIDTH = 8), MAX_SHIFTING is
  // in bytes, i.e., "4" for 32b transpose (includes shifting by 0 bytes)
  logic [MAX_SHIFTING-1:0][NB_ELEMENTS-1:0][ELEM_WIDTH-1:0] data_in_shifted;

  for(genvar ii=0; ii<MAX_SHIFTING; ii++) begin : gen_data_shifting_x
    for(genvar jj=0; jj<NB_ELEMENTS; jj++) begin : gen_data_shifting_y

      if(ii+jj < NB_ELEMENTS) begin : gen_feasible_shiftings
        assign data_in_shifted[ii][jj] = data_in_unrolled[ii+jj];
      end
      else begin : gen_unfeasible_shiftings
        assign data_in_shifted[ii][jj] = '0;
      end

    end // gen_data_shifting_y
  end // gen_data_shifting_x

  // Buffering matrix: this 2D array of word elements (e.g., bytes
  // when ELEM_WIDTH = 8) is used to buffer values to transpose.
  logic [NB_ELEMENTS-1:0][NB_ELEMENTS-1:0][ELEM_WIDTH-1:0] elem_matrix_q;
  logic clear_int;
  assign clear_int = clear_i | clear_elem_matrix;

  for(genvar ii=0; ii<NB_ELEMENTS; ii++) begin : gen_elem_matrix_x

    // enable buffer rows that are aligned with counter in groups of four (in 32b mode),
    // of two (in 16b mode) or single rows (in 8b mode).
    logic buffer_enable;
    assign buffer_enable = ctrl_i.transp_mode == TRANSP_NONE ? 1'b0 :
                           ctrl_i.transp_mode == TRANSP_4ELEM ? ((cnt_q >> 2) == (ii >> 2)) & data_in_valid & data_in_ready :
                           ctrl_i.transp_mode == TRANSP_2ELEM ? ((cnt_q >> 1) == (ii >> 1)) & data_in_valid & data_in_ready :
                                                                ( cnt_q       ==  ii      ) & data_in_valid & data_in_ready;
    // select appropriately shifted rows
    logic [NB_ELEMENTS-1:0][ELEM_WIDTH-1:0] data_in_selected;
    assign data_in_selected = ctrl_i.transp_mode == TRANSP_4ELEM? data_in_shifted[ii % 4] :
                              ctrl_i.transp_mode == TRANSP_2ELEM ? data_in_shifted[ii % 2] :
                                                                   data_in_shifted[0];

    for(genvar jj=0; jj<NB_ELEMENTS; jj++) begin : gen_elem_matrix_y

      always_ff @(posedge clk_i or negedge rst_ni)
      begin
        if (~rst_ni) begin
          elem_matrix_q[ii][jj] <= '0;
        end
        else if(clear_int) begin
          elem_matrix_q[ii][jj] <= '0;
        end
        else if(buffer_enable) begin
          elem_matrix_q[ii][jj] <= data_in_selected[jj];
        end
      end

    end // gen_elem_matrix_y
  end // gen_elem_matrix_x

  // Output assignment
  for(genvar ii=0; ii<NB_ELEMENTS; ii++) begin : gen_output
    assign data_out_unrolled[ii] = ctrl_i.transp_mode != TRANSP_NONE ? elem_matrix_q[ii][cnt_q] : data_in_unrolled[ii];
  end // gen_output

  // Input ready & output valid generation
  assign data_in_ready  = ctrl_i.transp_mode != TRANSP_NONE ? fsm_q == WRITE : data_out_ready;
  assign data_out_valid = ctrl_i.transp_mode != TRANSP_NONE ? fsm_q == READ  : data_in_valid;

`ifndef SYNTHESIS
`ifndef VERILATOR
`ifndef VCS
  // Parameter assertions (elaboration-time checks)
  initial begin
    assert (BANDWIDTH_ALIGNED <= MAX_BANDWIDTH)
      else $fatal("BANDWIDTH_ALIGNED (%0d) must not be greater than MAX_BANDWIDTH (%0d)", BANDWIDTH_ALIGNED, MAX_BANDWIDTH);
    assert ((BANDWIDTH_ALIGNED % WORD_WIDTH) == 0)
      else $fatal("BANDWIDTH_ALIGNED (%0d) must be a multiple of WORD_WIDTH (%0d)", BANDWIDTH_ALIGNED, WORD_WIDTH);
    assert ((NB_ELEMENTS != 0) && ((NB_ELEMENTS & (NB_ELEMENTS - 1)) == 0))
      else $fatal("NB_ELEMENTS (%0d) = BANDWIDTH_ALIGNED (%0d) / ELEM_WIDTH (%0d) must be a power of two", NB_ELEMENTS, BANDWIDTH_ALIGNED, ELEM_WIDTH);
    assert (NUM_ELEM_WORD <= MAX_SHIFTING)
      else $fatal("NUM_ELEM_WORD (%0d) must not be greater than MAX_SHIFTING (%0d)", NUM_ELEM_WORD, MAX_SHIFTING);
  end

  // Runtime assertions
  assert property (@(posedge clk_i) disable iff (!rst_ni || $isunknown(ctrl_i.transp_len))
    ctrl_i.transp_len <= NB_ELEMENTS
  ) else $error("transp_len (%0d) exceeds NB_ELEMENTS (%0d) — cnt_q will never match FSM transition condition",
                ctrl_i.transp_len, NB_ELEMENTS);
`endif
`endif
`endif

endmodule // datamover_engine

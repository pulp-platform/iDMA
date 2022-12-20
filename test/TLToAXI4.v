module plusarg_reader #(
    parameter string FORMAT,
    parameter bit DEFAULT,
    parameter int unsigned WIDTH
) (
    input logic[WIDTH-1:0] out
);
endmodule

module TLMonitor_4 (
    input        clock,
    input        reset,
    input        io_in_a_ready,
    input        io_in_a_valid,
    input [ 2:0] io_in_a_bits_opcode,
    input [ 2:0] io_in_a_bits_param,
    input [ 3:0] io_in_a_bits_size,
    input [ 4:0] io_in_a_bits_source,
    input [30:0] io_in_a_bits_address,
    input [ 7:0] io_in_a_bits_mask,
    input        io_in_a_bits_corrupt,
    input        io_in_d_ready,
    input        io_in_d_valid,
    input [ 2:0] io_in_d_bits_opcode,
    input [ 3:0] io_in_d_bits_size,
    input [ 4:0] io_in_d_bits_source,
    input        io_in_d_bits_denied,
    input        io_in_d_bits_corrupt
);
  wire [31:0] plusarg_reader_out;
  wire [31:0] plusarg_reader_1_out;
  wire _T_2 = ~reset;
  wire _source_ok_T_1 = io_in_a_bits_source[4:3] == 2'h0;
  wire _source_ok_T_7 = io_in_a_bits_source[4:3] == 2'h1;
  wire _source_ok_T_12 = io_in_a_bits_source == 5'h10;
  wire _source_ok_T_13 = io_in_a_bits_source == 5'h11;
  wire _source_ok_T_14 = io_in_a_bits_source == 5'h12;
  wire  source_ok = _source_ok_T_1 | _source_ok_T_7 | _source_ok_T_12 | _source_ok_T_13 | _source_ok_T_14;
  wire [22:0] _is_aligned_mask_T_1 = 23'hff << io_in_a_bits_size;
  wire [7:0] is_aligned_mask = ~_is_aligned_mask_T_1[7:0];
  wire [30:0] _GEN_71 = {{23'd0}, is_aligned_mask};
  wire [30:0] _is_aligned_T = io_in_a_bits_address & _GEN_71;
  wire is_aligned = _is_aligned_T == 31'h0;
  wire [1:0] mask_sizeOH_shiftAmount = io_in_a_bits_size[1:0];
  wire [3:0] _mask_sizeOH_T_1 = 4'h1 << mask_sizeOH_shiftAmount;
  wire [2:0] mask_sizeOH = _mask_sizeOH_T_1[2:0] | 3'h1;
  wire _mask_T = io_in_a_bits_size >= 4'h3;
  wire mask_size = mask_sizeOH[2];
  wire mask_bit = io_in_a_bits_address[2];
  wire mask_nbit = ~mask_bit;
  wire mask_acc = _mask_T | mask_size & mask_nbit;
  wire mask_acc_1 = _mask_T | mask_size & mask_bit;
  wire mask_size_1 = mask_sizeOH[1];
  wire mask_bit_1 = io_in_a_bits_address[1];
  wire mask_nbit_1 = ~mask_bit_1;
  wire mask_eq_2 = mask_nbit & mask_nbit_1;
  wire mask_acc_2 = mask_acc | mask_size_1 & mask_eq_2;
  wire mask_eq_3 = mask_nbit & mask_bit_1;
  wire mask_acc_3 = mask_acc | mask_size_1 & mask_eq_3;
  wire mask_eq_4 = mask_bit & mask_nbit_1;
  wire mask_acc_4 = mask_acc_1 | mask_size_1 & mask_eq_4;
  wire mask_eq_5 = mask_bit & mask_bit_1;
  wire mask_acc_5 = mask_acc_1 | mask_size_1 & mask_eq_5;
  wire mask_size_2 = mask_sizeOH[0];
  wire mask_bit_2 = io_in_a_bits_address[0];
  wire mask_nbit_2 = ~mask_bit_2;
  wire mask_eq_6 = mask_eq_2 & mask_nbit_2;
  wire mask_acc_6 = mask_acc_2 | mask_size_2 & mask_eq_6;
  wire mask_eq_7 = mask_eq_2 & mask_bit_2;
  wire mask_acc_7 = mask_acc_2 | mask_size_2 & mask_eq_7;
  wire mask_eq_8 = mask_eq_3 & mask_nbit_2;
  wire mask_acc_8 = mask_acc_3 | mask_size_2 & mask_eq_8;
  wire mask_eq_9 = mask_eq_3 & mask_bit_2;
  wire mask_acc_9 = mask_acc_3 | mask_size_2 & mask_eq_9;
  wire mask_eq_10 = mask_eq_4 & mask_nbit_2;
  wire mask_acc_10 = mask_acc_4 | mask_size_2 & mask_eq_10;
  wire mask_eq_11 = mask_eq_4 & mask_bit_2;
  wire mask_acc_11 = mask_acc_4 | mask_size_2 & mask_eq_11;
  wire mask_eq_12 = mask_eq_5 & mask_nbit_2;
  wire mask_acc_12 = mask_acc_5 | mask_size_2 & mask_eq_12;
  wire mask_eq_13 = mask_eq_5 & mask_bit_2;
  wire mask_acc_13 = mask_acc_5 | mask_size_2 & mask_eq_13;
  wire [7:0] mask = {
    mask_acc_13,
    mask_acc_12,
    mask_acc_11,
    mask_acc_10,
    mask_acc_9,
    mask_acc_8,
    mask_acc_7,
    mask_acc_6
  };
  wire _T_61 = io_in_a_bits_opcode == 3'h6;
  wire _T_63 = io_in_a_bits_size <= 4'hc;
  wire _T_84 = _T_63 & source_ok;
  wire [30:0] _T_87 = io_in_a_bits_address ^ 31'h60000000;
  wire [31:0] _T_88 = {1'b0, $signed(_T_87)};
  wire [31:0] _T_90 = $signed(_T_88) & -32'sh20000000;
  wire _T_91 = $signed(_T_90) == 32'sh0;
  wire _T_113 = 4'h6 == io_in_a_bits_size;
  wire _T_116 = _source_ok_T_12 & _T_113;
  wire _T_132 = _T_63 & _T_91;
  wire _T_134 = _T_116 & _T_132;
  wire _T_148 = io_in_a_bits_param <= 3'h2;
  wire [7:0] _T_152 = ~io_in_a_bits_mask;
  wire _T_153 = _T_152 == 8'h0;
  wire _T_157 = ~io_in_a_bits_corrupt;
  wire _T_161 = io_in_a_bits_opcode == 3'h7;
  wire _T_252 = io_in_a_bits_param != 3'h0;
  wire _T_265 = io_in_a_bits_opcode == 3'h4;
  wire _T_294 = io_in_a_bits_size <= 4'h6;
  wire _T_302 = _T_294 & _T_91;
  wire _T_313 = io_in_a_bits_param == 3'h0;
  wire _T_317 = io_in_a_bits_mask == mask;
  wire _T_325 = io_in_a_bits_opcode == 3'h0;
  wire _T_351 = io_in_a_bits_size <= 4'h8;
  wire _T_359 = _T_351 & _T_91;
  wire _T_361 = _T_84 & _T_359;
  wire _T_379 = io_in_a_bits_opcode == 3'h1;
  wire [7:0] _T_429 = ~mask;
  wire [7:0] _T_430 = io_in_a_bits_mask & _T_429;
  wire _T_431 = _T_430 == 8'h0;
  wire _T_435 = io_in_a_bits_opcode == 3'h2;
  wire _T_478 = io_in_a_bits_param <= 3'h4;
  wire _T_486 = io_in_a_bits_opcode == 3'h3;
  wire _T_529 = io_in_a_bits_param <= 3'h3;
  wire _T_537 = io_in_a_bits_opcode == 3'h5;
  wire _T_580 = io_in_a_bits_param <= 3'h1;
  wire _T_592 = io_in_d_bits_opcode <= 3'h6;
  wire _source_ok_T_19 = io_in_d_bits_source[4:3] == 2'h0;
  wire _source_ok_T_25 = io_in_d_bits_source[4:3] == 2'h1;
  wire _source_ok_T_30 = io_in_d_bits_source == 5'h10;
  wire _source_ok_T_31 = io_in_d_bits_source == 5'h11;
  wire _source_ok_T_32 = io_in_d_bits_source == 5'h12;
  wire  source_ok_1 = _source_ok_T_19 | _source_ok_T_25 | _source_ok_T_30 | _source_ok_T_31 | _source_ok_T_32;
  wire _T_596 = io_in_d_bits_opcode == 3'h6;
  wire _T_600 = io_in_d_bits_size >= 4'h3;
  wire _T_608 = ~io_in_d_bits_corrupt;
  wire _T_612 = ~io_in_d_bits_denied;
  wire _T_616 = io_in_d_bits_opcode == 3'h4;
  wire _T_644 = io_in_d_bits_opcode == 3'h5;
  wire _T_664 = _T_612 | io_in_d_bits_corrupt;
  wire _T_673 = io_in_d_bits_opcode == 3'h0;
  wire _T_690 = io_in_d_bits_opcode == 3'h1;
  wire _T_708 = io_in_d_bits_opcode == 3'h2;
  wire _a_first_T = io_in_a_ready & io_in_a_valid;
  wire [4:0] a_first_beats1_decode = is_aligned_mask[7:3];
  wire a_first_beats1_opdata = ~io_in_a_bits_opcode[2];
  reg [4:0] a_first_counter;
  wire [4:0] a_first_counter1 = a_first_counter - 5'h1;
  wire a_first = a_first_counter == 5'h0;
  reg [2:0] opcode;
  reg [2:0] param;
  reg [3:0] size;
  reg [4:0] source;
  reg [30:0] address;
  wire _T_738 = io_in_a_valid & ~a_first;
  wire _T_739 = io_in_a_bits_opcode == opcode;
  wire _T_743 = io_in_a_bits_param == param;
  wire _T_747 = io_in_a_bits_size == size;
  wire _T_751 = io_in_a_bits_source == source;
  wire _T_755 = io_in_a_bits_address == address;
  wire _d_first_T = io_in_d_ready & io_in_d_valid;
  wire [22:0] _d_first_beats1_decode_T_1 = 23'hff << io_in_d_bits_size;
  wire [7:0] _d_first_beats1_decode_T_3 = ~_d_first_beats1_decode_T_1[7:0];
  wire [4:0] d_first_beats1_decode = _d_first_beats1_decode_T_3[7:3];
  wire d_first_beats1_opdata = io_in_d_bits_opcode[0];
  reg [4:0] d_first_counter;
  wire [4:0] d_first_counter1 = d_first_counter - 5'h1;
  wire d_first = d_first_counter == 5'h0;
  reg [2:0] opcode_1;
  reg [3:0] size_1;
  reg [4:0] source_1;
  reg denied;
  wire _T_762 = io_in_d_valid & ~d_first;
  wire _T_763 = io_in_d_bits_opcode == opcode_1;
  wire _T_771 = io_in_d_bits_size == size_1;
  wire _T_775 = io_in_d_bits_source == source_1;
  wire _T_783 = io_in_d_bits_denied == denied;
  reg [18:0] inflight;
  reg [75:0] inflight_opcodes;
  reg [151:0] inflight_sizes;
  reg [4:0] a_first_counter_1;
  wire [4:0] a_first_counter1_1 = a_first_counter_1 - 5'h1;
  wire a_first_1 = a_first_counter_1 == 5'h0;
  reg [4:0] d_first_counter_1;
  wire [4:0] d_first_counter1_1 = d_first_counter_1 - 5'h1;
  wire d_first_1 = d_first_counter_1 == 5'h0;
  wire [6:0] _GEN_72 = {io_in_d_bits_source, 2'h0};
  wire [7:0] _a_opcode_lookup_T = {{1'd0}, _GEN_72};
  wire [75:0] _a_opcode_lookup_T_1 = inflight_opcodes >> _a_opcode_lookup_T;
  wire [15:0] _a_opcode_lookup_T_5 = 16'h10 - 16'h1;
  wire [75:0] _GEN_73 = {{60'd0}, _a_opcode_lookup_T_5};
  wire [75:0] _a_opcode_lookup_T_6 = _a_opcode_lookup_T_1 & _GEN_73;
  wire [75:0] _a_opcode_lookup_T_7 = {{1'd0}, _a_opcode_lookup_T_6[75:1]};
  wire [7:0] _a_size_lookup_T = {io_in_d_bits_source, 3'h0};
  wire [151:0] _a_size_lookup_T_1 = inflight_sizes >> _a_size_lookup_T;
  wire [15:0] _a_size_lookup_T_5 = 16'h100 - 16'h1;
  wire [151:0] _GEN_75 = {{136'd0}, _a_size_lookup_T_5};
  wire [151:0] _a_size_lookup_T_6 = _a_size_lookup_T_1 & _GEN_75;
  wire [151:0] _a_size_lookup_T_7 = {{1'd0}, _a_size_lookup_T_6[151:1]};
  wire _T_789 = io_in_a_valid & a_first_1;
  wire [31:0] _a_set_wo_ready_T = 32'h1 << io_in_a_bits_source;
  wire [31:0] _GEN_15 = io_in_a_valid & a_first_1 ? _a_set_wo_ready_T : 32'h0;
  wire _T_792 = _a_first_T & a_first_1;
  wire [3:0] _a_opcodes_set_interm_T = {io_in_a_bits_opcode, 1'h0};
  wire [3:0] _a_opcodes_set_interm_T_1 = _a_opcodes_set_interm_T | 4'h1;
  wire [4:0] _a_sizes_set_interm_T = {io_in_a_bits_size, 1'h0};
  wire [4:0] _a_sizes_set_interm_T_1 = _a_sizes_set_interm_T | 5'h1;
  wire [6:0] _GEN_77 = {io_in_a_bits_source, 2'h0};
  wire [7:0] _a_opcodes_set_T = {{1'd0}, _GEN_77};
  wire [3:0] a_opcodes_set_interm = _a_first_T & a_first_1 ? _a_opcodes_set_interm_T_1 : 4'h0;
  wire [258:0] _GEN_1 = {{255'd0}, a_opcodes_set_interm};
  wire [258:0] _a_opcodes_set_T_1 = _GEN_1 << _a_opcodes_set_T;
  wire [7:0] _a_sizes_set_T = {io_in_a_bits_source, 3'h0};
  wire [4:0] a_sizes_set_interm = _a_first_T & a_first_1 ? _a_sizes_set_interm_T_1 : 5'h0;
  wire [259:0] _GEN_2 = {{255'd0}, a_sizes_set_interm};
  wire [259:0] _a_sizes_set_T_1 = _GEN_2 << _a_sizes_set_T;
  wire [18:0] _T_794 = inflight >> io_in_a_bits_source;
  wire _T_796 = ~_T_794[0];
  wire [31:0] _GEN_16 = _a_first_T & a_first_1 ? _a_set_wo_ready_T : 32'h0;
  wire [258:0] _GEN_19 = _a_first_T & a_first_1 ? _a_opcodes_set_T_1 : 259'h0;
  wire [259:0] _GEN_20 = _a_first_T & a_first_1 ? _a_sizes_set_T_1 : 260'h0;
  wire _T_800 = io_in_d_valid & d_first_1;
  wire _T_802 = ~_T_596;
  wire _T_803 = io_in_d_valid & d_first_1 & ~_T_596;
  wire [31:0] _d_clr_wo_ready_T = 32'h1 << io_in_d_bits_source;
  wire [31:0] _GEN_21 = io_in_d_valid & d_first_1 & ~_T_596 ? _d_clr_wo_ready_T : 32'h0;
  wire [270:0] _GEN_3 = {{255'd0}, _a_opcode_lookup_T_5};
  wire [270:0] _d_opcodes_clr_T_5 = _GEN_3 << _a_opcode_lookup_T;
  wire [270:0] _GEN_4 = {{255'd0}, _a_size_lookup_T_5};
  wire [270:0] _d_sizes_clr_T_5 = _GEN_4 << _a_size_lookup_T;
  wire [31:0] _GEN_22 = _d_first_T & d_first_1 & _T_802 ? _d_clr_wo_ready_T : 32'h0;
  wire [270:0] _GEN_23 = _d_first_T & d_first_1 & _T_802 ? _d_opcodes_clr_T_5 : 271'h0;
  wire [270:0] _GEN_24 = _d_first_T & d_first_1 & _T_802 ? _d_sizes_clr_T_5 : 271'h0;
  wire _same_cycle_resp_T_2 = io_in_a_bits_source == io_in_d_bits_source;
  wire same_cycle_resp = _T_789 & io_in_a_bits_source == io_in_d_bits_source;
  wire [18:0] _T_813 = inflight >> io_in_d_bits_source;
  wire _T_815 = _T_813[0] | same_cycle_resp;
  wire [2:0] _GEN_27 = 3'h2 == io_in_a_bits_opcode ? 3'h1 : 3'h0;
  wire [2:0] _GEN_28 = 3'h3 == io_in_a_bits_opcode ? 3'h1 : _GEN_27;
  wire [2:0] _GEN_29 = 3'h4 == io_in_a_bits_opcode ? 3'h1 : _GEN_28;
  wire [2:0] _GEN_30 = 3'h5 == io_in_a_bits_opcode ? 3'h2 : _GEN_29;
  wire [2:0] _GEN_31 = 3'h6 == io_in_a_bits_opcode ? 3'h4 : _GEN_30;
  wire [2:0] _GEN_32 = 3'h7 == io_in_a_bits_opcode ? 3'h4 : _GEN_31;
  wire [2:0] _GEN_39 = 3'h6 == io_in_a_bits_opcode ? 3'h5 : _GEN_30;
  wire [2:0] _GEN_40 = 3'h7 == io_in_a_bits_opcode ? 3'h4 : _GEN_39;
  wire _T_820 = io_in_d_bits_opcode == _GEN_40;
  wire _T_821 = io_in_d_bits_opcode == _GEN_32 | _T_820;
  wire _T_825 = io_in_a_bits_size == io_in_d_bits_size;
  wire [3:0] a_opcode_lookup = _a_opcode_lookup_T_7[3:0];
  wire [2:0] _GEN_43 = 3'h2 == a_opcode_lookup[2:0] ? 3'h1 : 3'h0;
  wire [2:0] _GEN_44 = 3'h3 == a_opcode_lookup[2:0] ? 3'h1 : _GEN_43;
  wire [2:0] _GEN_45 = 3'h4 == a_opcode_lookup[2:0] ? 3'h1 : _GEN_44;
  wire [2:0] _GEN_46 = 3'h5 == a_opcode_lookup[2:0] ? 3'h2 : _GEN_45;
  wire [2:0] _GEN_47 = 3'h6 == a_opcode_lookup[2:0] ? 3'h4 : _GEN_46;
  wire [2:0] _GEN_48 = 3'h7 == a_opcode_lookup[2:0] ? 3'h4 : _GEN_47;
  wire [2:0] _GEN_55 = 3'h6 == a_opcode_lookup[2:0] ? 3'h5 : _GEN_46;
  wire [2:0] _GEN_56 = 3'h7 == a_opcode_lookup[2:0] ? 3'h4 : _GEN_55;
  wire _T_832 = io_in_d_bits_opcode == _GEN_56;
  wire _T_833 = io_in_d_bits_opcode == _GEN_48 | _T_832;
  wire [7:0] a_size_lookup = _a_size_lookup_T_7[7:0];
  wire [7:0] _GEN_79 = {{4'd0}, io_in_d_bits_size};
  wire _T_837 = _GEN_79 == a_size_lookup;
  wire _T_847 = _T_800 & a_first_1 & io_in_a_valid & _same_cycle_resp_T_2 & _T_802;
  wire _T_849 = ~io_in_d_ready | io_in_a_ready;
  wire [18:0] a_set_wo_ready = _GEN_15[18:0];
  wire [18:0] d_clr_wo_ready = _GEN_21[18:0];
  wire _T_856 = a_set_wo_ready != d_clr_wo_ready | ~(|a_set_wo_ready);
  wire [18:0] a_set = _GEN_16[18:0];
  wire [18:0] _inflight_T = inflight | a_set;
  wire [18:0] d_clr = _GEN_22[18:0];
  wire [18:0] _inflight_T_1 = ~d_clr;
  wire [18:0] _inflight_T_2 = _inflight_T & _inflight_T_1;
  wire [75:0] a_opcodes_set = _GEN_19[75:0];
  wire [75:0] _inflight_opcodes_T = inflight_opcodes | a_opcodes_set;
  wire [75:0] d_opcodes_clr = _GEN_23[75:0];
  wire [75:0] _inflight_opcodes_T_1 = ~d_opcodes_clr;
  wire [75:0] _inflight_opcodes_T_2 = _inflight_opcodes_T & _inflight_opcodes_T_1;
  wire [151:0] a_sizes_set = _GEN_20[151:0];
  wire [151:0] _inflight_sizes_T = inflight_sizes | a_sizes_set;
  wire [151:0] d_sizes_clr = _GEN_24[151:0];
  wire [151:0] _inflight_sizes_T_1 = ~d_sizes_clr;
  wire [151:0] _inflight_sizes_T_2 = _inflight_sizes_T & _inflight_sizes_T_1;
  reg [31:0] watchdog;
  wire _T_865 = ~(|inflight) | plusarg_reader_out == 32'h0 | watchdog < plusarg_reader_out;
  wire [31:0] _watchdog_T_1 = watchdog + 32'h1;
  reg [18:0] inflight_1;
  reg [151:0] inflight_sizes_1;
  reg [4:0] d_first_counter_2;
  wire [4:0] d_first_counter1_2 = d_first_counter_2 - 5'h1;
  wire d_first_2 = d_first_counter_2 == 5'h0;
  wire [151:0] _c_size_lookup_T_1 = inflight_sizes_1 >> _a_size_lookup_T;
  wire [151:0] _c_size_lookup_T_6 = _c_size_lookup_T_1 & _GEN_75;
  wire [151:0] _c_size_lookup_T_7 = {{1'd0}, _c_size_lookup_T_6[151:1]};
  wire _T_891 = io_in_d_valid & d_first_2 & _T_596;
  wire [31:0] _GEN_67 = _d_first_T & d_first_2 & _T_596 ? _d_clr_wo_ready_T : 32'h0;
  wire [270:0] _GEN_69 = _d_first_T & d_first_2 & _T_596 ? _d_sizes_clr_T_5 : 271'h0;
  wire [18:0] _T_899 = inflight_1 >> io_in_d_bits_source;
  wire [7:0] c_size_lookup = _c_size_lookup_T_7[7:0];
  wire _T_909 = _GEN_79 == c_size_lookup;
  wire [18:0] d_clr_1 = _GEN_67[18:0];
  wire [18:0] _inflight_T_4 = ~d_clr_1;
  wire [18:0] _inflight_T_5 = inflight_1 & _inflight_T_4;
  wire [151:0] d_sizes_clr_1 = _GEN_69[151:0];
  wire [151:0] _inflight_sizes_T_4 = ~d_sizes_clr_1;
  wire [151:0] _inflight_sizes_T_5 = inflight_sizes_1 & _inflight_sizes_T_4;
  reg [31:0] watchdog_1;
  wire _T_934 = ~(|inflight_1) | plusarg_reader_1_out == 32'h0 | watchdog_1 < plusarg_reader_1_out;
  wire [31:0] _watchdog_T_3 = watchdog_1 + 32'h1;
  plusarg_reader #(
      .FORMAT ("tilelink_timeout=%d"),
      .DEFAULT(0),
      .WIDTH  (32)
  ) plusarg_reader (
      .out(plusarg_reader_out)
  );
  plusarg_reader #(
      .FORMAT ("tilelink_timeout=%d"),
      .DEFAULT(0),
      .WIDTH  (32)
  ) plusarg_reader_1 (
      .out(plusarg_reader_1_out)
  );
  always @(posedge clock) begin
    if (reset) begin
      a_first_counter <= 5'h0;
    end else if (_a_first_T) begin
      if (a_first) begin
        if (a_first_beats1_opdata) begin
          a_first_counter <= a_first_beats1_decode;
        end else begin
          a_first_counter <= 5'h0;
        end
      end else begin
        a_first_counter <= a_first_counter1;
      end
    end
    if (_a_first_T & a_first) begin
      opcode <= io_in_a_bits_opcode;
    end
    if (_a_first_T & a_first) begin
      param <= io_in_a_bits_param;
    end
    if (_a_first_T & a_first) begin
      size <= io_in_a_bits_size;
    end
    if (_a_first_T & a_first) begin
      source <= io_in_a_bits_source;
    end
    if (_a_first_T & a_first) begin
      address <= io_in_a_bits_address;
    end
    if (reset) begin
      d_first_counter <= 5'h0;
    end else if (_d_first_T) begin
      if (d_first) begin
        if (d_first_beats1_opdata) begin
          d_first_counter <= d_first_beats1_decode;
        end else begin
          d_first_counter <= 5'h0;
        end
      end else begin
        d_first_counter <= d_first_counter1;
      end
    end
    if (_d_first_T & d_first) begin
      opcode_1 <= io_in_d_bits_opcode;
    end
    if (_d_first_T & d_first) begin
      size_1 <= io_in_d_bits_size;
    end
    if (_d_first_T & d_first) begin
      source_1 <= io_in_d_bits_source;
    end
    if (_d_first_T & d_first) begin
      denied <= io_in_d_bits_denied;
    end
    if (reset) begin
      inflight <= 19'h0;
    end else begin
      inflight <= _inflight_T_2;
    end
    if (reset) begin
      inflight_opcodes <= 76'h0;
    end else begin
      inflight_opcodes <= _inflight_opcodes_T_2;
    end
    if (reset) begin
      inflight_sizes <= 152'h0;
    end else begin
      inflight_sizes <= _inflight_sizes_T_2;
    end
    if (reset) begin
      a_first_counter_1 <= 5'h0;
    end else if (_a_first_T) begin
      if (a_first_1) begin
        if (a_first_beats1_opdata) begin
          a_first_counter_1 <= a_first_beats1_decode;
        end else begin
          a_first_counter_1 <= 5'h0;
        end
      end else begin
        a_first_counter_1 <= a_first_counter1_1;
      end
    end
    if (reset) begin
      d_first_counter_1 <= 5'h0;
    end else if (_d_first_T) begin
      if (d_first_1) begin
        if (d_first_beats1_opdata) begin
          d_first_counter_1 <= d_first_beats1_decode;
        end else begin
          d_first_counter_1 <= 5'h0;
        end
      end else begin
        d_first_counter_1 <= d_first_counter1_1;
      end
    end
    if (reset) begin
      watchdog <= 32'h0;
    end else if (_a_first_T | _d_first_T) begin
      watchdog <= 32'h0;
    end else begin
      watchdog <= _watchdog_T_1;
    end
    if (reset) begin
      inflight_1 <= 19'h0;
    end else begin
      inflight_1 <= _inflight_T_5;
    end
    if (reset) begin
      inflight_sizes_1 <= 152'h0;
    end else begin
      inflight_sizes_1 <= _inflight_sizes_T_5;
    end
    if (reset) begin
      d_first_counter_2 <= 5'h0;
    end else if (_d_first_T) begin
      if (d_first_2) begin
        if (d_first_beats1_opdata) begin
          d_first_counter_2 <= d_first_beats1_decode;
        end else begin
          d_first_counter_2 <= 5'h0;
        end
      end else begin
        d_first_counter_2 <= d_first_counter1_2;
      end
    end
    if (reset) begin
      watchdog_1 <= 32'h0;
    end else if (_d_first_T) begin
      watchdog_1 <= 32'h0;
    end else begin
      watchdog_1 <= _watchdog_T_3;
    end
  end
endmodule

module Queue_10 (
    input         clock,
    input         reset,
    output        io_enq_ready,
    input         io_enq_valid,
    input  [63:0] io_enq_bits_data,
    input  [ 7:0] io_enq_bits_strb,
    input         io_enq_bits_last,
    input         io_deq_ready,
    output        io_deq_valid,
    output [63:0] io_deq_bits_data,
    output [ 7:0] io_deq_bits_strb,
    output        io_deq_bits_last
);
  reg [63:0] ram_data[0:0];
  wire ram_data_io_deq_bits_MPORT_en;
  wire ram_data_io_deq_bits_MPORT_addr;
  wire [63:0] ram_data_io_deq_bits_MPORT_data;
  wire [63:0] ram_data_MPORT_data;
  wire ram_data_MPORT_addr;
  wire ram_data_MPORT_mask;
  wire ram_data_MPORT_en;
  reg [7:0] ram_strb[0:0];
  wire ram_strb_io_deq_bits_MPORT_en;
  wire ram_strb_io_deq_bits_MPORT_addr;
  wire [7:0] ram_strb_io_deq_bits_MPORT_data;
  wire [7:0] ram_strb_MPORT_data;
  wire ram_strb_MPORT_addr;
  wire ram_strb_MPORT_mask;
  wire ram_strb_MPORT_en;
  reg ram_last[0:0];
  wire ram_last_io_deq_bits_MPORT_en;
  wire ram_last_io_deq_bits_MPORT_addr;
  wire ram_last_io_deq_bits_MPORT_data;
  wire ram_last_MPORT_data;
  wire ram_last_MPORT_addr;
  wire ram_last_MPORT_mask;
  wire ram_last_MPORT_en;
  reg maybe_full;
  wire empty = ~maybe_full;
  wire _do_enq_T = io_enq_ready & io_enq_valid;
  wire _do_deq_T = io_deq_ready & io_deq_valid;
  wire _GEN_11 = io_deq_ready ? 1'h0 : _do_enq_T;
  wire do_enq = empty ? _GEN_11 : _do_enq_T;
  wire do_deq = empty ? 1'h0 : _do_deq_T;
  assign ram_data_io_deq_bits_MPORT_en = 1'h1;
  assign ram_data_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_data_io_deq_bits_MPORT_data = ram_data[ram_data_io_deq_bits_MPORT_addr];
  assign ram_data_MPORT_data = io_enq_bits_data;
  assign ram_data_MPORT_addr = 1'h0;
  assign ram_data_MPORT_mask = 1'h1;
  assign ram_data_MPORT_en = empty ? _GEN_11 : _do_enq_T;
  assign ram_strb_io_deq_bits_MPORT_en = 1'h1;
  assign ram_strb_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_strb_io_deq_bits_MPORT_data = ram_strb[ram_strb_io_deq_bits_MPORT_addr];
  assign ram_strb_MPORT_data = io_enq_bits_strb;
  assign ram_strb_MPORT_addr = 1'h0;
  assign ram_strb_MPORT_mask = 1'h1;
  assign ram_strb_MPORT_en = empty ? _GEN_11 : _do_enq_T;
  assign ram_last_io_deq_bits_MPORT_en = 1'h1;
  assign ram_last_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_last_io_deq_bits_MPORT_data = ram_last[ram_last_io_deq_bits_MPORT_addr];
  assign ram_last_MPORT_data = io_enq_bits_last;
  assign ram_last_MPORT_addr = 1'h0;
  assign ram_last_MPORT_mask = 1'h1;
  assign ram_last_MPORT_en = empty ? _GEN_11 : _do_enq_T;
  assign io_enq_ready = ~maybe_full;
  assign io_deq_valid = io_enq_valid | ~empty;
  assign io_deq_bits_data = empty ? io_enq_bits_data : ram_data_io_deq_bits_MPORT_data;
  assign io_deq_bits_strb = empty ? io_enq_bits_strb : ram_strb_io_deq_bits_MPORT_data;
  assign io_deq_bits_last = empty ? io_enq_bits_last : ram_last_io_deq_bits_MPORT_data;
  always @(posedge clock) begin
    if (ram_data_MPORT_en & ram_data_MPORT_mask) begin
      ram_data[ram_data_MPORT_addr] <= ram_data_MPORT_data;
    end
    if (ram_strb_MPORT_en & ram_strb_MPORT_mask) begin
      ram_strb[ram_strb_MPORT_addr] <= ram_strb_MPORT_data;
    end
    if (ram_last_MPORT_en & ram_last_MPORT_mask) begin
      ram_last[ram_last_MPORT_addr] <= ram_last_MPORT_data;
    end
    if (reset) begin
      maybe_full <= 1'h0;
    end else if (do_enq != do_deq) begin
      if (empty) begin
        if (io_deq_ready) begin
          maybe_full <= 1'h0;
        end else begin
          maybe_full <= _do_enq_T;
        end
      end else begin
        maybe_full <= _do_enq_T;
      end
    end
  end
endmodule

module Queue_11 (
    input         clock,
    input         reset,
    output        io_enq_ready,
    input         io_enq_valid,
    input  [ 2:0] io_enq_bits_id,
    input  [30:0] io_enq_bits_addr,
    input  [ 7:0] io_enq_bits_len,
    input  [ 2:0] io_enq_bits_size,
    input  [ 3:0] io_enq_bits_cache,
    input  [ 2:0] io_enq_bits_prot,
    input  [ 3:0] io_enq_bits_echo_tl_state_size,
    input  [ 4:0] io_enq_bits_echo_tl_state_source,
    input         io_enq_bits_wen,
    input         io_deq_ready,
    output        io_deq_valid,
    output [ 2:0] io_deq_bits_id,
    output [30:0] io_deq_bits_addr,
    output [ 7:0] io_deq_bits_len,
    output [ 2:0] io_deq_bits_size,
    output [ 1:0] io_deq_bits_burst,
    output        io_deq_bits_lock,
    output [ 3:0] io_deq_bits_cache,
    output [ 2:0] io_deq_bits_prot,
    output [ 3:0] io_deq_bits_qos,
    output [ 3:0] io_deq_bits_echo_tl_state_size,
    output [ 4:0] io_deq_bits_echo_tl_state_source,
    output        io_deq_bits_wen
);
  reg [2:0] ram_id[0:0];
  wire ram_id_io_deq_bits_MPORT_en;
  wire ram_id_io_deq_bits_MPORT_addr;
  wire [2:0] ram_id_io_deq_bits_MPORT_data;
  wire [2:0] ram_id_MPORT_data;
  wire ram_id_MPORT_addr;
  wire ram_id_MPORT_mask;
  wire ram_id_MPORT_en;
  reg [30:0] ram_addr[0:0];
  wire ram_addr_io_deq_bits_MPORT_en;
  wire ram_addr_io_deq_bits_MPORT_addr;
  wire [30:0] ram_addr_io_deq_bits_MPORT_data;
  wire [30:0] ram_addr_MPORT_data;
  wire ram_addr_MPORT_addr;
  wire ram_addr_MPORT_mask;
  wire ram_addr_MPORT_en;
  reg [7:0] ram_len[0:0];
  wire ram_len_io_deq_bits_MPORT_en;
  wire ram_len_io_deq_bits_MPORT_addr;
  wire [7:0] ram_len_io_deq_bits_MPORT_data;
  wire [7:0] ram_len_MPORT_data;
  wire ram_len_MPORT_addr;
  wire ram_len_MPORT_mask;
  wire ram_len_MPORT_en;
  reg [2:0] ram_size[0:0];
  wire ram_size_io_deq_bits_MPORT_en;
  wire ram_size_io_deq_bits_MPORT_addr;
  wire [2:0] ram_size_io_deq_bits_MPORT_data;
  wire [2:0] ram_size_MPORT_data;
  wire ram_size_MPORT_addr;
  wire ram_size_MPORT_mask;
  wire ram_size_MPORT_en;
  reg [1:0] ram_burst[0:0];
  wire ram_burst_io_deq_bits_MPORT_en;
  wire ram_burst_io_deq_bits_MPORT_addr;
  wire [1:0] ram_burst_io_deq_bits_MPORT_data;
  wire [1:0] ram_burst_MPORT_data;
  wire ram_burst_MPORT_addr;
  wire ram_burst_MPORT_mask;
  wire ram_burst_MPORT_en;
  reg ram_lock[0:0];
  wire ram_lock_io_deq_bits_MPORT_en;
  wire ram_lock_io_deq_bits_MPORT_addr;
  wire ram_lock_io_deq_bits_MPORT_data;
  wire ram_lock_MPORT_data;
  wire ram_lock_MPORT_addr;
  wire ram_lock_MPORT_mask;
  wire ram_lock_MPORT_en;
  reg [3:0] ram_cache[0:0];
  wire ram_cache_io_deq_bits_MPORT_en;
  wire ram_cache_io_deq_bits_MPORT_addr;
  wire [3:0] ram_cache_io_deq_bits_MPORT_data;
  wire [3:0] ram_cache_MPORT_data;
  wire ram_cache_MPORT_addr;
  wire ram_cache_MPORT_mask;
  wire ram_cache_MPORT_en;
  reg [2:0] ram_prot[0:0];
  wire ram_prot_io_deq_bits_MPORT_en;
  wire ram_prot_io_deq_bits_MPORT_addr;
  wire [2:0] ram_prot_io_deq_bits_MPORT_data;
  wire [2:0] ram_prot_MPORT_data;
  wire ram_prot_MPORT_addr;
  wire ram_prot_MPORT_mask;
  wire ram_prot_MPORT_en;
  reg [3:0] ram_qos[0:0];
  wire ram_qos_io_deq_bits_MPORT_en;
  wire ram_qos_io_deq_bits_MPORT_addr;
  wire [3:0] ram_qos_io_deq_bits_MPORT_data;
  wire [3:0] ram_qos_MPORT_data;
  wire ram_qos_MPORT_addr;
  wire ram_qos_MPORT_mask;
  wire ram_qos_MPORT_en;
  reg [3:0] ram_echo_tl_state_size[0:0];
  wire ram_echo_tl_state_size_io_deq_bits_MPORT_en;
  wire ram_echo_tl_state_size_io_deq_bits_MPORT_addr;
  wire [3:0] ram_echo_tl_state_size_io_deq_bits_MPORT_data;
  wire [3:0] ram_echo_tl_state_size_MPORT_data;
  wire ram_echo_tl_state_size_MPORT_addr;
  wire ram_echo_tl_state_size_MPORT_mask;
  wire ram_echo_tl_state_size_MPORT_en;
  reg [4:0] ram_echo_tl_state_source[0:0];
  wire ram_echo_tl_state_source_io_deq_bits_MPORT_en;
  wire ram_echo_tl_state_source_io_deq_bits_MPORT_addr;
  wire [4:0] ram_echo_tl_state_source_io_deq_bits_MPORT_data;
  wire [4:0] ram_echo_tl_state_source_MPORT_data;
  wire ram_echo_tl_state_source_MPORT_addr;
  wire ram_echo_tl_state_source_MPORT_mask;
  wire ram_echo_tl_state_source_MPORT_en;
  reg ram_wen[0:0];
  wire ram_wen_io_deq_bits_MPORT_en;
  wire ram_wen_io_deq_bits_MPORT_addr;
  wire ram_wen_io_deq_bits_MPORT_data;
  wire ram_wen_MPORT_data;
  wire ram_wen_MPORT_addr;
  wire ram_wen_MPORT_mask;
  wire ram_wen_MPORT_en;
  reg maybe_full;
  wire empty = ~maybe_full;
  wire _do_enq_T = io_enq_ready & io_enq_valid;
  wire _do_deq_T = io_deq_ready & io_deq_valid;
  wire _GEN_20 = io_deq_ready ? 1'h0 : _do_enq_T;
  wire do_enq = empty ? _GEN_20 : _do_enq_T;
  wire do_deq = empty ? 1'h0 : _do_deq_T;
  assign ram_id_io_deq_bits_MPORT_en = 1'h1;
  assign ram_id_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_id_io_deq_bits_MPORT_data = ram_id[ram_id_io_deq_bits_MPORT_addr];
  assign ram_id_MPORT_data = io_enq_bits_id;
  assign ram_id_MPORT_addr = 1'h0;
  assign ram_id_MPORT_mask = 1'h1;
  assign ram_id_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_addr_io_deq_bits_MPORT_en = 1'h1;
  assign ram_addr_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_addr_io_deq_bits_MPORT_data = ram_addr[ram_addr_io_deq_bits_MPORT_addr];
  assign ram_addr_MPORT_data = io_enq_bits_addr;
  assign ram_addr_MPORT_addr = 1'h0;
  assign ram_addr_MPORT_mask = 1'h1;
  assign ram_addr_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_len_io_deq_bits_MPORT_en = 1'h1;
  assign ram_len_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_len_io_deq_bits_MPORT_data = ram_len[ram_len_io_deq_bits_MPORT_addr];
  assign ram_len_MPORT_data = io_enq_bits_len;
  assign ram_len_MPORT_addr = 1'h0;
  assign ram_len_MPORT_mask = 1'h1;
  assign ram_len_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_size_io_deq_bits_MPORT_en = 1'h1;
  assign ram_size_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_size_io_deq_bits_MPORT_data = ram_size[ram_size_io_deq_bits_MPORT_addr];
  assign ram_size_MPORT_data = io_enq_bits_size;
  assign ram_size_MPORT_addr = 1'h0;
  assign ram_size_MPORT_mask = 1'h1;
  assign ram_size_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_burst_io_deq_bits_MPORT_en = 1'h1;
  assign ram_burst_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_burst_io_deq_bits_MPORT_data = ram_burst[ram_burst_io_deq_bits_MPORT_addr];
  assign ram_burst_MPORT_data = 2'h1;
  assign ram_burst_MPORT_addr = 1'h0;
  assign ram_burst_MPORT_mask = 1'h1;
  assign ram_burst_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_lock_io_deq_bits_MPORT_en = 1'h1;
  assign ram_lock_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_lock_io_deq_bits_MPORT_data = ram_lock[ram_lock_io_deq_bits_MPORT_addr];
  assign ram_lock_MPORT_data = 1'h0;
  assign ram_lock_MPORT_addr = 1'h0;
  assign ram_lock_MPORT_mask = 1'h1;
  assign ram_lock_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_cache_io_deq_bits_MPORT_en = 1'h1;
  assign ram_cache_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_cache_io_deq_bits_MPORT_data = ram_cache[ram_cache_io_deq_bits_MPORT_addr];
  assign ram_cache_MPORT_data = io_enq_bits_cache;
  assign ram_cache_MPORT_addr = 1'h0;
  assign ram_cache_MPORT_mask = 1'h1;
  assign ram_cache_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_prot_io_deq_bits_MPORT_en = 1'h1;
  assign ram_prot_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_prot_io_deq_bits_MPORT_data = ram_prot[ram_prot_io_deq_bits_MPORT_addr];
  assign ram_prot_MPORT_data = io_enq_bits_prot;
  assign ram_prot_MPORT_addr = 1'h0;
  assign ram_prot_MPORT_mask = 1'h1;
  assign ram_prot_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_qos_io_deq_bits_MPORT_en = 1'h1;
  assign ram_qos_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_qos_io_deq_bits_MPORT_data = ram_qos[ram_qos_io_deq_bits_MPORT_addr];
  assign ram_qos_MPORT_data = 4'h0;
  assign ram_qos_MPORT_addr = 1'h0;
  assign ram_qos_MPORT_mask = 1'h1;
  assign ram_qos_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_echo_tl_state_size_io_deq_bits_MPORT_en = 1'h1;
  assign ram_echo_tl_state_size_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_echo_tl_state_size_io_deq_bits_MPORT_data =
    ram_echo_tl_state_size[ram_echo_tl_state_size_io_deq_bits_MPORT_addr];
  assign ram_echo_tl_state_size_MPORT_data = io_enq_bits_echo_tl_state_size;
  assign ram_echo_tl_state_size_MPORT_addr = 1'h0;
  assign ram_echo_tl_state_size_MPORT_mask = 1'h1;
  assign ram_echo_tl_state_size_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_echo_tl_state_source_io_deq_bits_MPORT_en = 1'h1;
  assign ram_echo_tl_state_source_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_echo_tl_state_source_io_deq_bits_MPORT_data =
    ram_echo_tl_state_source[ram_echo_tl_state_source_io_deq_bits_MPORT_addr];
  assign ram_echo_tl_state_source_MPORT_data = io_enq_bits_echo_tl_state_source;
  assign ram_echo_tl_state_source_MPORT_addr = 1'h0;
  assign ram_echo_tl_state_source_MPORT_mask = 1'h1;
  assign ram_echo_tl_state_source_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign ram_wen_io_deq_bits_MPORT_en = 1'h1;
  assign ram_wen_io_deq_bits_MPORT_addr = 1'h0;
  assign ram_wen_io_deq_bits_MPORT_data = ram_wen[ram_wen_io_deq_bits_MPORT_addr];
  assign ram_wen_MPORT_data = io_enq_bits_wen;
  assign ram_wen_MPORT_addr = 1'h0;
  assign ram_wen_MPORT_mask = 1'h1;
  assign ram_wen_MPORT_en = empty ? _GEN_20 : _do_enq_T;
  assign io_enq_ready = ~maybe_full;
  assign io_deq_valid = io_enq_valid | ~empty;
  assign io_deq_bits_id = empty ? io_enq_bits_id : ram_id_io_deq_bits_MPORT_data;
  assign io_deq_bits_addr = empty ? io_enq_bits_addr : ram_addr_io_deq_bits_MPORT_data;
  assign io_deq_bits_len = empty ? io_enq_bits_len : ram_len_io_deq_bits_MPORT_data;
  assign io_deq_bits_size = empty ? io_enq_bits_size : ram_size_io_deq_bits_MPORT_data;
  assign io_deq_bits_burst = empty ? 2'h1 : ram_burst_io_deq_bits_MPORT_data;
  assign io_deq_bits_lock = empty ? 1'h0 : ram_lock_io_deq_bits_MPORT_data;
  assign io_deq_bits_cache = empty ? io_enq_bits_cache : ram_cache_io_deq_bits_MPORT_data;
  assign io_deq_bits_prot = empty ? io_enq_bits_prot : ram_prot_io_deq_bits_MPORT_data;
  assign io_deq_bits_qos = empty ? 4'h0 : ram_qos_io_deq_bits_MPORT_data;
  assign io_deq_bits_echo_tl_state_size = empty ? io_enq_bits_echo_tl_state_size :
    ram_echo_tl_state_size_io_deq_bits_MPORT_data;
  assign io_deq_bits_echo_tl_state_source = empty ? io_enq_bits_echo_tl_state_source :
    ram_echo_tl_state_source_io_deq_bits_MPORT_data;
  assign io_deq_bits_wen = empty ? io_enq_bits_wen : ram_wen_io_deq_bits_MPORT_data;
  always @(posedge clock) begin
    if (ram_id_MPORT_en & ram_id_MPORT_mask) begin
      ram_id[ram_id_MPORT_addr] <= ram_id_MPORT_data;
    end
    if (ram_addr_MPORT_en & ram_addr_MPORT_mask) begin
      ram_addr[ram_addr_MPORT_addr] <= ram_addr_MPORT_data;
    end
    if (ram_len_MPORT_en & ram_len_MPORT_mask) begin
      ram_len[ram_len_MPORT_addr] <= ram_len_MPORT_data;
    end
    if (ram_size_MPORT_en & ram_size_MPORT_mask) begin
      ram_size[ram_size_MPORT_addr] <= ram_size_MPORT_data;
    end
    if (ram_burst_MPORT_en & ram_burst_MPORT_mask) begin
      ram_burst[ram_burst_MPORT_addr] <= ram_burst_MPORT_data;
    end
    if (ram_lock_MPORT_en & ram_lock_MPORT_mask) begin
      ram_lock[ram_lock_MPORT_addr] <= ram_lock_MPORT_data;
    end
    if (ram_cache_MPORT_en & ram_cache_MPORT_mask) begin
      ram_cache[ram_cache_MPORT_addr] <= ram_cache_MPORT_data;
    end
    if (ram_prot_MPORT_en & ram_prot_MPORT_mask) begin
      ram_prot[ram_prot_MPORT_addr] <= ram_prot_MPORT_data;
    end
    if (ram_qos_MPORT_en & ram_qos_MPORT_mask) begin
      ram_qos[ram_qos_MPORT_addr] <= ram_qos_MPORT_data;
    end
    if (ram_echo_tl_state_size_MPORT_en & ram_echo_tl_state_size_MPORT_mask) begin
      ram_echo_tl_state_size[ram_echo_tl_state_size_MPORT_addr] <= ram_echo_tl_state_size_MPORT_data;
    end
    if (ram_echo_tl_state_source_MPORT_en & ram_echo_tl_state_source_MPORT_mask) begin
      ram_echo_tl_state_source[ram_echo_tl_state_source_MPORT_addr] <= ram_echo_tl_state_source_MPORT_data;
    end
    if (ram_wen_MPORT_en & ram_wen_MPORT_mask) begin
      ram_wen[ram_wen_MPORT_addr] <= ram_wen_MPORT_data;
    end
    if (reset) begin
      maybe_full <= 1'h0;
    end else if (do_enq != do_deq) begin
      if (empty) begin
        if (io_deq_ready) begin
          maybe_full <= 1'h0;
        end else begin
          maybe_full <= _do_enq_T;
        end
      end else begin
        maybe_full <= _do_enq_T;
      end
    end
  end
endmodule

module TLToAXI4 (
    input         clock,
    input         reset,
    output        auto_in_a_ready,
    input         auto_in_a_valid,
    input  [ 2:0] auto_in_a_bits_opcode,
    input  [ 2:0] auto_in_a_bits_param,
    input  [ 3:0] auto_in_a_bits_size,
    input  [ 4:0] auto_in_a_bits_source,
    input  [30:0] auto_in_a_bits_address,
    input         auto_in_a_bits_user_amba_prot_bufferable,
    input         auto_in_a_bits_user_amba_prot_modifiable,
    input         auto_in_a_bits_user_amba_prot_readalloc,
    input         auto_in_a_bits_user_amba_prot_writealloc,
    input         auto_in_a_bits_user_amba_prot_privileged,
    input         auto_in_a_bits_user_amba_prot_secure,
    input         auto_in_a_bits_user_amba_prot_fetch,
    input  [ 7:0] auto_in_a_bits_mask,
    input  [63:0] auto_in_a_bits_data,
    input         auto_in_a_bits_corrupt,
    input         auto_in_d_ready,
    output        auto_in_d_valid,
    output [ 2:0] auto_in_d_bits_opcode,
    output [ 3:0] auto_in_d_bits_size,
    output [ 4:0] auto_in_d_bits_source,
    output        auto_in_d_bits_denied,
    output [63:0] auto_in_d_bits_data,
    output        auto_in_d_bits_corrupt,
    input         auto_out_aw_ready,
    output        auto_out_aw_valid,
    output [ 2:0] auto_out_aw_bits_id,
    output [30:0] auto_out_aw_bits_addr,
    output [ 7:0] auto_out_aw_bits_len,
    output [ 2:0] auto_out_aw_bits_size,
    output [ 1:0] auto_out_aw_bits_burst,
    output        auto_out_aw_bits_lock,
    output [ 3:0] auto_out_aw_bits_cache,
    output [ 2:0] auto_out_aw_bits_prot,
    output [ 3:0] auto_out_aw_bits_qos,
    output [ 3:0] auto_out_aw_bits_echo_tl_state_size,
    output [ 4:0] auto_out_aw_bits_echo_tl_state_source,
    input         auto_out_w_ready,
    output        auto_out_w_valid,
    output [63:0] auto_out_w_bits_data,
    output [ 7:0] auto_out_w_bits_strb,
    output        auto_out_w_bits_last,
    output        auto_out_b_ready,
    input         auto_out_b_valid,
    input  [ 2:0] auto_out_b_bits_id,
    input  [ 1:0] auto_out_b_bits_resp,
    input  [ 3:0] auto_out_b_bits_echo_tl_state_size,
    input  [ 4:0] auto_out_b_bits_echo_tl_state_source,
    input         auto_out_ar_ready,
    output        auto_out_ar_valid,
    output [ 2:0] auto_out_ar_bits_id,
    output [30:0] auto_out_ar_bits_addr,
    output [ 7:0] auto_out_ar_bits_len,
    output [ 2:0] auto_out_ar_bits_size,
    output [ 1:0] auto_out_ar_bits_burst,
    output        auto_out_ar_bits_lock,
    output [ 3:0] auto_out_ar_bits_cache,
    output [ 2:0] auto_out_ar_bits_prot,
    output [ 3:0] auto_out_ar_bits_qos,
    output [ 3:0] auto_out_ar_bits_echo_tl_state_size,
    output [ 4:0] auto_out_ar_bits_echo_tl_state_source,
    output        auto_out_r_ready,
    input         auto_out_r_valid,
    input  [ 2:0] auto_out_r_bits_id,
    input  [63:0] auto_out_r_bits_data,
    input  [ 1:0] auto_out_r_bits_resp,
    input  [ 3:0] auto_out_r_bits_echo_tl_state_size,
    input  [ 4:0] auto_out_r_bits_echo_tl_state_source,
    input         auto_out_r_bits_last
);
  wire monitor_clock;
  wire monitor_reset;
  wire monitor_io_in_a_ready;
  wire monitor_io_in_a_valid;
  wire [2:0] monitor_io_in_a_bits_opcode;
  wire [2:0] monitor_io_in_a_bits_param;
  wire [3:0] monitor_io_in_a_bits_size;
  wire [4:0] monitor_io_in_a_bits_source;
  wire [30:0] monitor_io_in_a_bits_address;
  wire [7:0] monitor_io_in_a_bits_mask;
  wire monitor_io_in_a_bits_corrupt;
  wire monitor_io_in_d_ready;
  wire monitor_io_in_d_valid;
  wire [2:0] monitor_io_in_d_bits_opcode;
  wire [3:0] monitor_io_in_d_bits_size;
  wire [4:0] monitor_io_in_d_bits_source;
  wire monitor_io_in_d_bits_denied;
  wire monitor_io_in_d_bits_corrupt;
  wire deq_clock;
  wire deq_reset;
  wire deq_io_enq_ready;
  wire deq_io_enq_valid;
  wire [63:0] deq_io_enq_bits_data;
  wire [7:0] deq_io_enq_bits_strb;
  wire deq_io_enq_bits_last;
  wire deq_io_deq_ready;
  wire deq_io_deq_valid;
  wire [63:0] deq_io_deq_bits_data;
  wire [7:0] deq_io_deq_bits_strb;
  wire deq_io_deq_bits_last;
  wire queue_arw_deq_clock;
  wire queue_arw_deq_reset;
  wire queue_arw_deq_io_enq_ready;
  wire queue_arw_deq_io_enq_valid;
  wire [2:0] queue_arw_deq_io_enq_bits_id;
  wire [30:0] queue_arw_deq_io_enq_bits_addr;
  wire [7:0] queue_arw_deq_io_enq_bits_len;
  wire [2:0] queue_arw_deq_io_enq_bits_size;
  wire [3:0] queue_arw_deq_io_enq_bits_cache;
  wire [2:0] queue_arw_deq_io_enq_bits_prot;
  wire [3:0] queue_arw_deq_io_enq_bits_echo_tl_state_size;
  wire [4:0] queue_arw_deq_io_enq_bits_echo_tl_state_source;
  wire queue_arw_deq_io_enq_bits_wen;
  wire queue_arw_deq_io_deq_ready;
  wire queue_arw_deq_io_deq_valid;
  wire [2:0] queue_arw_deq_io_deq_bits_id;
  wire [30:0] queue_arw_deq_io_deq_bits_addr;
  wire [7:0] queue_arw_deq_io_deq_bits_len;
  wire [2:0] queue_arw_deq_io_deq_bits_size;
  wire [1:0] queue_arw_deq_io_deq_bits_burst;
  wire queue_arw_deq_io_deq_bits_lock;
  wire [3:0] queue_arw_deq_io_deq_bits_cache;
  wire [2:0] queue_arw_deq_io_deq_bits_prot;
  wire [3:0] queue_arw_deq_io_deq_bits_qos;
  wire [3:0] queue_arw_deq_io_deq_bits_echo_tl_state_size;
  wire [4:0] queue_arw_deq_io_deq_bits_echo_tl_state_source;
  wire queue_arw_deq_io_deq_bits_wen;
  wire a_isPut = ~auto_in_a_bits_opcode[2];
  reg count_1;
  wire idle = ~count_1;
  reg count_4;
  wire idle_3 = ~count_4;
  reg count_5;
  wire idle_4 = ~count_5;
  reg [3:0] count_3;
  wire idle_2 = count_3 == 4'h0;
  reg write_2;
  wire mismatch_1 = write_2 != a_isPut;
  wire idStall_2 = ~idle_2 & mismatch_1 | count_3 == 4'h8;
  reg [3:0] count_2;
  wire idle_1 = count_2 == 4'h0;
  reg write_1;
  wire mismatch = write_1 != a_isPut;
  wire idStall_1 = ~idle_1 & mismatch | count_2 == 4'h8;
  wire _GEN_29 = 5'h8 == auto_in_a_bits_source ? idStall_2 : idStall_1;
  wire _GEN_30 = 5'h9 == auto_in_a_bits_source ? idStall_2 : _GEN_29;
  wire _GEN_31 = 5'ha == auto_in_a_bits_source ? idStall_2 : _GEN_30;
  wire _GEN_32 = 5'hb == auto_in_a_bits_source ? idStall_2 : _GEN_31;
  wire _GEN_33 = 5'hc == auto_in_a_bits_source ? idStall_2 : _GEN_32;
  wire _GEN_34 = 5'hd == auto_in_a_bits_source ? idStall_2 : _GEN_33;
  wire _GEN_35 = 5'he == auto_in_a_bits_source ? idStall_2 : _GEN_34;
  wire _GEN_36 = 5'hf == auto_in_a_bits_source ? idStall_2 : _GEN_35;
  wire _GEN_37 = 5'h10 == auto_in_a_bits_source ? count_5 : _GEN_36;
  wire _GEN_38 = 5'h11 == auto_in_a_bits_source ? count_4 : _GEN_37;
  wire _GEN_39 = 5'h12 == auto_in_a_bits_source ? count_1 : _GEN_38;
  reg [4:0] counter;
  wire a_first = counter == 5'h0;
  wire stall = _GEN_39 & a_first;
  wire _bundleIn_0_a_ready_T = ~stall;
  reg doneAW;
  wire out_arw_ready = queue_arw_deq_io_enq_ready;
  wire _bundleIn_0_a_ready_T_1 = doneAW | out_arw_ready;
  wire out_w_ready = deq_io_enq_ready;
  wire _bundleIn_0_a_ready_T_3 = a_isPut ? (doneAW | out_arw_ready) & out_w_ready : out_arw_ready;
  wire bundleIn_0_a_ready = ~stall & _bundleIn_0_a_ready_T_3;
  wire _T = bundleIn_0_a_ready & auto_in_a_valid;
  wire [22:0] _beats1_decode_T_1 = 23'hff << auto_in_a_bits_size;
  wire [7:0] _beats1_decode_T_3 = ~_beats1_decode_T_1[7:0];
  wire [4:0] beats1_decode = _beats1_decode_T_3[7:3];
  wire [4:0] beats1 = a_isPut ? beats1_decode : 5'h0;
  wire [4:0] counter1 = counter - 5'h1;
  wire a_last = counter == 5'h1 | beats1 == 5'h0;
  wire queue_arw_bits_wen = queue_arw_deq_io_deq_bits_wen;
  wire queue_arw_valid = queue_arw_deq_io_deq_valid;
  wire [2:0] _GEN_10 = 5'h8 == auto_in_a_bits_source ? 3'h2 : 3'h1;
  wire [2:0] _GEN_11 = 5'h9 == auto_in_a_bits_source ? 3'h2 : _GEN_10;
  wire [2:0] _GEN_12 = 5'ha == auto_in_a_bits_source ? 3'h2 : _GEN_11;
  wire [2:0] _GEN_13 = 5'hb == auto_in_a_bits_source ? 3'h2 : _GEN_12;
  wire [2:0] _GEN_14 = 5'hc == auto_in_a_bits_source ? 3'h2 : _GEN_13;
  wire [2:0] _GEN_15 = 5'hd == auto_in_a_bits_source ? 3'h2 : _GEN_14;
  wire [2:0] _GEN_16 = 5'he == auto_in_a_bits_source ? 3'h2 : _GEN_15;
  wire [2:0] _GEN_17 = 5'hf == auto_in_a_bits_source ? 3'h2 : _GEN_16;
  wire [2:0] _GEN_18 = 5'h10 == auto_in_a_bits_source ? 3'h4 : _GEN_17;
  wire [2:0] _GEN_19 = 5'h11 == auto_in_a_bits_source ? 3'h3 : _GEN_18;
  wire [2:0] out_arw_bits_id = 5'h12 == auto_in_a_bits_source ? 3'h0 : _GEN_19;
  wire [25:0] _out_arw_bits_len_T_1 = 26'h7ff << auto_in_a_bits_size;
  wire [10:0] _out_arw_bits_len_T_3 = ~_out_arw_bits_len_T_1[10:0];
  wire [3:0] _out_arw_bits_size_T_1 = auto_in_a_bits_size >= 4'h3 ? 4'h3 : auto_in_a_bits_size;
  wire prot_1 = ~auto_in_a_bits_user_amba_prot_secure;
  wire [1:0] out_arw_bits_prot_hi = {auto_in_a_bits_user_amba_prot_fetch, prot_1};
  wire [1:0] out_arw_bits_cache_lo = {
    auto_in_a_bits_user_amba_prot_modifiable, auto_in_a_bits_user_amba_prot_bufferable
  };
  wire [1:0] out_arw_bits_cache_hi = {
    auto_in_a_bits_user_amba_prot_writealloc, auto_in_a_bits_user_amba_prot_readalloc
  };
  wire _out_arw_valid_T_1 = _bundleIn_0_a_ready_T & auto_in_a_valid;
  wire _out_arw_valid_T_4 = a_isPut ? ~doneAW & out_w_ready : 1'h1;
  wire out_arw_valid = _bundleIn_0_a_ready_T & auto_in_a_valid & _out_arw_valid_T_4;
  reg r_holds_d;
  reg [2:0] b_delay;
  wire r_wins = auto_out_r_valid & b_delay != 3'h7 | r_holds_d;
  wire bundleOut_0_r_ready = auto_in_d_ready & r_wins;
  wire _T_2 = bundleOut_0_r_ready & auto_out_r_valid;
  wire bundleOut_0_b_ready = auto_in_d_ready & ~r_wins;
  wire [2:0] _b_delay_T_1 = b_delay + 3'h1;
  wire bundleIn_0_d_valid = r_wins ? auto_out_r_valid : auto_out_b_valid;
  reg r_first;
  wire _GEN_42 = _T_2 ? auto_out_r_bits_last : r_first;
  wire _r_denied_T = auto_out_r_bits_resp == 2'h3;
  reg r_denied_r;
  wire _GEN_43 = r_first ? _r_denied_T : r_denied_r;
  wire r_corrupt = auto_out_r_bits_resp != 2'h0;
  wire b_denied = auto_out_b_bits_resp != 2'h0;
  wire r_d_corrupt = r_corrupt | _GEN_43;
  wire [7:0] _a_sel_T = 8'h1 << out_arw_bits_id;
  wire a_sel_0 = _a_sel_T[0];
  wire a_sel_1 = _a_sel_T[1];
  wire a_sel_2 = _a_sel_T[2];
  wire a_sel_3 = _a_sel_T[3];
  wire a_sel_4 = _a_sel_T[4];
  wire [2:0] d_sel_shiftAmount = r_wins ? auto_out_r_bits_id : auto_out_b_bits_id;
  wire [7:0] _d_sel_T_1 = 8'h1 << d_sel_shiftAmount;
  wire d_sel_0 = _d_sel_T_1[0];
  wire d_sel_1 = _d_sel_T_1[1];
  wire d_sel_2 = _d_sel_T_1[2];
  wire d_sel_3 = _d_sel_T_1[3];
  wire d_sel_4 = _d_sel_T_1[4];
  wire d_last = r_wins ? auto_out_r_bits_last : 1'h1;
  wire _inc_T = out_arw_ready & out_arw_valid;
  wire inc = a_sel_0 & _inc_T;
  wire _dec_T_1 = auto_in_d_ready & bundleIn_0_d_valid;
  wire dec = d_sel_0 & d_last & _dec_T_1;
  wire _count_T_2 = count_1 + inc;
  wire _T_10 = ~reset;
  wire inc_1 = a_sel_1 & _inc_T;
  wire dec_1 = d_sel_1 & d_last & _dec_T_1;
  wire [3:0] _GEN_49 = {{3'd0}, inc_1};
  wire [3:0] _count_T_6 = count_2 + _GEN_49;
  wire [3:0] _GEN_50 = {{3'd0}, dec_1};
  wire [3:0] _count_T_8 = _count_T_6 - _GEN_50;
  wire inc_2 = a_sel_2 & _inc_T;
  wire dec_2 = d_sel_2 & d_last & _dec_T_1;
  wire [3:0] _GEN_51 = {{3'd0}, inc_2};
  wire [3:0] _count_T_10 = count_3 + _GEN_51;
  wire [3:0] _GEN_52 = {{3'd0}, dec_2};
  wire [3:0] _count_T_12 = _count_T_10 - _GEN_52;
  wire inc_3 = a_sel_3 & _inc_T;
  wire dec_3 = d_sel_3 & d_last & _dec_T_1;
  wire _count_T_14 = count_4 + inc_3;
  wire inc_4 = a_sel_4 & _inc_T;
  wire dec_4 = d_sel_4 & d_last & _dec_T_1;
  wire _count_T_18 = count_5 + inc_4;
  TLMonitor_4 monitor (
      .clock(monitor_clock),
      .reset(monitor_reset),
      .io_in_a_ready(monitor_io_in_a_ready),
      .io_in_a_valid(monitor_io_in_a_valid),
      .io_in_a_bits_opcode(monitor_io_in_a_bits_opcode),
      .io_in_a_bits_param(monitor_io_in_a_bits_param),
      .io_in_a_bits_size(monitor_io_in_a_bits_size),
      .io_in_a_bits_source(monitor_io_in_a_bits_source),
      .io_in_a_bits_address(monitor_io_in_a_bits_address),
      .io_in_a_bits_mask(monitor_io_in_a_bits_mask),
      .io_in_a_bits_corrupt(monitor_io_in_a_bits_corrupt),
      .io_in_d_ready(monitor_io_in_d_ready),
      .io_in_d_valid(monitor_io_in_d_valid),
      .io_in_d_bits_opcode(monitor_io_in_d_bits_opcode),
      .io_in_d_bits_size(monitor_io_in_d_bits_size),
      .io_in_d_bits_source(monitor_io_in_d_bits_source),
      .io_in_d_bits_denied(monitor_io_in_d_bits_denied),
      .io_in_d_bits_corrupt(monitor_io_in_d_bits_corrupt)
  );
  Queue_10 deq (
      .clock(deq_clock),
      .reset(deq_reset),
      .io_enq_ready(deq_io_enq_ready),
      .io_enq_valid(deq_io_enq_valid),
      .io_enq_bits_data(deq_io_enq_bits_data),
      .io_enq_bits_strb(deq_io_enq_bits_strb),
      .io_enq_bits_last(deq_io_enq_bits_last),
      .io_deq_ready(deq_io_deq_ready),
      .io_deq_valid(deq_io_deq_valid),
      .io_deq_bits_data(deq_io_deq_bits_data),
      .io_deq_bits_strb(deq_io_deq_bits_strb),
      .io_deq_bits_last(deq_io_deq_bits_last)
  );
  Queue_11 queue_arw_deq (
      .clock(queue_arw_deq_clock),
      .reset(queue_arw_deq_reset),
      .io_enq_ready(queue_arw_deq_io_enq_ready),
      .io_enq_valid(queue_arw_deq_io_enq_valid),
      .io_enq_bits_id(queue_arw_deq_io_enq_bits_id),
      .io_enq_bits_addr(queue_arw_deq_io_enq_bits_addr),
      .io_enq_bits_len(queue_arw_deq_io_enq_bits_len),
      .io_enq_bits_size(queue_arw_deq_io_enq_bits_size),
      .io_enq_bits_cache(queue_arw_deq_io_enq_bits_cache),
      .io_enq_bits_prot(queue_arw_deq_io_enq_bits_prot),
      .io_enq_bits_echo_tl_state_size(queue_arw_deq_io_enq_bits_echo_tl_state_size),
      .io_enq_bits_echo_tl_state_source(queue_arw_deq_io_enq_bits_echo_tl_state_source),
      .io_enq_bits_wen(queue_arw_deq_io_enq_bits_wen),
      .io_deq_ready(queue_arw_deq_io_deq_ready),
      .io_deq_valid(queue_arw_deq_io_deq_valid),
      .io_deq_bits_id(queue_arw_deq_io_deq_bits_id),
      .io_deq_bits_addr(queue_arw_deq_io_deq_bits_addr),
      .io_deq_bits_len(queue_arw_deq_io_deq_bits_len),
      .io_deq_bits_size(queue_arw_deq_io_deq_bits_size),
      .io_deq_bits_burst(queue_arw_deq_io_deq_bits_burst),
      .io_deq_bits_lock(queue_arw_deq_io_deq_bits_lock),
      .io_deq_bits_cache(queue_arw_deq_io_deq_bits_cache),
      .io_deq_bits_prot(queue_arw_deq_io_deq_bits_prot),
      .io_deq_bits_qos(queue_arw_deq_io_deq_bits_qos),
      .io_deq_bits_echo_tl_state_size(queue_arw_deq_io_deq_bits_echo_tl_state_size),
      .io_deq_bits_echo_tl_state_source(queue_arw_deq_io_deq_bits_echo_tl_state_source),
      .io_deq_bits_wen(queue_arw_deq_io_deq_bits_wen)
  );
  assign auto_in_a_ready = ~stall & _bundleIn_0_a_ready_T_3;
  assign auto_in_d_valid = r_wins ? auto_out_r_valid : auto_out_b_valid;
  assign auto_in_d_bits_opcode = r_wins ? 3'h1 : 3'h0;
  assign auto_in_d_bits_size = r_wins ? auto_out_r_bits_echo_tl_state_size : auto_out_b_bits_echo_tl_state_size;
  assign auto_in_d_bits_source = r_wins ? auto_out_r_bits_echo_tl_state_source : auto_out_b_bits_echo_tl_state_source;
  assign auto_in_d_bits_denied = r_wins ? _GEN_43 : b_denied;
  assign auto_in_d_bits_data = auto_out_r_bits_data;
  assign auto_in_d_bits_corrupt = r_wins & r_d_corrupt;
  assign auto_out_aw_valid = queue_arw_valid & queue_arw_bits_wen;
  assign auto_out_aw_bits_id = queue_arw_deq_io_deq_bits_id;
  assign auto_out_aw_bits_addr = queue_arw_deq_io_deq_bits_addr;
  assign auto_out_aw_bits_len = queue_arw_deq_io_deq_bits_len;
  assign auto_out_aw_bits_size = queue_arw_deq_io_deq_bits_size;
  assign auto_out_aw_bits_burst = queue_arw_deq_io_deq_bits_burst;
  assign auto_out_aw_bits_lock = queue_arw_deq_io_deq_bits_lock;
  assign auto_out_aw_bits_cache = queue_arw_deq_io_deq_bits_cache;
  assign auto_out_aw_bits_prot = queue_arw_deq_io_deq_bits_prot;
  assign auto_out_aw_bits_qos = queue_arw_deq_io_deq_bits_qos;
  assign auto_out_aw_bits_echo_tl_state_size = queue_arw_deq_io_deq_bits_echo_tl_state_size;
  assign auto_out_aw_bits_echo_tl_state_source = queue_arw_deq_io_deq_bits_echo_tl_state_source;
  assign auto_out_w_valid = deq_io_deq_valid;
  assign auto_out_w_bits_data = deq_io_deq_bits_data;
  assign auto_out_w_bits_strb = deq_io_deq_bits_strb;
  assign auto_out_w_bits_last = deq_io_deq_bits_last;
  assign auto_out_b_ready = auto_in_d_ready & ~r_wins;
  assign auto_out_ar_valid = queue_arw_valid & ~queue_arw_bits_wen;
  assign auto_out_ar_bits_id = queue_arw_deq_io_deq_bits_id;
  assign auto_out_ar_bits_addr = queue_arw_deq_io_deq_bits_addr;
  assign auto_out_ar_bits_len = queue_arw_deq_io_deq_bits_len;
  assign auto_out_ar_bits_size = queue_arw_deq_io_deq_bits_size;
  assign auto_out_ar_bits_burst = queue_arw_deq_io_deq_bits_burst;
  assign auto_out_ar_bits_lock = queue_arw_deq_io_deq_bits_lock;
  assign auto_out_ar_bits_cache = queue_arw_deq_io_deq_bits_cache;
  assign auto_out_ar_bits_prot = queue_arw_deq_io_deq_bits_prot;
  assign auto_out_ar_bits_qos = queue_arw_deq_io_deq_bits_qos;
  assign auto_out_ar_bits_echo_tl_state_size = queue_arw_deq_io_deq_bits_echo_tl_state_size;
  assign auto_out_ar_bits_echo_tl_state_source = queue_arw_deq_io_deq_bits_echo_tl_state_source;
  assign auto_out_r_ready = auto_in_d_ready & r_wins;
  assign monitor_clock = clock;
  assign monitor_reset = reset;
  assign monitor_io_in_a_ready = ~stall & _bundleIn_0_a_ready_T_3;
  assign monitor_io_in_a_valid = auto_in_a_valid;
  assign monitor_io_in_a_bits_opcode = auto_in_a_bits_opcode;
  assign monitor_io_in_a_bits_param = auto_in_a_bits_param;
  assign monitor_io_in_a_bits_size = auto_in_a_bits_size;
  assign monitor_io_in_a_bits_source = auto_in_a_bits_source;
  assign monitor_io_in_a_bits_address = auto_in_a_bits_address;
  assign monitor_io_in_a_bits_mask = auto_in_a_bits_mask;
  assign monitor_io_in_a_bits_corrupt = auto_in_a_bits_corrupt;
  assign monitor_io_in_d_ready = auto_in_d_ready;
  assign monitor_io_in_d_valid = r_wins ? auto_out_r_valid : auto_out_b_valid;
  assign monitor_io_in_d_bits_opcode = r_wins ? 3'h1 : 3'h0;
  assign monitor_io_in_d_bits_size = r_wins ? auto_out_r_bits_echo_tl_state_size : auto_out_b_bits_echo_tl_state_size;
  assign monitor_io_in_d_bits_source = r_wins ? auto_out_r_bits_echo_tl_state_source :
    auto_out_b_bits_echo_tl_state_source;
  assign monitor_io_in_d_bits_denied = r_wins ? _GEN_43 : b_denied;
  assign monitor_io_in_d_bits_corrupt = r_wins & r_d_corrupt;
  assign deq_clock = clock;
  assign deq_reset = reset;
  assign deq_io_enq_valid = _out_arw_valid_T_1 & a_isPut & _bundleIn_0_a_ready_T_1;
  assign deq_io_enq_bits_data = auto_in_a_bits_data;
  assign deq_io_enq_bits_strb = auto_in_a_bits_mask;
  assign deq_io_enq_bits_last = counter == 5'h1 | beats1 == 5'h0;
  assign deq_io_deq_ready = auto_out_w_ready;
  assign queue_arw_deq_clock = clock;
  assign queue_arw_deq_reset = reset;
  assign queue_arw_deq_io_enq_valid = _bundleIn_0_a_ready_T & auto_in_a_valid & _out_arw_valid_T_4;
  assign queue_arw_deq_io_enq_bits_id = 5'h12 == auto_in_a_bits_source ? 3'h0 : _GEN_19;
  assign queue_arw_deq_io_enq_bits_addr = auto_in_a_bits_address;
  assign queue_arw_deq_io_enq_bits_len = _out_arw_bits_len_T_3[10:3];
  assign queue_arw_deq_io_enq_bits_size = _out_arw_bits_size_T_1[2:0];
  assign queue_arw_deq_io_enq_bits_cache = {out_arw_bits_cache_hi, out_arw_bits_cache_lo};
  assign queue_arw_deq_io_enq_bits_prot = {
    out_arw_bits_prot_hi, auto_in_a_bits_user_amba_prot_privileged
  };
  assign queue_arw_deq_io_enq_bits_echo_tl_state_size = auto_in_a_bits_size;
  assign queue_arw_deq_io_enq_bits_echo_tl_state_source = auto_in_a_bits_source;
  assign queue_arw_deq_io_enq_bits_wen = ~auto_in_a_bits_opcode[2];
  assign queue_arw_deq_io_deq_ready = queue_arw_bits_wen ? auto_out_aw_ready : auto_out_ar_ready;
  always @(posedge clock) begin
    if (reset) begin
      count_1 <= 1'h0;
    end else begin
      count_1 <= _count_T_2 - dec;
    end
    if (reset) begin
      count_4 <= 1'h0;
    end else begin
      count_4 <= _count_T_14 - dec_3;
    end
    if (reset) begin
      count_5 <= 1'h0;
    end else begin
      count_5 <= _count_T_18 - dec_4;
    end
    if (reset) begin
      count_3 <= 4'h0;
    end else begin
      count_3 <= _count_T_12;
    end
    if (inc_2) begin
      write_2 <= a_isPut;
    end
    if (reset) begin
      count_2 <= 4'h0;
    end else begin
      count_2 <= _count_T_8;
    end
    if (inc_1) begin
      write_1 <= a_isPut;
    end
    if (reset) begin
      counter <= 5'h0;
    end else if (_T) begin
      if (a_first) begin
        if (a_isPut) begin
          counter <= beats1_decode;
        end else begin
          counter <= 5'h0;
        end
      end else begin
        counter <= counter1;
      end
    end
    if (reset) begin
      doneAW <= 1'h0;
    end else if (_T) begin
      doneAW <= ~a_last;
    end
    if (reset) begin
      r_holds_d <= 1'h0;
    end else if (_T_2) begin
      r_holds_d <= ~auto_out_r_bits_last;
    end
    if (auto_out_b_valid & ~bundleOut_0_b_ready) begin
      b_delay <= _b_delay_T_1;
    end else begin
      b_delay <= 3'h0;
    end
    r_first <= reset | _GEN_42;
    if (r_first) begin
      r_denied_r <= _r_denied_T;
    end
  end
endmodule

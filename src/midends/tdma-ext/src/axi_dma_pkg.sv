// Copyright (c) 2019 ETH Zurich, University of Bologna
// All rights reserved.
//
// This code is under development and not yet released to the public.
// Until it is released, the code is under the copyright of ETH Zurich and
// the University of Bologna, and may contain confidential and/or unpublished
// work. Any reuse/redistribution is strictly forbidden without written
// permission from ETH Zurich.
//
// Thomas Benz <tbenz@ethz.ch>

// for now this is an extended copy of the axi_pkg
// eventually the DMA specific parts should be moved in axi_pkg aswell
package axi_dma_pkg; 

  typedef logic [1:0] burst_t;
  typedef logic [1:0] resp_t;
  typedef logic [3:0] cache_t;
  typedef logic [2:0] prot_t;
  typedef logic [3:0] qos_t;
  typedef logic [3:0] region_t;
  typedef logic [7:0] len_t;
  typedef logic [2:0] size_t;
  typedef logic [5:0] atop_t; // atomic operations
  typedef logic [3:0] nsaid_t; // non-secure address identifier

  localparam BURST_FIXED = 2'b00;
  localparam BURST_INCR  = 2'b01;
  localparam BURST_WRAP  = 2'b10;

  localparam RESP_OKAY   = 2'b00;
  localparam RESP_EXOKAY = 2'b01;
  localparam RESP_SLVERR = 2'b10;
  localparam RESP_DECERR = 2'b11;

  localparam CACHE_BUFFERABLE = 4'b0001;
  localparam CACHE_MODIFIABLE = 4'b0010;
  localparam CACHE_RD_ALLOC   = 4'b0100;
  localparam CACHE_WR_ALLOC   = 4'b1000;

  // ATOP[5:0]
  localparam ATOP_ATOMICSWAP  = 6'b110000;
  localparam ATOP_ATOMICCMP   = 6'b110001;
  // ATOP[5:4]
  localparam ATOP_NONE        = 2'b00;
  localparam ATOP_ATOMICSTORE = 2'b01;
  localparam ATOP_ATOMICLOAD  = 2'b10;
  // ATOP[3]
  localparam ATOP_LITTLE_END  = 1'b0;
  localparam ATOP_BIG_END     = 1'b1;
  // ATOP[2:0]
  localparam ATOP_ADD   = 3'b000;
  localparam ATOP_CLR   = 3'b001;
  localparam ATOP_EOR   = 3'b010;
  localparam ATOP_SET   = 3'b011;
  localparam ATOP_SMAX  = 3'b100;
  localparam ATOP_SMIN  = 3'b101;
  localparam ATOP_UMAX  = 3'b110;
  localparam ATOP_UMIN  = 3'b111;

  // 4 is recommended by AXI standard, so lets stick to it, do not change
  localparam IdWidth   = 4;
  localparam UserWidth = 1;
  localparam AddrWidth = 64;
  localparam DataWidth = 512;
  localparam StrbWidth = DataWidth / 8;

  typedef logic [IdWidth-1:0]   id_t;
  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [DataWidth-1:0] data_t;
  typedef logic [StrbWidth-1:0] strb_t;
  typedef logic [UserWidth-1:0] user_t;

  // DMA
  localparam OffsetWidth = $clog2(StrbWidth);
  typedef logic [OffsetWidth-1:0] offset_t;
  typedef logic [            7:0] beatlen_t;

  // localparam TransIdWidth = 32;
  // typedef logic [TransIdWidth-1:0] trans_id_t;

  // AW Channel
  typedef struct packed {
      id_t     id;
      addr_t   addr;
      len_t    len;
      size_t   size;
      burst_t  burst;
      logic    lock;
      cache_t  cache;
      prot_t   prot;
      qos_t    qos;
      region_t region;
      atop_t   atop;
  } aw_chan_t;

  // W Channel
  typedef struct packed {
      data_t data;
      strb_t strb;
      logic  last;
  } w_chan_t;

  // B Channel
  typedef struct packed {
      id_t   id;
      resp_t resp;
  } b_chan_t;

  // AR Channel
  typedef struct packed {
      id_t     id;
      addr_t   addr;
      len_t    len;
      size_t   size;
      burst_t  burst;
      logic    lock;
      cache_t  cache;
      prot_t   prot;
      qos_t    qos;
      region_t region;
  } ar_chan_t;

  // R Channel
  typedef struct packed {
      id_t   id;
      data_t data;
      resp_t resp;
      logic  last;
  } r_chan_t;

  // Request/Response structs
  typedef struct packed {
      aw_chan_t aw;
      logic     aw_valid;
      w_chan_t  w;
      logic     w_valid;
      logic     b_ready;
      ar_chan_t ar;
      logic     ar_valid;
      logic     r_ready;
  } req_t;

  typedef struct packed {
      logic     aw_ready;
      logic     ar_ready;
      logic     w_ready;
      logic     b_valid;
      b_chan_t  b;
      logic     r_valid;
      r_chan_t  r;
  } res_t;

  // DMA 
  typedef struct packed {
      id_t       id;
      logic      last;
      addr_t     addr;
      len_t      len;
      size_t     size;
      burst_t    burst;
      cache_t    cache;
  } desc_ax_t;

  typedef struct packed {
      offset_t offset;
      offset_t tailer;
      offset_t shift;
  } desc_r_t;

  typedef struct packed {
      offset_t  offset;
      offset_t  tailer;
      beatlen_t num_beats;
      logic     is_single;
  } desc_w_t;

  typedef struct packed {
      desc_ax_t aw;
      desc_w_t  w;
  } write_req_t;

  typedef struct packed {
      desc_ax_t ar;
      desc_r_t  r;
  } read_req_t;

  typedef struct packed {
      id_t       id;
      addr_t     addr;
      addr_t     num_bytes;
      cache_t    cache;
      burst_t    burst;
      logic      valid;
  } burst_chan_t;

  typedef struct packed {
      burst_chan_t src;
      burst_chan_t dst;
      offset_t     shift;
      logic        decouple_rw;
      logic        deburst;
  } burst_decoupled_t;

  typedef struct packed {
      id_t       id;
      addr_t     src, dst, num_bytes;
      cache_t    cache_src, cache_dst;
      burst_t    burst_src, burst_dst;
      logic      decouple_rw;
      logic      deburst;
  } burst_req_t;

  typedef struct packed {
      id_t       id;
      addr_t     src, dst, num_bytes;
      cache_t    cache_src, cache_dst;
      addr_t     stride_src, stride_dst, num_repetitions;
      burst_t    burst_src, burst_dst;
      logic      decouple_rw;
      logic      deburst;
      logic      is_twod;
  } twod_req_t;

  typedef struct packed {
      logic [63:0] aw_stall_cnt, ar_stall_cnt, r_stall_cnt, w_stall_cnt, buf_w_stall_cnt, buf_r_stall_cnt;
      logic [63:0] aw_valid_cnt, aw_ready_cnt, aw_done_cnt, aw_bw;
      logic [63:0] ar_valid_cnt, ar_ready_cnt, ar_done_cnt, ar_bw;
      logic [63:0]  r_valid_cnt,  r_ready_cnt,  r_done_cnt,  r_bw;
      logic [63:0]  w_valid_cnt,  w_ready_cnt,  w_done_cnt,  w_bw;
      logic [63:0]  b_valid_cnt,  b_ready_cnt,  b_done_cnt;
      logic [63:0] next_id,       completed_id;
      logic [63:0] dma_busy_cnt;
  } dma_perf_t;

  localparam NUM_DMA_PERF_REGS = 28;

endpackage

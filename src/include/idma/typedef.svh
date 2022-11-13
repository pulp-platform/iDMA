// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@ethz.ch>

// Macros to define iDMA structs

`ifndef IDMA_TYPEDEF_SVH_
`define IDMA_TYPEDEF_SVH_

////////////////////////////////////////////////////////////////////////////////////////////////////
// iDMA Request and Response Structs
//
// Usage Example:
// `IDMA_TYPEDEF_OPTIONS_T(options_t, axi_id_t)
// `IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, axi_addr_t)
// `IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, axi_addr_t, options_t)
// `IDMA_TYPEDEF_RSP_T(idma_rsp_t, err_payload_t)
`define IDMA_TYPEDEF_OPTIONS_T(options_t, axi_id_t)                      \
    typedef struct packed {                                              \
        idma_pkg::protocol_e        src_protocol;                        \
        idma_pkg::protocol_e        dst_protocol;                        \
        axi_id_t                    axi_id;                              \
        idma_pkg::axi_options_t     src;                                 \
        idma_pkg::axi_options_t     dst;                                 \
        idma_pkg::backend_options_t beo;                                 \
        logic                       last;                                \
    } options_t;
`define IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, axi_addr_t)            \
    typedef struct packed {                                              \
        axi_pkg::resp_t      cause;                                      \
        idma_pkg::err_type_t err_type;                                   \
        axi_addr_t           burst_addr;                                 \
    } err_payload_t;
`define IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, axi_addr_t, options_t)  \
    typedef struct packed {                                              \
        tf_len_t   length;                                               \
        axi_addr_t src_addr;                                             \
        axi_addr_t dst_addr;                                             \
        options_t  opt;                                                  \
    } idma_req_t;
`define IDMA_TYPEDEF_RSP_T(idma_rsp_t, err_payload_t)                    \
    typedef struct packed {                                              \
        logic         last;                                              \
        logic         error;                                             \
        err_payload_t pld;                                               \
    } idma_rsp_t;
////////////////////////////////////////////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////////////////////////////////////////////
// iDMA Full Request and Response Structs
//
// Usage Example:
// `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_id_t, axi_addr_t, tf_len_t)
// `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, axi_addr_t)
`define IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, axi_id_t, axi_addr_t, tf_len_t) \
    `IDMA_TYPEDEF_OPTIONS_T(options_t, axi_id_t)                            \
    `IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, axi_addr_t, options_t)
`define IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, axi_addr_t)                     \
    `IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, axi_addr_t)                  \
    `IDMA_TYPEDEF_RSP_T(idma_rsp_t, err_payload_t)
////////////////////////////////////////////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////////////////////////////////////////////
// iDMA n-dimensional Request Struct
//
// Usage Example:
// `IDMA_TYPEDEF_D_REQ_T(idma_d_req_t, reps_t, strides_t)
// `IDMA_TYPEDEF_ND_REQ_T(idma_nd_req_t, idma_req_t, idma_d_req_t)
`define IDMA_TYPEDEF_D_REQ_T(idma_d_req_t, reps_t, strides_t)            \
    typedef struct packed {                                              \
        reps_t    reps;                                                  \
        strides_t src_strides;                                           \
        strides_t dst_strides;                                           \
    } idma_d_req_t;
`define IDMA_TYPEDEF_ND_REQ_T(idma_nd_req_t, idma_req_t, idma_d_req_t)   \
    typedef struct packed {                                              \
        idma_req_t                burst_req;                             \
        idma_d_req_t [NumDim-2:0] d_req;                                 \
    } idma_nd_req_t;
////////////////////////////////////////////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////////////////////////////////////////////
// iDMA Full n-dimensional Request Struct
//
// Usage Example:
// `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)
`define IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t) \
    `IDMA_TYPEDEF_D_REQ_T(idma_d_req_t, reps_t, strides_t)                       \
    `IDMA_TYPEDEF_ND_REQ_T(idma_nd_req_t, idma_req_t, idma_d_req_t)
////////////////////////////////////////////////////////////////////////////////////////////////////

`define IDMA_OBI_TYPEDEF_A_CHAN_T(a_chan_t, addr_t, data_t, strb_t, id_t) \
  typedef struct packed {                                           \
    addr_t addr;                                                    \
    logic  we;                                                      \
    strb_t be;                                                      \
    data_t wdata;                                                   \
    id_t   aid;                                                     \
  } a_chan_t;

`define IDMA_OBI_TYPEDEF_R_CHAN_T(r_chan_t, data_t, id_t) \
  typedef struct packed {                           \
    data_t rdata;                                   \
    id_t   rid;                                     \
  } r_chan_t;

`define IDMA_OBI_TYPEDEF_REQ_T(req_t, a_chan_t) \
  typedef struct packed {                       \
    a_chan_t a;                                 \
    logic    a_req;                             \
    logic    r_ready;                           \
  } req_t;

`define IDMA_OBI_TYPEDEF_RESP_T(resp_t, r_chan_t) \
  typedef struct packed {                         \
    logic    a_gnt;                               \
    r_chan_t r;                                   \
    logic    r_valid;                             \
  } resp_t;

`define IDMA_TILELINK_TYPEDEF_A_CHAN_T(a_chan_t, addr_t, data_t, mask_t, size_t, source_t) \
  typedef struct packed { \
    logic [2:0] opcode;   \
    logic [2:0] param;    \
    size_t      size;     \
    source_t    source;   \
    addr_t      address;  \
    mask_t      mask;     \
    data_t      data;     \
    logic       corrupt;  \
  } a_chan_t;

`define IDMA_TILELINK_TYPEDEF_D_CHAN_T(d_chan_t, data_t, size_t, source_t, sink_t) \
  typedef struct packed { \
    logic [2:0] opcode;   \
    logic [1:0] param;    \
    size_t      size;     \
    source_t    source;   \
    sink_t      sink;     \
    logic       denied;   \
    data_t      data;     \
    logic       corrupt;  \
  } d_chan_t;

`define IDMA_TILELINK_TYPEDEF_REQ_T(req_t, a_chan_t) \
  typedef struct packed { \
    a_chan_t a;           \
    logic    a_valid;     \
    logic    d_ready;     \
  } req_t;

`define IDMA_TILELINK_TYPEDEF_RSP_T(rsp_t, d_chan_t) \
  typedef struct packed { \
    d_chan_t d;           \
    logic    d_valid;     \
    logic    a_ready;     \
  } rsp_t;

`define IDMA_AXI_STREAM_TYPEDEF_S_CHAN_T(s_chan_t, tdata_t, tstrb_t, tkeep_t, tid_t, tdest_t, tuser_t) \
  typedef struct packed {                                                                         \
    tdata_t data;                                                                                 \
    tstrb_t strb;                                                                                 \
    tkeep_t keep;                                                                                 \
    logic   last;                                                                                 \
    tid_t   id;                                                                                   \
    tdest_t dest;                                                                                 \
    tuser_t user;                                                                                 \
  } s_chan_t;

`define IDMA_AXI_STREAM_TYPEDEF_REQ_T(req_stream_t, s_chan_t) \
  typedef struct packed {                                \
    s_chan_t            t;                               \
    logic               tvalid;                          \
  } req_stream_t;

`define IDMA_AXI_STREAM_TYPEDEF_RSP_T(rsp_stream_t) \
  typedef struct packed {                      \
    logic                tready;               \
  } rsp_stream_t;

`endif

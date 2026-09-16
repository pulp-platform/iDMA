// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

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
        idma_pkg::multihead_t       src_head;                            \
        idma_pkg::multihead_t       dst_head;                            \
        axi_id_t                    axi_id;                              \
        idma_pkg::axi_options_t     src;                                 \
        idma_pkg::axi_options_t     dst;                                 \
        idma_pkg::backend_options_t   beo;                               \
        idma_pkg::compute_options_t   compute;                           \
        logic                         last;                              \
    } options_t;
`define IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, axi_addr_t)            \
    typedef struct packed {                                              \
        axi_pkg::resp_t      cause;                                      \
        idma_pkg::err_type_t err_type;                                   \
        axi_addr_t           burst_addr;                                 \
    } err_payload_t;
`define IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, axi_addr_t, options_t, user_t = logic)  \
    typedef struct packed {                                              \
        tf_len_t   length;                                               \
        axi_addr_t src_addr;                                             \
        axi_addr_t dst_addr;                                             \
        user_t     user;                                                 \
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

////////////////////////////////////////////////////////////////////////////////////////////////////
// iDMA INIT Protocol Channel Structs
//
// INIT has no external protocol repository, so iDMA owns its channel definitions. Integrators
// instantiating an INIT-capable backend or the inst64 frontend need these to fill the corresponding
// parameter types.
//
// The *_STRUCT variants are anonymous, for use in a localparam type parameter list.
//
// Usage Example:
// `IDMA_TYPEDEF_INIT_ALL(init, AddrWidth, DataWidth, StrbWidth, AxiIdWidth)
`define IDMA_INIT_REQ_CHAN_STRUCT(__addr_w, __data_w, __strb_w, __id_w)  \
    struct packed {                                                      \
        logic [(__addr_w)-1:0] cfg;                                      \
        logic [(__data_w)-1:0] term;                                     \
        logic [(__strb_w)-1:0] strb;                                     \
        logic [(__id_w)-1:0] id;                                         \
    }
`define IDMA_INIT_RSP_CHAN_STRUCT(__data_w)                              \
    struct packed {                                                      \
        logic [(__data_w)-1:0] init;                                     \
    }
`define IDMA_INIT_REQ_STRUCT(__chan_t)                                   \
    struct packed {                                                      \
        __chan_t req_chan;                                               \
        logic    req_valid;                                              \
        logic    rsp_ready;                                              \
    }
`define IDMA_INIT_RSP_STRUCT(__chan_t)                                   \
    struct packed {                                                      \
        __chan_t rsp_chan;                                               \
        logic    rsp_valid;                                              \
        logic    req_ready;                                              \
    }
`define IDMA_TYPEDEF_INIT_REQ_CHAN_T(__chan_t, __addr_w, __data_w, __strb_w, __id_w) \
    typedef `IDMA_INIT_REQ_CHAN_STRUCT(__addr_w, __data_w, __strb_w, __id_w) __chan_t;
`define IDMA_TYPEDEF_INIT_RSP_CHAN_T(__chan_t, __data_w) \
    typedef `IDMA_INIT_RSP_CHAN_STRUCT(__data_w) __chan_t;
`define IDMA_TYPEDEF_INIT_REQ_T(__req_t, __chan_t) \
    typedef `IDMA_INIT_REQ_STRUCT(__chan_t) __req_t;
`define IDMA_TYPEDEF_INIT_RSP_T(__rsp_t, __chan_t) \
    typedef `IDMA_INIT_RSP_STRUCT(__chan_t) __rsp_t;
////////////////////////////////////////////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////////////////////////////////////////////
// iDMA Full INIT Protocol Structs
//
// Usage Example:
// `IDMA_TYPEDEF_INIT_ALL(init, AddrWidth, DataWidth, StrbWidth, AxiIdWidth)
`define IDMA_TYPEDEF_INIT_ALL(__name, __addr_w, __data_w, __strb_w, __id_w)             \
    `IDMA_TYPEDEF_INIT_REQ_CHAN_T(__name``_req_chan_t, __addr_w, __data_w, __strb_w, __id_w) \
    `IDMA_TYPEDEF_INIT_RSP_CHAN_T(__name``_rsp_chan_t, __data_w)                        \
    `IDMA_TYPEDEF_INIT_REQ_T(__name``_req_t, __name``_req_chan_t)                       \
    `IDMA_TYPEDEF_INIT_RSP_T(__name``_rsp_t, __name``_rsp_chan_t)
////////////////////////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////////////////////////
// iDMA inst64 Event Struct
//
// The inst64 frontend drives every member from idma_inst64_events; integrators only count them.
//
// Usage Example:
// `IDMA_TYPEDEF_EVENTS_T(dma_events_t, DataWidth)
`define IDMA_TYPEDEF_EVENTS_T(__events_t, __data_w)                      \
    typedef struct packed {                                              \
        logic           aw_valid, aw_ready, aw_done, aw_stall;           \
        axi_pkg::len_t  aw_len;                                          \
        axi_pkg::size_t aw_size;                                         \
        logic           ar_valid, ar_ready, ar_done, ar_stall;           \
        axi_pkg::len_t  ar_len;                                          \
        axi_pkg::size_t ar_size;                                         \
        logic           r_valid, r_ready, r_done, r_bw, r_stall, buf_r_stall; \
        logic           w_valid, w_ready, w_done, w_stall, buf_w_stall;  \
        logic [$clog2((__data_w)/8):0] num_bytes_written;                \
        logic           b_valid, b_ready, b_done;                        \
        logic           obi_wr_req, obi_rd_req;                          \
        logic           dma_busy;                                        \
    } __events_t;
////////////////////////////////////////////////////////////////////////////////////////////////////

`endif

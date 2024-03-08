// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Tobias Senti <tsenti@ethz.ch>

// Macros to define Tilelink structs

`ifndef TILELINK_TYPEDEF_SVH_
`define TILELINK_TYPEDEF_SVH_

////////////////////////////////////////////////////////////////////////////////////////////////////
`define TILELINK_TYPEDEF_A_CHAN_T(a_chan_t, addr_t, data_t, mask_t, size_t, source_t) \
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

`define TILELINK_TYPEDEF_D_CHAN_T(d_chan_t, data_t, size_t, source_t, sink_t) \
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

`define TILELINK_TYPEDEF_REQ_T(req_t, a_chan_t) \
  typedef struct packed { \
    a_chan_t a;           \
    logic    a_valid;     \
    logic    d_ready;     \
  } req_t;

`define TILELINK_TYPEDEF_RSP_T(rsp_t, d_chan_t) \
  typedef struct packed { \
    d_chan_t d;           \
    logic    d_valid;     \
    logic    a_ready;     \
  } rsp_t;
////////////////////////////////////////////////////////////////////////////////////////////////////

`endif

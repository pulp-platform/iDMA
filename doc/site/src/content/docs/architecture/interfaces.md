---
title: Interfaces and Types
description: Request, response, and option structs used across iDMA layers.
---

## Overview

This page is the reference for `idma_req_t`, `options_t`, and `idma_rsp_t`. Use it when writing drivers or connecting custom frontends. For integration, prefer the convenience macros from `typedef.svh`.

## Transfer Request (`idma_req_t`)

The request carries addresses, transfer length, and options that control protocol and backend behavior.

```verilog
`IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, axi_addr_t, options_t)
// Expands to:
typedef struct packed {
    tf_len_t   length;    // Transfer length in bytes
    axi_addr_t src_addr;  // Source byte address
    axi_addr_t dst_addr;  // Destination byte address
    user_t     user;      // User-defined sideband data
    options_t  opt;       // Transfer options
} idma_req_t;
```

## Transfer Options (`options_t`)

Transfer options select protocols and carry sideband signals. Each request embeds one `options_t`.

```verilog
`IDMA_TYPEDEF_OPTIONS_T(options_t, axi_id_t)
// Expands to:
typedef struct packed {
    idma_pkg::protocol_e        src_protocol;  // Source bus protocol
    idma_pkg::protocol_e        dst_protocol;  // Destination bus protocol
    axi_id_t                    axi_id;        // AXI transaction ID
    idma_pkg::axi_options_t     src;           // Source AXI options
    idma_pkg::axi_options_t     dst;           // Destination AXI options
    idma_pkg::backend_options_t beo;           // Backend engine options
    logic                       last;          // Last transfer flag (for midend)
} options_t;
```

## Transfer Response (`idma_rsp_t`)

The response indicates completion and error status for a transfer.

```verilog
`IDMA_TYPEDEF_RSP_T(idma_rsp_t, err_payload_t)
// Expands to:
typedef struct packed {
    logic         last;   // Last response for this ND transfer
    logic         error;  // Error occurred
    err_payload_t pld;    // Error details (cause, type, address)
} idma_rsp_t;
```

## Error Payload (`err_payload_t`)

The error payload identifies the faulting burst and its origin.

```verilog
`IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, axi_addr_t)
// Expands to:
typedef struct packed {
    axi_pkg::resp_t      cause;      // AXI response code
    idma_pkg::err_type_t err_type;   // Error source (BUS_READ, BUS_WRITE, BACKEND, ND_MIDEND)
    axi_addr_t           burst_addr; // Address of the faulting burst
} err_payload_t;
```

## Handshake Semantics

All request and response interfaces use ready/valid handshaking. A transfer is accepted when `req_valid_i` and `req_ready_o` are both high in the same cycle. A response is accepted when `rsp_valid_o` and `rsp_ready_i` are both high.

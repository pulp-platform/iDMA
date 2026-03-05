---
title: Quickstart
description: Minimal steps to integrate iDMA and run a transfer.
---

## Overview

This guide shows the shortest path to an end-to-end iDMA transfer: choose a backend, define types, wire modules, and launch a request. It assumes a single clock domain and a 1D transfer flow.

## 1. Choose a Backend Variant

Pick the backend variant that matches your read/write protocols. For AXI-to-AXI systems, start with `rw_axi`.

## 2. Define Types

Use the `typedef.svh` macros to define the request/response structs you will wire between layers.

```verilog
`include "idma/typedef.svh"

typedef logic [AddrWidth-1:0]   addr_t;
typedef logic [DataWidth-1:0]   data_t;
typedef logic [IdWidth-1:0]     id_t;
typedef logic [TFLenWidth-1:0]  tf_len_t;

`IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
`IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
```

## 3. Instantiate the Backend

Instantiate the backend and connect the request/response handshake. The exact bus ports depend on the backend variant.

```verilog
idma_backend_rw_axi #(
    .DataWidth   ( DataWidth  ),
    .AddrWidth   ( AddrWidth  ),
    .idma_req_t  ( idma_req_t ),
    .idma_rsp_t  ( idma_rsp_t ),
    .axi_req_t   ( axi_req_t  ),
    .axi_rsp_t   ( axi_rsp_t  )
) i_backend (
    .clk_i,
    .rst_ni,
    .idma_req_i   ( dma_req   ),
    .req_valid_i  ( req_valid ),
    .req_ready_o  ( req_ready ),
    .idma_rsp_o   ( dma_rsp   ),
    .rsp_valid_o  ( rsp_valid ),
    .rsp_ready_i  ( rsp_ready )
    // ... bus ports ...
);
```

## 4. Submit a Transfer

A frontend produces `idma_req_t`. If you do not use a frontend, you can drive the request directly from a testbench or a custom control block.

## 5. Observe Completion

The backend produces one `idma_rsp_t` per completed transfer. Check `error` and `err_payload_t` to determine whether the transfer succeeded.

## Next Steps

- For a full integration recipe, see [System Integration](../system-integration/).
- For ND transfers, see [Programming Model](../../architecture/programming-model/).

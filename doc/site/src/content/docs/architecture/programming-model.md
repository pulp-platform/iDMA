---
title: Programming Model
description: How requests flow through frontend, midend, and backend.
---

## Model Overview

iDMA’s programming model centers on a request/response contract. Frontends emit `idma_req_t` (or `idma_nd_req_t`), the backend executes the transfer, and the response `idma_rsp_t` signals completion or error.

:::note[Figure placeholder]
Diagram: request lifecycle showing frontend submit, optional ND decomposition, backend legalizer/transport, and response path back to software.
:::

## 1D Transfers

A 1D transfer copies a contiguous byte range from `src_addr` to `dst_addr`. It is the native backend format. If you submit 1D requests, you can bypass the midend entirely.

## ND Transfers

ND transfers (2D/3D) are decomposed into a series of 1D transfers by the midend. Each dimension defines a repetition count and stride. The midend emits a stream of 1D bursts while preserving ordering and optional error semantics.

## Request Lifecycle

1. Frontend validates inputs and forms a request.
2. Midend (optional) expands ND into 1D.
3. Backend legalizer splits into protocol-legal bursts.
4. Transport layer executes bus reads/writes and realigns data.
5. Response is emitted when all bursts complete.

## Error Handling Choices

Error handling is a policy decision. The backend can be configured to continue on error, abort a transfer, or replay. Frontends interpret responses and decide how to recover. See [Error Handling](../../guides/error-handling/) for policies and software handling patterns.

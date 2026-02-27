---
title: Register Frontend
description: Memory-mapped register interface for submitting DMA transfers.
---

## Overview

The register frontend (`idma_reg64_2d`) exposes a standard memory-mapped register file through which software configures and launches DMA transfers. It connects via the PULP register interface and is the most common frontend for general-purpose SoCs. The module is generated from `src/frontend/reg/tpl/idma_reg.sv.tpl`.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NumRegs` | 1 | Number of configuration register ports (parallel access points) |
| `NumStreams` | 1 | Number of independent DMA streams (max 16). Each stream has its own transfer ID counter |
| `IdCounterWidth` | 32 | Width of the transfer ID counter (max 32-bit) |

## Register Map

The register file exposes the following key fields (accessible per register port):

| Register | Access | Description |
|----------|--------|-------------|
| `src_addr` | R/W | Source address for the next transfer |
| `dst_addr` | R/W | Destination address for the next transfer |
| `num_bytes` | R/W | Transfer length in bytes |
| `conf` | R/W | Configuration: decouple flags, stream selection |
| `status` | RO | Per-stream busy flags |
| `next_id` | RO | Per-stream next transfer ID. **Reading launches the transfer** |
| `done_id` | RO | Per-stream last completed transfer ID |
| `reps` | R/W | Number of 2D repetitions (ND mode) |
| `src_stride` | R/W | Source stride between rows (ND mode) |
| `dst_stride` | R/W | Destination stride between rows (ND mode) |

## Programming Sequence

1. **Write transfer parameters**: Set `src_addr`, `dst_addr`, `num_bytes`, and optionally `reps`/`src_stride`/`dst_stride` for 2D mode
2. **Write configuration**: Set `conf` with the desired stream index, decouple flags, and burst options
3. **Read `next_id[stream]`**: This read atomically launches the transfer and returns the assigned transfer ID. The register port stalls (backpressures the bus) until the backend accepts the request
4. **Poll `done_id[stream]`**: Wait until `done_id >= next_id` to confirm completion

## Multi-Port Arbitration

When `NumRegs > 1`, multiple register ports can submit transfers concurrently. An internal round-robin arbiter serializes requests to the single backend interface. Each port stalls independently on its `next_id` read until its request is accepted. This allows multiple cores to share a single DMA without software-level locking.

## Source Files

- **Template**: `src/frontend/reg/tpl/idma_reg.sv.tpl`
- **Generated output**: `target/rtl/idma_reg64_2d.sv`, `target/rtl/idma_reg32_2d.sv`

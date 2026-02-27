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

## Programming Sequence

1. **Write transfer parameters**: Set `src_addr`, `dst_addr`, `num_bytes`, and optionally `reps`/`src_stride`/`dst_stride` for 2D mode
2. **Write configuration**: Set `conf` with the desired stream index, decouple flags, and burst options
3. **Read `next_id[stream]`**: This read atomically launches the transfer and returns the assigned transfer ID. The register port stalls (backpressures the bus) until the backend accepts the request
4. **Poll `done_id[stream]`**: Wait until `done_id >= next_id` to confirm completion

:::caution[Side-effect read]
Reading the `next_id` register has a side effect — it atomically launches the configured transfer. This is intentional: the read stalls the bus until the backend accepts the request, and returns the transfer ID. This is non-standard register behavior; ensure your driver reads `next_id` exactly once per transfer.
:::

## Register Map

The register file provides direct access to all fields of the `idma_req_t` / `idma_nd_req_t` structs. Software writes the transfer parameters, then reads `next_id` to atomically submit the request:

:::note[32-bit register bus]
The register bus is 32 bits wide. 64-bit values (addresses, lengths, strides) are split across `_low` and `_high` register pairs (e.g., `src_addr_low` at offset 0xDC, `src_addr_high` at offset 0xE0). The simplified names in the table below refer to the logical fields; see the generated register description (`target/rtl/idma_reg64_2d.hjson`) for exact offsets and bit layouts.
:::

| Register | Access | Description |
|----------|--------|-------------|
| `src_addr` | R/W | Source address for the next transfer |
| `dst_addr` | R/W | Destination address for the next transfer |
| `num_bytes` | R/W | Transfer length in bytes |
| `conf` | R/W | Transfer configuration (see below) |
| `status` | RO | Per-stream busy flags |
| `next_id` | RO | Per-stream next transfer ID. **Reading launches the transfer** |
| `done_id` | RO | Per-stream last completed transfer ID |
| `reps` | R/W | Number of 2D repetitions (ND mode) |
| `src_stride` | R/W | Source stride between rows (ND mode) |
| `dst_stride` | R/W | Destination stride between rows (ND mode) |

### Configuration Register (`conf`)

Transfer configuration: `decouple_aw` (bit 0), `decouple_rw` (bit 1), `src_reduce_len` (bit 2), `dst_reduce_len` (bit 3), `src_max_llen` (bits 6:4), `dst_max_llen` (bits 9:7), `enable_nd` (bit 10), `src_protocol` (bits 13:11), `dst_protocol` (bits 16:14).

## Multi-Port Arbitration

When `NumRegs > 1`, multiple register ports can submit transfers concurrently. An internal round-robin arbiter serializes requests to the single backend interface. Each port stalls independently on its `next_id` read until its request is accepted. This allows multiple cores to share a single DMA without software-level locking.

## Source Files

- **Template**: `src/frontend/reg/tpl/idma_reg.sv.tpl`
- **Generated output**: `target/rtl/idma_reg64_2d.sv`, `target/rtl/idma_reg32_2d.sv`

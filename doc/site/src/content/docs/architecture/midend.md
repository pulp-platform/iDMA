---
title: Midend
description: The midend decomposes multi-dimensional and round-trip transfers into 1D requests.
---

## Overview

The midend sits between the frontend and backend. It accepts N-dimensional or round-trip transfer descriptors and decomposes them into a stream of 1D requests that the backend can execute. The midend is **optional** — for systems that only need 1D transfers, the frontend can drive the backend directly. See the [System Integration](../guides/system-integration/) guide for wiring examples showing how the midend connects to the frontend and backend.

Four midend variants are available:

| Variant | Module | Purpose |
|---------|--------|---------|
| **ND** | `idma_nd_midend` | Multi-dimensional transfer decomposition |
| **RT** | `idma_rt_midend` | Event-driven periodic (round-trip) transfers |
| **MP_DIST** | `idma_mp_dist_midend` | Distribute transfers across multiple backends by address |
| **MP_SPLIT** | `idma_mp_split_midend` | Split transfers at region boundaries for a single backend |

## ND Midend

The ND midend (`idma_nd_midend`) decomposes an N-dimensional transfer into a sequence of 1D transfers. It uses cascaded repetition counters (one per dimension above the first) and a popcount-based stride selector to determine which address stride to apply after each 1D burst.

When a lower dimension completes all its repetitions, the midend increments the next-higher dimension's counter and applies its stride. A popcount of the "dimension complete" signals selects which stride to add to the address — ensuring that when multiple dimensions overflow simultaneously, all their strides are applied.

### Parameters

| Parameter | Description |
|-----------|-------------|
| `NumDim` | Number of dimensions. Must be >= 2 (dimension 1 is the 1D burst handled by the backend) |
| `RepWidths` | Per-dimension counter widths — an array specifying the counter width for each dimension. For example, with `NumDim=3` and `RepWidths = '{32, 16, 8}`, dimension 1 supports up to 2³² repetitions, dimension 2 up to 2¹⁶, etc. |

### Request Types

The ND request wraps a 1D `idma_req_t` with per-dimension stride/repetition descriptors:

```verilog
`IDMA_TYPEDEF_D_REQ_T(idma_d_req_t, reps_t, strides_t)
// Expands to:
typedef struct packed {
    reps_t    reps;         // Number of repetitions for this dimension
    strides_t src_strides;  // Source address stride (bytes)
    strides_t dst_strides;  // Destination address stride (bytes)
} idma_d_req_t;

`IDMA_TYPEDEF_ND_REQ_T(idma_nd_req_t, idma_req_t, idma_d_req_t)
// Expands to:
typedef struct packed {
    idma_req_t                burst_req;       // Base 1D request
    idma_d_req_t [NumDim-2:0] d_req;           // Per-dimension descriptors
} idma_nd_req_t;
```

### Worked Example: 2D Transfer

Consider a 2D transfer copying a 64-byte row repeated 4 times with different source and destination pitches. For this transfer, the request parameters are:

```
NumDim     = 2
length     = 64           (bytes per row)
reps       = 4            (number of rows)
src_stride = 128          (source row pitch)
dst_stride = 64           (destination row pitch, tightly packed)
```

The ND midend emits 4 sequential 1D transfers:

| Iteration | src_addr | dst_addr | length |
|-----------|----------|----------|--------|
| 0 | `base_src + 0` | `base_dst + 0` | 64 |
| 1 | `base_src + 128` | `base_dst + 64` | 64 |
| 2 | `base_src + 256` | `base_dst + 128` | 64 |
| 3 | `base_src + 384` | `base_dst + 192` | 64 |

:::note[Zero repetitions]
If all repetition counts for a dimension are zero, that dimension is treated as a no-op ("zero stage"). The midend signals this as an `ND_MIDEND` error in the response.
:::

## RT Midend

The RT midend (`idma_rt_midend`) supports event-driven periodic transfers. It is designed for periodic data movement — sensor sampling at fixed intervals, display buffer refresh, or ring-buffer rotation. Each event channel triggers its pre-configured transfer when its countdown reaches zero, without CPU intervention.

It contains `NumEvents` countdown counters, each triggering an ND transfer when its counter reaches zero. A round-robin arbiter selects among ready events, and a bypass path allows non-periodic transfers to pass through.

### Parameters

| Parameter | Description |
|-----------|-------------|
| `NumEvents` | Number of parallel event channels |
| `EventCntWidth` | Width of the countdown counters (period in clock cycles) |
| `NumOutstanding` | Maximum outstanding transfers (depth of the response routing FIFO) |

### Operation

1. Software configures each event channel with: source/destination addresses, transfer length, 2D strides/repetitions, and a countdown threshold. Configuration is submitted through the module's `nd_req_i` port — software sends ND requests with an event channel ID. The countdown threshold and enable signals are separate input ports
2. Each enabled counter decrements every clock cycle
3. On overflow (reaching zero), the counter's pre-configured ND request is submitted to the arbiter
4. A round-robin arbiter (`stream_arbiter`) selects among triggered events
5. The bypass path allows direct ND requests to be interleaved with periodic ones via a second round-robin arbiter
6. A response FIFO routes completions back to the correct requester (periodic or bypass)

## Multicore Midends

### MP_DIST

Use MP_DIST when your SoC has multiple memory banks and you want a single transfer to be distributed across backends, each serving a contiguous address region (e.g., tightly-coupled data memory in a cluster).

The distributed midend (`idma_mp_dist_midend`) splits a single transfer across `NumBEs` backends based on address regions. Each backend owns a contiguous `RegionWidth`-byte slice within the range `[RegionStart, RegionEnd)`. The following parameters control the address region mapping:

| Parameter | Description |
|-----------|-------------|
| `NumBEs` | Number of backends to distribute across |
| `RegionWidth` | Size of each backend's address region in bytes |
| `RegionStart` | Base address of the distributed region |
| `RegionEnd` | End address of the distributed region |
| `AddrWidth` | Address width |
| `PrintInfo` | Print debug info on transfers |

The midend uses a `stream_fork` to fan out the request to all backends simultaneously. Backends whose region does not overlap the transfer receive a suppressed request (valid deasserted, ready tied high). Completion is signaled only when all involved backends have finished.

### MP_SPLIT

Use MP_SPLIT when a single transfer may span multiple address regions that require separate handling (e.g., crossing from one memory bank to another), and you want the hardware to serialize the sub-transfers automatically.

The split midend (`idma_mp_split_midend`) serializes a transfer that spans multiple `RegionWidth` boundaries into a sequence of region-aligned sub-transfers for a single backend. It uses a two-state FSM (`Idle` / `Busy`) to emit the first region-clipped transfer immediately, then iterates through remaining regions. The following parameters define the region layout:

| Parameter | Description |
|-----------|-------------|
| `RegionWidth` | Size of each region in bytes |
| `RegionStart` | Base address of the managed region |
| `RegionEnd` | End address of the managed region |
| `AddrWidth` | Address width |
| `PrintInfo` | Print debug info on transfers |

## Source Files

- `src/midend/idma_nd_midend.sv` — ND midend + counter submodule
- `src/midend/idma_rt_midend.sv` — RT midend
- `src/midend/idma_mp_dist_midend.sv` — Distributed multicore midend
- `src/midend/idma_mp_split_midend.sv` — Split multicore midend

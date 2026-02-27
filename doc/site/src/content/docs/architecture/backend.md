---
title: Backend
description: The backend executes 1D transfers over concrete transport protocols.
---

## Overview

The backend is the lowest layer of the iDMA pipeline. It takes 1D transfer requests from the midend and drives the actual bus transactions. Each backend variant targets a specific combination of read and write protocols. Generated modules follow the naming pattern `idma_backend_<variant>` (e.g., `idma_backend_rw_axi`, `idma_backend_r_obi_w_axi`).

![Backend Architecture](/fig/backend.svg)

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DataWidth` | 16 | Data bus width in bits. Must be a power of 2 in {16, 32, 64, 128, 256, 512, 1024} |
| `AddrWidth` | 24 | Address width in bits. Must be >= 12 |
| `UserWidth` | 1 | AXI user signal width. Must be > 0 |
| `AxiIdWidth` | 1 | AXI ID width. Must be > 0 |
| `NumAxInFlight` | 2 | Number of concurrent in-flight transactions. Must be > 1 |
| `BufferDepth` | 2 | Depth of the internal reorder buffer. 2 = minimal, **3 = recommended** (handles misaligned transfers efficiently) |
| `TFLenWidth` | 24 | Transfer length width. Max transfer size is `2^TFLenWidth` bytes. Must be >= 12 and <= AddrWidth |
| `MemSysDepth` | 0 | Depth of the attached memory system (additional pipeline stages) |
| `CombinedShifter` | 0 | Use a single barrel shifter instead of two (saves area, data no longer word-aligned in buffer) |
| `RAWCouplingAvail` | 1* | Enable R-AW coupling hardware. *Default is 1 for AXI-to-AXI variants, 0 otherwise |
| `MaskInvalidData` | 1 | Zero out invalid bytes on the manager interface to reduce toggling |
| `HardwareLegalizer` | 1 | Include hardware burst legalization. If 0, software must ensure legal bursts |
| `RejectZeroTransfers` | 1 | Reject zero-length transfers with a `BACKEND` error response |
| `ErrorCap` | `NO_ERROR_HANDLING` | Error handling capability: `NO_ERROR_HANDLING` or `ERROR_HANDLING` |
| `PrintFifoInfo` | 0 | Print FIFO configuration during elaboration |

The maximum number of transfers in-flight at any point is:

```
MetaFifoDepth = BufferDepth + NumAxInFlight + MemSysDepth
```

## Interface

### Port Groups

| Group | Signals | Direction | Description |
|-------|---------|-----------|-------------|
| **Request** | `idma_req_i`, `req_valid_i`, `req_ready_o` | in/in/out | 1D transfer request (valid/ready handshake) |
| **Response** | `idma_rsp_o`, `rsp_valid_o`, `rsp_ready_i` | out/out/in | Transfer completion response |
| **Error Handler** | `idma_eh_req_i`, `eh_req_valid_i`, `eh_req_ready_o` | in/in/out | Error handling action (CONTINUE/ABORT) |
| **Bus Read** | `<proto>_read_req_o`, `<proto>_read_rsp_i` | out/in | Read channel to memory system |
| **Bus Write** | `<proto>_write_req_o`, `<proto>_write_rsp_i` | out/in | Write channel to memory system |
| **Busy** | `busy_o` | out | Per-subunit busy flags (`idma_busy_t`) |

### Busy Signal (`idma_busy_t`)

```verilog
typedef struct packed {
    logic buffer_busy;       // Data buffer contains valid data
    logic r_dp_busy;         // Read datapath active
    logic w_dp_busy;         // Write datapath active
    logic r_leg_busy;        // Read legalizer processing
    logic w_leg_busy;        // Write legalizer processing
    logic eh_fsm_busy;       // Error handler FSM not idle
    logic eh_cnt_busy;       // Outstanding transfer counter != 0
    logic raw_coupler_busy;  // R-AW coupler holds pending AWs
} idma_busy_t;
```

## Variant Matrix

Each backend variant combines a set of read and write protocols:

| Variant ID | Read Protocol | Write Protocol |
|------------|---------------|----------------|
| `rw_axi` | AXI4 | AXI4 |
| `r_obi_w_axi` | OBI | AXI4 |
| `r_axi_w_obi` | AXI4 | OBI |
| `rw_axi_rw_axis` | AXI4 | AXI4 + AXI Stream |
| `r_obi_rw_init_w_axi` | OBI | INIT + AXI4 |
| `r_axi_rw_init_rw_obi` | AXI4 | INIT + OBI |

![Variant Matrix](/fig/variant_matrix.svg)

## Legalizer

The legalizer decomposes a 1D transfer request into a sequence of protocol-legal bus bursts. It operates as two coupled state machines — one for the read side, one for the write side — that track the remaining bytes and current address of each transfer independently.

The legalizer is pure control path: it does not touch the data. It computes page/burst boundaries, splits transfers accordingly, and emits `offset`, `tailer`, and `shift` values that the transport layer uses for data realignment.

![Legalizer](/fig/legalizer.svg)

### Splitting Rules

| Protocol | Burst Mode | Page Size | Max Beats |
|----------|-----------|-----------|-----------|
| AXI | `split_at_page_boundary` | 4096 B | 256 |
| OBI | `not_supported` (single-beat) | StrbWidth | 1 |
| INIT | `not_supported` (single-beat) | StrbWidth | 1 |
| AXI Stream | `not_supported` (single-beat) | StrbWidth | 1 |

For AXI, the legalizer ensures bursts do not cross 4 KiB page boundaries and respect the 256-beat maximum. For non-bursting protocols (OBI, INIT, AXI Stream), each transfer is a single bus-width beat. The effective page size is `min(max_beats * StrbWidth, page_size)`.

### Datapath Request Types

The legalizer emits `r_dp_req_t` and `w_dp_req_t` structs containing `offset` (bus-word alignment), `tailer` (padding bytes at the end), `shift` (barrel shifter amount), and `is_single` (single-beat flag). These flow through decoupling FIFOs to the transport layer.

### Software Legalization

When `HardwareLegalizer=0`, the legalizer is bypassed and replaced with a simple `stream_fork` that synchronizes the read and write paths. In this mode, software is responsible for ensuring all transfers are already legal for the target protocol (e.g., no AXI page-boundary crossings). This saves area but increases software complexity.

## Transport Layer

### Architecture

The transport layer contains the read channel, byte-granular data buffer, and write channel. Data flows as: **read port** -> **read barrel shifter** -> **dataflow element (buffer)** -> **write barrel shifter** -> **write port**.

The buffer (`idma_dataflow_element`) is an array of independent FIFOs, one per byte lane (`StrbWidth` FIFOs of depth `BufferDepth`). This byte-granular design allows data to enter and leave the buffer at arbitrary byte-lane positions, enabling misaligned transfers without additional alignment stages.

### Data Realignment

Two barrel shifters handle the address offset difference between source and destination. The **read shifter** aligns incoming data based on the source address offset; the **write shifter** rotates data to match the destination address offset.

When `CombinedShifter=1`, both shifts are folded into a single operation before the buffer. This halves the shifter area but means data inside the buffer is no longer word-aligned. The tradeoff is area (single shifter) vs. timing (data alignment happens earlier in the pipeline).

## Channel Coupler

The R-AW channel coupler (`idma_channel_coupler`) holds back AW requests until the first corresponding R beat arrives. This prevents the write channel from issuing addresses for data that hasn't been read yet, reducing memory system congestion. Controlled by `RAWCouplingAvail` (enables the hardware) and `decouple_aw` (per-transfer opt-in via `backend_options_t`). Only available for AXI-to-AXI variants.

## Error Handler

The error handler monitors R and W datapath responses for non-OKAY AXI responses. When an error is detected, it reports the faulting burst address and error type to software and waits for a CONTINUE or ABORT action. See the [Error Handling guide](../guides/error-handling/) for the full FSM description and software handling patterns.

## Source Files

- **Backend template**: `src/backend/tpl/idma_backend.sv.tpl`
- **Legalizer template**: `src/backend/tpl/idma_legalizer.sv.tpl`
- **Transport layer template**: `src/backend/tpl/idma_transport_layer.sv.tpl`
- **Error handler**: `src/backend/idma_error_handler.sv`
- **Channel coupler**: `src/backend/idma_channel_coupler.sv`
- **Dataflow element**: `src/backend/idma_dataflow_element.sv`
- **Generated output**: `target/rtl/idma_backend_*.sv`

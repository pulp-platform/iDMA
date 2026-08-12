---
title: iDMA
description: A modular DMA engine for heterogeneous PULP-platform SoCs.
---

## What iDMA Is

iDMA moves data between memories and peripherals across different bus protocols (AXI, OBI, TileLink) and supports multi-dimensional transfers. It splits the problem into three layers so you can mix and match integration styles without changing the core engine.

- **Frontend**: software-visible interface for requests (selectable register interface, Snitch ISA, descriptor rings).
- **Midend**: optional ND/RT decomposition and multicore split.
- **Backend**: protocol execution on the bus, with optional on-the-fly compute.

![Architecture Overview](/fig/architecture_overview.svg)

:::note[Figure placeholder]
Diagram: end-to-end request lifecycle (frontend request, optional midend split, backend legalizer + transport, response).
Show where `idma_req_t` and `idma_rsp_t` are created and consumed.
:::

## Start Here

If you are integrating iDMA into an SoC, read these in order:

- [Quickstart](./guides/quickstart/)
- [Programming Model](./architecture/programming-model/)
- [System Integration](./guides/system-integration/)

If you are deep-diving the design:

- [Frontend](./architecture/frontend/)
- [Midend](./architecture/midend/)
- [Backend](./architecture/backend/)
- [Compute](./architecture/compute/)
- [Interfaces and Types](./architecture/interfaces/)

## Supported Protocols

The backend supports these protocols via `protocol_e` in `idma_pkg.sv`:

| Enum Value | Protocol | Description | Typical Use |
|------------|----------|-------------|-------------|
| 0 | `AXI` | Full AXI4 | Main memory, high bandwidth |
| 1 | `OBI` | OBI | Simple peripherals, low area |
| 2 | `AXILITE` | AXI4-Lite | Register access |
| 3 | `TILELINK` | TileLink-UH | TL-based SoCs (via TLToAXI4) |
| 4 | `INIT` | Init protocol | Efficient zeroing (Occamy) |
| 5 | `AXI_STREAM` | AXI Stream | Streaming endpoints |

## On-the-Fly Compute

The backend can optionally transform data as it moves, in the transport datapath,
with no extra memory traffic. One operation is applied per transfer:

- **Transpose**: tiled matrix transpose (`idma_otf_transpose`).
- **MX quantize / dequantize**: OCP microscaling between FP32/FP16 and MXFP8
  (E5M2 elements with an E8M0-labelled block scale, 32-element / 33 B blocks).
  These are size-changing transfers, legalized in the legalizer.

Enabled via `EnableCompute` plus a per-op `ComputeOps` mask. See
[Compute](./architecture/compute/).

## Code Generation (High Level)

iDMA uses the MARIO generator to produce protocol-specific RTL from templates and YAML capability databases. This is how a single codebase produces many backend variants.

Key locations:

- `src/db/*.yml` - protocol capability databases
- `src/backend/tpl/` - backend templates
- `src/frontend/tpl/` - register frontend templates
- `util/gen_idma.py` - generator entry point
- `util/mario/` - generator modules

## Where to Find Details

- Full data type definitions: [Interfaces and Types](./architecture/interfaces/)
- Performance constraints and tradeoffs: [Performance and Limitations](./guides/performance-limitations/)
- Testbench and job files: [Verification](./guides/verification/)
- Documentation QA checklist: [Docs Verification Plan](./guides/docs-verification/)

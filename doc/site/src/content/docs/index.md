---
title: iDMA
description: A modular DMA engine for heterogeneous PULP-platform SoCs.
---

## Overview

Modern SoCs need to move data between memory regions, peripherals, and accelerators — often across different bus protocols (AXI, OBI, TileLink) and with multi-dimensional access patterns (2D tile copies, strided accesses). A hardwired DMA engine offloads this work from the CPU, but supporting multiple protocols and transfer shapes in a single design is complex.

iDMA solves this with a modular, protocol-agnostic DMA engine designed for heterogeneous PULP-platform SoCs. Its three-layer architecture — Frontend, Midend, Backend — cleanly separates the software interface, multi-dimensional decomposition, and transport protocol execution. Each layer is independently configurable and swappable, so the same infrastructure supports everything from a minimal 32-bit OBI system to a 512-bit AXI cluster with ISA-coupled transfers.

**Getting started?** If you're **integrating iDMA into an SoC**, start with the [System Integration](./guides/system-integration/) guide — it covers type macros, wiring, and parameter presets. If you're **understanding the architecture**, begin with the [Frontend](./architecture/frontend/) overview and follow the pipeline through to the [Backend](./architecture/backend/).

## Architecture at a Glance

iDMA's pipeline flows from **Frontend** (software interface) through an optional **Midend** (ND/RT decomposition) to the **Backend** (bus transactions). All RTL is generated from Mako templates and YAML protocol databases by the MARIO code generation framework. The backend handles burst legalization, data realignment, and error handling autonomously.

![Architecture Overview](/fig/architecture_overview.svg)

<!-- TODO: Replace with SVG diagram showing a single transfer lifecycle -->
<!--
┌──────────┐    ┌───────────┐    ┌─────────────────┐    ┌──────────┐
│ Frontend │───>│ Legalizer │───>│ Transport Layer  │───>│ Response │
│ (req_t)  │    │ (split)   │    │ (shift+buffer)   │    │ (rsp_t)  │
└──────────┘    └───────────┘    └─────────────────┘    └──────────┘
   idma_req_t      burst 1..N       read→shift→buf→       idma_rsp_t
                                    shift→write
-->

## Core Data Types

All iDMA layers communicate through a small set of struct types defined via macros in `typedef.svh`. The key option structs are summarized below; full type definitions are in the [expandable section](#type-definitions) at the bottom of this page.

### Backend Options (`backend_options_t`)

These options control how aggressively the backend pipelines read and write operations. The defaults (all zero) are safe; enable decoupling for higher throughput at the cost of complexity. Defined in `idma_pkg.sv`:

| Field | Width | Description |
|-------|-------|-------------|
| `decouple_aw` | 1 | Enable R-AW coupling: hold write addresses until read data arrives (safer, prevents write-before-read). Set to 1 for higher throughput on AXI-to-AXI transfers |
| `decouple_rw` | 1 | Fully decouple read and write channels (highest throughput, but risks deadlock if the buffer fills — only safe when `BufferDepth` is large enough) |
| `src_max_llen` | 3 | Maximum source burst length as log2(beats). 0 = single beat (full debursting), 3 = 8 beats, 7 = 128 beats. Lower values generate more bursts but cross fewer page boundaries |
| `dst_max_llen` | 3 | Maximum destination burst length as log2(beats). Same encoding as `src_max_llen` |
| `src_reduce_len` | 1 | When set, the legalizer shortens source bursts beyond what page-boundary splitting requires. Used for bandwidth throttling or to match narrow interconnect capabilities |
| `dst_reduce_len` | 1 | When set, the legalizer shortens destination bursts (same effect as `src_reduce_len` but for the write side) |

### AXI Options (`axi_options_t`)

AXI sideband signals that travel with each burst. These are pass-through to the bus — iDMA does not interpret them, but the interconnect may use them for routing, caching, and protection decisions. Defined in `idma_pkg.sv`, carried per-direction in `options_t.src` and `options_t.dst`:

| Field | Width | Description |
|-------|-------|-------------|
| `burst` | 2 | AXI burst type (FIXED=00, INCR=01, WRAP=10) |
| `cache` | 4 | AXI cache attributes (bufferable, modifiable, read-alloc, write-alloc) |
| `lock` | 1 | AXI lock (not used by most frontends, tied to 0) |
| `prot` | 3 | AXI protection flags |
| `qos` | 4 | AXI QoS priority |
| `region` | 4 | AXI region identifier |

## Supported Protocols

From `protocol_e` in `idma_pkg.sv`:

| Enum Value | Protocol | Description | Use Case |
|------------|----------|-------------|----------|
| 0 | `AXI` | Full AXI4 | General-purpose high-bandwidth interconnects |
| 1 | `OBI` | OBI | Simple low-gate-count interconnects (PULP clusters) |
| 2 | `AXILITE` | AXI4-Lite | Register-mapped peripherals |
| 3 | `TILELINK` | TileLink-UH | TileLink-based SoCs (via TLToAXI4 bridge) |
| 4 | `INIT` | Init protocol (Occamy) | Efficient memory zeroing without read-modify-write |
| 5 | `AXI_STREAM` | AXI Stream | Streaming peripherals (e.g., network interfaces, DSP chains) |

Most systems use **AXI** for main memory and **OBI** for simple peripherals. **INIT** is Occamy-specific for memory zeroing. **AXI Stream** is for streaming endpoints (network, DSP). **TileLink** requires a TLToAXI4 bridge and inherits its limitations.

## Code Generation

Code generation is necessary because each protocol combination (read from AXI, write to OBI, etc.) requires different bus interface logic, legalizer rules, and transport layer wiring. Rather than maintaining N² hand-written variants, iDMA uses the **MARIO** framework (`util/mario/`) to generate all RTL from Mako templates (a Python-based text templating engine) and YAML protocol databases.

**Key locations**:
- `src/db/*.yml` — Per-protocol capability databases (e.g., `idma_axi.yml`, `idma_obi.yml`, `idma_tilelink.yml`). These define burst modes, page sizes, meta-channel types, and legalizer rules for each protocol.
- `src/backend/tpl/` — Backend templates (backend, legalizer, transport layer)
- `src/frontend/tpl/` — Register frontend templates
- `test/tpl/` — Testbench and trace templates
- `util/gen_idma.py` — Entry point. Reads YAML databases, invokes MARIO modules, renders Mako templates.
- `util/mario/` — Generation modules: `backend.py`, `frontend.py`, `legalizer.py`, `transport_layer.py`, `synth.py`, `testbench.py`, `wave.py`, `tracer.py`

**Workflow**: `make idma_hw_all` runs `gen_idma.py`, which reads the YAML databases, instantiates the MARIO modules, and renders the Mako templates into SystemVerilog. Generated output is written to `target/rtl/` and is committed to the repository. After modifying templates or databases, always regenerate and commit the result.

## Type Definitions

<details>
<summary>Full type macro expansions (click to expand)</summary>

Use this reference when you need the exact field layout for writing a driver or debugging struct packing. For integration, the `IDMA_TYPEDEF_FULL_*` macros handle all of this automatically — see the [System Integration](./guides/system-integration/#2-define-types) guide.

### Transfer Request (`idma_req_t`)

The transfer request is what frontends produce and backends consume. It carries the source/destination addresses, transfer length, and all protocol options:

```verilog
`IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, axi_addr_t, options_t)
// Expands to:
typedef struct packed {
    tf_len_t   length;    // Transfer length in bytes
    axi_addr_t src_addr;  // Source byte address
    axi_addr_t dst_addr;  // Destination byte address
    user_t     user;      // User-defined sideband data
    options_t  opt;       // Transfer options (see below)
} idma_req_t;
```

### Transfer Options (`options_t`)

Transfer options carry protocol selection, AXI sideband signals, and backend engine options. Every transfer request embeds one `options_t`:

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

### Transfer Response (`idma_rsp_t`)

The response indicates whether a transfer completed successfully or encountered an error. Frontends receive one response per submitted transfer:

```verilog
`IDMA_TYPEDEF_RSP_T(idma_rsp_t, err_payload_t)
// Expands to:
typedef struct packed {
    logic         last;   // Last response for this ND transfer
    logic         error;  // Error occurred
    err_payload_t pld;    // Error details (cause, type, address)
} idma_rsp_t;
```

### Error Payload (`err_payload_t`)

The error payload identifies the faulting burst address and error source. It is only meaningful when `idma_rsp_t.error` is asserted:

```verilog
`IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, axi_addr_t)
// Expands to:
typedef struct packed {
    axi_pkg::resp_t      cause;      // AXI response code
    idma_pkg::err_type_t err_type;   // Error source (BUS_READ, BUS_WRITE, BACKEND, ND_MIDEND)
    axi_addr_t           burst_addr; // Address of the faulting burst
} err_payload_t;
```

</details>

## Quick Links

- **Architecture**
  - [Frontend](./architecture/frontend/) — register, Snitch ISA, descriptor-ring interfaces
  - [Midend](./architecture/midend/) — ND decomposition, round-trip, multicore splitting
  - [Backend](./architecture/backend/) — 1D transfer execution, legalizer, transport layer
- **Guides**
  - [System Integration](./guides/system-integration/) — wiring iDMA into an SoC
  - [Error Handling](./guides/error-handling/) — error types, FSM, software handling
  - [Verification](./guides/verification/) — testbench, job files, simulation

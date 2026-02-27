---
title: iDMA
description: A modular DMA engine for heterogeneous PULP-platform SoCs.
---

## Overview

iDMA is a modular, protocol-agnostic DMA engine designed for integration into heterogeneous systems-on-chip built on the PULP platform. Its three-layer architecture — Frontend, Midend, Backend — cleanly separates the transfer interface, multi-dimensional decomposition, and transport protocol concerns.

## Architecture at a Glance

iDMA's pipeline flows from **Frontend** (software interface) through an optional **Midend** (ND/RT decomposition) to the **Backend** (bus transactions). All RTL is generated from Mako templates and YAML protocol databases by the MARIO code generation framework. The backend handles burst legalization, data realignment, and error handling autonomously.

![Architecture Overview](/fig/architecture_overview.svg)

## Core Data Types

All iDMA layers communicate through a small set of struct types defined via macros in `typedef.svh`.

### Transfer Request (`idma_req_t`)

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

### Backend Options (`backend_options_t`)

Defined in `idma_pkg.sv`:

| Field | Width | Description |
|-------|-------|-------------|
| `decouple_aw` | 1 | Send AWs only after first corresponding R arrives |
| `decouple_rw` | 1 | Fully decouple R and W channels (can cause deadlocks) |
| `src_max_llen` | 3 | Maximum log-length of a source burst |
| `dst_max_llen` | 3 | Maximum log-length of a destination burst |
| `src_reduce_len` | 1 | Reduce source burst length |
| `dst_reduce_len` | 1 | Reduce destination burst length |

### Transfer Response (`idma_rsp_t`)

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

```verilog
`IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, axi_addr_t)
// Expands to:
typedef struct packed {
    axi_pkg::resp_t      cause;      // AXI response code
    idma_pkg::err_type_t err_type;   // Error source (BUS_READ, BUS_WRITE, BACKEND, ND_MIDEND)
    axi_addr_t           burst_addr; // Address of the faulting burst
} err_payload_t;
```

## Supported Protocols

From `protocol_e` in `idma_pkg.sv`:

| Enum Value | Protocol | Description |
|------------|----------|-------------|
| 0 | `AXI` | Full AXI4 |
| 1 | `OBI` | OBI |
| 2 | `AXILITE` | AXI4-Lite |
| 3 | `TILELINK` | TileLink-UH |
| 4 | `INIT` | Init protocol (Occamy) |
| 5 | `AXI_STREAM` | AXI Stream |

## Code Generation

iDMA uses the **MARIO** framework (`util/mario/`) to generate all RTL. Protocol capabilities are described in YAML databases (`src/db/*.yml`), and Mako templates (`*.tpl`) render the final SystemVerilog. Run `make idma_hw_all` to regenerate everything into `target/rtl/`.

## Quick Links

- **Architecture**
  - [Backend](./architecture/backend/) — 1D transfer execution, legalizer, transport layer
  - [Midend](./architecture/midend/) — ND decomposition, round-trip, multicore splitting
  - [Frontend](./architecture/frontend/) — register, Snitch ISA, descriptor-ring interfaces
- **Guides**
  - [System Integration](./guides/system-integration/) — wiring iDMA into an SoC
  - [Error Handling](./guides/error-handling/) — error types, FSM, software handling
  - [Verification](./guides/verification/) — testbench, job files, simulation

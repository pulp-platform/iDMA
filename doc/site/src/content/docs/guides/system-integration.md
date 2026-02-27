---
title: System Integration
description: How to wire iDMA into an SoC, including type macros, parameters, and real-world examples.
---

## Overview

This guide covers the practical steps for integrating iDMA into a system-on-chip: choosing a frontend/midend/backend combination, instantiating the type macros, wiring the bus interfaces, and setting the key parameters.

![System Integration](/fig/system_integration.svg)

![System Integration (alternate view)](/fig/system_integration_alt.svg)

## Integration Steps

### 1. Choose Your Stack

Select a frontend, midend, and backend based on your requirements:

- **Backend**: Pick the variant matching your bus protocols — see the [variant matrix](../architecture/backend/#variant-matrix). If your SoC uses AXI4 throughout, `rw_axi` is the standard choice. Use `r_obi_w_axi` when reading from OBI-attached memory but writing via AXI. The Occamy variants (`r_obi_rw_init_w_axi`, `r_axi_rw_init_rw_obi`) add the INIT protocol for efficient memory zeroing. The backend page also covers [legalizer splitting rules](../architecture/backend/#splitting-rules) and [error handling](../architecture/backend/#error-handler) constraints.
- **Frontend**: Choose based on your SoC's control interface — see the [frontend comparison](../architecture/frontend/#choosing-a-frontend)
- **Midend**: Use the [ND midend](../architecture/midend/#nd-midend) for 2D/3D transfers, [RT midend](../architecture/midend/#rt-midend) for periodic transfers, or skip the midend entirely for 1D-only systems

### 2. Define Types

Use the convenience macros from `typedef.svh` to define all required types in one shot:

```verilog
`include "idma/typedef.svh"

// Define address, data, and ID types
typedef logic [AddrWidth-1:0]   addr_t;
typedef logic [DataWidth-1:0]   data_t;
typedef logic [IdWidth-1:0]     id_t;
typedef logic [TFLenWidth-1:0]  tf_len_t;

// 1D request/response types (expands options_t and err_payload_t internally)
`IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
`IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)

// ND request type (if using ND midend)
typedef logic [RepWidth-1:0]    reps_t;
typedef logic [StrideWidth-1:0] strides_t;
`IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, reps_t, strides_t)
```

The `IDMA_TYPEDEF_FULL_REQ_T` macro is a convenience wrapper that internally invokes `IDMA_TYPEDEF_OPTIONS_T` and `IDMA_TYPEDEF_REQ_T`. Use the `FULL_` variants for integration — they define all intermediate types automatically.

### 3. Instantiate

Wire the three layers together. The key connections are:
- Frontend `dma_req_o` / `req_valid_o` / `req_ready_i` -> Midend ND request input
- Midend `burst_req_o` / `burst_req_valid_o` / `burst_req_ready_i` -> Backend request input
- Backend `idma_rsp_o` / `rsp_valid_o` / `rsp_ready_i` -> back through midend to frontend

The following skeleton shows how the three layers connect. Signal types come from the macros defined in step 2 above — `fe_req` is `idma_nd_req_t`, `be_req` is `idma_req_t`:

```verilog
// Frontend -> Midend -> Backend

idma_reg64_2d #(
    .NumRegs    ( 1          ),
    .NumStreams  ( 1          ),
    .reg_req_t  ( reg_req_t  ),
    .reg_rsp_t  ( reg_rsp_t  ),
    .dma_req_t  ( idma_nd_req_t )
) i_frontend ( ... );

idma_nd_midend #(
    .NumDim        ( 2              ),
    .addr_t        ( addr_t         ),
    .idma_req_t    ( idma_req_t     ),
    .idma_rsp_t    ( idma_rsp_t     ),
    .idma_nd_req_t ( idma_nd_req_t  ),
    .RepWidths     ( 32'd32         )
) i_midend (
    .nd_req_i          ( fe_req       ),
    .nd_req_valid_i    ( fe_valid     ),
    .nd_req_ready_o    ( fe_ready     ),
    .burst_req_o       ( be_req       ),
    .burst_req_valid_o ( be_valid     ),
    .burst_req_ready_i ( be_ready     ),
    ...
);

idma_backend_rw_axi #(
    .DataWidth    ( DataWidth    ),
    .AddrWidth    ( AddrWidth    ),
    .idma_req_t   ( idma_req_t   ),
    .idma_rsp_t   ( idma_rsp_t   ),
    .axi_req_t    ( axi_req_t    ),
    .axi_rsp_t    ( axi_rsp_t    ),
    ...
) i_backend (
    .idma_req_i  ( be_req   ),
    .req_valid_i ( be_valid ),
    .req_ready_o ( be_ready ),
    ...
);
```

### 4. Set Parameters

Recommended parameter presets:

| | Minimum Area | Balanced | High Throughput |
|---|-------------|----------|-----------------|
| `DataWidth` | 32 | 64 | 256–512 |
| `BufferDepth` | 2 | 3 | 3 |
| `NumAxInFlight` | 2 | 3 | 4–8 |
| `MemSysDepth` | 0 | 0 | 8–16 |
| `CombinedShifter` | 1 | 0 | 0 |
| `RAWCouplingAvail` | 0 | 1 | 1 |
| `HardwareLegalizer` | 0 | 1 | 1 |
| `ErrorCap` | `NO_ERROR_HANDLING` | `ERROR_HANDLING` | `ERROR_HANDLING` |

**Minimum Area** sacrifices throughput for gate count — single shifter, no coupling, software legalization. **Balanced** adds hardware legalization and coupling for correct-by-default behavior. **High Throughput** uses deep FIFOs and wide buses to saturate memory bandwidth.

:::caution[Parameter misconfiguration]
Setting `RAWCouplingAvail=1` on a mixed-protocol backend (e.g., `r_obi_w_axi`) where the write protocol has no AW channel will cause synthesis errors. Set `ErrorCap=ERROR_HANDLING` only on single-read/single-write AXI variants (`rw_axi`), or the design will `$fatal` during elaboration.
:::

## Real-World Examples

The following SoCs provide canonical integration examples spanning different bus protocols, data widths, and frontend styles.

### Cheshire

| | |
|---|---|
| **Repo** | [pulp-platform/cheshire](https://github.com/pulp-platform/cheshire) |
| **Frontend** | `idma_reg64_{1d,2d}` |
| **Midend** | ND (2D, conditional) |
| **Backend** | `rw_axi` |
| **Bus** | AXI4 |
| **Data Width** | 64-bit |
| **Key File** | [`hw/cheshire_idma_wrap.sv`](https://github.com/pulp-platform/cheshire/blob/main/hw/cheshire_idma_wrap.sv) |

Cheshire is a CVA6-based Linux-capable SoC built around an AXI4 fabric. Its iDMA instance supports conditional 1D/2D mode, making it a good reference for register-frontend integrations with optional multi-dimensional transfers.

### Croc

| | |
|---|---|
| **Repo** | [pulp-platform/croc](https://github.com/pulp-platform/croc) |
| **Frontend** | Custom OBI register interface |
| **Midend** | ND (2D) |
| **Backend** | `rw_obi` |
| **Bus** | OBI |
| **Data Width** | 32-bit |
| **Key File** | [`rtl/idma/croc_idma.sv`](https://github.com/pulp-platform/croc/blob/main/rtl/idma/croc_idma.sv) |

Croc is a minimal OBI-based SoC with a custom register frontend. Its simplicity makes it an excellent starting template for new OBI integrations.

### Snitch Cluster

| | |
|---|---|
| **Repo** | [pulp-platform/snitch_cluster](https://github.com/pulp-platform/snitch_cluster) |
| **Frontend** | inst64 (Xdma ISA) |
| **Midend** | ND |
| **Backend** | `rw_axi` |
| **Bus** | AXI4 |
| **Data Width** | 512-bit |
| **Key File** | [`hw/snitch_cluster/src/`](https://github.com/pulp-platform/snitch_cluster/tree/main/hw/snitch_cluster/src) |

The Snitch cluster uses a wide 512-bit data path with an ISA-coupled DMA on a dedicated core. Transfers are submitted via Xdma custom instructions, achieving single-cycle launch latency.

### PULP Cluster

| | |
|---|---|
| **Repo** | [pulp-platform/pulp_cluster](https://github.com/pulp-platform/pulp_cluster) |
| **Frontend** | `idma_reg32_2d_frontend` |
| **Midend** | ND (2D) |
| **Backend** | `rw_axi` |
| **Bus** | AXI4 |
| **Data Width** | 64-bit |
| **Key File** | [`rtl/idma_wrap.sv`](https://github.com/pulp-platform/pulp_cluster/blob/main/rtl/idma_wrap.sv) |

The PULP cluster is a multi-core architecture with tightly-coupled data memory (TCDM). It uses a register-based 2D frontend and supports conditional selection between the legacy mchan DMA and iDMA via the `TARGET_MCHAN` parameter.

## Dependency Management

iDMA uses [Bender](https://github.com/pulp-platform/bender) for RTL dependency management. Add iDMA to your `Bender.yml` and run `bender update` to pull it and its transitive dependencies (`axi`, `common_cells`, `register_interface`, `obi`). Bender resolves the source file list for your build system — use `bender script vsim` for Questa or `bender script vcs` for VCS.

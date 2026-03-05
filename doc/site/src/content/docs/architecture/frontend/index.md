---
title: Frontend
description: Frontends accept transfer descriptors from the platform and emit iDMA requests.
---

## Overview

The frontend is the topmost layer of the iDMA pipeline. It provides the software-visible interface through which the host or an accelerator core submits transfer descriptors. iDMA ships three frontend families, each targeting a different integration style:

- **[Register Frontend](./register/)** — memory-mapped register interface (`reg64_2d`)
- **[Snitch Frontend](./snitch/)** — ISA-coupled frontend for Snitch cores (`inst64`)
- **[Descriptor Frontend](./descriptor/)** — descriptor-ring frontend (`desc64`)

## Choosing a Frontend

| | Register | Descriptor | Snitch |
|---|---------|-----------|--------|
| **Interface** | Memory-mapped registers (PULP `reg_interface` — a lightweight request/response protocol similar to APB, used for memory-mapped register access in PULP SoCs) | Descriptor ring in shared memory (AXI) | Custom ISA extension (accelerator bus) |
| **Typical SoC** | General-purpose (CVA6, RISC-V) | CVA6 / Linux-capable | Snitch cluster |
| **Data Width** | Any | 64-bit | Any (typically 64–512 bit) |
| **ND Support** | Yes (2D via `reg64_2d`) | No (1D only) | Yes (2D, `NumDim=2`) |
| **Key Advantage** | Simple, portable | Hardware-managed queue, low CPU overhead | Single-cycle launch, zero register overhead |
| **Error Visibility** | Status register (poll `done_id`, check response) | IRQ (if `flags.irq` set) | Poll via `DMSTAT` |

:::note[Figure placeholder]
Diagram: frontend selection decision flow.
Show Snitch decision first, then descriptor vs register based on queue needs.
:::

## Common Pattern

All frontends produce `idma_req_t` (or `idma_nd_req_t` for ND-capable frontends) and consume `idma_rsp_t`. Frontends are interchangeable at the `idma_req_t` / `idma_rsp_t` boundary, but each has a different control plane: register bus, AXI (descriptor fetch), or accelerator interface. Switching frontends requires re-wiring the host-side interface.

## Generated Variants

The register frontend is **generated** from Mako templates (`src/frontend/reg/tpl/`) by the MARIO framework, producing variants like `idma_reg64_2d`. The descriptor (`desc64`) and Snitch (`inst64`) frontends are **hand-written** SystemVerilog in `src/frontend/desc64/` and `src/frontend/inst64/` respectively.

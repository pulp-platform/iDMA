---
title: Snitch Frontend
description: ISA-coupled frontend for Snitch cores using Xdma custom instructions.
---

## Overview

The Snitch frontend (`idma_inst64_top`) is tightly coupled to the Snitch RISC-V core through custom Xdma ISA extensions. DMA transfers are launched directly from the instruction stream via the accelerator bus interface, eliminating register file overhead and enabling single-cycle transfer submission.

![Snitch Integration](/fig/system_integration_alt.svg)

## Xdma Instruction Set

A DMA transfer requires three steps: (1) set the source and destination addresses (`DMSRC`, `DMDST`), (2) launch the transfer with a length and config (`DMCPY`/`DMCPYI`), (3) poll for completion (`DMSTAT`/`DMSTATI`). Optional instructions set 2D parameters (`DMSTR`, `DMREP`) and AXI user fields (`DMUSER`).

All DMA instructions that return a value write to `rd` (destination register). The assembly syntax is `DMCPYI rd, rs1, imm` — `rd` receives the transfer ID, `rs1` provides the length.

| Instruction | Operands | Description |
|-------------|----------|-------------|
| `DMSRC` | `rs1` (low 32b), `rs2` (high bits) | Set source address |
| `DMDST` | `rs1` (low 32b), `rs2` (high bits) | Set destination address |
| `DMCPYI` | `rd` = transfer ID, `rs1` = length, imm = {channel, config} | Launch transfer (immediate config). Returns transfer ID in `rd` |
| `DMCPY` | `rd` = transfer ID, `rs1` = length, `rs2` = {channel, config} | Launch transfer (register config). Returns transfer ID in `rd` |
| `DMSTATI` | `rd` = status value, imm = {channel, status_sel} | Query status (immediate). Returns status in `rd` |
| `DMSTAT` | `rd` = status value, `rs2` = {channel, status_sel} | Query status (register). Returns status in `rd` |
| `DMSTR` | `rs1` = src_stride, `rs2` = dst_stride | Set 2D strides |
| `DMREP` | `rs1` = repetitions | Set 2D repetition count |
| `DMUSER` | `rs1`, `rs2` | Set AXI user field. When `AxiUserWidth <= 32`, only `rs1` is used (lower bits). When `AxiUserWidth > 32`, `rs1` provides bits [31:0] and `rs2` provides the remaining upper bits |

**Status select values** (`DMSTAT`/`DMSTATI`):
- `0`: Completed transfer ID — compare against the ID returned by `DMCPY` to check if a specific transfer has finished
- `1`: Next transfer ID — the ID that will be assigned to the next submitted transfer
- `2`: Busy flag — 1 if any transfer is in-flight on this channel
- `3`: Backend FIFO full flag — 1 if the request FIFO is full; software should wait before submitting more transfers

**Config field** (`DMCPY`/`DMCPYI`):
- Bit 0: Reserved
- Bit 1: Enable 2D mode (use previously set strides/reps). If 2D mode is enabled but `DMSTR`/`DMREP` were not called since the last transfer, the previously set stride and repetition values are reused. On reset, these default to zero
- Bits 4:2: Channel select — `$clog2(NumChannels)` bits wide, remaining upper bits are zero-extended. For the common single-channel case (`NumChannels=1`), these bits are unused and only bit 1 (2D enable) matters

## Parameters

For most Snitch cluster integrations, `NumChannels=1` and `NumAxInFlight=3` are standard. Increase `NumChannels` only if you need independent DMA channels on separate address spaces.

| Parameter | Description |
|-----------|-------------|
| `AxiDataWidth` | AXI data bus width |
| `AxiAddrWidth` | AXI address width |
| `AxiUserWidth` | AXI user signal width (max 64 bits) |
| `AxiIdWidth` | AXI ID width |
| `NumAxInFlight` | Number of in-flight AXI transactions (default: 3) |
| `DMAReqFifoDepth` | Depth of the request FIFO between frontend and midend (default: 3) |
| `NumChannels` | Number of independent DMA channels, each with its own backend + ND midend (default: 1) |
| `DMATracing` | Enable DMA trace file generation for debugging |

## Programming Sequence

The following assembly sequence demonstrates a complete 2D DMA transfer with polling completion:

```asm
# 1. Set source address
DMSRC   a0, a1          # src_addr = {a1, a0}

# 2. Set destination address
DMDST   a2, a3          # dst_addr = {a3, a2}

# 3. (Optional) Set 2D parameters
DMSTR   a4, a5          # src_stride = a4, dst_stride = a5
DMREP   a6              # reps = a6

# 4. Launch transfer (2D mode on channel 0)
DMCPYI  t0, a7, 0b010   # t0 = transfer_id, config[1]=1 (2D mode)

# 5. Poll for completion
loop:
  DMSTATI t1, 0b000      # t1 = completed_id on channel 0
  blt     t1, t0, loop   # Wait until completed_id >= transfer_id
```

## Internal Architecture

The `idma_inst64_top` module instantiates `NumChannels` independent backends, each paired with an ND midend (`NumDim=2`, `BufferDepth=3`). The frontend instruction decoder fills an `idma_nd_req_t` struct from the instruction stream and routes it to the selected channel's request FIFO. A per-channel transfer ID generator tracks issue and retire events. Each backend produces separate AXI read and write manager ports. The `axi_rw_join` module merges them into a single AXI manager port for connection to the SoC interconnect.

When `NumChannels > 1`, each channel has its own independent backend and ND midend. The channel is selected via the config field in `DMCPY`/`DMCPYI` (bits 4:2). Channels operate independently — one can be busy while another accepts new transfers. The AXI ports from all channels are merged via `axi_rw_join`, so they share bus bandwidth.

## Source Files

- `src/frontend/inst64/idma_inst64_top.sv` — Top-level module
- `src/frontend/inst64/idma_inst64_snitch_pkg.sv` — Instruction encodings
- `src/frontend/inst64/idma_inst64_events.sv` — Performance event counters

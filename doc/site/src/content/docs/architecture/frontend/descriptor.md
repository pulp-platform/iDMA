---
title: Descriptor Frontend
description: Descriptor-ring frontend for hardware-managed transfer queues.
---

## Overview

The descriptor frontend (`idma_desc64_top`) uses a linked list of transfer descriptors in shared memory. Hardware fetches descriptors autonomously over an AXI read port, enabling software to enqueue multiple transfers without polling for completion of each one.

## Descriptor Format

The descriptor frontend's reshaper (`idma_desc64_reshaper`) maps flag bits to backend options, but also hardcodes some values. Notably, `src_max_llen` and `dst_max_llen` are always set to 0 (full debursting), and `lock`, `prot`, `qos`, `region` are zeroed. These options cannot be controlled per-descriptor.

Each descriptor is a 256-bit packed struct stored in shared memory. The fields are laid out MSB-first (flags at the top, dest_addr at the bottom in a packed representation):

```verilog
typedef struct packed {
    logic [31:0] flags;      // Transfer flags (see below)
    logic [31:0] length;     // Transfer length in bytes
    addr_t       next;       // Address of next descriptor (0xFFFF...F = end of chain)
    addr_t       src_addr;   // Source address
    addr_t       dest_addr;  // Destination address
} descriptor_t;              // Total: 256 bits (addr_t = 64 bits)
```

Descriptors must be in memory accessible to the DMA's AXI read port. If the CPU caches this memory, ensure coherency (or use uncached memory). Descriptors are read as 256-bit naturally-aligned bursts.

### Flags Bitfield

| Bits | Field | Description |
|------|-------|-------------|
| 0 | `irq` | Trigger interrupt on completion |
| 2:1 | `src_burst` | Source burst type: 00=FIXED, 01=INCR, 10=WRAP |
| 4:3 | `dst_burst` | Destination burst type: 00=FIXED, 01=INCR, 10=WRAP |
| 5 | `decouple_rw` | Fully decouple read and write channels — the backend can write without waiting for reads to complete (risk of deadlock if buffer fills) |
| 6 | `decouple_aw` | Safer decoupling: write *addresses* are held back until the first read data arrives, but once data starts flowing, reads and writes proceed independently |
| 7 | `reduce_len` | Reduce burst length on both source and destination (`opt.beo.src_reduce_len` + `opt.beo.dst_reduce_len`) |
| 11:8 | `src_cache` | AXI cache attributes for source (bufferable, modifiable, read-alloc, write-alloc) |
| 15:12 | `dst_cache` | AXI cache attributes for destination |
| 23:16 | `axi_id` | AXI ID for the transfer |
| 31:24 | — | Reserved |

## Descriptor Chain Example

A two-descriptor chain that transfers 64 bytes, then 128 bytes, then stops:

```c
// Each descriptor is 32 bytes (256 bits), naturally aligned.
descriptor_t chain[2];
chain[0] = '{src_addr: 0x1000, dest_addr: 0x2000, length: 64,
             next: &chain[1], flags: 0};
chain[1] = '{src_addr: 0x1100, dest_addr: 0x2100, length: 128,
             next: 64'hFFFF_FFFF_FFFF_FFFF, flags: 1};  // flags[0]=1: IRQ on completion
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AddrWidth` | 64 | Address width |
| `DataWidth` | 64 | AXI data width |
| `AxiIdWidth` | 3 | AXI ID width |
| `InputFifoDepth` | 8 | Depth of the descriptor address input FIFO |
| `PendingFifoDepth` | 8 | Depth of the pending request tracking FIFO |
| `BackendDepth` | 0 | Backend pipeline depth (`NumAxInFlight + BufferDepth`) |
| `NSpeculation` | 4 | Number of descriptors to prefetch speculatively |

## Programming Sequence

1. **Allocate descriptors** in memory accessible to both CPU and DMA (e.g., uncached or coherent region)
2. **Fill descriptor fields**: Set `src_addr`, `dest_addr`, `length`, `flags` for each transfer
3. **Chain descriptors**: Set each descriptor's `next` field to the address of the following descriptor. Use `0xFFFFFFFF_FFFFFFFF` to mark the end of the chain
4. **Write first descriptor address** to the `desc_addr` register (via the register bus slave interface)
5. **Hardware fetches autonomously**: The frontend reads descriptors over AXI, submits them to the backend, and follows the `next` pointer chain
6. **Wait for completion**: Poll the status register (bit 0 = busy) or wait for the IRQ (if `flags.irq` is set)

## Speculative Prefetch

The `NSpeculation` parameter controls how many descriptors the frontend may fetch ahead of the backend's consumption. This hides the descriptor fetch latency — while the backend processes one transfer, the frontend is already reading the next `NSpeculation` descriptors from memory. Setting `NSpeculation=0` disables prefetching (each descriptor is fetched only after the previous transfer completes).

## Source Files

- `src/frontend/desc64/idma_desc64_top.sv` — Top-level module
- `src/frontend/desc64/idma_desc64_reg_wrapper.sv` — Register interface wrapper
- `src/frontend/desc64/idma_desc64_reshaper.sv` — Descriptor-to-request conversion

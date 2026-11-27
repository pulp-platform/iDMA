---
title: Descriptor Frontend
description: Descriptor-ring frontend for hardware-managed transfer queues.
---

## Descriptor Frontend Role

The descriptor frontend (`idma_desc64_top`) uses a linked list of transfer descriptors in shared memory. Hardware fetches descriptors autonomously over an AXI read port, enabling software to enqueue multiple transfers without polling for completion of each one.

## Descriptor Format

The reshaper (`idma_desc64_reshaper`) converts descriptor flags into backend
options. `src_max_llen` and `dst_max_llen` are fixed at zero, so setting
`reduce_len` limits both sides to one beat per burst. When `reduce_len` is clear,
the user limits are ignored; safe mode may still shorten read bursts.
`lock`, `prot`, `qos`, and `region` are fixed at zero.

Each descriptor is a 256-bit packed struct stored in shared memory. In a SystemVerilog packed struct, the first field (`flags`) occupies the most-significant bits and the last field (`dest_addr`) occupies the least-significant bits. In memory (little-endian), `dest_addr` is at the lowest byte address:

```verilog
typedef struct packed {
    logic [31:0] flags;      // Transfer flags (see below)
    logic [31:0] length;     // Transfer length in bytes
    addr_t       next;       // Address of next descriptor (0xFFFF...F = end of chain)
    addr_t       src_addr;   // Source address
    addr_t       dest_addr;  // Destination address
} descriptor_t;              // Total: 256 bits (addr_t = 64 bits)
```

Descriptors must be in memory accessible to the DMA's AXI read port. Descriptors are read as 256-bit naturally-aligned bursts.

:::caution[Cache coherency]
If the CPU uses a data cache, descriptors must be in an uncached or cache-coherent memory region. If you modify a descriptor after writing it and before the DMA reads it, flush the relevant cache lines. The DMA does not snoop CPU caches.
:::

### Flags Bitfield

| Bits | Field | Description |
|------|-------|-------------|
| 0 | `irq` | Trigger interrupt on completion |
| 2:1 | `src_burst` | Source burst type: 00=FIXED, 01=INCR, 10=WRAP |
| 4:3 | `dst_burst` | Destination burst type: 00=FIXED, 01=INCR, 10=WRAP |
| 5 | `decouple_rw` | Fully decouple read and write channels - the backend can write without waiting for reads to complete (risk of deadlock if buffer fills) |
| 6 | `decouple_aw` | Safer decoupling: write *addresses* are held back until the first read data arrives, but once data starts flowing, reads and writes proceed independently |
| 7 | `reduce_len` | Reduce burst length on both source and destination (`opt.beo.src_reduce_len` + `opt.beo.dst_reduce_len`) |
| 11:8 | `src_cache` | AXI cache attributes for source (bufferable, modifiable, read-alloc, write-alloc) |
| 15:12 | `dst_cache` | AXI cache attributes for destination |
| 23:16 | `axi_id` | AXI ID for the transfer |
| 24 | `deadlock_free` | Reserve byte-lane data-buffer capacity before issuing each read request |
| 31:25 | — | Reserved |

Set flag bit 24 to enable deadlock-free mode for that descriptor, for example
`flags |= (1u << 24)`. It is off when the bit is clear. Leave all other flags as
required by the transfer; safe mode does not select burst types or decoupling.

The backend shortens read bursts to fit its buffer, then checks space before
issuing each one. Data promised to earlier reads still counts as used space,
even if it has not arrived yet. Smaller user limits still apply; the descriptor's
`reduce_len` flag can further limit reads and writes to one beat each.

The descriptor format cannot select a four-beat limit or another arbitrary LLEN:
it offers only the default limit or one-beat bursts on both sides via `reduce_len`.
For finer tuning, use the register frontend or supply backend requests directly.
See [Choosing a Read Burst Limit](../../backend/#choosing-a-read-burst-limit).

Descriptors in a chain may use different safe-mode settings. Requests with the
mode off are still counted, but enabling it on a later descriptor cannot fix
an earlier transfer that is already stuck. Use it on every transfer that needs
the protection. The flag has no effect with `HardwareLegalizer=0`. See
[Deadlock-Free Mode](../../backend/#deadlock-free-mode) for details.

**Typical flags values**: `0x0000000A` selects INCR on both sides, with no IRQ;
`0x0000000B` also requests an IRQ; `0x0000006B` also sets both decoupling flags;
`0x0100000A` selects deadlock-free INCR transfers. Set the burst fields explicitly:
zero does not select INCR. This backend requires INCR on both sides.

## Descriptor Chain Example

:::note[Figure placeholder]
Diagram: descriptor chain layout in memory.
Show two descriptors, next pointer, and end-of-chain marker.
:::

A two-descriptor chain that transfers 64 bytes, then 128 bytes, then stops. Assume the descriptors are allocated at addresses `0x4000` and `0x4020` (32 bytes apart, naturally aligned):

```
// Descriptor at address 0x4000:
//   src_addr  = 0x1000
//   dest_addr = 0x2000
//   next      = 0x4020           (address of the second descriptor)
//   length    = 64
//   flags     = 0x0000000A       (INCR on both sides, no IRQ)

// Descriptor at address 0x4020:
//   src_addr  = 0x1100
//   dest_addr = 0x2100
//   next      = 0xFFFFFFFF_FFFFFFFF  (end of chain)
//   length    = 128
//   flags     = 0x0000000B       (INCR on both sides, IRQ on completion)
```

## Parameters

The descriptor frontend is configured through module parameters at instantiation time:

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
4. **Write first descriptor address** to the `desc_addr` register. This register is part of the descriptor frontend's own small register file (separate from the descriptor memory). Writing a non-zero address to it triggers the fetch engine
5. **Hardware fetches autonomously**: The frontend reads descriptors over AXI, submits them to the backend, and follows the `next` pointer chain
6. **Wait for completion**: Poll the status register (bit 0 = busy) or wait for the IRQ (if `flags.irq` is set)

## Speculative Prefetch

The `NSpeculation` parameter controls how many descriptors the frontend may fetch ahead of the backend's consumption. This hides the descriptor fetch latency - while the backend processes one transfer, the frontend is already reading the next `NSpeculation` descriptors from memory. Setting `NSpeculation=0` disables prefetching (each descriptor is fetched only after the previous transfer completes).

Set `NSpeculation` to match your expected descriptor chain length or `NumAxInFlight`, whichever is smaller. Higher values waste memory bandwidth on speculative reads if chains are short. For most systems, `NSpeculation=4` is a good default.

## Source Files

- `src/frontend/desc64/idma_desc64_top.sv` - Top-level module
- `src/frontend/desc64/idma_desc64_reg_wrapper.sv` - Register interface wrapper
- `src/frontend/desc64/idma_desc64_reshaper.sv` - Descriptor-to-request conversion

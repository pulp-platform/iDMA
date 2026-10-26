---
title: Performance and Limitations
description: Constraints, tradeoffs, and tuning guidance.
---

## Constraints Overview

This guide summarizes practical constraints and tradeoffs that impact performance, area, and correctness.

## Alignment and Burst Limits

- AXI bursts cannot cross 4 KiB boundaries.
- TileLink bursts are power-of-2 and limited by TLToAXI4 behavior.
- OBI and INIT are single-beat protocols.

## Buffer Depth

`BufferDepth` impacts throughput and alignment tolerance. Depth 3 is the default recommendation for mixed alignment cases; smaller depths can stall when read and write offsets differ.

## Decoupling and Deadlocks

- Read and write burst lengths are chosen independently.
- `decouple_aw=1` enables R-AW coupling, which can reduce bus contention but adds latency.
- `deadlock_free=1` shortens read bursts to fit the buffer and waits for enough
  free space before issuing each one. It also counts reads whose data has not
  arrived yet. Short bursts alone do not provide this check.
- The mode is off by default and requires `HardwareLegalizer=1`. Use it on all
  transfers that may block each other's reads and writes. It does not fix an
  already-stuck unsafe transfer or a memory system that never responds.

See [Deadlock-Free Mode](../../architecture/backend/#deadlock-free-mode) for
buffer accounting and examples. The extra checks and shorter bursts may reduce
throughput; disabling the mode is appropriate only if the system guarantees progress.

### Read Burst Size in Safe Mode

The default read limit is the largest power of two that fits in `BufferDepth`,
subject to the protocol and field limits. Depth 8 therefore permits eight-beat
reads. A burst that reserves the whole buffer makes the next equally sized read
wait for all lanes to drain, leaving a gap while new data arrives.

Try a smaller limit near half the depth, rounded down to a power of two (minimum
one beat). For depth 8, keep `deadlock_free=1`, set `src_reduce_len=1`, and set
`src_max_llen=2` for four-beat reads. The next read can start while writes still
have buffered data. More small bursts can remain outstanding without exceeding
the buffer's total space.

This trades earlier reads for more address transactions. Measure both settings;
half depth is a starting point, not always the best choice. Changing the read
limit does not change the write limit. See
[Choosing a Read Burst Limit](../../architecture/backend/#choosing-a-read-burst-limit)
for examples and frontend controls.

## Outstanding Transactions

`NumAxInFlight` controls how many bursts can be in flight. Increasing it improves throughput on high-latency buses but increases area and verification complexity.

## Software Legalization

If `HardwareLegalizer=0`, software must split transfers into protocol-legal bursts. This reduces hardware but shifts correctness burden to software.

In this configuration `deadlock_free` is ignored; software must also ensure
the memory system cannot deadlock on outstanding DMA reads and writes.

## On-the-Fly Compute

Compute (`EnableCompute`) applies only on compute-eligible backends (AXI or OBI on both read and write paths). Per-transfer constraints, enforced by the legalizer:

- Size-changing MX ops force `decouple_aw`, since read and write lengths differ.
- Transfer length must be a whole multiple of the op's input granule (128 B FP32, 64 B FP16, 32 B per block of the MX data plane); source and destination must be beat-aligned.
- MX ops require `StrbWidth <= 64` (one 64 B scale line per beat).
- MX dequant reads whole beats: the last data beat may read up to `StrbWidth - 1` bytes past the end of the data plane, and a partial last group reads its whole 64 B scale line (never across a 4 KiB page). The memory behind both planes must be readable there.
- A quant transfer of one block writes two beats (data and scale) per read beat. While the write side emits an MX transfer, the legalizer's read side runs up to three requests ahead of it, so a stream of such transfers keeps the read channel ahead after a read stall, and the read side of a dequant or copy behind a short quant starts without waiting for the quant's writes.
- MX beats bypass the dataflow element into per-engine input queues, so a dequant transfer whose input waits for the write side does not hold back the next transfer's input. Transfer boundaries are covered in Back-to-Back Transfers below.
- Size-changing MX is validated on AXI source/destination only; OBI is not yet supported. TileLink is not a valid compute write destination.
- Transpose is size-preserving but restricted to single-beat writes.

Transpose throughput is one beat per cycle once the first `NE`-beat tile is filled, where `NE = StrbWidth / element_bytes`, also across back-to-back requests with the same compute config. A changed config (`mode`, `M`, `N` or op) drains the backend first, so a stream of per-tile requests with alternating geometry runs at about half rate or less. `ComputeTuning.transpose_full_duplex = 0` halves both area and rate by using a single tile bank. Unselected `ComputeOps` are not synthesized, so build only the ops you use.

## Back-to-Back Transfers

The legalizer splits one request at a time into bursts and takes the next request in the cycle it emits the last burst of the current one. Read and write burst requests queue separately (`NumAxInFlight` deep), so the next transfer's AR goes out while the current transfer's data is still in flight, and the write side follows in request order. Copy beats pass the dataflow element (`BufferDepth` beats per byte lane); read and write move at the same rate, so a stream of copies has no idle cycle at a transfer boundary on either channel.

MX transfers and copies do not drain the datapath at a boundary (transpose does, see above). MX beats go from the read side into their engine with the transfer's options in a beat tag, and the write side takes each burst from the output queue of its op. Since the write side is in order and the queues are a few beats deep, a read-bound transfer (quant, copy) behind a write-bound one (dequant, quant of one block) can leave the read channel idle while the write channel keeps moving. With an ideal memory, a transfer's bottleneck channel idles at a boundary only in these cases:

| Case | Idle channel | Bound | Cause | Removing it needs |
|------|--------------|-------|-------|-------------------|
| Read-bound transfer behind an earlier write-bound one | R | one cycle per W beat of the earlier transfer, once the next engine's queues (or the dataflow element, for a copy) are full | W still writes the earlier transfer | output buffering for the overlap, up to the earlier transfer's write length |
| Quant after W switches to it from a write-bound transfer | R | 2 cycles | registered credit return of the quant output queue | a combinational W-ready to R-ready path |
| Copy behind a quant | R | per quant: the cycles W writes it, plus `BufferDepth` + quant pipeline + one scale line (9 at 512 bit, `BufferDepth` 3) | copy beats wait in the dataflow element until the quant output is written | engines on the read side of the dataflow element |

The first write beat of a dequant behind a copy typically comes one cycle after the copy's last one, since the dequant pipeline is one cycle longer than the copy path; this is latency, not a stall. A short shifted copy behind an MX transfer can also be refused for a cycle when the byte lanes it needs in the dataflow element are full while others have room.

## Register Frontend Config Bus

The register frontend's config bus is a selectable PeakRDL CPUIF (`IDMA_REG_CPUIF`): `apb4-flat` (default), `obi-flat`, or `axi4-lite-flat`. The descriptor (`desc64`) frontend is APB-native and not part of the selector.

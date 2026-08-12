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

## Decoupling Tradeoffs

- `decouple_rw=1` maximizes throughput but can deadlock if the buffer is too shallow.
- `decouple_aw=1` enables R-AW coupling, which can reduce bus contention but adds latency.

## Outstanding Transactions

`NumAxInFlight` controls how many bursts can be in flight. Increasing it improves throughput on high-latency buses but increases area and verification complexity.

## Software Legalization

If `HardwareLegalizer=0`, software must split transfers into protocol-legal bursts. This reduces hardware but shifts correctness burden to software.

## On-the-Fly Compute

Compute (`EnableCompute`) applies only on compute-eligible backends (AXI or OBI on both read and write paths). Per-transfer constraints, enforced by the legalizer:

- Size-changing MX ops force `decouple_rw`/`decouple_aw`, since read and write lengths differ.
- Transfer length must be a whole multiple of the op's input granule (128 B FP32, 64 B FP16, 33 B MX block); source and destination must be beat-aligned.
- FP16 MX paths require `StrbWidth <= 64` (at most one 32-element block completes per beat).
- Size-changing MX is validated on AXI source/destination only; OBI is not yet supported. TileLink is not a valid compute write destination.
- Transpose is size-preserving but restricted to single-beat writes.

Transpose throughput is `1 + 1/NE` cycles per `NE`-beat tile, where `NE = StrbWidth / element_bytes`. `ComputeTuning.transpose_full_duplex = 0` halves both area and rate by using a single tile bank. Unselected `ComputeOps` are not synthesized, so build only the ops you use.

## Register Frontend Config Bus

The register frontend's config bus is a selectable PeakRDL CPUIF (`IDMA_REG_CPUIF`): `apb4-flat` (default), `obi-flat`, or `axi4-lite-flat`. The descriptor (`desc64`) frontend is APB-native and not part of the selector.

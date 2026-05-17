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

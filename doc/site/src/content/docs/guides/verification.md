---
title: Verification
description: Testbench architecture, job files, and simulation workflow for iDMA.
---

## Overview

iDMA uses a SystemVerilog testbench driven by **job files** that describe transfer sequences. The testbench compares hardware behavior against a byte-accurate golden model. Tests are run with Questa or VCS, with job files located in `jobs/<backend_variant>/`.

## Testbench Architecture

### Key Components

| Component | Location | Description |
|-----------|----------|-------------|
| `idma_test` package | `test/idma_test.sv` | Shared test infrastructure: job class, golden model, drivers |
| `tb_idma_backend_*` | `test/tpl/tb_idma_backend.sv.tpl` (generated) | Per-variant top-level testbench module |
| `tb_tasks.svh` | `test/include/tb_tasks.svh` | Protocol-specific memory access tasks, job file parser |

### Golden Model

The testbench uses a **golden model** — a software reference implementation that predicts the expected memory state after each DMA transfer. By comparing the hardware's actual memory writes against the model's predictions, the testbench detects functional bugs without requiring hand-written expected values.

The `idma_model` class in `idma_test.sv` is a byte-addressed memory model that simulates DMA transfers at the byte granularity. It replicates the legalizer's burst splitting logic (page boundaries, maximum burst lengths) and error handling behavior (continue/abort semantics). After each transfer, the testbench compares the hardware memory state against the model's expected state to detect mismatches. The golden model uses the `max_src_len` and `max_dst_len` fields from the job file to configure burst splitting — these must match the protocol's actual limits for comparisons to pass. If `max_src_len`/`max_dst_len` don't match the protocol's actual burst limits, the golden model will split bursts differently than the hardware legalizer, causing false mismatches.

## Job File Format

Each job file contains one or more transfer descriptions, concatenated back-to-back. Each transfer is described by the following fields, one per line.

The most important fields are `length`, `src_addr`, `dst_addr`, and the two `max_*_len` fields (which must match your protocol's actual burst limits). For a basic AXI test, set both protocols to 0, both max lengths to 256, and both decoupling flags to 0.

### Fields

| Line | Format | Field | Description |
|------|--------|-------|-------------|
| 1 | `%d` | `length` | Transfer length in bytes |
| 2 | `0x%x` | `src_addr` | Source address (hex) |
| 3 | `0x%x` | `dst_addr` | Destination address (hex) |
| 4 | `%d` | `src_protocol` | Source protocol enum (0=AXI, 1=OBI, ...) |
| 5 | `%d` | `dst_protocol` | Destination protocol enum |
| 6 | `%d` | `max_src_len` | Max source burst length in beats |
| 7 | `%d` | `max_dst_len` | Max destination burst length in beats |
| 8 | `%b` | `aw_decoupled` | AW decoupling flag (0 or 1) |
| 9 | `%b` | `rw_decoupled` | RW decoupling flag (0 or 1) |
| 10 | `%d` | `num_errors` | Number of injected errors (0 for clean transfers) |
| 11+ | `%c%c0x%h` | error specs | One line per error: `r`/`w` + `c`/`a` + hex address |

Error spec format: first character is `r` (read) or `w` (write), second is `c` (continue) or `a` (abort), followed by the error address in hex.

### Example

Annotated `simple.txt` (a single 2-byte transfer with no errors):

```
2           # length: 2 bytes
0x0         # src_addr: 0x000
0x3ff       # dst_addr: 0x3ff
0           # src_protocol: AXI (0)
0           # dst_protocol: AXI (0)
256         # max_src_len: 256 beats
256         # max_dst_len: 256 beats
0           # aw_decoupled: no
0           # rw_decoupled: no
0           # num_errors: 0
```

Annotated error transfer (from `error_simple.txt`):

```
32          # length: 32 bytes
0x0         # src_addr
0x10000     # dst_addr
0           # AXI read
0           # AXI write
256         # max 256 beats
256         # max 256 beats
0           # aw_decoupled: no
0           # rw_decoupled: no
3           # 3 injected errors:
rc0x4       #   read error at 0x4, action: continue
rc0x8       #   read error at 0x8, action: continue
rc0xc       #   read error at 0xc, action: continue
```

### Writing Custom Job Files

To create a custom test, write a text file following the format above. Each field is on its own line, with transfers concatenated back-to-back (no blank lines between them). The `max_src_len` and `max_dst_len` fields control burst splitting in the golden model — set to 256 for AXI (matching the protocol maximum) or 1 for single-beat protocols (OBI, INIT, AXI Stream).

Here is an example with two back-to-back transfers in a single job file (64 bytes followed by 128 bytes, no errors):

```
64
0x0
0x1000
0
0
256
256
0
0
0
128
0x100
0x2000
0
0
256
256
1
0
0
```

## Available Test Suites

Each backend variant has its own set of job files under `jobs/<variant>/`:

**Basic** — start here for bring-up and sanity checks:

| Job File | Description |
|----------|-------------|
| `simple.txt` | Minimal transfer (2 bytes), basic sanity check |
| `small.txt` | A few short transfers |
| `tiny.txt` | Very small (sub-word) transfers |

**Stress** — increasing transfer sizes for throughput and boundary testing:

| Job File | Description |
|----------|-------------|
| `medium.txt` | Mixed lengths, some with AW decoupling |
| `large.txt` | Longer transfers approaching page boundaries |
| `huge.txt` | Large transfers spanning multiple pages |

**Pattern** — specific address and access patterns:

| Job File | Description |
|----------|-------------|
| `linear.txt` | Sequential address patterns |
| `mixed.txt` | Varied source/destination alignments |
| `same_dst.txt` | Multiple transfers to the same destination |
| `zero_transfer.txt` | Zero-length transfer (tests `RejectZeroTransfers`) |

**Error** — error injection and handling:

| Job File | Description |
|----------|-------------|
| `error_simple.txt` | Transfers with injected read/write errors and continue/abort actions |
| `error_mixed.txt` | Complex error scenarios with multiple error types |

For initial bring-up, start with `simple.txt` on the `rw_axi` variant — it's the smallest test on the most common backend.

<!-- TODO: Replace with SVG testbench block diagram -->
<!--
┌──────────────────────────────────────────────────────────────┐
│                        Testbench                             │
│                                                              │
│  ┌──────────┐    ┌────────────────────┐    ┌──────────────┐  │
│  │ Job File │───>│  tb_idma_backend   │───>│  Sim Memory  │  │
│  │ Parser   │    │  (DUT wrapper)     │    │  (AXI slave) │  │
│  └──────────┘    └────────────────────┘    └──────────────┘  │
│       │                                          │           │
│       v                                          v           │
│  ┌──────────┐                             ┌──────────────┐   │
│  │  Golden  │─── compare after each ─────>│   Checker    │   │
│  │  Model   │    transfer                 │  (pass/fail) │   │
│  └──────────┘                             └──────────────┘   │
└──────────────────────────────────────────────────────────────┘
-->

## Running Simulations

### Prerequisites

Before running any simulation, generate the RTL and simulation scripts:

```bash
make idma_hw_all    # Generate RTL into target/rtl/
make idma_sim_all   # Generate compile.tcl and start.tcl into target/sim/vsim/
```

### Compile

Compile the generated design with Questa:

```bash
cd target/sim/vsim
questa-2023.4 vsim -c -do "source compile.tcl; quit"
```

### Run

Run a simulation against a specific job file:

```bash
questa-2023.4 vsim -c -t 1ps -voptargs=+acc \
  +job_file=../../../jobs/backend_rw_axi/simple.txt \
  -logfile output.log \
  tb_idma_backend_rw_axi \
  -do "source start.tcl; run -all"
```

Replace `backend_rw_axi` and `tb_idma_backend_rw_axi` with the desired variant. The `+job_file` plusarg points to the job file describing the test sequence.

### Debugging Failures

If a simulation fails, the testbench prints the first mismatching address and expected vs. actual values. To debug further, open the waveform in the Questa GUI by removing the `-c` flag from the vsim command.

Check the `busy_o` flags to identify which subunit stalled:

| Flag | Stuck means |
|------|-------------|
| `r_leg_busy` | Legalizer can't split — check transfer parameters |
| `r_dp_busy` | Read channel not getting responses — check memory slave |
| `buffer_busy` | Write channel not draining — check write backpressure |
| `w_dp_busy` | Write channel blocked — check destination memory |
| `eh_fsm_busy` | Error handler waiting for software action |

Key signals to trace in waveforms: `idma_req_i`/`req_valid_i`/`req_ready_o` (request handshake), `idma_rsp_o`/`rsp_valid_o` (response), `busy_o` (subunit status), and the AXI AR/AW/R/W/B channels on the bus interface.

### VCS

Simulation scripts for VCS are generated alongside Questa scripts via `make idma_sim_all`. The flow is analogous — compile with the generated script, then run with the `+job_file` plusarg.

## Source Files

- `test/idma_test.sv` — Test package (job class, golden model, drivers)
- `test/tpl/tb_idma_backend.sv.tpl` — Testbench template (generates per-variant TBs)
- `test/include/tb_tasks.svh` — Memory tasks, job parser (`read_jobs`)
- `jobs/` — Job files organized by backend variant

---
title: Error Handling
description: How iDMA reports and propagates errors across the frontend, midend, and backend.
---

## Overview

iDMA propagates error information from the backend (bus-level faults) back through the midend to the frontend, where software can read error status registers. Error handling is optional — controlled by the `ErrorCap` parameter. When enabled (`ErrorCap = ERROR_HANDLING`), the error handler FSM monitors datapath responses and gives software the choice to continue or abort a faulting transfer.

## Error Types

From `err_type_e` in `idma_pkg.sv`:

| Value | Name | Description |
|-------|------|-------------|
| `2'b00` | `BUS_READ` | AXI read channel returned a non-OKAY response |
| `2'b01` | `BUS_WRITE` | AXI write channel returned a non-OKAY response |
| `2'b10` | `BACKEND` | Internal backend error (currently: transfer length == 0) |
| `2'b11` | `ND_MIDEND` | ND midend error (all repetition counts are zero) |

## Error Response

When an error occurs, the `idma_rsp_t` response is populated. These structs flow from the error handler to the frontend:

```verilog
typedef struct packed {
    axi_pkg::resp_t      cause;      // AXI response code (SLVERR, DECERR)
    idma_pkg::err_type_t err_type;   // BUS_READ, BUS_WRITE, BACKEND, or ND_MIDEND
    axi_addr_t           burst_addr; // Address of the faulting burst
} err_payload_t;

typedef struct packed {
    logic         last;   // Last response in this transfer sequence
    logic         error;  // 1 = error occurred
    err_payload_t pld;    // Error details
} idma_rsp_t;
```

The `burst_addr` field reports the base address of the AXI burst that faulted — this is the address from the AR or AW channel, not the individual beat address.

## Error Handler FSM

The error handler (`idma_error_handler`) implements a 5-state FSM:

| State | Description | Transition |
|-------|-------------|------------|
| `IDLE` | Pass-through mode. Monitors R and W datapath responses for non-OKAY | -> `WAIT` on read error; -> `WAIT` or `WAIT_LAST_W` on write error |
| `WAIT` | Error reported to software. Waiting for CONTINUE or ABORT action | -> `IDLE` on CONTINUE; -> `IDLE` if ABORT with multiple outstanding; -> `LEG_FLUSH` if ABORT with single outstanding |
| `WAIT_LAST_W` | Like WAIT, but the error occurred on the last write burst of a 1D transfer. Requires an extra response after handling | -> `EMIT_EXTRA_RSP` on CONTINUE; -> `EMIT_EXTRA_RSP` if ABORT with multiple outstanding; -> `LEG_FLUSH` if ABORT with single outstanding |
| `EMIT_EXTRA_RSP` | Send the completion response that was deferred due to the error | -> `IDLE` when response is accepted |
| `LEG_FLUSH` | Flush the legalizer: drain remaining bursts, poison data, then kill the active transfer | -> `EMIT_EXTRA_RSP` when datapath is idle |

The `WAIT_LAST_W` state exists because write errors on the last burst of a transfer require special handling. Normally, the backend emits a completion response when the last write finishes. But if that last write *also* faults, the error response must be sent *before* the completion response, requiring an extra `EMIT_EXTRA_RSP` state.

Read errors have higher priority than write errors — if both occur simultaneously, the read error is reported first.

## Actions

Software responds to an error via the `idma_eh_req_t` interface:

| Action | Value | Behavior |
|--------|-------|----------|
| `CONTINUE` | `1'b0` | Complete the remaining bursts of the current 1D transfer normally. Data for the faulting burst is undefined |
| `ABORT` | `1'b1` | Abort the current 1D transfer. The legalizer is flushed (remaining bursts suppressed) and the datapath drains. If multiple 1D transfers are outstanding, abort degrades to continue (see below) |

**Data integrity on CONTINUE**: When a read error occurs, the data for that burst is undefined (whatever the bus returned). The buffer may contain partial or garbage data. If CONTINUE is selected, subsequent bursts are read normally but the faulting burst's data is corrupted in the destination.

**ABORT degradation**: When multiple 1D transfers are queued in the legalizer, aborting would require flushing transfers that may have already issued bus requests. Since AXI requires all issued bursts to complete, flushing mid-stream would leave the bus in an inconsistent state. Therefore, ABORT only takes effect when a single transfer is outstanding; otherwise it degrades to CONTINUE.

## Software Handling Pattern

1. **Launch transfer**: Submit `idma_req_t` through the frontend
2. **Wait for response**: Poll or wait for `rsp_valid`
3. **Check `rsp.error`**: If 0, transfer completed successfully
4. **Read error details**: Extract `rsp.pld.err_type`, `rsp.pld.cause`, and `rsp.pld.burst_addr`
5. **Issue action**: Write CONTINUE or ABORT to the error handler request interface (`idma_eh_req_i` + `eh_req_valid_i`), then wait for the final completion response

## Error Visibility by Frontend

How errors reach software depends on the frontend:

- **Register frontend**: Exposes error status through the `idma_rsp_t` response — poll `done_id` then check the response
- **Descriptor frontend**: Signals errors via IRQ (if `flags.irq` is set in the descriptor)
- **Snitch frontend**: Returns error information through `DMSTAT` polling

## Constraints

- **AXI-to-AXI only**: The error handler is only instantiated for backend variants with a single AXI read port and a single AXI write port (i.e., the `rw_axi` variant). Mixed-protocol variants (`r_obi_w_axi`, `r_axi_w_obi`) and multi-port variants (`rw_axi_rw_axis`) will produce a fatal elaboration error (`$fatal`) if `ErrorCap = ERROR_HANDLING`. See the [Backend](../architecture/backend/) page for the full variant matrix
- **ErrorCap parameter**: Must be set at elaboration time. When `NO_ERROR_HANDLING`, all error signals are tied to neutral values and the error handler is bypassed
- **AXI compliance**: Once a burst is issued, all beats must complete — the error handler cannot cancel individual beats mid-burst. ABORT takes effect at burst boundaries
- **Outstanding transfer limit**: The error handler tracks outstanding transfers with a credit counter sized to `MetaFifoDepth`. The `cnt_busy` signal indicates transfers are still in-flight

## Source Files

- `src/backend/idma_error_handler.sv` — Error handler FSM
- `src/idma_pkg.sv` — Error type definitions (`err_type_e`, `eh_action_e`, `error_cap_e`)
- `src/include/idma/typedef.svh` — `err_payload_t` macro

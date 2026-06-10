# Snitch (inst64) iDMA integration

Standalone host for the **inst64** ISA-coupled frontend (`idma_inst64_top`) — the
tightly-coupled Snitch DMA interface. iDMA already owns `idma_inst64_top`; this
directory adds a cluster-free verification harness and (Stage 2) the on-the-fly
transpose wired through the accelerator interface.

## Recycled, not reinvented

The harness is **recycled from the vidma fork's inst64 verification interface**
(`idma_alu_vec/test/frontend/`), adapted only as the clean upstream single-head
`idma_inst64_top` requires:

| File | Provenance |
|------|------------|
| `test/idma_inst64_tb_pkg.sv` | faithful copy (8-line delta: `AxiDataWidth`/`NumAxInFlight` sizing + header) |
| `test/idma_inst64_drv_if.sv` | faithful copy; dropped the 4 vidma-only tasks (`DMOPC`, multi-head copy, immediate `DMCPYI`) to match upstream |
| `test/idma_inst64_base.sv` | adapted: single-head (`axi_req_o[NumChannels]`, no `NumHeads`/`enable_single_head_mode`) |
| `test/tb_idma_inst64_copy.sv` | Stage-1 plain-copy regression |

The accelerator interface (the 4-field `acc_req`/`acc_res` bus + the `DM*`
instruction BFM) is exactly the vidma one — no reinvention.

## Why split_rtl

`idma_inst64_top` is gated behind the `snitch_cluster` Bender target. The build
uses `-t split_rtl` (per-variant RTL) because the **bundled `idma_generated.sv`
predates the typed `opt.compute` struct** (it still references the old flat
`opt.transpose_en` fields) and won't elaborate against the current package. The
split_rtl `idma_backend_rw_axi` is compute-enabled (`IDMA_VIDMA_IDS=rw_axi`).

## Standalone simulation

```bash
make -C systems/snitch snitch_sim                 # plain-copy regression (Stage 1)
make -C systems/snitch snitch_sim TOP=tb_idma_inst64_transpose   # transpose (Stage 2)
```

Drives `DMSRC`/`DMDST`/`DMCPY` (+ `DMSTR`/`DMREP` for 2D) over the accelerator
bus and verifies the AXI sim memory. Requires `questa-2023.4`.

## Status

- **Stage 1 (done):** plain copy through the single-head frontend — 3 transfers pass.
- **Stage 2 (done):** multi-tile on-the-fly transpose, end-to-end. A transpose is
  programmed with the spare `DMCPY` argb bits (`[5]`=enable, `[7:6]`=mode,
  `[19:8]`=M, `[31:20]`=N), populating the typed per-transfer `opt.compute`; the
  dedicated `src/midend/idma_transpose_midend.sv` expands `(M,N,mode)` into the
  `NumDim=4` tiled walk; the unmodified `idma_nd_midend` walks it into the
  compute-enabled `rw_axi` backend. Gated by `idma_inst64_top`'s
  `ComputeEnable.transpose` (off by default, so other snitch_cluster consumers
  are unaffected). Verified across int8/fp16/fp32, single/multi-tile, edge tiles,
  padding integrity, back-to-back, and cross-transfer no-leak:
  `make -C systems/snitch snitch_transpose_sweep`. Full functionality at any
  `NumAxInFlight` (down to the backend min) — the compute backend internally
  buffers a tile of write descriptors (`ComputeFifoDepth = StrbWidth`), so there
  is no `NumAxInFlight >= NE` constraint.

## Transpose memory contract

A transposed transfer reads the source up to the tile-padded bounds
(`ceil(M/NE)*NE` rows of `N` elements, the last row tile reading past row `M-1`)
and writes the full padded destination extent (`ceil(N/NE)*NE` rows at pitch
`MP = ceil(M/NE)*NE`; padding is strobe-masked but addressed). Both regions must
be mapped, side-effect-free memory.

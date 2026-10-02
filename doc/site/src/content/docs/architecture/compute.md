---
title: Compute
description: On-the-fly transpose and OCP microscaling (MX) quant/dequant in the transport datapath.
---

## On-the-Fly Compute Role

iDMA can transform data *while it is in flight* instead of moving it verbatim. The compute engine sits in the transport layer on the write side, between the read dataflow buffer and the write barrel shifter, so the transform runs on the beats streaming from source to destination with no round trip to memory. It is optional and elaborated only when `EnableCompute` is set; otherwise the write path is a plain pass-through.

Two op families are provided:

- **Transpose** (`idma_otf_transpose`) - tiled matrix transpose, element size 1/2/4/8 B.
- **MX quant / dequant** (`idma_otf_mxquant`, `idma_otf_mxdequant`) - OCP microscaling conversion between FP32/FP16 and MXFP8, with the FP cast math in `src/idma_float_pkg.sv`.

A single dispatcher, `idma_otf_compute`, routes one op per transfer to the selected sub-unit. Changing the compute config drains the engine before the next transfer starts.

:::note[Diagram placeholder]
TODO: transport-layer datapath showing the compute engine between the read buffer output and the write barrel shifter, with transpose / mxquant / mxdequant sub-units fed by the op dispatcher.
:::

## Elaboration and Selection

Compute is configured at two levels:

**Compile time** (backend/transport-layer parameters):

| Parameter | Type | Description |
|-----------|------|-------------|
| `EnableCompute` | `bit` | Elaborate the compute engine at all |
| `ComputeOps` | `idma_pkg::compute_enable_t` | Per-op enable mask: `transpose`, `mxquant`, `mxdequant`, `mxfp16` |
| `ComputeTuning` | `idma_pkg::compute_tuning_t` | Implementation knobs (`transpose_full_duplex`) |

`mxfp16` gates the FP16 source/destination paths of the MX ops; leaving it off drops that area. An op requested at run time but not elaborated is caught by the legalizer (`ComputeOpUnsupported`) and a simulation assertion in the dispatcher.

**Per transfer** (`idma_req_t.opt.compute`, type `idma_pkg::compute_options_t`):

| Field | Description |
|-------|-------------|
| `enable` | Arm compute for this transfer |
| `op` | `idma_pkg::compute_op_e` selector |
| `params.transpose` | `mode` (element size), `tensor_m`, `tensor_n` (elements) |

The register frontend exposes these through its `compute_cfg` register. The op encoding is single-homed in `src/frontend/reg/idma_reg.rdl` and re-exported as `idma_pkg::compute_op_e`:

| `compute_op_e` | Meaning | Input granule | Output granule |
|----------------|---------|---------------|----------------|
| `COMPUTE_NONE` | Plain copy | - | - |
| `COMPUTE_TRANSPOSE` | Tiled transpose | = output | = input |
| `COMPUTE_MXQUANT` | Quantize, FP32 source | 128 B / block | 33 B / block |
| `COMPUTE_MXQUANT_FP16` | Quantize, FP16 source | 64 B / block | 33 B / block |
| `COMPUTE_MXDEQUANT` | Dequantize, FP32 destination | 33 B / block | 128 B / block |
| `COMPUTE_MXDEQUANT_FP16` | Dequantize, FP16 destination | 33 B / block | 64 B / block |

## Transpose

`idma_otf_transpose` transposes a row-major M x N tensor using flip-flop tile banks. The element size is `E = 1 << mode` bytes (8/16/32/64 bit); tiles are `NE x NE` elements where `NE = StrbWidth / E`. Input is fed padded to full tiles in (col-tile, row-tile, row) order and the output realizes `out[n][m] = in[m][n]`; partial edge tiles are masked with the per-byte output strobe. Dimensions are `TransposeDimWidth = 12` bits (elements).

Tuning: with `transpose_full_duplex = 1` two tile banks let the engine fill one bank while draining the other (full rate, one beat per cycle once the first tile is filled); `0` uses a single bank at half area and half rate. Each bank carries the geometry of the tile it holds, so the overlap also spans back-to-back transfers, such as one padded tile per request. A request whose compute config differs from the previous one (another op, `mode`, `M` or `N`) still waits for the backend to drain.

Transpose does not change transfer size, and the transport layer retires an output beat only once every logical byte lane has been consumed, so one output beat may span several bus beats. `ComputeTransposeShape` accepts a tiled-walk strip of at most one beat (the shape the midend emits) or one whole padded tile in a single burst (`length == NE * StrbWidth`, `M` and `N` at most `NE`, source at a `StrbWidth` row pitch). The tile shape additionally requires a beat-aligned destination, since a misaligned bus beat would draw from two consecutive compute beats at once; a misaligned source is fine in either shape.

## MX Quant / Dequant

The MX ops implement OCP microscaling (MX) format conversion in blocks of `MxBlockElems = 32` elements. A compressed MX block is `MxBlockBytes = 33` B: one OCP E8M0 block scale byte followed by 32 MXFP8 (E5M2) element bytes. The uncompressed forms are FP32 (`4 * 32 = 128` B) or FP16 (`2 * 32 = 64` B) per block.

- **Quantize** (`idma_otf_mxquant`): a four-stage pipeline on whole beats. Q0 unpacks the FP32 (4 B/elem) or FP16 (2 B/elem, natively) elements of a beat into the block's lane register and takes a partial exponent maximum; Q1 computes the block scale from the maximum element exponent (the shared exponent clamps to the E8M0 range) and each lane's exponent distance to it; Q2 casts the 32 elements to E5M2 with round-to-nearest-even, exact FP16/FP32 subnormal inputs and E5M2 subnormal outputs; Q3 writes the 33 B block at its byte offset into an output queue of whole destination beats.
- **Dequantize** (`idma_otf_mxdequant`): expands each 33 B MX block back to FP32 (128 B) or FP16 (64 B), applying the decoded block scale per element. It accepts whole input beats into a 3-entry input buffer, extracts one output beat's worth of elements per cycle (a whole block for FP16 at 512 bit, half a block for FP32) and expands them straight into a 3-entry output queue.
- Both engines never stall once a beat is in: a beat leaves the dataflow element only while the engine holds credit for it, and the credit check is registered. Each MX beat carries a tag (`idma_pkg::mx_tag_t`: op, format, poison disable, last beat of the transfer) in a FIFO beside byte lane 0 of the dataflow element, and every byte lane marks the bytes of MX beats, so an MX beat is popped once it heads every lane, independent of the copy bytes around it. The write side takes the head of the current write burst's output queue after the write shifter and pops it on the W handshake. MX transfers therefore need no transfer-boundary clear.

The FP cast primitives (quantizer lane unpack and E5M2 element rounding, E5M2 -> FP32/FP16 expansion) live in the `idma_float_pkg` package.

:::note[E8M0 block scale]
The scale byte `E` is OCP MX v1.0 E8M0: the block scale is `2^(E - 127)`, `E` in 0..254, and `0xFF` is NaN. Quantize sets the shared exponent to the block's largest finite FP32 exponent minus the E5M2 emax (15), clamped to [-127, 127]; an all-zero block gets `E = 0`. A block holding an Inf or NaN is poisoned: its scale is `0xFF` and every element the canonical E5M2 NaN `0x7D`. The per-transfer `mx_options_t.poison_dis` bit (register `mx_cfg.mx_poison_dis`, DMOPC `rs1[18]` on the quant opcodes) keeps such a block finite instead: the scale comes from the finite lanes, NaN quantizes to E5M2 NaN and Inf saturates to the E5M2 max normal. Dequantize turns every element of a `0xFF`-scale block into NaN and is exact: results below the FP32 min normal become FP32 subnormals, results above the FP32 max become Inf.
:::

## Size-Changing Transfers

MX ops change the byte count between read and write. The legalizer computes the write length from the per-op ratio:

```
write_length = (req.length / compute_in_bytes(op)) * compute_out_bytes(op)
```

and forces `decouple_rw` / `decouple_aw` on for any compute transfer. Constraints enforced by legalizer assertions:

| Assertion | Requirement |
|-----------|-------------|
| `ComputeSizeAligned` | `length` is a whole multiple of the op's input granule |
| `ComputeSrcAligned` / `ComputeDstAligned` | src/dst addresses are beat-aligned for size-changing ops |
| `ComputeMxdequantBeatAligned` | dequant input `length` is a multiple of `MxBlockBytes * StrbWidth` |
| `ComputeMxFp16Width` | FP16 element formats require `StrbWidth <= 64` (at most one block per beat) |
| `ComputeMxSrcProtocol` / `ComputeMxDstProtocol` | size-changing ops are AXI-only on src and dst (OBI is a TODO) |
| `ComputeDstTilelink` | compute retires per beat, so a TileLink destination is not supported |
| `ComputeMxdequantLengthFits` | dequant output length must fit the `length` field width |

## Source Files

- `src/backend/idma_otf_compute.sv` - op dispatcher, MX beat-tag FIFO and write-source select
- `src/backend/idma_otf_transpose.sv` - tiled transpose engine
- `src/backend/idma_otf_mxquant.sv`, `src/backend/idma_otf_mxdequant.sv` - MX pack/expand
- `src/idma_float_pkg.sv` - FP32/FP16 <-> MXFP8 cast math
- `src/idma_pkg.sv` - `compute_options_t`, `compute_op_e`, `compute_enable_t`, MX block geometry
- `src/backend/tpl/idma_legalizer.sv.tpl` - size-changing length calc and compute constraints
- `src/backend/tpl/idma_transport_layer.sv.tpl` - engine instantiation (`gen_compute`)

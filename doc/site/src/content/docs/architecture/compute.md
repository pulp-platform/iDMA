---
title: Compute
description: On-the-fly transpose and OCP microscaling (MX) quant/dequant in the transport datapath.
---

## On-the-Fly Compute Role

iDMA can transform data *while it is in flight* instead of moving it verbatim. The compute engine sits in the transport layer on the write side, between the read dataflow buffer and the write barrel shifter, so the transform runs on the beats streaming from source to destination with no round trip to memory. It is optional and elaborated only when `EnableCompute` is set; otherwise the write path is a plain pass-through.

Two op families are provided:

- **Transpose** (`idma_otf_transpose`) - tiled matrix transpose, element size 1/2/4/8 B.
- **MX quant / dequant** (`idma_otf_mxquant`, `idma_otf_mxdequant`) - OCP microscaling conversion between FP32/FP16 and MXFP8, with the FP cast math in `src/idma_float_pkg.sv`.

A single dispatcher, `idma_otf_compute`, routes each transfer to the selected sub-unit. A transfer whose compute config differs from the previous one waits for the backend to drain when either of them is a transpose; MX transfers and copies follow each other without a drain (see below).

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

`EnableCompute` requires `ErrorCap == NO_ERROR_HANDLING` (an elaboration assertion in the backend), and the MX ops need `StrbWidth <= 64`. `mxfp16` gates the FP16 source/destination paths of the MX ops; leaving it off drops that area. An op requested at run time but not elaborated (or a reserved op code) runs as a plain copy of its length; the legalizer (`ComputeOpUnsupported`) and a simulation assertion in the dispatcher flag it, and both frontends refuse it (`ComputeOps` parameter).

**Per transfer** (`idma_req_t.opt.compute`, type `idma_pkg::compute_options_t`):

| Field | Description |
|-------|-------------|
| `enable` | Arm compute for this transfer |
| `op` | `idma_pkg::compute_op_e` selector |
| `params.transpose` | `mode` (element size), `tensor_m`, `tensor_n` (elements) |
| `params.mx` | `poison_dis`, `rceil`, `elem_fmt`, `group` (see MX Planes) |

MX transfers also use `idma_req_t.scale_addr`, the scale plane address; other ops ignore it.

The register frontend exposes these through its `compute_cfg` register. The op encoding is single-homed in `src/frontend/reg/idma_reg.rdl` and re-exported as `idma_pkg::compute_op_e`:

| `compute_op_e` | Meaning | Input granule | Output granule |
|----------------|---------|---------------|----------------|
| `COMPUTE_NONE` | Plain copy | - | - |
| `COMPUTE_TRANSPOSE` | Tiled transpose | = output | = input |
| `COMPUTE_MXQUANT` | Quantize, FP32 source | 128 B / block | 32 B data + 1 B scale / block |
| `COMPUTE_MXQUANT_FP16` | Quantize, FP16 source | 64 B / block | 32 B data + 1 B scale / block |
| `COMPUTE_MXDEQUANT` | Dequantize, FP32 destination | 32 B data + 1 B scale / block | 128 B / block |
| `COMPUTE_MXDEQUANT_FP16` | Dequantize, FP16 destination | 32 B data + 1 B scale / block | 64 B / block |

## Transpose

`idma_otf_transpose` transposes a row-major M x N tensor using flip-flop tile banks. The element size is `E = 1 << mode` bytes (8/16/32/64 bit); tiles are `NE x NE` elements where `NE = StrbWidth / E`. Input is fed padded to full tiles in (col-tile, row-tile, row) order and the output realizes `out[n][m] = in[m][n]`; partial edge tiles are masked with the per-byte output strobe. Dimensions are `TransposeDimWidth = 12` bits (elements).

Tuning: with `transpose_full_duplex = 1` two tile banks let the engine fill one bank while draining the other (full rate, one beat per cycle once the first tile is filled); `0` uses a single bank at half area and half rate. Each bank carries the geometry of the tile it holds, so the overlap also spans back-to-back transfers, such as one padded tile per request. A request whose compute config differs from the previous one (another op, `mode`, `M` or `N`) still waits for the backend to drain.

Transpose does not change transfer size, and the transport layer retires an output beat only once every logical byte lane has been consumed, so one output beat may span several bus beats. `ComputeTransposeShape` accepts a tiled-walk strip of at most one beat (the shape the midend emits) or one whole padded tile in a single burst (`length == NE * StrbWidth`, `M` and `N` at most `NE`, source at a `StrbWidth` row pitch). The tile shape additionally requires a beat-aligned destination, since a misaligned bus beat would draw from two consecutive compute beats at once; a misaligned source is fine in either shape.

## MX Quant / Dequant

The MX ops implement OCP microscaling (MX) format conversion in blocks of `MxBlockElems = 32` elements. The compressed side of a transfer is two planes: a data plane of `MxDataBlockBytes = 32` MXFP8 element bytes per block, E5M2 or E4M3 per transfer (`mx_options_t.elem_fmt`), and a scale plane of one OCP E8M0 block scale byte per block. The uncompressed forms are FP32 (`4 * 32 = 128` B) or FP16 (`2 * 32 = 64` B) per block.

- **Quantize** (`idma_otf_mxquant`): a four-stage pipeline on whole beats. Q0 unpacks the FP32 (4 B/elem) or FP16 (2 B/elem, natively) elements of a beat into the block's lane register and takes a partial exponent maximum; Q1 computes the block scale from the maximum element exponent (the shared exponent clamps to the E8M0 range) and each lane's exponent distance to it; Q2 casts the 32 elements to E5M2 or E4M3 with round-to-nearest-even, exact FP16/FP32 subnormal inputs, element subnormal outputs and saturation to the element max normal; Q3 writes the block's 32 B into its slot of an output queue of whole destination beats and its scale byte into the open line of a scale queue.
- **Dequantize** (`idma_otf_mxdequant`): expands each block's 32 elements (E5M2 or E4M3) back to FP32 (128 B) or FP16 (64 B), applying the decoded block scale per element. It accepts whole data beats into an input buffer, reads one output beat's worth of elements per cycle (a whole block for FP16 at 512 bit, half a block for FP32) and expands them straight into an output queue.
- Both engines never stall once a beat is in: the engine takes a beat only while it holds credit for it, and the credit check is registered. MX beats do not enter the dataflow element. The read side hands each whole MX beat with its tag (`idma_pkg::mx_tag_t`: op, format, element format, RCEIL, poison disable, group, scale or half beat, last beat of the transfer) to its engine: to the quant input queue of `BufferDepth` beats, which refills in the cycle the engine takes its head, or to the dequant input buffer of three more beats; `r_ready` for an MX beat is that queue's flop-driven ready. With `TimingCuts.mx_in_reg` the beat first enters a one-beat register stage in front of both engines (it takes one queue entry of each engine), loaded whenever it can take a beat, so the read side's handshake and data paths end at that stage and the engine queues see registered inputs; MX beats then take one cycle more from R to W. With `TimingCuts.mx_beat_push` the queue push is the AXI read beat handshake taken without the read port's byte-lane masks, which a whole beat does not need, at no extra latency. A copy, or a dequant transfer whose input waits for the write side, therefore never holds back the input of another engine. The write side takes the head of the current write burst's output queue after the write shifter and pops it on the W handshake. MX transfers therefore need no transfer-boundary clear and are not part of the compute config interlock; consecutive transfers with different MX ops or copies stream without draining. The interlock remains for transpose.

The FP cast primitives (quantizer lane unpack, E5M2 and E4M3 element rounding, E5M2/E4M3 -> FP32/FP16 expansion) live in the `idma_float_pkg` package.

:::note[E8M0 block scale]
The scale byte `E` is OCP MX v1.0 E8M0: the block scale is `2^(E - 127)`, `E` in 0..254, and `0xFF` is NaN. Quantize sets the shared exponent to `floor(log2(amax))` of the block's largest finite magnitude minus the element emax (15 for E5M2, 8 for E4M3), clamped to [-127, 127]; an all-zero block gets `E = 0`. With `mx_options_t.rceil` the shared exponent is one higher when the significand of `amax` exceeds 1.75 (the significand of the element max normal), so the block max never saturates (`ceil(log2(amax / max_normal))`). A block holding an Inf or NaN is poisoned: its scale is `0xFF` and every element the canonical NaN (`0x7D` E5M2, `0x7F` E4M3). The per-transfer `mx_options_t.poison_dis` bit (register `mx_cfg.mx_poison_dis`, DMOPC `rs1[18]` on the quant opcodes) keeps such a block finite instead: the scale comes from the finite lanes, NaN quantizes to the element NaN (sign kept) and Inf saturates to the element max normal (`0x7B` E5M2, `0x7E` E4M3; E4M3 has no Inf). Dequantize turns every element of a `0xFF`-scale block into NaN and is exact: results below the FP32 min normal become FP32 subnormals, results above the FP32 max become Inf.
:::

### MX Planes

The compressed side of an MX transfer (quant destination, dequant source) is two planes: the
data plane at the compressed-side address (`dst_addr` for quant, `src_addr` for dequant), 32 B
per block, and the scale plane at `idma_req_t.scale_addr`, one E8M0 byte per block.
`mx_options_t` (in `compute_params_t`, register `mx_cfg`, DMOPC fields on the MX opcodes) holds
the per-transfer options:

| Field | Bits | Meaning |
|-------|------|---------|
| `poison_dis` | 1 | keep Inf/NaN blocks finite (quant) |
| `rceil` | 1 | round the block scale up instead of down (quant) |
| `elem_fmt` | 2 | element format `mx_elem_e`: E5M2 or E4M3 (E2M1 and 3 reserved, `ComputeMxElemFmt`) |
| `group` | 1 | blocks per scale group G: `g64` (a full 64 B scale line) or `g32` (half a line) |
| `resv` | 22 | unused, zero |

Quant writes both planes in one pass: per group of G blocks the legalizer emits the group's data
bursts, then one burst of its scale bytes, on the same AW/W port. Dequant reads the group's
scale bytes first (whole aligned beats, never past their 64 B line), then the group's data as
whole beats; the last data beat may read up to `StrbWidth - 1` bytes past the end of the data
plane, so the memory behind the plane must be readable up to the end of that beat. The quant
`length` is the source length; the dequant `length` is the data-plane length.

Placement rules:

- The scale plane starts on a 64 B scale line, `scale_addr % 64 == 0` (`ComputeMxScaleAligned`),
  and the data plane on a beat (`ComputeSrcAligned` / `ComputeDstAligned`). Group `g` of a
  transfer has its scale bytes at `scale_addr + g * G`.
- The last group of a transfer may be partial (`n < G` blocks): quant writes exactly its `n`
  scale bytes (byte strobes) and leaves the rest of the line untouched; dequant reads the whole
  line and ignores the bytes past `n`. The next transfer's scale plane starts on its own line, so
  the scale bytes of two transfers never share a line.
- The ND midend steps `scale_addr` per row with `idma_d_req_t.scale_strides`, a multiple of
  64 B, as it steps the source and destination addresses with theirs.
- A frontend refuses an MX transfer that breaks these rules, whose length is not a whole
  number of blocks (`ComputeSizeAligned`), whose ND data strides move a plane off a beat, whose
  written length overflows the length field (`ComputeMxdequantLengthFits`), or that carries a
  reserved `elem_fmt` (register frontend: `next_id` reads 0; inst64: `DMCPY` returns id 0 with
  the error bit; inst64 also refuses planes in the TCDM window), so no such request reaches the
  backend from them. The register frontend
  checks beats of its `DataWidth` parameter (default 512 bit, the widest MX backend). The backend
  itself checks the rules only with the simulation assertions above; a request from another
  source with a misaligned data plane or a partial block can write wrong data or never finish.

The quant engine collects the scale bytes of the open group in a scale queue of 64 B lines and
emits them after the group's last data beat; the dequant engine holds the group's scale line in
a scale register and copies each data beat's scale bytes into its input-buffer entry. MX compute
needs `StrbWidth <= 64` (a scale line is one 64 B beat); `idma_otf_compute` stops elaboration
otherwise.

## Size-Changing Transfers

MX ops change the byte count between read and write. The legalizer computes the write length from the per-op ratio:

```
write_length = (req.length / compute_in_bytes(op)) * compute_out_bytes(op)
```

where the MX ratio counts the data plane (32 B per block); the scale bursts come on top, one per
group. The legalizer also forces `decouple_rw` / `decouple_aw` on for any compute transfer. Constraints enforced by legalizer assertions:

| Assertion | Requirement |
|-----------|-------------|
| `ComputeSizeAligned` | `length` is a whole multiple of the op's input granule |
| `ComputeSrcAligned` / `ComputeDstAligned` | src/dst addresses are beat-aligned for size-changing ops |
| `ComputeMxElemFmt` | `elem_fmt` is E5M2 or E4M3 (E2M1 is not elaborated) |
| `ComputeMxScaleAligned` | `scale_addr` of an MX transfer is 64 B aligned |
| `ComputeMxSrcProtocol` / `ComputeMxDstProtocol` | size-changing ops are AXI-only on src and dst (OBI is a TODO) |
| `ComputeDstTilelink` | compute retires per beat, so a TileLink destination is not supported (variants with a TileLink write port) |
| `ComputeMxdequantLengthFits` | dequant output length must fit the `length` field width |

## Source Files

- `src/backend/idma_otf_compute.sv` - op dispatcher, MX quant input queue and write-source select
- `src/backend/idma_otf_transpose.sv` - tiled transpose engine
- `src/backend/idma_otf_mxquant.sv`, `src/backend/idma_otf_mxdequant.sv` - MX pack/expand
- `src/idma_float_pkg.sv` - FP32/FP16 <-> MXFP8 cast math
- `src/idma_pkg.sv` - `compute_options_t`, `compute_op_e`, `compute_enable_t`, MX block geometry
- `src/backend/tpl/idma_legalizer.sv.tpl` - size-changing length calc and compute constraints
- `src/backend/tpl/idma_transport_layer.sv.tpl` - engine instantiation (`gen_compute`)

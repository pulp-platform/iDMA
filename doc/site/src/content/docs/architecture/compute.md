---
title: Compute
description: On-the-fly transpose, OCP microscaling (MX) quant/dequant and a byte-wise SIMD ALU in the transport datapath.
---

## On-the-Fly Compute Role

iDMA can transform data *while it is in flight* instead of moving it verbatim. The compute engine sits in the transport layer on the write side, between the read dataflow buffer and the write barrel shifter, so the transform runs on the beats streaming from source to destination with no round trip to memory. It is optional and elaborated only when `EnableCompute` is set; otherwise the write path is a plain pass-through.

Three op families are provided:

- **Transpose** (`idma_otf_transpose`) - tiled matrix transpose, element size 1/2/4/8 B.
- **MX quant / dequant** (`idma_otf_mxquant`, `idma_otf_mxdequant`) - OCP microscaling conversion between FP32/FP16 and MXFP8, with the FP cast math in `src/idma_float_pkg.sv`.
- **ALU** (`idma_otf_alu`) - byte-wise SIMD arithmetic and logic against an immediate, one independent 8-bit lane per byte.

A single dispatcher, `idma_otf_compute`, routes one op per transfer to the selected sub-unit. Changing the compute config drains the engine before the next transfer starts. The transpose and MX units consume whole beats; the ALU handshakes per byte lane, so it accepts any alignment and length like a plain copy.

:::note[Diagram placeholder]
TODO: transport-layer datapath showing the compute engine between the read buffer output and the write barrel shifter, with transpose / mxquant / mxdequant sub-units fed by the op dispatcher.
:::

## Elaboration and Selection

Compute is configured at two levels:

**Compile time** (backend/transport-layer parameters):

| Parameter | Type | Description |
|-----------|------|-------------|
| `EnableCompute` | `bit` | Elaborate the compute engine at all |
| `ComputeOps` | `idma_pkg::compute_enable_t` | Per-op enable mask: `transpose`, `mxquant`, `mxdequant`, `mxfp16`, `alu`, `alu_mul`, `dual` |
| `ComputeTuning` | `idma_pkg::compute_tuning_t` | Implementation knobs (`transpose_full_duplex`) |

`mxfp16` gates the FP16 source/destination paths of the MX ops and `alu_mul` the ALU multiplier; leaving them off drops that area. `dual` elaborates the second operand stream for the two-operand ALU functions (see [Two-Operand Transfers](#two-operand-transfers)) and only takes effect on backends with a single write port and one read protocol with at least two heads (`2r_axi_w_axi`). An op (or ALU function) requested at run time but not elaborated is caught by the legalizer (`ComputeOpUnsupported`, `ComputeOperandsUnsupported`) and a simulation assertion in the dispatcher.

**Per transfer** (`idma_req_t.opt.compute`, type `idma_pkg::compute_options_t`):

| Field | Description |
|-------|-------------|
| `enable` | Arm compute for this transfer |
| `op` | `idma_pkg::compute_op_e` selector |
| `params.transpose` | `mode` (element size), `tensor_m`, `tensor_n` (elements) |
| `params.alu` | `func` (`idma_pkg::alu_func_e`), `imm` (8-bit immediate) |

`params` is a union: a transfer carries the member its op reads. The register frontend exposes these through its `compute_cfg` (op, transpose fields) and `compute_alu` (ALU function, immediate) registers. The op and ALU function encodings are single-homed in `src/frontend/reg/idma_reg.rdl` and re-exported as `idma_pkg::compute_op_e` and `idma_pkg::alu_func_e`:

| `compute_op_e` | Meaning | Input granule | Output granule |
|----------------|---------|---------------|----------------|
| `COMPUTE_NONE` | Plain copy | - | - |
| `COMPUTE_TRANSPOSE` | Tiled transpose | = output | = input |
| `COMPUTE_MXQUANT` | Quantize, FP32 source | 128 B / block | 33 B / block |
| `COMPUTE_MXQUANT_FP16` | Quantize, FP16 source | 64 B / block | 33 B / block |
| `COMPUTE_MXDEQUANT` | Dequantize, FP32 destination | 33 B / block | 128 B / block |
| `COMPUTE_MXDEQUANT_FP16` | Dequantize, FP16 destination | 33 B / block | 64 B / block |
| `COMPUTE_ALU` | Byte-wise ALU, function in `params.alu` | 1 B | 1 B |

## Transpose

`idma_otf_transpose` transposes a row-major M x N tensor using flip-flop tile banks. The element size is `E = 1 << mode` bytes (8/16/32/64 bit); tiles are `NE x NE` elements where `NE = StrbWidth / E`. Input is fed padded to full tiles in (col-tile, row-tile, row) order and the output realizes `out[n][m] = in[m][n]`; partial edge tiles are masked with the per-byte output strobe. Dimensions are `TransposeDimWidth = 12` bits (elements).

Tuning: with `transpose_full_duplex = 1` two tile banks let the engine fill one bank while draining the other (full rate, ~`1 + 1/NE` cycles per `NE`-beat tile); `0` uses a single bank at half area and half rate.

Transpose does not change transfer size (input bytes == output bytes). The write side is currently single-beat: the legalizer rejects transpose transfers with `length > StrbWidth` (`ComputeTransposeSingleBeat`); tiling across a larger tensor is driven by the midend issuing single-beat strips.

## MX Quant / Dequant

The MX ops implement OCP microscaling (MX) format conversion in blocks of `MxBlockElems = 32` elements. A compressed MX block is `MxBlockBytes = 33` B: one E8M0-style block scale byte followed by 32 MXFP8 (E5M2) element bytes. The uncompressed forms are FP32 (`4 * 32 = 128` B) or FP16 (`2 * 32 = 64` B) per block.

- **Quantize** (`idma_otf_mxquant`): gathers a 32-element block from the input beats (FP32 4 B/elem, or FP16 2 B/elem widened to FP32), computes the block scale from the maximum element exponent (Inf/NaN lanes excluded; the scale saturates rather than wrapping), casts each element to E5M2 with round-to-nearest-even and full subnormal support, and emits the packed 33 B block.
- **Dequantize** (`idma_otf_mxdequant`): expands each 33 B MX block back to FP32 (128 B) or FP16 (64 B), applying the decoded block scale per element.

The FP cast primitives (FP32 <-> MXFP8 E5M2, FP16 <-> FP32 widen/narrow, block-scale computation) live in the `idma_float_pkg` package.

:::note[Internal scale encoding]
The block scale is currently an internal signed 2's-complement value, not the OCP E8M0 (unsigned bias-127) encoding. This is a known deviation flagged in `idma_float_pkg.sv` and is internal-only for now.
:::

## Byte-Wise ALU

`idma_otf_alu` applies one function per transfer to every byte lane, with an 8-bit immediate broadcast to all lanes and arithmetic wrapping modulo 256:

| `alu_func_e` | Result per lane | Needs |
|--------------|-----------------|-------|
| `ALU_NOT` | `~x` | `alu` |
| `ALU_ADDI` | `x + imm` | `alu` |
| `ALU_SUBI` | `x - imm` | `alu` |
| `ALU_MULI` | `x * imm` | `alu`, `alu_mul` |
| `ALU_ANDI` | `x & imm` | `alu` |
| `ALU_ORI` | `x \| imm` | `alu` |
| `ALU_XORI` | `x ^ imm` | `alu` |
| `ALU_ADD` | `a + b` | `alu`, `dual` |
| `ALU_SUB` | `a - b` | `alu`, `dual` |
| `ALU_MUL` | `a * b` | `alu`, `alu_mul`, `dual` |
| `ALU_AND` | `a & b` | `alu`, `dual` |
| `ALU_OR` | `a \| b` | `alu`, `dual` |
| `ALU_XOR` | `a ^ b` | `alu`, `dual` |
| `ALU_AXPY` | `imm * a + b` | `alu`, `alu_mul`, `dual` |

The unit is combinational and passes the per-lane valid/ready of the dataflow buffer straight through, so it has no alignment or length constraints beyond a plain copy and no internal state to drain. `tb_idma_alu` checks the single-operand functions byte-exact against a DPI-C golden across misaligned bases, partial tail beats, page crossings and multi-burst lengths; `tb_idma_dual` does the same for the two-operand functions on `2r_axi_w_axi`.

## Two-Operand Transfers

On a backend with two read heads and `ComputeOps.dual` set, a two-operand ALU function consumes two concurrent read streams: operand `a` from one head, operand `b` from the other. Software issues an **operand pair**: a normal transfer with the two-operand op (source `a`, the destination, `src_head` of `a`) immediately followed by its **operand-only partner** with the same compute configuration and length, source `b` and the other `src_head`. The partner writes nothing; its destination is ignored.

- The legalizer parks the partner and interleaves the read bursts of both operands (`a`, `b`, `a`, ...); the first operand's reads only start once the partner is accepted, so neither stream can run ahead further than the per-head request queues hold. Each partner then completes with a single operand-only burst after the first operand's last write, so both requests get their response in order (the partner's never overtakes the first's).
- The transport layer queues requests per read head (a role, `a` or `b`, sits on one head at a time), shifts each head's data into its own dataflow buffer and joins the two buffers lane by lane in front of the compute engine: a lane is presented once both operands hold it and popped from both when written. An operand that arrives early stalls in its buffer until the other has caught up.
- Operand-only bursts issue no AW and no W; their response is fabricated once every earlier B has returned.

Constraints (legalizer assertions): the request after a two-operand request must be its partner with the same compute configuration (`ComputeOperandPair`), the same length (`ComputeOperandLength`) and another read head (`ComputeOperandHead`); a two-operand function on a backend without the second stream is rejected (`ComputeOperandsUnsupported`). The two operands may be misaligned independently. Both requests use the AXI ID and options of the first for the write side; the partner's `src` AXI options apply to its reads. Error handling is not available with compute in general.

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
| `ComputeOperandsUnsupported` | two-operand functions need `dual` on a two-read-head backend |
| `ComputeOperandPair` / `ComputeOperandLength` / `ComputeOperandHead` | the operand-only partner follows immediately with the same config and length on another head |

## Source Files

- `src/backend/idma_otf_compute.sv` - per-transfer op dispatcher
- `src/backend/idma_otf_transpose.sv` - tiled transpose engine
- `src/backend/idma_otf_mxquant.sv`, `src/backend/idma_otf_mxdequant.sv` - MX pack/expand
- `src/backend/idma_otf_alu.sv` - byte-wise SIMD ALU
- `src/idma_float_pkg.sv` - FP32/FP16 <-> MXFP8 cast math and block scale
- `src/idma_pkg.sv` - `compute_options_t`, `compute_op_e`, `alu_func_e`, `compute_enable_t`, MX block geometry
- `src/backend/tpl/idma_legalizer.sv.tpl` - size-changing length calc and compute constraints
- `src/backend/tpl/idma_transport_layer.sv.tpl` - engine instantiation (`gen_compute`), operand streams (`gen_operand_streams`) and the operand-only write bypass

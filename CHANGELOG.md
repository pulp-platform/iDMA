# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).


## 0.7.0 - 2026-08-19

### Added
- Add multi-head capabilities to the backend and front-ends [#85](https://github.com/pulp-platform/iDMA/pull/85),
  with datapath fixes and verification testbenches [#123](https://github.com/pulp-platform/iDMA/pull/123).
- Add on-the-fly compute at the write seam: a transpose engine
  [#112](https://github.com/pulp-platform/iDMA/pull/112), OCP microscaling quantise and
  dequantise [#170](https://github.com/pulp-platform/iDMA/pull/170), engine instantiation as a
  SystemVerilog parameter [#159](https://github.com/pulp-platform/iDMA/pull/159), and transpose
  parameters in the register map [#160](https://github.com/pulp-platform/iDMA/pull/160).
- Add OBI events to the event struct [#145](https://github.com/pulp-platform/iDMA/pull/145).
- Add C register headers for downstream drivers [#158](https://github.com/pulp-platform/iDMA/pull/158).
- Add a `BurstLen` parameter to the legalizer page splitter [#109](https://github.com/pulp-platform/iDMA/pull/109).
- Add a license-free public verification matrix: slang elaborates every variant and verilator
  simulates the compute datapath against DPI-C goldens
  [#186](https://github.com/pulp-platform/iDMA/pull/186), with an inst64 frontend testbench
  [#185](https://github.com/pulp-platform/iDMA/pull/185) and the testbenches under the style gate
  [#192](https://github.com/pulp-platform/iDMA/pull/192).
- Harden the compute and transpose testbenches so a failed check aborts the run
  [#133](https://github.com/pulp-platform/iDMA/pull/133),
  [#178](https://github.com/pulp-platform/iDMA/pull/178),
  [#188](https://github.com/pulp-platform/iDMA/pull/188),
  [#107](https://github.com/pulp-platform/iDMA/pull/107).
- Add a Starlight documentation site [#103](https://github.com/pulp-platform/iDMA/pull/103),
  [#181](https://github.com/pulp-platform/iDMA/pull/181).

### Changed
- Generate the register blocks from SystemRDL with PeakRDL
  [#73](https://github.com/pulp-platform/iDMA/pull/73), and single-source the compute-op encoding
  there [#176](https://github.com/pulp-platform/iDMA/pull/176).
- Generate one tracer header per backend id [#186](https://github.com/pulp-platform/iDMA/pull/186),
  and qualify the trace signal keys by direction.
- Bump `common_cells` to v2 [#99](https://github.com/pulp-platform/iDMA/pull/99) and align the
  ecosystem pins [#180](https://github.com/pulp-platform/iDMA/pull/180).
- Replace morty with the bender slang pickle [#110](https://github.com/pulp-platform/iDMA/pull/110)
  and rename its output directory to `target/pickle`
  [#114](https://github.com/pulp-platform/iDMA/pull/114).
- Manage the Python environment with `pyproject.toml` and uv
  [#121](https://github.com/pulp-platform/iDMA/pull/121),
  [#111](https://github.com/pulp-platform/iDMA/pull/111),
  [#128](https://github.com/pulp-platform/iDMA/pull/128).
- Update the `inst64` front-end for streamlined Snitch integration
  [#88](https://github.com/pulp-platform/iDMA/pull/88), and prioritise OBI writes
  [#138](https://github.com/pulp-platform/iDMA/pull/138).
- Retire compute on `w_dp_req_ready` and drop the dead `w_beat_done`
  [#163](https://github.com/pulp-platform/iDMA/pull/163).
- Render `compute.svh` with the PeakRDL raw-header template
  [#179](https://github.com/pulp-platform/iDMA/pull/179).
- Bump all bender dependencies [#130](https://github.com/pulp-platform/iDMA/pull/130).
- Various CI and build modernisation: consolidated workflows and pre-commit hooks
  [#90](https://github.com/pulp-platform/iDMA/pull/90), bender and object caching
  [#120](https://github.com/pulp-platform/iDMA/pull/120),
  [#198](https://github.com/pulp-platform/iDMA/pull/198),
  [#199](https://github.com/pulp-platform/iDMA/pull/199),
  [#200](https://github.com/pulp-platform/iDMA/pull/200), author lint by domain
  [#169](https://github.com/pulp-platform/iDMA/pull/169), per-top trimmed compile scripts
  [#116](https://github.com/pulp-platform/iDMA/pull/116), and pipeline hygiene
  [#117](https://github.com/pulp-platform/iDMA/pull/117),
  [#118](https://github.com/pulp-platform/iDMA/pull/118),
  [#122](https://github.com/pulp-platform/iDMA/pull/122),
  [#124](https://github.com/pulp-platform/iDMA/pull/124),
  [#125](https://github.com/pulp-platform/iDMA/pull/125),
  [#127](https://github.com/pulp-platform/iDMA/pull/127),
  [#175](https://github.com/pulp-platform/iDMA/pull/175).

- Sweep the MX roundtrip over both element formats, covering the `mxfp16` opt-out below a
  1024b bus [#203](https://github.com/pulp-platform/iDMA/pull/203).
- Publish the documentation site from `master` only
  [#208](https://github.com/pulp-platform/iDMA/pull/208).

### Fixed
- Gate the channel coupler `AW` release on a queued `AW` and carry `decouple_aw` down the write
  datapath [#204](https://github.com/pulp-platform/iDMA/pull/204). The coupler released an `AW`
  while its store was empty, presenting a stale payload, and its credit counter charged stall
  cycles rather than transfers, so `AW` desynchronised from `W` until the transfer hung. This
  corrects the accounting introduced with [#80](https://github.com/pulp-platform/iDMA/pull/80)
  while keeping its fix.
- Send `AW` when `W` is ready, fixing AW starvation with `decouple_rw` and without `decouple_aw`
  [#80](https://github.com/pulp-platform/iDMA/pull/80).
- Break a combinational loop in the desc64 speculation FIFO
  [#91](https://github.com/pulp-platform/iDMA/pull/91).
- Fix compute synth-wrapper emission and AXI-write eligibility
  [#162](https://github.com/pulp-platform/iDMA/pull/162).
- Emit synth-wrapper head ports only for multi-head backends
  [#136](https://github.com/pulp-platform/iDMA/pull/136).
- Gate the external register read-ack [#134](https://github.com/pulp-platform/iDMA/pull/134).
- Sync the `rt_midend` choice FIFO [#108](https://github.com/pulp-platform/iDMA/pull/108).
- Align the desc64 addrmap symbol references with the generated package
  [#182](https://github.com/pulp-platform/iDMA/pull/182).
- Report the documented stall polarity in the `inst64` events
  [#187](https://github.com/pulp-platform/iDMA/pull/187). `r_stall` and `w_stall` were carrying
  the definitions of the buffer-pressure metrics, which overrode the correct assignments.
- Fix the documentation site base path [#183](https://github.com/pulp-platform/iDMA/pull/183).

Four changes are not backwards compatible. The tracer is generated one header per backend id, so
`` `include "idma/tracer.svh" `` becomes `` `include "idma/tracer_<id>.svh" `` for the variant being
traced. The trace signal keys are qualified by direction, so a consumer reading `axi_rsp_ready` now
reads `axi_read_rsp_ready`; without this a protocol present on both sides emitted the same key twice
and the read channel was lost. `common_cells` v2 is required, which is an ecosystem-wide bump. The
pickle moves from `target/morty` to `target/pickle`.

The `inst64` stall counters change meaning without a version marker
[#187](https://github.com/pulp-platform/iDMA/pull/187). `dma_r_stall` and `dma_w_stall` now report
what the Snitch cluster documents them to report, so a profile captured before this release is not
comparable with one captured after.

## 0.6.5 - 2025-07-15

### Added
- Add generalized multicast capabilities to Snitch DMA [#74](https://github.com/pulp-platform/iDMA/pull/74) and [#77](https://github.com/pulp-platform/iDMA/pull/77).

### Fixed
- Fix GitHub actions [#76](https://github.com/pulp-platform/iDMA/pull/76).
- Various linting and compatibility fixes [#76](https://github.com/pulp-platform/iDMA/pull/76).
- Fix performance issue in `idma_axis_write` [#76](https://github.com/pulp-platform/iDMA/pull/76).
- Fix buffering invalid data with `idma_backend_rw_axi_rw_axis` [#79](https://github.com/pulp-platform/iDMA/pull/79).

### Changed
- Change protocol enum of AXI_LITE to AXILITE, otherwise it collides with AXI interface names [#76](https://github.com/pulp-platform/iDMA/pull/76).
- Change assertions in `idma_error_handler` to not be sequential logic instead always_comb block [#76](https://github.com/pulp-platform/iDMA/pull/76).


## 0.6.4 - 2025-02-28

### Added
- Add tracing support to `inst64` [#52](https://github.com/pulp-platform/iDMA/pull/52).

### Changed
- Various fixes and small changes to upstream PULPv2/Chimera features. Combining PRs #49, #55, #56, #57 in [#66](https://github.com/pulp-platform/iDMA/pull/66).
- Minor changes to fix linting [#54](https://github.com/pulp-platform/iDMA/pull/54).
- Expand tracer to track more signals, increase Verilator support [#52](https://github.com/pulp-platform/iDMA/pull/52).

### Fixed
- Ensuring `r_dp_valid_i` is ready before accepting data [#67](https://github.com/pulp-platform/iDMA/pull/67).
- Updated `upload-pages-artifact` to `v3` [#68](https://github.com/pulp-platform/iDMA/pull/68) and `upload-artifact` to `v4` to restore CI.
- Fix `DMCPY` instruction in `inst64` front-end for multi-channel DMA operation [#65](https://github.com/pulp-platform/iDMA/pull/65).
- Ensure correct `PageAddrWidth` in `legalizer` for transfers without bursts; fixes issue [#53](https://github.com/pulp-platform/iDMA/issues/51) and was merged as [#53](https://github.com/pulp-platform/iDMA/pull/53).


## 0.6.3 - 2024-07-02

### Added
- Multichannel support in `inst64` [#46](https://github.com/pulp-platform/iDMA/pull/46)

### Fixed
- `inst64` sources are only present if the `snitch_cluster` target is set [#47](https://github.com/pulp-platform/iDMA/pull/47).
- zero-length ND transfers are properly handled [#50](https://github.com/pulp-platform/iDMA/pull/50).


## 0.6.2 - 2024-05-10

### Fixed
- Missing signal assign in backend template

## 0.6.1 - 2024-04-23

### Fixed
- Missing signal assign in legalizer template

## 0.6.0 - 2024-03-11

### Fixed

### Changed
- Various cleanup and modernization passes: CI, documentation, scripts
- Rework ND-front-ends for both 32 and 64-bit systems [#30](https://github.com/pulp-platform/iDMA/pull/30),
  [#32](https://github.com/pulp-platform/iDMA/pull/32), [#33](https://github.com/pulp-platform/iDMA/pull/33)
- Remove default system wrappers and drivers
- Update descriptor-based frontend [#18](https://github.com/pulp-platform/iDMA/pull/18),
  [#26](https://github.com/pulp-platform/iDMA/pull/26)
- Update tracer to the multiprotocol version of iDMA [#8](https://github.com/pulp-platform/iDMA/pull/8)
- Modified `init` protocol to support writes to implement the `simple FIFO` interface
- Update `inst64` frontend, add changes from Occamy, and update to newest backend version
- Upstream resources and update dependencies

### Added
- Add true multiprotocol capabilities to iDMA using MARIO [#22](https://github.com/pulp-platform/iDMA/pull/22)
- Add multiple default protocols next to AXI read/write:
  - AXI read, OBI write
  - OBI read, AXI write
  - AXI and AXI Stream read/write
  - OBI read, AXI write, Init read/write
  - AXI read, OBI and Init read/write
- Add RT midend [#24](https://github.com/pulp-platform/iDMA/pull/24)
- Add Mempool midend [#34](https://github.com/pulp-platform/iDMA/pull/34)
- Add `retarget.py` Python script to transform patterns to new protocol configurations

## 0.5.1 - 2023-10-21

### Fixed
- Increase SV language compatibility in `dma_core_wrap`. [#28](https://github.com/pulp-platform/iDMA/pull/28).

## 0.5.0 - 2023-10-14

### Changed
- Add a struct variant to CVA6's `dma_core_wrap` [#25](https://github.com/pulp-platform/iDMA/pull/25).
- Expose all important back-end parameters in `dma_core_wrap` [#27](https://github.com/pulp-platform/iDMA/pull/27).

### Added
- Add a 2D version of the 64-bit register-based front-end intended to be used with CVA6 and enable
  it in the `dma_core_wrap` [#27](https://github.com/pulp-platform/iDMA/pull/27).


## 0.4.2 - 2023-02-09

### Fixed
- Fix `idma_backend` instantiation in `dma_core_wrap` [#23](https://github.com/pulp-platform/iDMA/pull/23).

## 0.4.1 - 2023-02-08

### Fixed
- Fix typo in `dma_core_wrap` [#21](https://github.com/pulp-platform/iDMA/pull/21).

## 0.4.0 - 2022-11-11

### Changed
- Bump AXI version to [`v.0.39.0-beta.2`](https://github.com/pulp-platform/axi/releases/tag/v0.39.0-beta.2)
  [#20](https://github.com/pulp-platform/iDMA/pull/20).
- Add new protocol capabilities introduced by [#20](https://github.com/pulp-platform/iDMA/pull/20) to the `README.md`.

### Fixed
- Various fixes; add missing ports in the testbenches, remove stale comments, and remove duplicates
  in `Bender.yml` [#17](https://github.com/pulp-platform/iDMA/pull/17).

### Added
- Add `guard.svh`, a simple macro to guard nonsynthesizable code in the iDMA
  repository [#17](https://github.com/pulp-platform/iDMA/pull/17).
- Add support for the [OBI v1.5.0](https://github.com/openhwgroup/programs/blob/master/TGs/cores-task-group/obi/OBI-v1.5.0.pdf)
  protocol [#20](https://github.com/pulp-platform/iDMA/pull/20).
- Add support for the AXI4 Lite protocol [#20](https://github.com/pulp-platform/iDMA/pull/20).

## 0.3.1 - 2022-10-28

### Fixed
- `dma_core_wrap`: Remove parameter `DmaAddrWidth` in `idma_reg64_frontend` [#16](https://github.com/pulp-platform/iDMA/pull/16).

## 0.3.0 - 2022-10-28

### Fixed
- Fix the `Aw`-handshaking in the `channel-coupler` module [#13](https://github.com/pulp-platform/iDMA/pull/13).
- Minor fixes in `dma_core_wrap` and `idma_reg64_frontend` [#15](https://github.com/pulp-platform/iDMA/pull/15).

`dma_core_wrap` has lost the `DmaAddrWidth` parameter rendering `v0.3.0` incompatible to previous
versions.

## 0.2.4 - 2022-09-05

### Added
- Add support to enable non-ideal behavior of the testbench memory using  the `axi_throttle` module
  as well as an AXI multicut.

### Changed
- Update the following dependencies:
  - `axi` from `v0.35.1` to `v0.37.0`
  - `common_cells` from `1.21.0` to `1.26.0`
  - `common_verification` from `0.2.0` to `0.2.2`
- Replace local modules with their upstream versions: [#11](https://github.com/pulp-platform/iDMA/pull/11), [#12](https://github.com/pulp-platform/iDMA/pull/12).

### Fixed
- Fix the `Aw`-handshaking in the `channel-coupler` module [#10](https://github.com/pulp-platform/iDMA/pull/10).
- Fix missing python modules in GitHub CI.
- Fix wrong date format as well as missing indentation in `CHANGELOG.md`.

`v0.2.4` is fully **backward-compatible** to versions `v0.2.0` through `v0.2.3`.

## 0.2.3 - 2022-08-11

### Changed
- Morty is now fetched as a binary distributable for building the doc in CI.

## 0.2.2 - 2022-08-09

### Changed
- Add GitHub actions to lint the code as well as build the documentation. Remove the corresponding
  jobs from the IIS-internal GitLab pipeline.

### Fixed
- Fix the `AX`-handshaking. The ready signal of the iDMA request no longer depends on the ready
  signal of the `Ax` channels. See [#3](https://github.com/pulp-platform/iDMA/pull/3).

## 0.2.1 - 2022-08-07

### Changed
- Moved the IIS-internal non-free resources to a dedicated subgroup to tidy up. Version v0.2.1 is
fully compatible with v0.2.0.

## 0.2.0 - 2022-08-04

### Changed
- Added a completely redesigned DMA engine - the iDMA including a basic verification environment.

## 0.1.0 - 2022-08-02

- Final version of the legacy DMA engine (used to be part of the [AXI Repository](https://github.com/pulp-platform/axi)
on the [`axi_dma_tbenz` branch](https://github.com/pulp-platform/axi/tree/axi_dma_tbenz)).
This release replaces ***all*** older versions of this IP.

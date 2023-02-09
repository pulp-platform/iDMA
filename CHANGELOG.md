# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

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

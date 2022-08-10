# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).


## Unreleased

## 0.2.3 - 11-08-2022
### Changed
Morty is now fetched as a binary distributable for building the doc in CI.

## 0.2.2 - 09-08-2022
### Changed
Add GitHub actions to lint the code as well as build the documentation. Remove the corresponding
jobs from the IIS-internal GitLab pipeline.

### Fixed
Fix the `AX`-handshaking. The ready signal of the iDMA request no longer depends on the ready signal
of the `Ax` channels. See [#3](https://github.com/pulp-platform/iDMA/pull/3).

## 0.2.1 - 07-08-2022
### Changed
Moved the IIS-internal non-free resources to a dedicated subgroup to tidy up. Version v0.2.1 is
fully compatible with v0.2.0.

## 0.2.0 - 04-08-2022
### Changed
Added a completely redesigned DMA engine - the iDMA including a basic verification environment.

## 0.1.0 - 02-08-2022
- Final version of the legacy DMA engine (used to be part of the [AXI Repository](https://github.com/pulp-platform/axi)
on the [`axi_dma_tbenz` branch](https://github.com/pulp-platform/axi/tree/axi_dma_tbenz)).
This release replaces ***all*** older versions of this IP.

System Integration
==================

Some system integration examples are provided in this repository as a reference.

PULP Open
---------

The PULP Open `dmac_wrap` makes use of multiple PULP peripheral interface connections to register frontends, allowing for individual configuration for each PULP core.
PULP is a 32bit system that supports 2D transfers between an external AXI port and an internal L1 TCDM, making use of an AXI X-bar to access the separate regions.

The folder also includes basic driver implementations, for which the main development is included in both the PULP-SDK and the PULP-runtime.

CVA6 Register
-------------

The `cva6_reg` frontend includes a register-based frontend for the DMA, exposing an AXI slave port for configuration of the DMA. A basic driver and software test is also included.

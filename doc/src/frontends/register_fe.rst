Register Frontends
==================

The Register frontends are built as a register file using lowrisc's reggen.py tool.

To configure a transfer, the corresponding registers can be filled with the transfer details, requesting the a next transfer ID once all registers are appropriately filled will launch the transfer.
The transfer status can be queried using the transfer ID, as soon as the `done_id` is equal to or larger than the id received when launching the transfer the transfer is complete.

There are a variety of configurations, depending on the bitwidth and feature set required.
Currently supported are:

.. only:: html

- `32bit 3D register frontend <../regs/idma_reg32_3d_reg/index.html>`_
- `64bit 1D register frontend <../regs/idma_reg64_1d_reg/index.html>`_
- `64bit 2D register frontend <../regs/idma_reg64_2d_reg/index.html>`_

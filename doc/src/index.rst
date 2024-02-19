iDMA: An intelligent AXI Direct Memory Access unit
==================================================

An intelligent, configurable & modular DMA based on an AXI memory interface.

Overview
--------
This DMA is split into two groups of modules to combine reusability with a generic programming interface.
The modules of the :doc:`backend <backend>` provide the basics of moving data over an on-chip interconnect.
The modules of the :doc:`frontend <frontend>` implement the programming interface and can be customized depending on the needs of a project.
An optional :doc:`midend <midend>` can be added to allow for translation of N-D requests from the :doc:`frontend <frontend>` to the :ref:`1-D requests <Interface>` accepted by the :doc:`backend <backend>`.

.. image:: ../fig/iDMA_overview.svg
  :width: 600

Philosophy / Idea
-----------------

- **clear interfaces**, whenever possible using existing standards
- **modular** -> one hardware fits all
- **adaptable** and **extensible**
- extensively **verified**
- clean code
- minimal hardware

Docs
----

The main documentation of the submodules is divided into the following sections:

.. toctree::
  :maxdepth: 1

  backend.rst
  midend.rst
  frontend.rst
  error_handling.rst
  verification.rst
  system_integration.rst


The morty docs provide the generated description of the SystemVerilog files within this repository.

.. only:: html

  `R_AXI_W_OBI Backend <idma_backend_synth_r_axi_w_obi/index.html>`_

  `R_OBI_W_AXI Backend <idma_backend_synth_r_obi_w_axi/index.html>`_

  `RW_AXI Backend <idma_backend_synth_rw_axi/index.html>`_


.. image:: ../fig/graph/idma_backend_synth_r_axi_w_obi.png
  :width: 600

.. image:: ../fig/graph/idma_backend_synth_r_obi_w_axi.png
  :width: 600

.. image:: ../fig/graph/idma_backend_synth_rw_axi.png
  :width: 600


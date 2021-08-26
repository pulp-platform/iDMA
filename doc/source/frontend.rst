iDMA Frontend
=============

The frontend is responsible for providing a configuration interface for the DMA to the rest of the system.
The frontend subsequently translates the system-specific configuration commands to the DMA's 1D or ND request interfaces.

The frontend provides a configuration interface for the iDMA for various platforms. 
Currently the following three frontends are planned and in development:

- :doc:`PULP <frontends/pulp_fe>`: Configuration interface for the pulp cluster
- :doc:`Snitch <frontends/snitch_fe>`: Snitch integration
- :doc:`Ariane/Linux <frontends/ariane_fe>`: An Ariane interface to allow use in a Linux system (not a priority yet)

.. toctree::
  :hidden:

  frontends/pulp_fe.rst
  frontends/snitch_fe.rst
  frontends/ariane_fe.rst

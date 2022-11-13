Error Handling
==============

On Error:
---------

- send error response over response interface
- frontend needs to receive and acknowledge the error respons

-> Notification / SW handling is up to the frontend (i.e. platform)

3 Options to be implemented in backend:
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- **Abort** generic 1D transfer
- **Continue** generic 1D transfer
- **Replay** AXI transfer with response != 0 (optimally: not full 1D transfer)

On Success:
-----------

- completed response over response interface

Important:
----------

- Even if error occurs on AXI interface, burst needs to be completed for AXI compliance.

  + It is possible only a few transactions in the burst present an error

- Certain features may be difficult to implement with proper error handling, may result in significant performance impact.

// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Tracer macro of the ${identifier} iDMA backend
`ifndef IDMA_TRACER_${identifier_cap}_SVH_
`define IDMA_TRACER_${identifier_cap}_SVH_

`include "idma/tracer.svh"
${body}
`endif

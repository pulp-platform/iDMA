// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

// Shared resources of the iDMA backend tracer; the per-id macros live in
// idma/tracer_<id>.svh and include this file themselves
`ifndef IDMA_TRACER_SVH_
`define IDMA_TRACER_SVH_

// largest type to trace
`define IDMA_TRACER_MAX_TYPE_WIDTH 1024
`define IDMA_TRACER_MAX_TYPE logic [`IDMA_TRACER_MAX_TYPE_WIDTH-1:0]

// string assembly function
`define IDMA_TRACER_STR_ASSEMBLY(__dict, __cond) \
    if(__cond) begin \
        trace = $sformatf("%s'%s':{", trace, `"__dict`"); \
        foreach(__dict``[key]) trace = $sformatf("%s'%s': 0x%0x,", trace, key, __dict``[key]); \
        trace = $sformatf("%s},", trace); \
    end

// helper to clear a condition
`define IDMA_TRACER_CLEAR_COND(__cond) \
    if(__cond) begin \
        __cond = ~__cond; \
    end
`endif


// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// DMOPC opcode-byte contract of the `inst64` frontend: decodes the software-visible
/// on-the-fly compute opcode into `idma_pkg::compute_options_t`.
package idma_inst64_compute_pkg;

    /// Transpose mode width, taken from the field itself so added struct members cannot skew it
    function automatic int unsigned tp_mode_width();
        idma_pkg::transpose_options_t tp;
        return $bits(tp.mode);
    endfunction

    localparam int unsigned TpModeWidth = tp_mode_width();

    // Opcode bytes, operand layout, and decode; generated from src/db/idma_dmopc.yml
    `include "idma/dmopc.svh"

endpackage

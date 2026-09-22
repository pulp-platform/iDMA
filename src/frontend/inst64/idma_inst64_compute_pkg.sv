// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// DMOPC opcode-byte contract of the `inst64` frontend: decodes the software-visible
/// on-the-fly compute opcode into `idma_pkg::compute_options_t`.
package idma_inst64_compute_pkg;

    /// Transpose mode width; `transpose_options_t` is the mode plus the two dimensions
    localparam int unsigned TpModeWidth =
        $bits(idma_pkg::transpose_options_t) - 32'd2 * idma_pkg::TransposeDimWidth;

    // Opcode bytes, operand layout, and decode; generated from src/db/idma_dmopc.yml
    `include "idma/dmopc.svh"

endpackage

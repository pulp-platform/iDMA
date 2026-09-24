// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Instruction encodings and per-instruction attributes of the `inst64` frontend.
package idma_inst64_snitch_pkg;

    // Encodings and attribute table; generated from src/db/idma_inst64.yml
    `include "idma/inst64.svh"

    /// Core-side port of `idma_inst64_top`
    typedef enum logic {
        /// Snitch accelerator bus (`acc_req`/`acc_res`)
        FrontendAcc,
        /// CORE-V eXtension Interface: issue, register, commit, and result
        FrontendXif
    } frontend_if_e;

endpackage

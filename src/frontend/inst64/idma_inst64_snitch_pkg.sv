// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

/// Instruction decoding for `inst64` in the context of snitch. This content was copied from the
/// generated risc-v opcodes file: `snitch/src/riscv_instr.sv`.
package idma_inst64_snitch_pkg;

  localparam logic [31:0] DMSRC              = 32'b0000000??????????000000000101011;
  localparam logic [31:0] DMDST              = 32'b0000001??????????000000000101011;
  localparam logic [31:0] DMCPYI             = 32'b0000010??????????000?????0101011;
  localparam logic [31:0] DMCPY              = 32'b0000011??????????000?????0101011;
  localparam logic [31:0] DMSTATI            = 32'b0000100?????00000000?????0101011;
  localparam logic [31:0] DMSTAT             = 32'b0000101?????00000000?????0101011;
  localparam logic [31:0] DMSTR              = 32'b0000110??????????000000000101011;
  localparam logic [31:0] DMREP              = 32'b000011100000?????000000000101011;

endpackage

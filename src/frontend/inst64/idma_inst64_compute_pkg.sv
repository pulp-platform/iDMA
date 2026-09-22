// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// DMOPC opcode-byte contract of the `inst64` frontend: decodes the software-visible
/// on-the-fly compute opcode into `idma_pkg::compute_options_t`.
package idma_inst64_compute_pkg;

    /// Opcode bytes; the gaps are reserved for ops not implemented in this backend family
    localparam logic [7:0] OpcPassthrough   = 8'h08;
    localparam logic [7:0] OpcMxQuant       = 8'h20;
    localparam logic [7:0] OpcMxDequant     = 8'h21;
    localparam logic [7:0] OpcMxQuantFp16   = 8'h22;
    localparam logic [7:0] OpcMxDequantFp16 = 8'h23;
    localparam logic [7:0] OpcTranspose     = 8'h50;

    /// Transpose mode width; `transpose_options_t` is the mode plus the two dimensions
    localparam int unsigned TpModeWidth =
        $bits(idma_pkg::transpose_options_t) - 32'd2 * idma_pkg::TransposeDimWidth;

    /// DMOPC operand layout; `rs1` is `data_arga`, `rs2` is `data_argb`
    localparam int unsigned Rs1OpcByteLsb   = 32'd0;
    localparam int unsigned Rs1OpcByteWidth = $bits(OpcPassthrough);
    localparam int unsigned Rs1TpModeLsb    = 32'd16;
    /// The transpose dimensions need 24 bits, so they ride `rs2` rather than straddling `rs1`
    localparam int unsigned Rs2TpTensorMLsb = 32'd0;
    localparam int unsigned Rs2TpTensorNLsb = 32'd12;

    /// An RV32 core sign-extends `rs1`/`rs2` into the upper operand half; no field may cross it
    localparam bit LayoutRv32Safe =
        (Rs1OpcByteLsb + Rs1OpcByteWidth <= 32'd32) &&
        (Rs1TpModeLsb + TpModeWidth <= 32'd32) &&
        (Rs2TpTensorMLsb + idma_pkg::TransposeDimWidth <= 32'd32) &&
        (Rs2TpTensorNLsb + idma_pkg::TransposeDimWidth <= 32'd32);

    /// Fields sharing an operand must not overlap
    localparam bit LayoutDisjoint =
        (Rs1OpcByteLsb + Rs1OpcByteWidth <= Rs1TpModeLsb) &&
        (Rs2TpTensorMLsb + idma_pkg::TransposeDimWidth <= Rs2TpTensorNLsb);

    /// Decode the DMOPC operands; an unknown byte decodes to a plain copy and is asserted on.
    function automatic idma_pkg::compute_options_t opc_decode(logic [63:0] arga, logic [63:0] argb);
        idma_pkg::compute_options_t cmp;
        logic [7:0] opc;
        cmp = '0;
        opc = arga[Rs1OpcByteLsb +: Rs1OpcByteWidth];
        unique case (opc)
            OpcMxQuant:       begin cmp.enable = 1'b1; cmp.op = idma_pkg::COMPUTE_MXQUANT; end
            OpcMxDequant:     begin cmp.enable = 1'b1; cmp.op = idma_pkg::COMPUTE_MXDEQUANT; end
            OpcMxQuantFp16:   begin cmp.enable = 1'b1; cmp.op = idma_pkg::COMPUTE_MXQUANT_FP16; end
            OpcMxDequantFp16: begin
                cmp.enable = 1'b1;
                cmp.op     = idma_pkg::COMPUTE_MXDEQUANT_FP16;
            end
            OpcTranspose: begin
                cmp.enable                    = 1'b1;
                cmp.op                        = idma_pkg::COMPUTE_TRANSPOSE;
                cmp.params.transpose.mode     = arga[Rs1TpModeLsb +: TpModeWidth];
                cmp.params.transpose.tensor_m =
                    argb[Rs2TpTensorMLsb +: idma_pkg::TransposeDimWidth];
                cmp.params.transpose.tensor_n =
                    argb[Rs2TpTensorNLsb +: idma_pkg::TransposeDimWidth];
            end
            default: cmp = '0;
        endcase
        return cmp;
    endfunction

    /// Is the opcode byte decodable on this implementation?
    function automatic logic opc_known(logic [7:0] opc);
        idma_pkg::compute_options_t cmp;
        cmp = opc_decode(64'(opc), 64'b0);
        return (opc == OpcPassthrough) | cmp.enable;
    endfunction

    /// `idma_pkg::compute_op_e` encoding space; a value of it is also the all-mapped sentinel
    localparam int unsigned NumComputeOpValues = 1 << $bits(idma_pkg::compute_op_e);
    localparam int unsigned NumOpcodes         = 1 << $bits(OpcPassthrough);

    /// Lowest `idma_pkg::compute_op_e` value that `opc_decode` reaches for no opcode byte
    function automatic int unsigned first_unmapped_op();
        logic [NumComputeOpValues-1:0] reached;
        idma_pkg::compute_options_t    cmp;
        reached = '0;
        for (int unsigned b = 0; b < NumOpcodes; b++) begin
            cmp = opc_decode(64'(b), 64'b0);
            reached[cmp.op] = 1'b1;
        end
        for (int unsigned v = 0; v < NumComputeOpValues; v++) begin
            if (idma_pkg::ComputeOpValid[v] & ~reached[v]) return v;
        end
        return NumComputeOpValues;
    endfunction

    localparam int unsigned UnmappedComputeOp = first_unmapped_op();
    localparam bit          ComputeOpsMapped  = UnmappedComputeOp == NumComputeOpValues;

endpackage

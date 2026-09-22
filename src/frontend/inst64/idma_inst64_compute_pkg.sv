// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

/// DMOPC opcode-byte contract of the `inst64` frontend: decodes the software-visible
/// on-the-fly compute opcode into `idma_pkg::compute_options_t`.
package idma_inst64_compute_pkg;

    /// DMOPC operand layout in `rs1` (accelerator-bus `data_arga`)
    localparam int unsigned OpcByteLsb   = 32'd0;
    localparam int unsigned TpModeLsb    = 32'd16;
    localparam int unsigned TpTensorMLsb = 32'd18;
    localparam int unsigned TpTensorNLsb = 32'd30;

    /// Opcode bytes; the gaps are reserved for ops not implemented in this backend family
    localparam logic [7:0] OpcPassthrough   = 8'h08;
    localparam logic [7:0] OpcMxQuant       = 8'h20;
    localparam logic [7:0] OpcMxDequant     = 8'h21;
    localparam logic [7:0] OpcMxQuantFp16   = 8'h22;
    localparam logic [7:0] OpcMxDequantFp16 = 8'h23;
    localparam logic [7:0] OpcTranspose     = 8'h50;

    /// Decode the DMOPC operand; an unknown byte decodes to a plain copy and is asserted on.
    function automatic idma_pkg::compute_options_t opc_decode(logic [63:0] arga);
        idma_pkg::compute_options_t cmp;
        logic [7:0] opc;
        cmp = '0;
        opc = arga[OpcByteLsb +: 8];
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
                cmp.params.transpose.mode     = arga[TpModeLsb +: 2];
                cmp.params.transpose.tensor_m = arga[TpTensorMLsb +: idma_pkg::TransposeDimWidth];
                cmp.params.transpose.tensor_n = arga[TpTensorNLsb +: idma_pkg::TransposeDimWidth];
            end
            default: cmp = '0;
        endcase
        return cmp;
    endfunction

    /// Is the opcode byte decodable on this implementation?
    function automatic logic opc_known(logic [7:0] opc);
        idma_pkg::compute_options_t cmp;
        cmp = opc_decode(64'(opc));
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
            cmp = opc_decode(64'(b));
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

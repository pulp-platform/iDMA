// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Michael Rogenmoser <michaero@iis.ee.ethz.ch>
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

<%
    # Config-bus CPUIF family, derived from --cpuif (idma.mk IDMA_REG_CPUIF). The wrapper packs
    # the PeakRDL reg_top's flat CPUIF signals into the matching req/rsp struct; the reg_top is
    # generated with the same --cpuif so its port set matches the branch selected here.
    if cpuif.startswith('apb'):
        _fam = 'apb'
    elif cpuif.startswith('obi'):
        _fam = 'obi'
    elif cpuif.startswith('axi4-lite'):
        _fam = 'axil'
    else:
        raise Exception("idma_reg.sv.tpl: unsupported register CPUIF '%s' (add a branch)" % cpuif)
%>\
% if _fam == 'apb':
`include "apb/typedef.svh"
% elif _fam == 'obi':
`include "obi/typedef.svh"
% elif _fam == 'axil':
`include "axi/typedef.svh"
% endif

/// Description: Register-based front-end for iDMA
module idma_${identifier} #(
  /// Number of configuration register ports
  parameter int unsigned NumRegs        = 32'd1,
  /// Number of streams (max 16)
  parameter int unsigned NumStreams     = 32'd1,
  /// Width of the transfer id (max 32-bit)
  parameter int unsigned IdCounterWidth = 32'd32,
  /// Dependent parameter: Stream Idx
  parameter int unsigned StreamWidth    = cf_math_pkg::idx_width(NumStreams),
% if _fam == 'apb':
  /// APB4 request type
  parameter type         apb_req_t      = logic,
  /// APB4 response type
  parameter type         apb_rsp_t      = logic,
% elif _fam == 'obi':
  /// OBI request type
  parameter type         obi_req_t      = logic,
  /// OBI response type
  parameter type         obi_rsp_t      = logic,
% elif _fam == 'axil':
  /// AXI4-Lite request type
  parameter type         axi_lite_req_t = logic,
  /// AXI4-Lite response type
  parameter type         axi_lite_rsp_t = logic,
% endif
  /// DMA 1d or ND burst request type
  parameter type         dma_req_t      = logic,
  /// Dependent type for IdCounterWidth
  parameter type         cnt_width_t    = logic [IdCounterWidth-1:0],
  /// Dependent type for StreamWidth
  parameter type         stream_t       = logic [StreamWidth-1:0]
) (
  input  logic clk_i,
  input  logic rst_ni,
  /// Configuration control slave (${cpuif})
% if _fam == 'apb':
  input  apb_req_t [NumRegs-1:0] dma_ctrl_req_i,
  output apb_rsp_t [NumRegs-1:0] dma_ctrl_rsp_o,
% elif _fam == 'obi':
  input  obi_req_t [NumRegs-1:0] dma_ctrl_req_i,
  output obi_rsp_t [NumRegs-1:0] dma_ctrl_rsp_o,
% elif _fam == 'axil':
  input  axi_lite_req_t [NumRegs-1:0] dma_ctrl_req_i,
  output axi_lite_rsp_t [NumRegs-1:0] dma_ctrl_rsp_o,
% endif
  /// Request signals
  output dma_req_t   dma_req_o,
  output logic       req_valid_o,
  input  logic       req_ready_i,
  input  cnt_width_t next_id_i,
  output stream_t    stream_idx_o,
  /// Status signals
  input  cnt_width_t           [NumStreams-1:0] done_id_i,
  input  idma_pkg::idma_busy_t [NumStreams-1:0] busy_i,
  input  logic                 [NumStreams-1:0] midend_busy_i
);

  /// Maximum number of streams is set to 16. It can be enlarged, but the register file
  /// needs to be adapted too.
  localparam int unsigned MaxNumStreams = 32'd16;
  localparam int unsigned RegAddrWidth  = idma_${identifier}_reg_pkg::IDMA_${identifier.upper()}_REG_TOP_MIN_ADDR_WIDTH;

  // register connections
  idma_${identifier}_reg_pkg::idma_reg__out_t dma_reg2hw [NumRegs-1:0];
  idma_${identifier}_reg_pkg::idma_reg__in_t  dma_hw2reg [NumRegs-1:0];

  // arbitration output
  dma_req_t [NumRegs-1:0] arb_dma_req;
  logic     [NumRegs-1:0] arb_valid;
  logic     [NumRegs-1:0] arb_ready;

  // hold the next_id launch across the read-stall (req is masked mid-stall)
  logic [NumRegs-1:0][NumStreams-1:0] nxt_read_seen;
  logic [NumRegs-1:0][NumStreams-1:0] nxt_read_pending_q;

  always_comb begin
      stream_idx_o = '0;
      for (int r = 0; r < NumRegs; r++) begin
          for (int c = 0; c < NumStreams; c++) begin
              if (nxt_read_seen[r][c] || nxt_read_pending_q[r][c]) begin
                  stream_idx_o = c;
              end
          end
      end
  end

  // generate the registers
  for (genvar i = 0; i < NumRegs; i++) begin : gen_core_regs


% if _fam == 'obi':
    // override the reg_top ID width so s_obi_aid/s_obi_rid match the OBI bus id width
    idma_${identifier}_reg_top #(
      .ID_WIDTH ( $bits(dma_ctrl_req_i[i].a.aid) )
    ) i_idma_${identifier}_reg_top (
% else:
    idma_${identifier}_reg_top i_idma_${identifier}_reg_top (
% endif
      .clk    ( clk_i ),
      .arst_n ( rst_ni ),

% if _fam == 'apb':
      .s_apb_psel    ( dma_ctrl_req_i[i].psel                    ),
      .s_apb_penable ( dma_ctrl_req_i[i].penable                 ),
      .s_apb_pwrite  ( dma_ctrl_req_i[i].pwrite                  ),
      .s_apb_pprot   ( dma_ctrl_req_i[i].pprot                   ),
      .s_apb_paddr   ( dma_ctrl_req_i[i].paddr[RegAddrWidth-1:0] ),
      .s_apb_pwdata  ( dma_ctrl_req_i[i].pwdata                  ),
      .s_apb_pstrb   ( dma_ctrl_req_i[i].pstrb                   ),
      .s_apb_pready  ( dma_ctrl_rsp_o[i].pready                  ),
      .s_apb_prdata  ( dma_ctrl_rsp_o[i].prdata                  ),
      .s_apb_pslverr ( dma_ctrl_rsp_o[i].pslverr                 ),
% elif _fam == 'obi':
      .s_obi_req     ( dma_ctrl_req_i[i].req                     ),
      .s_obi_gnt     ( dma_ctrl_rsp_o[i].gnt                     ),
      .s_obi_addr    ( dma_ctrl_req_i[i].a.addr[RegAddrWidth-1:0] ),
      .s_obi_we      ( dma_ctrl_req_i[i].a.we                    ),
      .s_obi_be      ( dma_ctrl_req_i[i].a.be                    ),
      .s_obi_wdata   ( dma_ctrl_req_i[i].a.wdata                 ),
      .s_obi_aid     ( dma_ctrl_req_i[i].a.aid                   ),
      .s_obi_rvalid  ( dma_ctrl_rsp_o[i].rvalid                  ),
      .s_obi_rready  ( dma_ctrl_req_i[i].rready                  ),
      .s_obi_rdata   ( dma_ctrl_rsp_o[i].r.rdata                 ),
      .s_obi_err     ( dma_ctrl_rsp_o[i].r.err                   ),
      .s_obi_rid     ( dma_ctrl_rsp_o[i].r.rid                   ),
% elif _fam == 'axil':
      .s_axil_awvalid ( dma_ctrl_req_i[i].aw_valid                  ),
      .s_axil_awready ( dma_ctrl_rsp_o[i].aw_ready                  ),
      .s_axil_awaddr  ( dma_ctrl_req_i[i].aw.addr[RegAddrWidth-1:0] ),
      .s_axil_awprot  ( dma_ctrl_req_i[i].aw.prot                   ),
      .s_axil_wvalid  ( dma_ctrl_req_i[i].w_valid                   ),
      .s_axil_wready  ( dma_ctrl_rsp_o[i].w_ready                   ),
      .s_axil_wdata   ( dma_ctrl_req_i[i].w.data                    ),
      .s_axil_wstrb   ( dma_ctrl_req_i[i].w.strb                    ),
      .s_axil_bvalid  ( dma_ctrl_rsp_o[i].b_valid                   ),
      .s_axil_bready  ( dma_ctrl_req_i[i].b_ready                   ),
      .s_axil_bresp   ( dma_ctrl_rsp_o[i].b.resp                    ),
      .s_axil_arvalid ( dma_ctrl_req_i[i].ar_valid                  ),
      .s_axil_arready ( dma_ctrl_rsp_o[i].ar_ready                  ),
      .s_axil_araddr  ( dma_ctrl_req_i[i].ar.addr[RegAddrWidth-1:0] ),
      .s_axil_arprot  ( dma_ctrl_req_i[i].ar.prot                   ),
      .s_axil_rvalid  ( dma_ctrl_rsp_o[i].r_valid                   ),
      .s_axil_rready  ( dma_ctrl_req_i[i].r_ready                   ),
      .s_axil_rdata   ( dma_ctrl_rsp_o[i].r.data                    ),
      .s_axil_rresp   ( dma_ctrl_rsp_o[i].r.resp                    ),
% endif

      .hwif_out  ( dma_reg2hw       [i] ),
      .hwif_in   ( dma_hw2reg       [i] )
    );

    // next_id launch-pending latch: set on read, cleared on grant
    for (genvar c = 0; c < NumStreams; c++) begin : gen_nxt_read_pending
        assign nxt_read_seen[i][c] = dma_reg2hw[i].next_id[c].req
                                   & ~dma_reg2hw[i].next_id[c].req_is_wr;
        always_ff @(posedge clk_i or negedge rst_ni) begin : proc_nxt_read_pending
            if (!rst_ni) begin
                nxt_read_pending_q[i][c] <= 1'b0;
            end else if (nxt_read_pending_q[i][c] & arb_ready[i]) begin
                nxt_read_pending_q[i][c] <= 1'b0;
            end else if (nxt_read_seen[i][c] & ~arb_ready[i]) begin
                nxt_read_pending_q[i][c] <= 1'b1;
            end
        end
    end

    logic read_happens;
    always_comb begin : proc_launch
        read_happens = 1'b0;
        for (int c = 0; c < NumStreams; c++) begin
            read_happens |= nxt_read_seen[i][c] | nxt_read_pending_q[i][c];
        end
        arb_valid[i] = read_happens;
    end

    // assign request struct
    always_comb begin : proc_hw_req_conv
      // all fields are zero per default
      arb_dma_req[i] = '0;

      // address and length
% if bit_width == '32':
      arb_dma_req[i]${sep}length   = dma_reg2hw[i].length[0].length.value;
      arb_dma_req[i]${sep}src_addr = dma_reg2hw[i].src_addr[0].src_addr.value;
      arb_dma_req[i]${sep}dst_addr = dma_reg2hw[i].dst_addr[0].dst_addr.value;
% else:
      arb_dma_req[i]${sep}length   = {dma_reg2hw[i].length[1].length.value,     dma_reg2hw[i].length[0].length.value};
      arb_dma_req[i]${sep}src_addr = {dma_reg2hw[i].src_addr[1].src_addr.value, dma_reg2hw[i].src_addr[0].src_addr.value};
      arb_dma_req[i]${sep}dst_addr = {dma_reg2hw[i].dst_addr[1].dst_addr.value, dma_reg2hw[i].dst_addr[0].dst_addr.value};
% endif

      // Protocols
      arb_dma_req[i]${sep}opt.src_protocol = idma_pkg::protocol_e'(dma_reg2hw[i].conf.src_protocol.value);
      arb_dma_req[i]${sep}opt.dst_protocol = idma_pkg::protocol_e'(dma_reg2hw[i].conf.dst_protocol.value);

      // Current backend only supports incremental burst
      arb_dma_req[i]${sep}opt.src.burst = axi_pkg::BURST_INCR;
      arb_dma_req[i]${sep}opt.dst.burst = axi_pkg::BURST_INCR;
        // this frontend currently does not support cache variations
      arb_dma_req[i]${sep}opt.src.cache = axi_pkg::CACHE_MODIFIABLE;
      arb_dma_req[i]${sep}opt.dst.cache = axi_pkg::CACHE_MODIFIABLE;

      // Backend options
      arb_dma_req[i]${sep}opt.beo.decouple_aw    = dma_reg2hw[i].conf.decouple_aw.value;
      arb_dma_req[i]${sep}opt.beo.decouple_rw    = dma_reg2hw[i].conf.decouple_rw.value;
      arb_dma_req[i]${sep}opt.beo.src_max_llen   = dma_reg2hw[i].conf.src_max_llen.value;
      arb_dma_req[i]${sep}opt.beo.dst_max_llen   = dma_reg2hw[i].conf.dst_max_llen.value;
      arb_dma_req[i]${sep}opt.beo.src_reduce_len = dma_reg2hw[i].conf.src_reduce_len.value;
      arb_dma_req[i]${sep}opt.beo.dst_reduce_len = dma_reg2hw[i].conf.dst_reduce_len.value;

% if num_dim != 1:
      // ND connections
% for nd in range(0, num_dim-1):
% if bit_width == '32':
      arb_dma_req[i].d_req[${nd}].reps = dma_reg2hw[i].dim[${nd}].reps[0].reps.value;
      arb_dma_req[i].d_req[${nd}].src_strides = dma_reg2hw[i].dim[${nd}].src_stride[0].src_stride.value;
      arb_dma_req[i].d_req[${nd}].dst_strides = dma_reg2hw[i].dim[${nd}].dst_stride[0].dst_stride.value;
% else:
      arb_dma_req[i].d_req[${nd}].reps = {dma_reg2hw[i].dim[${nd}].reps[1].reps.value,
                                      dma_reg2hw[i].dim[${nd}].reps[0].reps.value };
      arb_dma_req[i].d_req[${nd}].src_strides = {dma_reg2hw[i].dim[${nd}].src_stride[1].src_stride.value,
                                             dma_reg2hw[i].dim[${nd}].src_stride[0].src_stride.value};
      arb_dma_req[i].d_req[${nd}].dst_strides = {dma_reg2hw[i].dim[${nd}].dst_stride[1].dst_stride.value,
                                             dma_reg2hw[i].dim[${nd}].dst_stride[0].dst_stride.value};
% endif
% endfor

      // Disable higher dimensions
      if ( dma_reg2hw[i].conf.enable_nd.value == 0) begin
% for nd in range(0, num_dim-1):
        arb_dma_req[i].d_req[${nd}].reps = ${"'0" if nd != num_dim-2 else "'d1"};
% endfor
      end
% for nd in range(1, num_dim-1):
      else if ( dma_reg2hw[i].conf.enable_nd.value == ${nd}) begin
% for snd in range(nd, num_dim-1):
        arb_dma_req[i].d_req[${snd}].reps = 'd1;
% endfor
      end
% endfor
% endif
    end

    // observational registers
    for (genvar c = 0; c < NumStreams; c++) begin : gen_hw2reg_connections
        assign dma_hw2reg[i].status[c].rd_data.busy  = {midend_busy_i[c], busy_i[c]};
        assign dma_hw2reg[i].status[c].rd_ack = dma_reg2hw[i].status[c].req
                                              & ~dma_reg2hw[i].status[c].req_is_wr;
        assign dma_hw2reg[i].next_id[c].rd_data.next_id = next_id_i;
        assign dma_hw2reg[i].next_id[c].rd_ack = (nxt_read_seen[i][c] | nxt_read_pending_q[i][c])
                                               & arb_ready[i];
        assign dma_hw2reg[i].done_id[c].rd_data.done_id = done_id_i[c];
        assign dma_hw2reg[i].done_id[c].rd_ack = dma_reg2hw[i].done_id[c].req
                                               & ~dma_reg2hw[i].done_id[c].req_is_wr;
    end

    // tie-off unused channels
    for (genvar c = NumStreams; c < MaxNumStreams; c++) begin : gen_hw2reg_unused
        assign dma_hw2reg[i].status[c].rd_data = '0;
        assign dma_hw2reg[i].status[c].rd_ack  = '0;
        assign dma_hw2reg[i].next_id[c].rd_data.next_id = '0;
        assign dma_hw2reg[i].next_id[c].rd_ack = '0;
        assign dma_hw2reg[i].done_id[c].rd_data.done_id = '0;
        assign dma_hw2reg[i].done_id[c].rd_ack = '0;
    end

  end

  // arbitration
  rr_arb_tree #(
    .NumIn     ( NumRegs   ),
    .DataType  ( dma_req_t ),
    .ExtPrio   ( 0         ),
    .AxiVldRdy ( 1         ),
    .LockIn    ( 1         )
  ) i_rr_arb_tree (
    .clk_i,
    .rst_ni,
    .flush_i ( 1'b0        ),
    .rr_i    ( '0          ),
    .req_i   ( arb_valid   ),
    .gnt_o   ( arb_ready   ),
    .data_i  ( arb_dma_req ),
    .gnt_i   ( req_ready_i ),
    .req_o   ( req_valid_o ),
    .data_o  ( dma_req_o   ),
    .idx_o   ( /* NC */    )
  );

endmodule
